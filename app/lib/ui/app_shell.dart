import 'dart:async';

import 'package:flutter/material.dart';

import '../core/theme.dart';
import '../data/auth_store.dart';
import '../data/store.dart';
import 'screens/customers_screen.dart';
import 'screens/delivery_notes_screen.dart';
import 'screens/generator_screen.dart';
import 'screens/insights_screen.dart';
import 'screens/invoices_screen.dart';
import 'screens/mils_screen.dart';
import 'screens/notifications_screen.dart';
import 'screens/receipts_screen.dart';
import 'screens/sales_screen.dart';
import 'screens/staff_screen.dart';
import 'screens/stock_screen.dart';
import 'screens/settings_screen.dart';
import 'screens/summary_screen.dart';
import 'screens/transactions_screen.dart';
import 'screens/waybills_screen.dart';
import 'watermark_background.dart';

class Destination {
  final String id;
  final String label;
  final IconData icon;
  final IconData selectedIcon;
  final Widget screen;
  const Destination(this.id, this.label, this.icon, this.selectedIcon, this.screen);
}

const _insights = Destination('insights', 'Insights', Icons.insights_outlined, Icons.insights, InsightsScreen());
const _transactions = Destination('transactions', 'Transactions', Icons.swap_horiz_outlined, Icons.swap_horiz, TransactionsScreen());
const _customers = Destination('customers', 'Customers', Icons.people_outline, Icons.people, CustomersScreen());
const _receipts = Destination('receipts', 'Receipts', Icons.receipt_long_outlined, Icons.receipt_long, ReceiptsScreen());
const _invoices = Destination('invoices', 'Invoices', Icons.request_quote_outlined, Icons.request_quote, InvoicesScreen());
const _waybills = Destination('waybills', 'Waybills', Icons.local_shipping_outlined, Icons.local_shipping, WaybillsScreen());
const _deliveryNotes = Destination('deliverynotes', 'Delivery Notes', Icons.inventory_2_outlined, Icons.inventory_2, DeliveryNotesScreen());
const _mils = Destination('mils', 'MILS', Icons.build_circle_outlined, Icons.build_circle, MilsScreen());
const _sales = Destination('sales', 'Sales', Icons.point_of_sale_outlined, Icons.point_of_sale, SalesScreen());
const _stock = Destination('stock', 'Stock', Icons.inventory_2_outlined, Icons.inventory_2, StockScreen());
const _summary = Destination('summary', 'Summary', Icons.summarize_outlined, Icons.summarize, SummaryScreen());
const _docs = Destination('docs', 'Documents', Icons.draw_outlined, Icons.draw, GeneratorScreen());
const _notifications = Destination('notifications', 'Notifications', Icons.notifications_outlined, Icons.notifications, NotificationsScreen());
const _staff = Destination('staff', 'Staff', Icons.badge_outlined, Icons.badge, StaffScreen());

const _settings = Destination('settings', 'Settings', Icons.settings_outlined, Icons.settings, SettingsScreen());

/// Admin sees everything; Sales never sees revenue/profit/settings (SPEC §6).
/// Notifications are visible to every role (owner directive 2026-09-01 —
/// "any user" gets notified of every transaction); Staff is CEO/Admin-only
/// (view for both, but only the CEO can actually change a role).
List<Destination> destinationsFor(String? role) {
  // Authority: CEO > Admin > Sales. Settings is visible to EVERY role
  // (owner directive 2026-09-01) — Account/Recovery/Preferences/About are
  // universal, while the management controls inside it (VAT, serial reseed,
  // stock seed import) stay CEO-only. Stock editing is CEO/Admin.
  if (role == 'ceo' || role == 'admin') return _allDestinations;
  return const [
    _sales, _stock, _customers, _receipts, _invoices, _waybills, _deliveryNotes, _docs, _notifications, _settings,
  ];
}

/// The complete management destination set (CEO view).
const _allDestinations = <Destination>[
  _insights, _transactions, _customers, _receipts, _invoices, _waybills, _deliveryNotes,
  _mils, _sales, _stock, _summary, _docs, _notifications, _staff, _settings,
];

/// Kept for backwards compatibility (admin view).
const destinations = <Destination>[
  _insights, _transactions, _customers, _receipts, _invoices, _waybills, _deliveryNotes,
  _mils, _sales, _stock, _summary, _docs, _notifications, _staff, _settings,
];

/// Primary destinations for the phone bottom bar; everything else lives
/// behind "More" (opens the drawer).
const _bottomBarIndexes = [0, 8, 9, 7]; // Insights, Sales, Stock, MILS

/// Responsive shell — four tiers:
///   ≥1280px : NavigationRail with extended labels (desktop)
///   ≥1000px : compact NavigationRail (small desktop / tablet landscape)
///    ≥640px : drawer + AppBar menu (tablet portrait / large phones)
///    <640px : bottom NavigationBar (5 slots incl. "More") + drawer
class AppShell extends StatefulWidget {
  const AppShell({super.key});

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> {
  int _index = 0;
  final _scaffoldKey = GlobalKey<ScaffoldState>();
  Timer? _notifyTimer;

  List<Destination> get _visible => destinationsFor(AuthStore.instance.current?.role);

  @override
  void initState() {
    super.initState();
    // Poll for new notifications every 20s — every signed-in user (CEO,
    // Admin, Sales) sees the same live feed (owner directive 2026-09-01).
    unawaited(AppStore.instance.refreshNotifications());
    _notifyTimer = Timer.periodic(const Duration(seconds: 20), (_) {
      unawaited(AppStore.instance.refreshNotifications());
    });
  }

  @override
  void dispose() {
    _notifyTimer?.cancel();
    super.dispose();
  }

  void _openNotifications() {
    final i = _visible.indexWhere((d) => d.id == 'notifications');
    if (i != -1) setState(() => _index = i);
  }

  @override
  Widget build(BuildContext context) {
    final w = MediaQuery.of(context).size.width;
    final extended = w >= 1280;
    final useRail = w >= 1000;
    final useBottomBar = w < 640;
    final visible = _visible;
    if (_index >= visible.length) _index = 0;
    final dest = visible[_index];

    final appBar = AppBar(
      title: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Image.asset('assets/branding/logo.png', height: 34,
                errorBuilder: (_, __, ___) => const SizedBox.shrink()),
          ),
          const SizedBox(width: 10),
          Flexible(child: Text(dest.label, style: const TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        ],
      ),
      actions: [
        AnimatedBuilder(
          animation: AppStore.instance,
          builder: (context, _) {
            final unread = AppStore.instance.unreadNotificationCount;
            return IconButton(
              tooltip: 'Notifications',
              icon: Badge(
                label: Text('$unread'),
                isLabelVisible: unread > 0,
                child: const Icon(Icons.notifications_outlined),
              ),
              onPressed: _openNotifications,
            );
          },
        ),
        Padding(
          padding: const EdgeInsets.only(right: 8),
          child: Center(
            child: Text(AuthStore.instance.current?.role.toUpperCase() ?? '',
                style: const TextStyle(fontSize: 11, letterSpacing: 1)),
          ),
        ),
        IconButton(
          tooltip: 'Sign out',
          icon: const Icon(Icons.logout),
          onPressed: () => AuthStore.instance.signOut(),
        ),
      ],
      leading: useRail
          ? null
          : IconButton(
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
    );

    Widget body;
    if (useRail) {
      body = Row(children: [
        _rail(extended: extended),
        Expanded(
          child: Stack(children: [
            const Positioned.fill(child: WatermarkBackground()),
            dest.screen,
          ]),
        ),
      ]);
    } else {
      body = Stack(children: [
        const Positioned.fill(child: WatermarkBackground()),
        dest.screen,
      ]);
    }

    return Scaffold(
      key: _scaffoldKey,
      appBar: appBar,
      drawer: useRail ? null : _drawer(context),
      body: body,
      bottomNavigationBar: useBottomBar ? _bottomBar() : null,
    );
  }

  Widget _rail({required bool extended}) {
    return NavigationRail(
      selectedIndex: _index,
      onDestinationSelected: (i) => setState(() => _index = i),
      extended: extended,
      labelType: extended ? null : NavigationRailLabelType.all,
      leading: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(10),
          child: Image.asset('assets/branding/logo.png', width: 40, height: 40,
              errorBuilder: (_, __, ___) => const SizedBox.shrink()),
        ),
      ),
      destinations: [
        for (final d in _visible)
          NavigationRailDestination(
            icon: Icon(d.icon),
            selectedIcon: Icon(d.selectedIcon),
            label: Text(d.label),
          ),
      ],
    );
  }

  Widget _bottomBar() {
    final moreSelected = !_bottomBarIndexes.contains(_index);
    final visibleBottom = AuthStore.instance.isManagement
        ? _bottomBarIndexes.where((i) => i < _visible.length).toList()
        : [for (var i = 0; i < _visible.length && i < 4; i++) i];
    return NavigationBar(
      height: 64,
      selectedIndex: visibleBottom.indexOf(_index) == -1
          ? visibleBottom.length
          : visibleBottom.indexOf(_index),
      onDestinationSelected: (i) {
        if (i < visibleBottom.length) {
          setState(() => _index = visibleBottom[i]);
        } else {
          _scaffoldKey.currentState?.openDrawer();
        }
      },
      destinations: [
        for (final idx in visibleBottom)
          NavigationDestination(
            icon: Icon(_visible[idx].icon),
            selectedIcon: Icon(_visible[idx].selectedIcon),
            label: _visible[idx].label,
          ),
        const NavigationDestination(
          icon: Icon(Icons.menu),
          selectedIcon: Icon(Icons.menu),
          label: 'More',
        ),
      ],
    );
  }

  Widget _drawer(BuildContext context) {
    return NavigationDrawer(
      selectedIndex: _index,
      onDestinationSelected: (i) {
        setState(() => _index = i);
        Navigator.pop(context);
      },
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(28, 24, 16, 12),
          child: Text('M-Tek Fire & Safety',
              style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16, color: Colors.white)),
        ),
        for (final d in _visible)
          NavigationDrawerDestination(icon: Icon(d.icon), label: Text(d.label)),
      ],
    );
  }
}
