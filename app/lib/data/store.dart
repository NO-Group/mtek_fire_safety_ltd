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
///   3. every mutation PERSISTS locally and enqueues a sync record,
///   4. a sync flush pushes the queue to Supabase REST when configured
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
  final List<Map<String, dynamic>> _syncQueue = [];
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
    if (Env.apiConfigured) {
      _api = ApiClient(baseUrl: Env.apiBase);
    }
    var loadedAny = false;
    if (Env.apiConfigured && AuthStore.instance.accessToken != null) {
      loadedAny = await _loadRemote();
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
        // identity so a promoted/demoted account (e.g. the CEO) reflects
        // immediately on the next data reload — no re-login required.
        final cur = AuthStore.instance.current;
        if (remoteRole.isNotEmpty && cur != null && cur.role != remoteRole) {
          cur.role = remoteRole;
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
        if (e is Map) {
          final m = (e).cast<String, dynamic>();
          invoices.add(Invoice(
            number: '${m['no'] ?? ''}',
            issued: DateTime.tryParse('${m['created_at']}') ?? DateTime.now(),
            due: (DateTime.tryParse('${m['created_at']}') ?? DateTime.now())
                .add(const Duration(days: 14)),
            customer: customers.firstWhere(
                (x) => x.id == '${m['customer_id'] ?? ''}',
                orElse: () => Customer(
                    id: 'inv', name: '${m['customer_name'] ?? '—'}',
                    isCorporate: false, phone: '', email: '', address: '')),
            items: const [],
            amountPaid: _asInt(m['amount_paid']),
          ));
        }
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
      return products.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  /// Clears local collections and pulls the live dataset again (called right
  /// after a successful sign-in, so the app lands on real server data).
  Future<void> reloadRemote() async {
    if (!Env.apiConfigured || _api == null) return;
    _api!.accessToken = AuthStore.instance.accessToken;
    products.clear();
    customers.clear();
    sales.clear();
    transactions.clear();
    receipts.clear();
    invoices.clear();
    milsLogs.clear();
    adjustments.clear();
    docHistory.clear();
    final okRemote = await _loadRemote();
    if (okRemote) await _persistAll();
    notifyListeners();
    pushHomeWidgetStats();
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
    final api = _api;
    if (!Env.apiConfigured || api == null || AuthStore.instance.accessToken == null) return;
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

  // ------------------------------------------------------------------ staff
  /// CEO/Admin staff directory (name/email/phone/role). Only the CEO can
  /// actually change a role via [setStaffRole] — the server enforces this
  /// too, so an Admin calling it will get a 403 back.
  Future<void> refreshStaff() async {
    final api = _api;
    if (!Env.apiConfigured || api == null || AuthStore.instance.accessToken == null) return;
    api.accessToken = AuthStore.instance.accessToken;
    try {
      final res = await api.get('/api/staff');
      if (res == null || !res.ok || res.json is! Map) return;
      final list = (res.json as Map)['staff'];
      if (list is! List) return;
      staff
        ..clear()
        ..addAll([
          for (final e in list)
            if (e is Map) StaffMember.fromJson(e.cast<String, dynamic>()),
        ]);
      notifyListeners();
    } catch (_) {
      // offline — keep whatever was last loaded
    }
  }

  /// CEO-only: promotes a Sales staffer to Admin, or demotes an Admin back
  /// to Sales. Throws (as a message string) on any refusal — including a
  /// non-CEO caller, since the server is the source of truth on authority.
  Future<String?> setStaffRole(String uid, String role) async {
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
    if (!serverApplied) {
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
    if (!serverApplied) {
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
    if (rawProducts.isEmpty && rawCustomers.isEmpty) return false;

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
    notifyListeners();
    return added;
  }

  // ---------------------------------------------------------------- sync
  void enqueueSync(String table, List<Map<String, dynamic>> rows) {
    _syncQueue.add({'table': table, 'rows': rows, 'at': DateTime.now().toIso8601String()});
    writeStore('sync_queue', _syncQueue);
  }

  /// Pushes the offline queue to Supabase (PostgREST). No-op when the
  /// backend isn't configured or the device is offline — the queue stays.
  Future<void> flushSyncQueue() async {
    if (!Env.apiConfigured || _api == null || _syncQueue.isEmpty) return;
    if (AuthStore.instance.accessToken != null) _api!.accessToken = AuthStore.instance.accessToken;
    // Offline-made mutations are replayed to the data API, collection by
    // collection (never on a failing server response — those stay queued).
    const endpoints = {
      'products': '/api/products/upsert',
      'customers': '/api/customers',
    };
    final pending = List.of(_syncQueue);
    for (final job in pending) {
      final table = job['table'] as String;
      final path = endpoints[table];
      if (path == null) { _syncQueue.remove(job); continue; } // sales/etc are RPC-backed now
      final rows = job['rows'] as List<dynamic>;
      try {
        final res = await _api!.post(path, table == 'products'
            ? {'products': rows}
            : (rows.isNotEmpty ? rows.first as Map<String, dynamic> : <String, dynamic>{}));
        if (res != null && res.ok) _syncQueue.remove(job);
      } catch (_) {
        break; // server refused — keep the queue for the next flush
      }
    }
    await writeStore('sync_queue', _syncQueue);
  }

  // ---------------------------------------------------------------- docs
  /// Persists a generated document (Phase A flow) into history + serials.
  Future<IssuedDocument> issueDocument({
    required String type,
    required int serial,
    required String customer,
    required double total,
    required String signedBy,
    required String verifyHash,
    bool serverIssued = false,
  }) async {
    final doc = IssuedDocument(
      type: type,
      serial: serial,
      customer: customer,
      total: total,
      signedBy: signedBy,
      verifyHash: verifyHash,
      issuedAt: DateTime.now(),
    );
    docHistory.insert(0, doc);
    await writeStore('doc_history', docHistory.map((d) => d.toJson()).toList());
    if (!serverIssued) {
      // server already recorded it via mtek_issue_document — local mirror only
      enqueueSync('documents', [doc.toJson()]);
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
      // only queue when the server has NOT already applied this sale
      enqueueSync('sales', [saleToJson(sale)]);
      unawaited(flushSyncQueue());
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
    if (!serverApplied) {
      enqueueSync('invoices', [invoiceToJson(invoices[idx])]);
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
    if (!serverApplied) {
      enqueueSync('mils_logs', [milsLogToJson(log)]);
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
    if (!serverApplied) {
      enqueueSync('stock_adjustments', [adjToJson(adj)]);
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
    unawaited(() async {
      await writeStore('customers', customers.map(customerToJson).toList());
      enqueueSync('customers', [customerToJson(c)]);
      unawaited(flushSyncQueue());
    }());
    notifyListeners();
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
      'amount_paid': i.amountPaid, 'total': i.total,
    };

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

