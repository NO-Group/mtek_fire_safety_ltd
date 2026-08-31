import 'models.dart';

/// Parses the owner-editable stock seed file (seed/products_seed.txt).
/// Format: optional leading `#` comment lines, then a TAB-separated header:
///   ID · NAME · CATEGORY · COST PRICE (NGN) · SELLING PRICE (NGN) ·
///   QTY / OPENING BALANCE · REORDER LEVEL · UNIT · NOTES
/// Column lookup is header-name based, so the owner can reorder columns.
List<Product> parseSeedTsv(String tsv) {
  final lines = tsv
      .split('\n')
      .map((l) => l.trimRight())
      .where((l) => l.isNotEmpty && !l.startsWith('#'))
      .toList();
  if (lines.isEmpty) return const [];

  final headers = lines.first.split('\t').map((h) => h.trim().toUpperCase()).toList();
  int col(String needle) {
    for (var i = 0; i < headers.length; i++) {
      final h = headers[i];
      if (h == needle || h.startsWith(needle)) return i;
    }
    return -1;
  }

  final cId = col('ID');
  final cName = col('NAME');
  final cCat = col('CATEGORY');
  final cCost = col('COST PRICE');
  final cSell = col('SELLING PRICE');
  final cQty = col('QTY');
  final cReorder = col('REORDER');
  final cUnit = col('UNIT');
  final cService = col('SERVICE');

  final out = <Product>[];
  for (var i = 1; i < lines.length; i++) {
    final cells = lines[i].split('\t');
    String cell(int idx) => idx >= 0 && idx < cells.length ? cells[idx].trim() : '';
    final id = cell(cId);
    final name = cell(cName);
    if (id.isEmpty || name.isEmpty) continue;
    out.add(Product(
      id: id,
      name: name,
      category: categoryFromName(cell(cCat)),
      costPrice: numFrom(cell(cCost)),
      sellingPrice: numFrom(cell(cSell)),
      qtyOnHand: numFrom(cell(cQty)),
      reorderLevel: numFrom(cell(cReorder)),
      unit: cell(cUnit).isEmpty ? 'pcs' : cell(cUnit),
      isService: cell(cService).toUpperCase() == 'YES',
    ));
  }
  return out;
}

ProductCategory categoryFromName(String raw) {
  final n = raw.trim().toLowerCase();
  if (n.startsWith('safety')) return ProductCategory.safety;
  if (n.startsWith('security')) return ProductCategory.security;
  if (n.startsWith('solar')) return ProductCategory.solar;
  if (n.startsWith('home') || n.contains('automation') || n.contains('surveillance')) {
    return ProductCategory.automation;
  }
  return ProductCategory.fire;
}

int numFrom(String raw) {
  final cleaned = raw.replaceAll(RegExp(r'[^0-9.]'), '');
  return int.tryParse(cleaned) ?? double.tryParse(cleaned)?.round() ?? 0;
}
