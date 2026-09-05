import 'dart:async';
import 'dart:collection';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../core/format.dart' as fmt;
import '../core/widget_bridge.dart';
import 'api_client.dart';
import 'auth_store.dart';
import 'env.dart';
import 'local_store.dart';
import 'models.dart';
import 'rest_client.dart';
import '../documents/serial_service.dart';
import 'seed_import.dart';

// re-export for callers that imported it from here
export 'models.dart';
export 'seed_import.dart';

/// AppStore — the Phase B data layer. Same observable API the screens were
/// built against, now:
///   1. loads from the LOCAL CACHE (local_store, JSON per collection),
///   2. falls back to the bundled TXT seed (the owner's REAL catalogue),
///   3. every mutation PERSISTS locally (offline key per record),
///   4. a sync flush uploads every record the server does not hold yet
///      to POST /api/sync/import (idempotent) whenever the API is reachable
///      (env.dart) — the app stays fully usable offline (SPEC §5, §12 Phase B).
class AppStore extends ChangeNotifier {
  AppStore._();
  static final AppStore instance = AppStore._();

  final List<Product> products = [];
  final List<Customer> customers = [];
  final List<Sale> sales = [];
  final List<Transaction> transactions = [];
  final List<Receipt> receipts = [];
  final List<Invoice> invoices = [];
  final List<MaintenanceLog> milsLogs = [];
  final List<StockAdjustment> adjustments = [];

  /// Generated-document history (Phase A/B): every PDF the app issued.
  final List<IssuedDocument> docHistory = [];

  StoreSettings settings = StoreSettings();
  bool _loaded = false;
  bool get isLoaded => _loaded;

  /// In-app notifications (every transaction/document/stock/customer/product
  /// change, plus CEO/Admin announcements) — newest first. Populated by
  /// [refreshNotifications], polled periodically by the app shell.
  List<AppNotification> notifications = [];
  int get unreadNotificationCount {
    final uid = AuthStore.instance.remoteSignInUid;
    if (uid == null || uid.isEmpty) return notifications.length;
    return notifications.where((n) => !n.isReadBy(uid)).length;
  }

  /// Staff directory (CEO/Admin only) — populated by [refreshStaff].
  final List<StaffMember> staff = [];

  RestClient? _remote;
  ApiClient? _api;

  /// The live Supabase auth client (null until configured).
  RestClient? get remote => _remote;

  /// The M-TEK data API client (MongoDB sections) — null until configured.
  ApiClient? get api => _api;

  // ---------------------------------------------------------------- init
  Future<void> init() async {
    if (_loaded) return;
    if (Env.supabaseUrl.isNotEmpty) {
      _remote = RestClient(
        baseUrl: Env.supabaseUrl,
        apiKey: Env.supabaseAnonKey,
      );
    }
    if (Env.authApiConfigured) {
      _api = ApiClient(baseUrl: Env.apiBase); // auth routes always; data routes only when apiConfigured
    }
    var loadedAny = false;
    if (Env.apiConfigured && AuthStore.instance.accessToken != null) {
      // OFFLINE → SERVER: anything recorded on this device while the data
      // API was disconnected is uploaded FIRST. Only when nothing is pending
      // (or the upload succeeded) do we switch to the server dataset —
      // otherwise the local files would be overwritten and the offline
      // records silently lost.
      final clean = await _uploadOfflineData();
      if (clean) {
        loadedAny = await _loadRemote();
        if (loadedAny) {
          await _markAllKnown();
        } else {
          _clearAll(); // partial server data must not mix with the local files
        }
      }
    }
    if (!loadedAny) loadedAny = await _loadLocal();
    if (!loadedAny) {
      // STOCK IS NEVER SEEDED (owner directive 2026-08-30): the catalogue
      // starts EMPTY on a fresh install and is filled entirely through the
      // app's own fields (Add product / Import TXT) into MongoDB via the
      // data API. Nothing is bundled, nothing is hard-coded.
    }
    _loaded = true;
    notifyListeners();
    unawaited(flushSyncQueue());
    pushHomeWidgetStats();
  }

  Future<List<dynamic>> _readList(String key) async {
    final raw = await localRead(key);
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  /// LIVE load — one bootstrap call to the data API (MongoDB sections).
  /// Returns true when real data arrived; otherwise offline fallbacks kick in.
  Future<bool> _loadRemote() async {
    final api = _api;
    if (api == null) return false;
    try {
      final res = await api.get('/api/bootstrap');
      if (res == null || !res.ok || res.json is! Map) return false; // offline / not signed in
      final data = (res.json as Map).cast<String, dynamic>();
      final u = data['user'];
      if (u is Map) {
        remoteRole = '${u['role'] ?? ''}';
        // Reconcile the authoritative server role into the signed-in
        // identity so a promoted/demoted account reflects immediately on
        // the next data reload — no re-login required. EXCEPT the CEO, whose
        // role is LOCKED to their email: a stale deployed function that
        // answers role 'sales' must never downgrade the boss to Sales UI.
        final cur = AuthStore.instance.current;
        final lockedCeo = cur != null && cur.email == AuthStore.ceoEmail;
        if (remoteRole.isNotEmpty && cur != null && cur.role != remoteRole && !lockedCeo) {
          cur.role = remoteRole;
          AuthStore.instance.ping();
        }
        if (lockedCeo && cur!.role != 'ceo') {
          cur.role = 'ceo';
          AuthStore.instance.ping();
        }
      }

      products.addAll(parseProducts([
        for (final e in (data['products'] as List? ?? const []))
          if (e is Map) {...(e).cast<String, dynamic>(), 'id': e['_id']},
      ]));
      for (final e in (data['customers'] as List? ?? const [])) {
        if (e is Map) {
          customers.add(parseCustomer(
            {...(e).cast<String, dynamic>(), 'id': e['_id'] ?? ''}));
        }
      }
      final s = data['settings'];
      if (s is Map) {
        settings = StoreSettings.fromJson((s).cast<String, dynamic>());
      }
      SerialService.instance
          .loadFrom((data['serials'] as Map? ?? {}).cast<String, dynamic>());
      for (final e in (data['transactions'] as List? ?? const [])) {
        if (e is Map) {
          final m = (e).cast<String, dynamic>();
          transactions.add(Transaction(
            id: '${m['_id'] ?? ''}',
            date: DateTime.tryParse('${m['txn_date']}') ?? DateTime.now(),
            type: TxnType.values.firstWhere((t) => t.name == m['txn_type'],
                orElse: () => TxnType.salePayment),
            amount: _asInt(m['amount']),
            method: PaymentMethod.values.firstWhere((t) => t.name == m['method'],
                orElse: () => PaymentMethod.cash),
            reference: '${m['reference'] ?? ''}',
          ));
        }
      }
      for (final e in (data['receipts'] as List? ?? const [])) {
        if (e is Map) {
          final m = (e).cast<String, dynamic>();
          receipts.add(Receipt(
            number: '${m['no'] ?? ''}',
            date: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
            customer: Customer(
                id: '${m['customer_id'] ?? 'r'}',
                name: '${m['customer_name'] ?? '—'}',
                isCorporate: false, phone: '', email: '', address: ''),
            amount: _asInt(m['amount']),
            method: PaymentMethod.values.firstWhere((t) => t.name == m['method'],
                orElse: () => PaymentMethod.cash),
            forDoc: '${m['source'] ?? ''}',
            signedBy: '${m['issued_name'] ?? 'Admin'}',
            issuedBy: '${m['issued_name'] ?? 'Admin'}',
            customerSignature: '${m['customer_signature'] ?? ''}',
          ));
        }
      }
      for (final e in (data['invoices'] as List? ?? const [])) {
        if (e is Map) invoices.add(_invoiceFromServer((e).cast<String, dynamic>(), products, customers));
      }
      for (final e in (data['docs'] as List? ?? const [])) {
        if (e is Map) {
          docHistory.add(IssuedDocument.fromJson((e).cast<String, dynamic>()));
        }
      }
      for (final e in (data['sales'] as List? ?? const [])) {
        if (e is Map) sales.add(_saleFromServer((e).cast<String, dynamic>(), products, customers));
      }
      for (final e in (data['adjustments'] as List? ?? const [])) {
        if (e is Map) {
          final adj = _adjustmentFromServer((e).cast<String, dynamic>(), products);
          if (adj != null) adjustments.add(adj);
        }
      }
      for (final e in (data['mils'] as List? ?? const [])) {
        if (e is Map) {
          final log = _milsLogFromServer((e).cast<String, dynamic>(), customers);
          if (log != null) milsLogs.add(log);
        }
      }
      // A successful bootstrap IS the live dataset, even when the catalogue
      // is still empty on the server (fresh cluster) — the device's own
      // records were uploaded just before this call.
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Clears local collections and pulls the live dataset again (called right
  /// after a successful sign-in, so the app lands on real server data).
  Future<void> reloadRemote() async {
    if (!Env.apiConfigured || _api == null) return;
    _api!.accessToken = AuthStore.instance.accessToken;
    // never discard local records the server has not received yet
    if (!await _uploadOfflineData()) return;
    _clearAll();
    final okRemote = await _loadRemote();
    if (okRemote) {
      await _persistAll();
      await _markAllKnown();
    } else {
      _clearAll();
      await _loadLocal();
    }
    notifyListeners();
    pushHomeWidgetStats();
  }

  /// LIVE REFRESH (every page, every device): re-pulls the server dataset
  /// and swaps it in atomically. Called by the app shell on a timer, on app
  /// resume and after pull-to-refresh, so a sale made on one device shows
  /// on every other device within seconds. Pending offline records are
  /// uploaded first; if the server is unreachable the current data is kept.
  bool _refreshing = false;
  DateTime? lastServerSync;
  String _changeStamp = '';

  /// Cheap poll: asks the server for its latest change stamp and only pulls
  /// the full dataset when it differs from the last one seen. Lets the app
  /// poll every few seconds without re-downloading anything.
  Future<void> pollChanges() async {
    if (!Env.apiConfigured || _api == null || AuthStore.instance.accessToken == null) return;
    if (_refreshing || _uploading) return;
    _api!.accessToken = AuthStore.instance.accessToken;
    final res = await _api!.get('/api/changes');
    if (res == null || !res.ok || res.json is! Map) return;
    final stamp = '${(res.json as Map)['stamp'] ?? ''}';
    if (stamp == _changeStamp && lastServerSync != null) return;
    if (await refreshRemote()) _changeStamp = stamp;
  }

  /// Loads history older than what the bootstrap carries (latest 300).
  /// Returns how many rows were appended; false-y when nothing older exists.
  bool _loadingMore = false;
  final Set<String> exhaustedHistory = {};
  Future<int> loadOlder(String kind) async {
    if (!Env.apiConfigured || _api == null || AuthStore.instance.accessToken == null) return 0;
    if (_loadingMore || exhaustedHistory.contains(kind)) return 0;
    _loadingMore = true;
    try {
      _api!.accessToken = AuthStore.instance.accessToken;
      String? before;
      switch (kind) {
        case 'sales': if (sales.isNotEmpty) before = sales.map((s) => s.date).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
        case 'receipts': if (receipts.isNotEmpty) before = receipts.map((s) => s.date).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
        case 'invoices': if (invoices.isNotEmpty) before = invoices.map((s) => s.issued).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
        case 'transactions': if (transactions.isNotEmpty) before = transactions.map((s) => s.date).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
        case 'mils': if (milsLogs.isNotEmpty) before = milsLogs.map((s) => s.serviceDate).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
        case 'docs': if (docHistory.isNotEmpty) before = docHistory.map((s) => s.issuedAt).reduce((a, b) => a.isBefore(b) ? a : b).toIso8601String(); break;
      }
      final q = before == null ? '' : '&before=${Uri.encodeQueryComponent(before)}';
      final res = await _api!.get('/api/history?kind=$kind$q');
      if (res == null || !res.ok || res.json is! Map) return 0;
      final body = res.json as Map;
      final rows = [for (final e in (body['rows'] as List? ?? const [])) if (e is Map) e.cast<String, dynamic>()];
      if (body['more'] != true) exhaustedHistory.add(kind);
      var added = 0;
      for (final m in rows) {
        switch (kind) {
          case 'sales':
            final id = '${m['_id'] ?? ''}';
            if (sales.any((x) => x.id == id)) continue;
            sales.add(_saleFromServer(m, products, customers)); added++;
          case 'receipts':
            final no = '${m['no'] ?? ''}';
            if (receipts.any((x) => x.number == no)) continue;
            receipts.add(Receipt(
              number: no, date: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
              customer: _lookupCustomer(customers, m['customer_id'] as String?, '${m['customer_name'] ?? '—'}'),
              amount: _asInt(m['amount']),
              method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
              forDoc: '${m['source'] ?? ''}', signedBy: '${m['issued_name'] ?? 'Admin'}',
              issuedBy: '${m['issued_name'] ?? 'Admin'}', customerSignature: '${m['customer_signature'] ?? ''}',
            )); added++;
          case 'invoices':
            final no = '${m['no'] ?? ''}';
            if (invoices.any((x) => x.number == no)) continue;
            invoices.add(_invoiceFromServer(m, products, customers)); added++;
          case 'transactions':
            final id = '${m['_id'] ?? ''}';
            if (transactions.any((x) => x.id == id)) continue;
            transactions.add(Transaction(
              id: id, date: DateTime.tryParse('${m['txn_date']}') ?? DateTime.now(),
              type: TxnType.values.firstWhere((t) => t.name == m['txn_type'], orElse: () => TxnType.salePayment),
              amount: _asInt(m['amount']),
              method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
              reference: '${m['reference'] ?? ''}',
            )); added++;
          case 'mils':
            final log = _milsLogFromServer(m, customers);
            if (log == null || milsLogs.any((x) => x.id == log.id)) continue;
            milsLogs.add(log); added++;
          case 'docs':
            final d = IssuedDocument.fromJson(m);
            if (docHistory.any((x) => x.type == d.type && x.serial == d.serial)) continue;
            docHistory.add(d); added++;
        }
      }
      if (added > 0) notifyListeners();
      return added;
    } catch (_) {
      return 0;
    } finally {
      _loadingMore = false;
    }
  }

  Future<bool> refreshRemote() async {
    if (!Env.apiConfigured || _api == null || AuthStore.instance.accessToken == null) return false;
    if (_refreshing || _uploading) return false;
    _refreshing = true;
    try {
      _api!.accessToken = AuthStore.instance.accessToken;
      if (!await _uploadOfflineData()) return false;
      exhaustedHistory.clear();
      // load into the live lists but keep a snapshot to roll back on failure
      final snap = (
        List.of(products), List.of(customers), List.of(sales), List.of(transactions),
        List.of(receipts), List.of(invoices), List.of(milsLogs), List.of(adjustments), List.of(docHistory),
      );
      _clearAll();
      final ok = await _loadRemote();
      if (!ok) {
        _clearAll();
        products.addAll(snap.$1); customers.addAll(snap.$2); sales.addAll(snap.$3);
        transactions.addAll(snap.$4); receipts.addAll(snap.$5); invoices.addAll(snap.$6);
        milsLogs.addAll(snap.$7); adjustments.addAll(snap.$8); docHistory.addAll(snap.$9);
        return false;
      }
      lastServerSync = DateTime.now();
      await _persistAll();
      await _markAllKnown();
      notifyListeners();
      pushHomeWidgetStats();
      return true;
    } catch (_) {
      return false;
    } finally {
      _refreshing = false;
    }
  }

  void _clearAll() {
    products.clear();
    customers.clear();
    sales.clear();
    transactions.clear();
    receipts.clear();
    invoices.clear();
    milsLogs.clear();
    adjustments.clear();
    docHistory.clear();
  }

  /// Pushes the three headline figures onto the Android home-screen widget.
  /// No-op everywhere else (the method channel only exists on Android).
  void pushHomeWidgetStats() {
    final now = DateTime.now();
    var todaySales = 0;
    for (final t in transactions) {
      if (t.date.year == now.year &&
          t.date.month == now.month &&
          t.date.day == now.day) {
        todaySales += t.amount;
      }
    }
    final dueInvoices = invoices.where((i) => i.balance > 0).length;
    unawaited(WidgetBridge.updateStats(
      todaySales: fmt.nairaCompact(todaySales),
      receipts: '${receipts.length}',
      invoices: '$dueInvoices',
    ));
  }

  // ------------------------------------------------------------ notifications
  /// Pulls the latest notifications (transactions, documents, stock,
  /// customers, products, MILS, staff changes, announcements) for every
  /// signed-in user — CEO, Admin and Sales all see the same feed (owner
  /// directive 2026-09-01). Safe to call repeatedly (e.g. from a poll timer).
  Future<void> refreshNotifications() async {
    unawaited(flushSyncQueue()); // piggy-back: retry pending offline uploads
    final api = _api;
    if (!Env.apiConfigured || api == null || AuthStore.instance.accessToken == null) {
      await _loadLocalNotifications();
      return;
    }
    api.accessToken = AuthStore.instance.accessToken;
    try {
      final res = await api.get('/api/notifications');
      if (res == null || !res.ok || res.json is! Map) return;
      final list = (res.json as Map)['notifications'];
      if (list is! List) return;
      notifications
        ..clear()
        ..addAll([
          for (final e in list)
            if (e is Map) AppNotification.fromJson(e.cast<String, dynamic>()),
        ]);
      notifyListeners();
    } catch (_) {
      // offline — keep whatever was last loaded
    }
  }

  /// Marks a notification as read by the current user (idempotent — the
  /// server only appends once per uid) and updates the local copy so the
  /// unread badge count reflects it immediately.
  Future<void> markNotificationRead(String id) async {
    final uid = AuthStore.instance.remoteSignInUid;
    final name = AuthStore.instance.current?.name ?? '';
    final idx = notifications.indexWhere((n) => n.id == id);
    if (idx != -1 && uid != null && !notifications[idx].isReadBy(uid)) {
      notifications[idx] = AppNotification(
        id: notifications[idx].id,
        kind: notifications[idx].kind,
        title: notifications[idx].title,
        message: notifications[idx].message,
        ref: notifications[idx].ref,
        createdBy: notifications[idx].createdBy,
        createdByName: notifications[idx].createdByName,
        createdAt: notifications[idx].createdAt,
        readBy: [
          ...notifications[idx].readBy,
          NotificationRead(uid: uid, name: name, at: DateTime.now()),
        ],
      );
      notifyListeners();
    }
    await _saveLocalNotifications();
    try {
      await _apiPost('/api/notifications/read', {'id': id});
    } catch (_) {
      // best-effort — the read receipt will resync next refresh
    }
  }

  /// Marks EVERY notification as read by the current user (Settings →
  /// Preferences). Updates the local copies immediately so the unread badge
  /// clears, then asks the server to do the same (idempotent — each uid is
  /// only appended to a notification's `read_by` once).
  Future<void> markAllNotificationsRead() async {
    final uid = AuthStore.instance.remoteSignInUid;
    final name = AuthStore.instance.current?.name ?? '';
    if (uid != null && uid.isNotEmpty) {
      notifications = [
        for (final n in notifications)
          if (!n.isReadBy(uid))
            AppNotification(
              id: n.id,
              kind: n.kind,
              title: n.title,
              message: n.message,
              ref: n.ref,
              createdBy: n.createdBy,
              createdByName: n.createdByName,
              createdAt: n.createdAt,
              readBy: [
                ...n.readBy,
                NotificationRead(uid: uid, name: name, at: DateTime.now()),
              ],
            )
          else
            n,
      ];
      notifyListeners();
    }
    await _saveLocalNotifications();
    try {
      await _apiPost('/api/notifications/read-all', {});
    } catch (_) {
      // best-effort — the read receipts will resync on the next refresh
    }
  }

  /// CEO/Admin-only: broadcasts an announcement, which lands in every
  /// user's notification feed exactly like a transaction notification, but
  /// with kind 'announcement' so the UI can show it distinctly and the
  /// sender can see who has read it via `readBy`.
  Future<String?> sendAnnouncement(String title, String message) async {
    if (!Env.apiConfigured) {
      if (title.trim().isEmpty) return 'Announcement title is required';
      if (message.trim().isEmpty) return 'Announcement message is required';
      await addLocalNotification('announcement', title.trim(), message.trim(), '');
      return null;
    }
    try {
      final applied = await _apiPost('/api/announcements', {'title': title, 'message': message});
      if (!applied) return 'Network unreachable — check your connection';
      await refreshNotifications();
      return null;
    } catch (e) {
      debugPrint('sendAnnouncement failed: $e');
      final msg = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '';
      return msg.isEmpty ? 'Something went wrong — please try again.' : msg;
    }
  }

  // ---- device-local notification feed (offline-first) ----
  bool _localNotifsLoaded = false;
  Future<void> _loadLocalNotifications() async {
    if (_localNotifsLoaded) return;
    _localNotifsLoaded = true;
    final raw = await _readList('notifications');
    notifications = [
      for (final e in raw)
        if (e is Map) AppNotification.fromJson(e.cast<String, dynamic>()),
    ];
    notifyListeners();
  }

  Future<void> _saveLocalNotifications() =>
      writeStore('notifications', notifications.take(500).map((n) => n.toJson()).toList());

  /// Records an in-app notification on this device (mirrors what the server
  /// used to write for transactions, documents, stock, MILS, announcements).
  Future<void> addLocalNotification(String kind, String title, String message, String ref) async {
    await _loadLocalNotifications();
    final me = AuthStore.instance.current;
    notifications.insert(0, AppNotification(
      id: 'L${DateTime.now().microsecondsSinceEpoch}',
      kind: kind, title: title, message: message, ref: ref,
      createdBy: AuthStore.instance.remoteSignInUid ?? me?.email ?? '',
      createdByName: me?.name ?? '',
      createdAt: DateTime.now(),
      readBy: const [],
    ));
    notifyListeners();
    await _saveLocalNotifications();
  }

  // ------------------------------------------------------------------ staff
  /// CEO/Admin staff directory (name/email/phone/role). Only the CEO can
  /// actually change a role via [setStaffRole] — the server enforces this
  /// too, so an Admin calling it will get a 403 back.
  Future<void> refreshStaff() async {
    final api = _api;
    if (!Env.apiConfigured || api == null || AuthStore.instance.accessToken == null) {
      // OFFLINE-FIRST: the directory is every account known to this device.
      staff
        ..clear()
        ..addAll([
          for (final u in AuthStore.instance.users)
            StaffMember(uid: u.email, name: u.name, email: u.email, phone: '', role: u.role),
        ]);
      notifyListeners();
      return;
    }
    api.accessToken = AuthStore.instance.accessToken;
    try {
      final res = await api.get('/api/staff');
      if (res == null || !res.ok || res.json is! Map) return;
      final list = (res.json as Map)['staff'];
      if (list is! List) return;
      // A historical bootstrap bug could leave duplicate profile documents.
      // Canonicalise by uid first and normalised email second so the locked
      // CEO (and every other staff identity) can render only once.
      final unique = <String, StaffMember>{};
      for (final e in list) {
        if (e is! Map) continue;
        final member = StaffMember.fromJson(e.cast<String, dynamic>());
        final emailKey = member.email.trim().toLowerCase();
        final key = emailKey.isNotEmpty ? 'email:$emailKey' : 'uid:${member.uid}';
        unique[key] = member;
      }
      staff
        ..clear()
        ..addAll(unique.values);
      notifyListeners();
    } catch (_) {
      // offline — keep whatever was last loaded
    }
  }

  /// CEO-only: promotes a Sales staffer to Admin, or demotes an Admin back
  /// to Sales. Throws (as a message string) on any refusal — including a
  /// non-CEO caller, since the server is the source of truth on authority.
  Future<String?> setStaffRole(String uid, String role) async {
    if (!Env.apiConfigured) {
      if (!AuthStore.instance.isCeo) return 'Only the CEO can promote or demote staff';
      final u = AuthStore.instance.users.where((x) => x.email == uid).firstOrNull;
      if (u == null) return 'Staff member not found';
      if (u.role == 'ceo' || u.email == AuthStore.ceoEmail) return 'The CEO role cannot be changed here';
      u.role = role;
      await AuthStore.instance.persistUsers();
      await refreshStaff();
      return null;
    }
    try {
      final applied = await _apiPost('/api/staff/role', {'uid': uid, 'role': role});
      if (!applied) return 'Network unreachable — check your connection';
      await refreshStaff();
      return null;
    } catch (e) {
      debugPrint('setStaffRole failed: $e');
      final msg = e is Exception ? e.toString().replaceFirst('Exception: ', '') : '';
      return msg.isEmpty ? 'Something went wrong — please try again.' : msg;
    }
  }

  /// Role reported by the API for the signed-in user (ceo/admin/sales).
  String remoteRole = '';

  /// Site photos attached to MILS jobs: logId → data URLs. Real captures
  /// from the device camera/gallery (no placeholders).
  final Map<String, List<String>> milsPhotos = {};

  /// CEO/Admin stock import: upsert rows parsed from a products_seed.txt-style
  /// TSV (the owner edits the file, picks it here — no terminal needed).
  Future<int> importProductsTsv(String tsv) async {
    final imported = parseSeedTsv(tsv);
    if (imported.isEmpty) throw Exception('No valid rows found in that file');
    // server first (both builds share the same MongoDB)…
    final serverApplied = await _apiPost('/api/products/upsert', {
      'products': imported.map(productToJson).toList(),
    });
    // …then local cache (+ offline queue when the server was unreachable)
    for (final p in imported) {
      final idx = products.indexWhere((x) => x.id == p.id);
      if (idx == -1) {
        products.add(p);
      } else {
        products[idx] = p;
      }
    }
    await _persistAll();
    if (serverApplied) {
      await _markKnown('products', imported.map(productToJson));
    } else {
      enqueueSync('products', imported.map(productToJson).toList());
      unawaited(flushSyncQueue());
    }
    notifyListeners();
    return imported.length;
  }

  /// CEO/Admin: create a product from the app's own fields (stock is NEVER
  /// pre-seeded — everything is entered here) and push it to the same server
  /// both builds use. Local cache mirrors it; offline it queues for sync.
  Future<void> addProduct(Product p) async {
    final serverApplied = await _apiPost('/api/products/upsert', {
      'products': [productToJson(p)],
    });
    final idx = products.indexWhere((x) => x.id == p.id);
    if (idx == -1) {
      products.add(p);
    } else {
      products[idx] = p;
    }
    await _persistAll();
    if (serverApplied) {
      await _markKnown('products', [productToJson(p)]);
    } else {
      enqueueSync('products', [productToJson(p)]);
      unawaited(flushSyncQueue());
    }
    notifyListeners();
  }

  /// Attach real site photos (data URLs) to a MILS job.
  Future<void> attachMilsPhotos(String logId, List<String> dataUrls) async {
    if (dataUrls.isEmpty) return;
    milsPhotos.putIfAbsent(logId, () => <String>[]).addAll(dataUrls);
    final all = <Map<String, dynamic>>[];
    milsPhotos.forEach((log, urls) {
      for (final u in urls) {
        all.add({'log': log, 'url': u});
      }
    });
    await writeStore('mils_photos', all);
    notifyListeners();
  }

  /// Next document serial — SERVER-assigned when the backend is configured
  /// (atomic RPC, paper-book continuity, passcode re-verified server-side);
  /// local counter otherwise (offline dev).
  Future<int> nextDocSerial({
    required String type,
    required String customer,
    required double total,
    required String passcode,
    String? verifyHash,
    String contact = '', // customer phone OR email — server rejects documents without one
  }) async {
    if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
      final res = await _api!.post('/api/docs/issue', {
        'type': type, 'customer': customer, 'total': total,
        'hash': verifyHash ?? '', 'passcode': passcode,
        'contact': contact,
      });
      if (res != null && res.ok && res.json is Map) {
        final serial = _asInt((res.json as Map)['serial']);
        if (serial > 0) {
          SerialService.instance.reseed(type, serial); // keep peek() in step
          return serial;
        }
      }
      throw Exception(res == null
          ? 'Data API unreachable — document NOT issued offline'
          : 'Document NOT issued — ${(res.json is Map ? (res.json as Map)['error'] : null) ?? 'server refused (check your Signature Passcode)'}');
    }
    return SerialService.instance.next(type);
  }

  Future<bool> _loadLocal() async {
    final rawProducts = await _readList('products');
    final rawCustomers = await _readList('customers');

    products.addAll(parseProducts(rawProducts));
    for (final e in rawCustomers) {
      if (e is Map) customers.add(parseCustomer((e).cast<String, dynamic>()));
    }
    final rawPhotos = await _readList('mils_photos');
    for (final e in rawPhotos) {
      if (e is Map) {
        final m = (e).cast<String, dynamic>();
        milsPhotos.putIfAbsent('${m['log']}', () => <String>[]).add('${m['url']}');
      }
    }
    final rawTxns = await _readList('transactions');
    for (final e in rawTxns) {
      if (e is Map) {
        final m = (e).cast<String, dynamic>();
        transactions.add(Transaction(
          id: '${m['id'] ?? ''}',
          date: DateTime.tryParse('${m['date']}') ?? DateTime.now(),
          type: TxnType.values.firstWhere((t) => t.name == m['type'], orElse: () => TxnType.salePayment),
          amount: _asInt(m['amount']),
          method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
          reference: '${m['reference'] ?? ''}',
        ));
      }
    }
    final rawSettings = await readStore('settings');
    if (rawSettings.isNotEmpty) {
      settings = StoreSettings.fromJson(rawSettings);
    }
    final rawSerials = await readStore('serials');
    if (rawSerials.isNotEmpty) {
      SerialService.instance.loadFrom(rawSerials);
    }
    final rawReceipts = await _readList('receipts');
    for (final e in rawReceipts) {
      if (e is Map) {
        final m = (e).cast<String, dynamic>();
        receipts.add(Receipt(
          number: '${m['number'] ?? ''}',
          date: DateTime.tryParse('${m['date']}') ?? DateTime.now(),
          customer: Customer(id: 'r', name: '${m['customer'] ?? ''}', isCorporate: false, phone: '', email: '', address: ''),
          amount: _asInt(m['amount']),
          method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
          forDoc: '${m['for_doc'] ?? ''}',
          signedBy: '${m['signed_by'] ?? 'Admin'}',
          issuedBy: '${m['issued_by'] ?? 'Admin'}',
        ));
      }
    }
    final rawInvoices = await _readList('invoices');
    for (final e in rawInvoices) {
      if (e is Map) {
        final inv = _invoiceFromLocal((e).cast<String, dynamic>(), products, customers);
        if (inv != null) invoices.add(inv);
      }
    }
    final rawDocs = await _readList('doc_history');
    for (final e in rawDocs) {
      if (e is Map) docHistory.add(IssuedDocument.fromJson((e).cast<String, dynamic>()));
    }
    final rawSales = await _readList('sales');
    for (final e in rawSales) {
      if (e is Map) {
        final s = _saleFromLocal((e).cast<String, dynamic>(), products, customers);
        if (s != null) sales.add(s);
      }
    }
    final rawAdjustments = await _readList('adjustments');
    for (final e in rawAdjustments) {
      if (e is Map) {
        final a = _adjustmentFromLocal((e).cast<String, dynamic>(), products);
        if (a != null) adjustments.add(a);
      }
    }
    final rawMils = await _readList('mils_logs');
    for (final e in rawMils) {
      if (e is Map) {
        final log = _milsLogFromLocal((e).cast<String, dynamic>(), customers);
        if (log != null) milsLogs.add(log);
      }
    }
    return true;
  }

  /// First run: import the owner-editable seed file bundled as an asset
  /// (seed/products_seed.txt workflow — SPEC §8).

  /// Owner sends an edited TXT back → Admin imports it here (Stock screen).
  Future<int> importSeedCsv(String tsv) async {
    final imported = parseSeedTsv(tsv);
    var added = 0;
    for (final p in imported) {
      final idx = products.indexWhere((x) => x.id == p.id);
      if (idx == -1) {
        products.add(p);
        added++;
      } else {
        products[idx] = p;
      }
    }
    await writeStore('products', products.map(productToJson).toList());
    enqueueSync('products', products.map(productToJson).toList());
    unawaited(flushSyncQueue());
    notifyListeners();
    return added;
  }

  // ---------------------------------------------------------------- sync
  // OFFLINE ↔ SERVER RECONCILIATION. Every record has a stable offline key
  // (<device>:<table>:<id>:<date>). `_known` holds the keys the server
  // already has (loaded from it, applied by it, or uploaded). A flush posts
  // every local record NOT in that set to POST /api/sync/import, which is
  // idempotent server-side ($setOnInsert by offline_key), so a retry after a
  // half-failed upload can never duplicate anything.
  final Set<String> _known = {};
  bool _knownLoaded = false;
  String _deviceId = '';
  bool _uploading = false;

  Future<void> _loadSyncState() async {
    if (_knownLoaded) return;
    final st = await readStore('sync_state');
    _deviceId = '${st['device'] ?? ''}';
    if (_deviceId.isEmpty) {
      _deviceId = 'd${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}';
      await writeStore('sync_state', {'device': _deviceId, 'known': const []});
    }
    for (final k in (st['known'] as List? ?? const [])) {
      _known.add('$k');
    }
    _knownLoaded = true;
  }

  Future<void> _saveSyncState() =>
      writeStore('sync_state', {'device': _deviceId, 'known': _known.toList()});

  static final _objectId = RegExp(r'^[0-9a-f]{24}$');
  // Mongo ObjectIds, or customers already uploaded under their offline key
  // (their server _id IS the key, so they come back as '<device>:c:<id>').
  static bool _isServerId(String id) => _objectId.hasMatch(id) || id.contains(':c:');

  /// Offline key for a LOCAL JSON row (the same shape the files hold).
  String? _keyFor(String table, Map<String, dynamic> r) {
    String id;
    switch (table) {
      case 'customers':
        id = '${r['id'] ?? ''}';
        if (id.isEmpty || _isServerId(id)) return null; // server customers need no upload
        return '$_deviceId:c:$id';
      case 'products':
        id = '${r['id'] ?? ''}';
        return id.isEmpty ? null : '$_deviceId:p:$id';
      case 'sales':
        id = '${r['id'] ?? ''}';
        if (id.isEmpty || _isServerId(id)) return null;
        return '$_deviceId:s:$id:${r['date']}';
      case 'transactions':
        id = '${r['id'] ?? ''}';
        if (id.isEmpty || _isServerId(id)) return null;
        return '$_deviceId:t:$id:${r['date']}';
      case 'receipts':
        id = '${r['number'] ?? ''}';
        return id.isEmpty ? null : '$_deviceId:r:$id:${r['date']}';
      case 'invoices':
        id = '${r['number'] ?? ''}';
        return id.isEmpty ? null : '$_deviceId:i:$id:${r['issued']}';
      case 'documents':
        return '$_deviceId:d:${r['type']}:${r['serial']}';
      case 'mils_logs':
        id = '${r['mils_no'] ?? ''}';
        return id.isEmpty ? null : '$_deviceId:m:$id:${r['service_date']}';
      case 'stock_adjustments':
        id = '${r['id'] ?? ''}';
        if (id.isEmpty || _isServerId(id)) return null;
        return '$_deviceId:a:$id:${r['date']}';
    }
    return null;
  }

  /// Marks rows the SERVER already holds (applied online or loaded from it).
  Future<void> _markKnown(String table, Iterable<Map<String, dynamic>> rows) async {
    await _loadSyncState();
    var changed = false;
    for (final r in rows) {
      final k = _keyFor(table, r);
      if (k != null && _known.add(k)) changed = true;
    }
    if (changed) await _saveSyncState();
  }

  Future<void> _markAllKnown() async {
    await _loadSyncState();
    await _markKnown('customers', customers.map(customerToJson));
    await _markKnown('products', products.map(productToJson));
    await _markKnown('sales', sales.map(saleToJson));
    await _markKnown('transactions', transactions.map(txnToJson));
    await _markKnown('receipts', receipts.map(receiptToJson));
    await _markKnown('invoices', invoices.map(invoiceToJson));
    await _markKnown('documents', docHistory.map((d) => d.toJson()));
    await _markKnown('mils_logs', milsLogs.map(milsLogToJson));
    await _markKnown('stock_adjustments', adjustments.map(adjToJson));
  }

  /// Flags rows as changed so the next flush re-sends them (products carry
  /// their stock level, so an edit must reach the server again).
  void enqueueSync(String table, List<Map<String, dynamic>> rows) {
    if (table != 'products') return; // other tables are append-only by key
    unawaited(() async {
      await _loadSyncState();
      for (final r in rows) {
        final k = _keyFor(table, r);
        if (k != null) _known.remove(k);
      }
      await _saveSyncState();
    }());
  }

  /// Pushes pending offline records to the data API. No-op when the backend
  /// isn't configured or nothing is pending; safe to call often.
  Future<void> flushSyncQueue() async {
    await _uploadOfflineData();
  }

  Future<List<Map<String, dynamic>>> _rows(String file, Iterable<Map<String, dynamic>> Function() live) async {
    if (_loaded) return live().toList();
    return [for (final e in await _readList(file)) if (e is Map) e.cast<String, dynamic>()];
  }

  /// True when nothing is pending or the upload succeeded; false when
  /// offline records still wait (server unreachable / rejected).
  Future<bool> _uploadOfflineData() async {
    if (!Env.apiConfigured || _api == null || AuthStore.instance.accessToken == null) return false;
    if (_uploading) return false;
    _uploading = true;
    try {
      await _loadSyncState();
      _api!.accessToken = AuthStore.instance.accessToken;
      final custRows = await _rows('customers', () => customers.map(customerToJson));
      final prodRows = await _rows('products', () => products.map(productToJson));
      final saleRows = await _rows('sales', () => sales.map(saleToJson));
      final txnRows = await _rows('transactions', () => transactions.map(txnToJson));
      final recRows = await _rows('receipts', () => receipts.map(receiptToJson));
      final invRows = await _rows('invoices', () => invoices.map(invoiceToJson));
      final docRows = await _rows('doc_history', () => docHistory.map((d) => d.toJson()));
      final milsRows = await _rows('mils_logs', () => milsLogs.map(milsLogToJson));
      final adjRows = await _rows('adjustments', () => adjustments.map(adjToJson));
      final serialsRaw = _loaded ? SerialService.instance.toJson() : await readStore('serials');

      final custName = {for (final c in custRows) '${c['id']}': '${c['name'] ?? ''}'};
      String? custRef(dynamic id) {
        final s = '$id';
        if (s.isEmpty || s == 'null') return null;
        if (_isServerId(s)) return s;
        return custName.containsKey(s) ? '$_deviceId:c:$s' : null;
      }
      final prodName = {for (final p in prodRows) '${p['id']}': '${p['name'] ?? ''}'};

      final sent = <String>[];
      List<Map<String, dynamic>> pick(String table, List<Map<String, dynamic>> rows,
          Map<String, dynamic> Function(Map<String, dynamic>) shape) {
        final out = <Map<String, dynamic>>[];
        for (final r in rows) {
          final k = _keyFor(table, r);
          if (k == null || _known.contains(k)) continue;
          out.add({...shape(r), 'offline_key': k});
          sent.add(k);
        }
        return out;
      }

      final payload = <String, dynamic>{
        'device': _deviceId,
        'customers': pick('customers', custRows, (r) => {
          'name': r['name'], 'is_corporate': r['is_corporate'] == true, 'phone': r['phone'],
          'email': r['email'], 'address': r['address'], 'credit_balance': r['credit_balance'],
        }),
        'products': pick('products', prodRows, (r) => r),
        'sales': pick('sales', saleRows, (r) {
          final items = [
            for (final it in (r['items'] as List? ?? const []))
              if (it is Map) {
                'product_id': '${it['product']}', 'name': prodName['${it['product']}'] ?? 'Item',
                'qty': it['qty'], 'unit_price': it['unit_price'],
              }
          ];
          var subtotal = 0;
          for (final it in items) subtotal += _asInt(it['qty']) * _asInt(it['unit_price']);
          return {
            'id': r['id'], 'created_at': r['date'], 'customer_id': custRef(r['customer']),
            'customer_name': custName['${r['customer']}'] ?? 'Walk-in customer',
            'method': r['method'], 'discount': r['discount'], 'items': items,
            'total': subtotal - _asInt(r['discount']) < 0 ? 0 : subtotal - _asInt(r['discount']),
          };
        }),
        'transactions': pick('transactions', txnRows, (r) => {
          'txn_type': r['type'], 'method': r['method'], 'amount': r['amount'],
          'reference': r['reference'], 'txn_date': r['date'],
        }),
        'receipts': pick('receipts', recRows, (r) => {
          'no': r['number'], 'created_at': r['date'], 'amount': r['amount'], 'method': r['method'],
          'source': '${r['for_doc']}'.startsWith('MTK-INV') ? 'invoice' : 'sale',
          'reference': r['for_doc'], 'customer_name': r['customer'], 'issued_name': r['issued_by'],
          'customer_signature': r['customer_signature'],
        }),
        'invoices': pick('invoices', invRows, (r) => {
          'no': r['number'], 'created_at': r['issued'], 'due': r['due'],
          'customer_id': custRef(r['customer_id']), 'customer_name': r['customer'],
          'amount_paid': r['amount_paid'], 'total': r['total'],
          'items': [
            for (final it in (r['items'] as List? ?? const []))
              if (it is Map) {'product_id': '${it['product']}', 'name': it['name'], 'qty': it['qty'], 'unit_price': it['unit_price']}
          ],
        }),
        'documents': pick('documents', docRows, (r) => {
          'doc_type': r['type'], 'serial': r['serial'], 'customer': r['customer'],
          'customer_contact': r['customer_contact'], 'total': r['total'],
          'signed_name': r['signed_by'], 'verify_hash': r['verify_hash'], 'issued_at': r['issued_at'],
        }),
        'mils': pick('mils_logs', milsRows, (r) => {...r, 'customer_id': custRef(r['customer_id'])}),
        'adjustments': pick('stock_adjustments', adjRows, (r) => {
          'product_id': r['product'], 'delta': r['delta'], 'reason': r['reason'],
          'note': r['note'], 'created_at': r['date'],
        }),
        'serials': {
          ...serialsRaw,
          'receiptIssue': recRows.fold<int>(0, (m, r) {
            final n = int.tryParse('${r['number']}'.replaceFirst('MTK-REC-', '')) ?? 0;
            return n > m ? n : m;
          }),
          'invoice': invRows.fold<int>(_asInt(serialsRaw['invoice']), (m, r) {
            final n = int.tryParse('${r['number']}'.replaceFirst('MTK-INV-', '')) ?? 0;
            return n > m ? n : m;
          }),
        },
      };
      if (sent.isEmpty) return true;
      final res = await _api!.post('/api/sync/import', payload);
      if (res == null || !res.ok) {
        debugPrint('offline sync: server unavailable/rejected (${sent.length} pending)');
        return false;
      }
      final body = res.json is Map ? (res.json as Map) : const {};
      final skipped = {for (final k in (body['skipped'] as List? ?? const [])) '$k'};
      _known.addAll(sent.where((k) => !skipped.contains(k)));
      // rows the server refused for this role (e.g. Sales uploading stock
      // edits) are dropped from the retry set too — they would fail forever
      _known.addAll(skipped);
      await _saveSyncState();
      debugPrint('offline sync: uploaded ${sent.length - skipped.length} records');
      return true;
    } catch (e) {
      debugPrint('offline sync failed: $e');
      return false;
    } finally {
      _uploading = false;
    }
  }

  // ---------------------------------------------------------------- docs
  /// Persists a generated document (Phase A flow) into history + serials.
  Future<IssuedDocument> issueDocument({
    required String type,
    required int serial,
    required String customer,
    String customerContact = '',
    required double total,
    required String signedBy,
    required String verifyHash,
    bool serverIssued = false,
  }) async {
    final doc = IssuedDocument(
      type: type,
      serial: serial,
      customer: customer,
      customerContact: customerContact,
      total: total,
      signedBy: signedBy,
      verifyHash: verifyHash,
      issuedAt: DateTime.now(),
    );
    docHistory.insert(0, doc);
    await writeStore('doc_history', docHistory.map((d) => d.toJson()).toList());
    unawaited(addLocalNotification('document', 'Document issued',
        '$signedBy issued $type No ${serial.toString().padLeft(9, '0')} for $customer',
        '$type $serial'));
    if (serverIssued) {
      await _markKnown('documents', [doc.toJson()]); // server archive already has it
    } else {
      unawaited(flushSyncQueue());
    }
    notifyListeners();
    return doc;
  }

  // ------------------------------------------------------------ settings
  Future<void> updateSettings({
    bool? vatEnabled,
    double? vatRate,
    Map<String, int>? serialReseed,
  }) async {
    // CEO-only — enforced again server-side (owner directive 2026-08-30)
    if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
      if (vatEnabled != null || vatRate != null) {
        await _api!.post('/api/settings', {
          'vatEnabled': vatEnabled, 'vatRate': vatRate, 'watermark': null,
        });
      }
      if (serialReseed != null) {
        for (final e in serialReseed.entries) {
          await _api!.post('/api/settings',
              {'reseed': {'type': e.key, 'value': e.value}});
        }
      }
    }
    if (vatEnabled != null) settings = settings.copyWith(vatEnabled: vatEnabled);
    if (vatRate != null) settings = settings.copyWith(vatRate: vatRate);
    if (serialReseed != null) {
      for (final e in serialReseed.entries) {
        SerialService.instance.reseed(e.key, e.value);
      }
    }
    await writeStore('settings', settings.toJson());
    notifyListeners();
  }

  // ------------------------------------------------------- persistence IO
  Future<void> writeStore(String key, Object data) =>
      localWrite(key, jsonEncode(data));

  Future<Map<String, dynamic>> readStore(String key) async {
    final raw = await localRead(key);
    if (raw == null || raw.isEmpty) return {};
    try {
      return jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      return {};
    }
  }

  Future<void> _persistAll() async {
    await writeStore('products', products.map(productToJson).toList());
    await writeStore('customers', customers.map(customerToJson).toList());
    await writeStore('settings', settings.toJson());
    await writeStore('serials', SerialService.instance.toJson());
    await writeStore('sales', sales.map(saleToJson).toList());
    await writeStore('adjustments', adjustments.map(adjToJson).toList());
    await writeStore('mils_logs', milsLogs.map(milsLogToJson).toList());
    await writeStore('transactions', transactions.map(txnToJson).toList());
    await writeStore('receipts', receipts.map(receiptToJson).toList());
    await writeStore('invoices', invoices.map(invoiceToJson).toList());
    await writeStore('doc_history', docHistory.map((d) => d.toJson()).toList());
  }

  // ------------------------------------------------------------ analytics

  /// Net revenue: all payments in, minus refunds.
  int revenue({DateTime? from, DateTime? to}) {
    int sum = 0;
    for (final t in transactions) {
      if (from != null && t.date.isBefore(from)) continue;
      if (to != null && t.date.isAfter(to)) continue;
      sum += t.isRefund ? -t.amount : t.amount;
    }
    return sum;
  }

  int get revenueToday {
    final now = DateTime.now();
    return revenue(
      from: DateTime(now.year, now.month, now.day),
      to: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  int get revenueThisWeek {
    final now = DateTime.now();
    final monday = now.subtract(Duration(days: now.weekday - 1));
    return revenue(
      from: DateTime(monday.year, monday.month, monday.day),
      to: DateTime(now.year, now.month, now.day, 23, 59, 59),
    );
  }

  int get revenueThisMonth {
    final now = DateTime.now();
    return revenue(
      from: DateTime(now.year, now.month),
      to: DateTime(now.year, now.month + 1),
    );
  }

  /// Avg. transaction value = net revenue / paying transactions.
  int avgTransactionValue() {
    final paying = transactions.where((t) => !t.isRefund).length;
    return paying == 0 ? 0 : revenue() ~/ paying;
  }

  /// Revenue grouped by product category (for the breakdown chart).
  Map<ProductCategory, int> revenueByCategory() {
    final byCat = <ProductCategory, int>{};
    for (final sale in sales) {
      for (final item in sale.items) {
        if (sale.method == PaymentMethod.credit && !_invoiceFullyPaid(sale)) {
          continue; // credit counts when the invoice is paid
        }
        byCat[item.product.category] =
            (byCat[item.product.category] ?? 0) + item.total;
      }
    }
    return byCat;
  }

  Map<PaymentMethod, int> revenueByMethod() {
    final byMethod = <PaymentMethod, int>{};
    for (final t in transactions) {
      if (t.isRefund) continue;
      byMethod[t.method] = (byMethod[t.method] ?? 0) + t.amount;
    }
    return byMethod;
  }

  bool _invoiceFullyPaid(Sale sale) => invoices
      .where((i) =>
          i.items.length == sale.items.length && i.total == sale.total)
      .any((i) => i.amountPaid >= i.total);

  int stockValueAtCost() =>
      products.fold(0, (s, p) => s + (p.isService ? 0 : p.costPrice * p.qtyOnHand));

  int outstandingInvoicesTotal() => invoices.fold(0, (s, i) => s + i.balance);

  int estimatedProfit({DateTime? from, DateTime? to}) {
    int profit = 0;
    for (final sale in sales) {
      if (sale.method == PaymentMethod.credit) continue; // recognised on payment
      if (from != null && sale.date.isBefore(from)) continue;
      if (to != null && sale.date.isAfter(to)) continue;
      final cost =
          sale.items.fold(0, (s, i) => s + i.product.costPrice * i.qty);
      profit += sale.total - cost;
    }
    return profit;
  }

  LinkedHashMap<String, int> topProducts({int limit = 5}) {
    final byProduct = <String, int>{};
    final qty = <String, int>{};
    for (final sale in sales) {
      for (final i in sale.items) {
        byProduct[i.product.name] = (byProduct[i.product.name] ?? 0) + i.total;
        qty[i.product.name] = (qty[i.product.name] ?? 0) + i.qty;
      }
    }
    final entries = byProduct.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final out = LinkedHashMap<String, int>();
    for (final e in entries.take(limit)) {
      out['${e.key} ×${qty[e.key]}'] = e.value;
    }
    return out;
  }

  // ------------------------------------------------------------ mutations
  Future<void> completeSale({
    required Customer customer,
    required List<SaleItem> items,
    required PaymentMethod method,
    int discount = 0,
    required String signedBy,
    String? customerSignature,
    String? passcode,
  }) async {
    final now = DateTime.now();
    // SERVER-AUTHENTICATED SALE: stock check, pricing (server prices),
    // decrement, transaction + receipt happen in ONE Supabase RPC. The
    // passcode is re-verified against the bcrypt hash server-side. If the backend
    // is unreachable we fall back to the offline path and sync later.
    String? serverReceiptNo;
    if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
      try {
        final res = await _api!.post('/api/sales', {
          'customerId': customer.id.length > 20 ? customer.id : null,
          'customer': customer.id.length > 20 ? null : {'name': customer.name, 'phone': customer.phone},
          'method': method.name,
          'items': [for (final i in items) {'product_id': i.product.id, 'qty': i.qty}],
          'discount': discount,
          'customer_signature': customerSignature,
          'passcode': passcode ?? '',
        });
        if (res != null && res.ok && res.json is Map) {
          serverReceiptNo = '${(res.json as Map)['receipt_no'] ?? ''}';
        } else if (res != null) {
          throw Exception((res.json is Map ? (res.json as Map)['error'] : null) ?? 'sale rejected');
        }
      } catch (e) {
        debugPrint('completeSale: server refused — offline fallback (${e.toString().split('\n').first})');
        serverReceiptNo = null;
      }
    }
    final sale = Sale(
      id: 'S${sales.length + 1}',
      date: now,
      customer: customer,
      items: List.of(items),
      method: method,
      discount: discount,
    );
    sales.add(sale);
    for (final i in items) {
      final idx = products.indexWhere((p) => p.id == i.product.id);
      if (idx != -1 && !products[idx].isService) {
        products[idx] = products[idx].copyWith(qtyOnHand: products[idx].qtyOnHand - i.qty);
      }
    }
    if (method == PaymentMethod.credit) {
      final number = 'MTK-INV-${(invoices.length + 1).toString().padLeft(4, '0')}';
      invoices.add(Invoice(
        number: number,
        issued: now,
        due: now.add(const Duration(days: 14)),
        customer: customer,
        items: List.of(items),
      ));
    } else {
      _postPayment(date: now, amount: sale.total, method: method, forDoc: sale.id,
          customer: customer, signedBy: signedBy,
          receiptNo: serverReceiptNo, customerSignature: customerSignature);
    }
    final serverApplied = serverReceiptNo != null && serverReceiptNo.isNotEmpty;
    await _persistSaleSide(sale, enqueue: !serverApplied);
    unawaited(addLocalNotification('transaction', 'Sale recorded',
        '$signedBy recorded a ${fmt.naira(sale.total)} sale for ${customer.name}', sale.id));
    notifyListeners();
    pushHomeWidgetStats();
  }

  Future<void> _persistSaleSide(Sale sale, {bool enqueue = true}) async {
    await writeStore('products', products.map(productToJson).toList());
    await writeStore('sales', sales.map(saleToJson).toList());
    await writeStore('transactions', transactions.map(txnToJson).toList());
    await writeStore('receipts', receipts.map(receiptToJson).toList());
    await writeStore('invoices', invoices.map(invoiceToJson).toList());
    if (enqueue) {
      unawaited(flushSyncQueue()); // server did not apply it — upload when reachable
    } else {
      // the server already holds this sale + its receipt/transaction/invoice
      await _markKnown('sales', [saleToJson(sale)]);
      if (transactions.isNotEmpty) await _markKnown('transactions', [txnToJson(transactions.last)]);
      if (receipts.isNotEmpty) await _markKnown('receipts', [receiptToJson(receipts.last)]);
      if (sale.method == PaymentMethod.credit && invoices.isNotEmpty) {
        await _markKnown('invoices', [invoiceToJson(invoices.last)]);
      }
    }
  }

  Future<void> payInvoice(Invoice invoice, int amount, {required String signedBy, String? passcode}) async {
    final idx = invoices.indexOf(invoice);
    final now = DateTime.now();
    String? serverReceiptNo;
    if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
      final res = await _api!.post('/api/invoices/pay', {
        'no': invoice.number, 'amount': amount, 'method': 'transfer',
        'passcode': passcode ?? '',
      });
      if (res != null && res.ok && res.json is Map) {
        serverReceiptNo = '${(res.json as Map)['receipt_no'] ?? ''}';
      }
    }
    invoices[idx] = Invoice(
      number: invoice.number,
      issued: invoice.issued,
      due: invoice.due,
      customer: invoice.customer,
      items: invoice.items,
      amountPaid: invoice.amountPaid + amount,
    );
    _postPayment(date: now, amount: amount, method: PaymentMethod.transfer, forDoc: invoice.number,
        customer: invoice.customer, signedBy: signedBy, receiptNo: serverReceiptNo);
    final serverApplied = serverReceiptNo != null && serverReceiptNo.isNotEmpty;
    await writeStore('invoices', invoices.map(invoiceToJson).toList());
    await writeStore('transactions', transactions.map(txnToJson).toList());
    await writeStore('receipts', receipts.map(receiptToJson).toList());
    if (serverApplied) {
      if (transactions.isNotEmpty) await _markKnown('transactions', [txnToJson(transactions.last)]);
      if (receipts.isNotEmpty) await _markKnown('receipts', [receiptToJson(receipts.last)]);
    } else {
      // re-send the invoice so the server picks up the new amount_paid
      await _loadSyncState();
      final k = _keyFor('invoices', invoiceToJson(invoices[idx]));
      if (k != null) _known.remove(k);
      unawaited(flushSyncQueue());
    }
    notifyListeners();
    pushHomeWidgetStats();
  }

  /// Records a completed maintenance/service job (CEO/Admin — MILS screen +
  /// the MILS document generator both feed this). Server-first via
  /// POST /api/mils; the local mirror keeps the MILS screen usable offline.
  Future<MaintenanceLog> logMaintenance({
    required String equipment,
    String? serial,
    required Customer client,
    required String location,
    required MaintenanceAction action,
    required String findings,
    required String technician,
    DateTime? serviceDate,
    DateTime? nextDue,
    String? milsNo,
  }) async {
    final service = serviceDate ?? DateTime.now();
    final due = nextDue ?? service.add(const Duration(days: 180));
    var log = MaintenanceLog(
      id: milsNo ?? 'MILS-${(milsLogs.length + 1).toString().padLeft(9, '0')}',
      serviceDate: service,
      equipment: equipment,
      serial: serial,
      client: client,
      location: location,
      action: action,
      findings: findings,
      technician: technician,
      nextDue: due,
    );
    var serverApplied = false;
    if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
      try {
        final res = await _api!.post('/api/mils', {
          'equipment': equipment, 'serial': serial,
          'customer_id': client.id.length > 20 ? client.id : null,
          'customer_name': client.name, 'location': location,
          'action': action.name, 'findings': findings, 'technician': technician,
          'service_date': service.toIso8601String(), 'next_due': due.toIso8601String(),
        });
        if (res != null && res.ok && res.json is Map) {
          final serverNo = '${(res.json as Map)['mils_no'] ?? ''}';
          if (serverNo.isNotEmpty) {
            log = MaintenanceLog(
              id: serverNo, serviceDate: service, equipment: equipment, serial: serial,
              client: client, location: location, action: action, findings: findings,
              technician: technician, nextDue: due,
            );
          }
          serverApplied = true;
        }
      } catch (_) {
        serverApplied = false;
      }
    }
    milsLogs.insert(0, log);
    await writeStore('mils_logs', milsLogs.map(milsLogToJson).toList());
    if (serverApplied) {
      await _markKnown('mils_logs', [milsLogToJson(log)]);
    } else {
      unawaited(flushSyncQueue());
    }
    notifyListeners();
    return log;
  }

  Future<void> adjustStock(Product product, int delta, AdjustmentReason reason, String note) async {
    // CEO/Admin only — enforced AGAIN server-side by the RPC (RLS + check)
    final serverApplied = await _apiPost(
        '/api/stock/adjust', {
      'id': product.id, 'delta': delta, 'reason': reason.name, 'note': note,
    });
    final idx = products.indexOf(product);
    products[idx] = product.copyWith(qtyOnHand: products[idx].qtyOnHand + delta);
    final adj = StockAdjustment(
      id: 'ADJ-${adjustments.length + 1}',
      date: DateTime.now(),
      product: products[idx],
      delta: delta,
      reason: reason,
      note: note,
    );
    adjustments.insert(0, adj);
    await writeStore('products', products.map(productToJson).toList());
    await writeStore('adjustments', adjustments.map(adjToJson).toList());
    if (serverApplied) {
      await _markKnown('stock_adjustments', [adjToJson(adj)]);
      await _markKnown('products', [productToJson(products[idx])]);
    } else {
      enqueueSync('products', [productToJson(products[idx])]);
      unawaited(flushSyncQueue());
    }
    notifyListeners();
  }

  /// POSTs to the data API; true when the server applied it (false when
  /// unreachable — callers fall back to the offline queue). Throws when the
  /// server actively refuses (e.g. permission denied).
  Future<bool> _apiPost(String path, Map<String, dynamic> body) async {
    if (!Env.apiConfigured || _api == null) return false;
    if (AuthStore.instance.accessToken != null) _api!.accessToken = AuthStore.instance.accessToken;
    final res = await _api!.post(path, body);
    if (res == null) return false; // unreachable → offline fallback
    if (!res.ok) {
      throw Exception((res.json is Map ? (res.json as Map)['error'] : null) ?? 'request rejected');
    }
    return true;
  }

  void addCustomer(Customer c) {
    customers.add(c);
    notifyListeners();
    unawaited(() async {
      // server-first: create it online so every other device sees it on
      // its next refresh; otherwise it stays local and uploads later
      if (Env.apiConfigured && _api != null && AuthStore.instance.accessToken != null) {
        _api!.accessToken = AuthStore.instance.accessToken;
        final res = await _api!.post('/api/customers', {
          'name': c.name, 'kind': c.isCorporate ? 'corporate' : 'individual',
          'phone': c.phone, 'email': c.email, 'address': c.address,
        });
        if (res != null && res.ok && res.json is Map) {
          final srv = ((res.json as Map)['customer'] as Map?) ?? const {};
          final sid = '${srv['_id'] ?? ''}';
          final idx = customers.indexOf(c);
          if (sid.isNotEmpty && idx != -1) {
            customers[idx] = Customer(id: sid, name: c.name, isCorporate: c.isCorporate,
                phone: c.phone, email: c.email, address: c.address, creditBalance: c.creditBalance);
            notifyListeners();
          }
        }
      }
      await writeStore('customers', customers.map(customerToJson).toList());
      unawaited(flushSyncQueue());
    }());
  }

  void _postPayment({
    required DateTime date,
    required int amount,
    required PaymentMethod method,
    required String forDoc,
    required Customer customer,
    required String signedBy,
    String? receiptNo,
    String? customerSignature,
  }) {
    final txnSeq = transactions.length + 1;
    transactions.add(Transaction(
      id: 'TXN-${txnSeq.toString().padLeft(4, '0')}',
      date: date,
      type: forDoc.startsWith('MTK-INV') ? TxnType.invoicePayment : TxnType.salePayment,
      amount: amount,
      method: method,
      reference: forDoc,
    ));
    receipts.add(Receipt(
      number: (receiptNo == null || receiptNo.isEmpty)
          ? 'MTK-REC-${(receipts.length + 1).toString().padLeft(9, '0')}'
          : receiptNo, // server-assigned (authoritative when online)
      date: date,
      customer: customer,
      amount: amount,
      method: method,
      forDoc: forDoc,
      signedBy: signedBy,
      issuedBy: signedBy,
      customerSignature: customerSignature ?? '',
    ));
  }
}

// ---------------------------------------------------------------- model IO
// Lightweight JSON shims kept beside the store so models stay dependency-free.

Map<String, dynamic> productToJson(Product p) => {
      'id': p.id, 'name': p.name, 'category': p.category.name,
      'cost_price': p.costPrice, 'selling_price': p.sellingPrice,
      'qty_on_hand': p.qtyOnHand, 'reorder_level': p.reorderLevel,
      'unit': p.unit, 'is_service': p.isService,
    };

List<Product> parseProducts(dynamic raw) {
  final list = raw is List ? raw : (raw is Map ? raw['rows'] ?? raw['items'] ?? const [] : const []);
  return list.map<Product>((e) {
    final m = (e as Map).cast<String, dynamic>();
    return Product(
      id: '${m['id'] ?? m['ID'] ?? ''}',
      name: '${m['name'] ?? m['NAME'] ?? ''}',
      category: ProductCategory.values.firstWhere(
        (c) => c.name == (m['category'] ?? ''), orElse: () => ProductCategory.fire),
      costPrice: _asInt(m['cost_price'] ?? m['COST PRICE (NGN)']),
      sellingPrice: _asInt(m['selling_price'] ?? m['SELLING PRICE (NGN)']),
      qtyOnHand: _asInt(m['qty_on_hand'] ?? m['QTY / OPENING BALANCE']),
      reorderLevel: _asInt(m['reorder_level'] ?? m['REORDER LEVEL']),
      unit: '${m['unit'] ?? 'pcs'}',
      isService: m['is_service'] == true,
    );
  }).toList();
}

Customer parseCustomer(Map<String, dynamic> m) => Customer(
      id: '${m['id'] ?? ''}', name: '${m['name'] ?? ''}',
      isCorporate: m['is_corporate'] == true,
      phone: '${m['phone'] ?? ''}', email: '${m['email'] ?? ''}',
      address: '${m['address'] ?? ''}',
      creditBalance: _asInt(m['credit_balance']),
    );

Map<String, dynamic> customerToJson(Customer c) => {
      'id': c.id, 'name': c.name, 'is_corporate': c.isCorporate,
      'phone': c.phone, 'email': c.email, 'address': c.address,
      'credit_balance': c.creditBalance,
    };

Map<String, dynamic> saleToJson(Sale s) => {
      'id': s.id, 'date': s.date.toIso8601String(), 'customer': s.customer.id,
      'items': s.items.map((i) => {'product': i.product.id, 'qty': i.qty, 'unit_price': i.unitPrice}).toList(),
      'discount': s.discount, 'method': s.method.name,
    };

Map<String, dynamic> txnToJson(Transaction t) => {
      'id': t.id, 'date': t.date.toIso8601String(), 'type': t.type.name,
      'amount': t.amount, 'method': t.method.name, 'reference': t.reference,
    };

Map<String, dynamic> receiptToJson(Receipt r) => {
      'number': r.number, 'date': r.date.toIso8601String(),
      'customer_signature': r.customerSignature,
      'customer': r.customer.name, 'amount': r.amount,
      'method': r.method.name, 'for_doc': r.forDoc,
      'signed_by': r.signedBy, 'issued_by': r.issuedBy,
    };

Map<String, dynamic> invoiceToJson(Invoice i) => {
      'number': i.number, 'issued': i.issued.toIso8601String(),
      'due': i.due.toIso8601String(), 'customer': i.customer.name,
      'customer_id': i.customer.id,
      'amount_paid': i.amountPaid, 'total': i.total,
      'items': i.items.map((x) => {'product': x.product.id, 'name': x.product.name, 'qty': x.qty, 'unit_price': x.unitPrice}).toList(),
    };

/// Offline-first: rebuild an invoice from disk. Line items that no longer
/// match a product fall back to a detached product so totals stay right.
Invoice? _invoiceFromLocal(Map<String, dynamic> m, List<Product> products, List<Customer> customers) {
  final number = '${m['number'] ?? ''}';
  if (number.isEmpty) return null;
  final items = <SaleItem>[];
  for (final it in (m['items'] as List? ?? const [])) {
    if (it is! Map) continue;
    final pid = '${it['product'] ?? ''}';
    final found = products.where((p) => p.id == pid).toList();
    final product = found.isNotEmpty
        ? found.first
        : Product(id: pid, name: '${it['name'] ?? 'Item'}', category: ProductCategory.safety, unit: 'unit',
            costPrice: 0, sellingPrice: _asInt(it['unit_price']), qtyOnHand: 0, reorderLevel: 0, isService: true);
    items.add(SaleItem(product: product, qty: _asInt(it['qty']), unitPrice: _asInt(it['unit_price'])));
  }
  if (items.isEmpty) {
    // legacy record without lines — keep the total as one summary line
    final total = _asInt(m['total']);
    if (total <= 0) return null;
    items.add(SaleItem(
        product: Product(id: 'legacy', name: 'Invoice total', category: ProductCategory.safety, unit: 'unit',
            costPrice: 0, sellingPrice: total, qtyOnHand: 0, reorderLevel: 0, isService: true),
        qty: 1, unitPrice: total));
  }
  return Invoice(
    number: number,
    issued: DateTime.tryParse('${m['issued']}') ?? DateTime.now(),
    due: DateTime.tryParse('${m['due']}') ?? DateTime.now(),
    customer: _lookupCustomer(customers, m['customer_id'] as String?, '${m['customer'] ?? '—'}'),
    items: items,
    amountPaid: _asInt(m['amount_paid']),
  );
}

Map<String, dynamic> adjToJson(StockAdjustment a) => {
      'id': a.id, 'date': a.date.toIso8601String(), 'product': a.product.id,
      'delta': a.delta, 'reason': a.reason.name, 'note': a.note,
    };

int _asInt(dynamic v) => v is int ? v : v is num ? v.round() : int.tryParse('$v') ?? 0;

// ---------------------------------------------------- server ↔ UI mapping
// The data API's /api/bootstrap already returns `sales`, `adjustments` and
// `mils` — these turn that server shape into the models the Insights,
// Customers, Stock and MILS screens already read (store.sales,
// store.adjustments, store.milsLogs).

Customer _lookupCustomer(List<Customer> customers, String? id, String fallbackName) {
  if (id != null && id.isNotEmpty) {
    final found = customers.where((c) => c.id == id).toList();
    if (found.isNotEmpty) return found.first;
  }
  return Customer(id: id ?? 'walk-in', name: fallbackName, isCorporate: false, phone: '', email: '', address: '');
}

/// Server invoice → model WITH its line items (the server stores
/// {product_id,name,qty,unit_price} per line; a detached product is built
/// for lines whose product no longer exists so totals stay exact).
Invoice _invoiceFromServer(Map<String, dynamic> m, List<Product> products, List<Customer> customers) {
  final items = <SaleItem>[];
  for (final it in (m['items'] as List? ?? const [])) {
    if (it is! Map) continue;
    final pid = '${it['product_id'] ?? it['product'] ?? ''}';
    final found = products.where((p) => p.id == pid).toList();
    final product = found.isNotEmpty
        ? found.first
        : Product(id: pid, name: '${it['name'] ?? 'Item'}', category: ProductCategory.safety, unit: 'unit',
            costPrice: 0, sellingPrice: _asInt(it['unit_price']), qtyOnHand: 0, reorderLevel: 0, isService: true);
    items.add(SaleItem(product: product, qty: _asInt(it['qty']), unitPrice: _asInt(it['unit_price'])));
  }
  if (items.isEmpty) {
    final total = _asInt(m['total']);
    if (total > 0) {
      items.add(SaleItem(
          product: Product(id: 'legacy', name: 'Invoice total', category: ProductCategory.safety, unit: 'unit',
              costPrice: 0, sellingPrice: total, qtyOnHand: 0, reorderLevel: 0, isService: true),
          qty: 1, unitPrice: total));
    }
  }
  final issued = DateTime.tryParse('${m['created_at']}') ?? DateTime.now();
  return Invoice(
    number: '${m['no'] ?? ''}',
    issued: issued,
    due: DateTime.tryParse('${m['due'] ?? ''}') ?? issued.add(const Duration(days: 14)),
    customer: _lookupCustomer(customers, m['customer_id'] as String?, '${m['customer_name'] ?? '—'}'),
    items: items,
    amountPaid: _asInt(m['amount_paid']),
  );
}

Sale _saleFromServer(Map<String, dynamic> m, List<Product> products, List<Customer> customers) {
  final rawItems = m['items'] as List? ?? const [];
  final items = <SaleItem>[];
  for (final it in rawItems) {
    if (it is! Map) continue;
    final pid = '${it['product_id'] ?? ''}';
    final product = products.where((p) => p.id == pid).toList();
    items.add(SaleItem(
      product: product.isNotEmpty
          ? product.first
          : Product(id: pid, name: '${it['name'] ?? 'Item'}', category: ProductCategory.fire,
              costPrice: 0, sellingPrice: _asInt(it['unit_price']), qtyOnHand: 0, reorderLevel: 0),
      qty: _asInt(it['qty']),
      unitPrice: _asInt(it['unit_price']),
    ));
  }
  return Sale(
    id: '${m['_id'] ?? ''}',
    date: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
    customer: _lookupCustomer(customers, m['customer_id'] as String?, '${m['customer_name'] ?? 'Walk-in customer'}'),
    items: items,
    discount: _asInt(m['discount']),
    method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
  );
}

Sale? _saleFromLocal(Map<String, dynamic> m, List<Product> products, List<Customer> customers) {
  final rawItems = m['items'] as List? ?? const [];
  final items = <SaleItem>[];
  for (final it in rawItems) {
    if (it is! Map) continue;
    final pid = '${it['product'] ?? ''}';
    final product = products.where((p) => p.id == pid).toList();
    if (product.isEmpty) continue;
    items.add(SaleItem(product: product.first, qty: _asInt(it['qty']), unitPrice: _asInt(it['unit_price'])));
  }
  if (items.isEmpty) return null;
  return Sale(
    id: '${m['id'] ?? ''}',
    date: DateTime.tryParse('${m['date']}') ?? DateTime.now(),
    customer: _lookupCustomer(customers, m['customer'] as String?, 'Walk-in customer'),
    items: items,
    discount: _asInt(m['discount']),
    method: PaymentMethod.values.firstWhere((t) => t.name == m['method'], orElse: () => PaymentMethod.cash),
  );
}

StockAdjustment? _adjustmentFromServer(Map<String, dynamic> m, List<Product> products) {
  final pid = '${m['product_id'] ?? ''}';
  final product = products.where((p) => p.id == pid).toList();
  if (product.isEmpty) return null;
  return StockAdjustment(
    id: '${m['_id'] ?? ''}',
    date: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
    product: product.first,
    delta: _asInt(m['delta']),
    reason: AdjustmentReason.values.firstWhere((r) => r.name == m['reason'], orElse: () => AdjustmentReason.correction),
    note: '${m['note'] ?? ''}',
  );
}

StockAdjustment? _adjustmentFromLocal(Map<String, dynamic> m, List<Product> products) {
  final pid = '${m['product'] ?? ''}';
  final product = products.where((p) => p.id == pid).toList();
  if (product.isEmpty) return null;
  return StockAdjustment(
    id: '${m['id'] ?? ''}',
    date: DateTime.tryParse('${m['date']}') ?? DateTime.now(),
    product: product.first,
    delta: _asInt(m['delta']),
    reason: AdjustmentReason.values.firstWhere((r) => r.name == m['reason'], orElse: () => AdjustmentReason.correction),
    note: '${m['note'] ?? ''}',
  );
}

MaintenanceLog? _milsLogFromServer(Map<String, dynamic> m, List<Customer> customers) {
  final equipment = '${m['equipment'] ?? ''}';
  if (equipment.isEmpty) return null;
  return MaintenanceLog(
    id: '${m['mils_no'] ?? m['_id'] ?? ''}',
    serviceDate: DateTime.tryParse('${m['service_date']}') ?? DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
    equipment: equipment,
    serial: m['serial'] as String?,
    client: _lookupCustomer(customers, m['customer_id'] as String?, '${m['customer_name'] ?? '—'}'),
    location: '${m['location'] ?? ''}',
    action: MaintenanceAction.values.firstWhere((a) => a.name == m['action'], orElse: () => MaintenanceAction.refill),
    findings: '${m['findings'] ?? ''}',
    technician: '${m['technician'] ?? m['recorded_name'] ?? ''}',
    nextDue: DateTime.tryParse('${m['next_due']}') ?? DateTime.now().add(const Duration(days: 180)),
  );
}

MaintenanceLog? _milsLogFromLocal(Map<String, dynamic> m, List<Customer> customers) =>
    _milsLogFromServer(m, customers);

Map<String, dynamic> milsLogToJson(MaintenanceLog l) => {
      'mils_no': l.id,
      'service_date': l.serviceDate.toIso8601String(),
      'equipment': l.equipment,
      'serial': l.serial,
      'customer_id': l.client.id,
      'customer_name': l.client.name,
      'location': l.location,
      'action': l.action.name,
      'findings': l.findings,
      'technician': l.technician,
      'next_due': l.nextDue.toIso8601String(),
    };

// ------------------------------------------------------------- settings
class StoreSettings {
  final bool vatEnabled;
  final double vatRate;
  StoreSettings({this.vatEnabled = false, this.vatRate = 0.075});

  StoreSettings copyWith({bool? vatEnabled, double? vatRate}) => StoreSettings(
        vatEnabled: vatEnabled ?? this.vatEnabled,
        vatRate: vatRate ?? this.vatRate,
      );

  Map<String, dynamic> toJson() => {'vat_enabled': vatEnabled, 'vat_rate': vatRate};
  static StoreSettings fromJson(Map<String, dynamic> j) => StoreSettings(
        vatEnabled: j['vat_enabled'] == true,
        vatRate: (j['vat_rate'] as num?)?.toDouble() ?? 0.075,
      );
}

/// One row of the generated-document history (Phase A/B).
class IssuedDocument {
  final String type; // receipt | invoice | mils | waybill | deliverynote
  final int serial;
  final String customer;
  final String customerContact; // phone or email captured on the document
  final double total;
  final String signedBy;
  final String verifyHash;
  final DateTime issuedAt;
  IssuedDocument({
    required this.type,
    required this.serial,
    required this.customer,
    this.customerContact = '',
    required this.total,
    required this.signedBy,
    required this.verifyHash,
    required this.issuedAt,
  });

  Map<String, dynamic> toJson() => {
        'type': type, 'serial': serial, 'customer': customer,
        'customer_contact': customerContact,
        'total': total, 'signed_by': signedBy,
        'verify_hash': verifyHash, 'issued_at': issuedAt.toIso8601String(),
      };
  /// Accepts BOTH shapes: local JSON (type/signed_by/…) and the real
  /// MongoDB archive rows served by /api/bootstrap (doc_type/signed_name/…).
  static IssuedDocument fromJson(Map<String, dynamic> j) => IssuedDocument(
        type: '${j['type'] ?? j['doc_type'] ?? 'doc'}',
        serial: _asInt(j['serial']),
        customer: '${j['customer'] ?? j['customer_name'] ?? '—'}',
        customerContact: '${j['customer_contact'] ?? j['contact'] ?? ''}',
        total: (j['total'] as num?)?.toDouble() ?? 0,
        signedBy: '${j['signed_name'] ?? j['signed_by'] ?? '—'}',
        verifyHash: '${j['verify_hash'] ?? j['hash'] ?? ''}',
        issuedAt: DateTime.tryParse('${j['issued_at'] ?? j['created_at'] ?? ''}') ??
            DateTime.now(),
      );
}

