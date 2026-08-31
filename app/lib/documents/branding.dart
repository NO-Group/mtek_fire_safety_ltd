/// M-Tek corporate branding — EXACT text from the physical forms
/// (docs/forms/FORM_LAYOUTS.md). Used by every PDF header block.
abstract final class MtekBranding {
  static const companyName = 'M-TEK FIRE & SAFETY LTD.';
  static const rcNumber = 'RC: 1082534';

  static const servicesLine =
      '*Sales *Supplies *Installations *Refilling *Maintenance *Training *Consultancy on';

  static const fireEquipment =
      'FIRE EQUIPMENT: FM 200, Fire Extinguishers, Fire Alarm Systems, Fire Hose Reels, '
      'Fire Hydrants, Water Sprinkler, Flame Fighting Hoses, Fire Tenders, Fire Proof Safes etc';
  static const safetyEquipment =
      'SAFETY EQUIPMENT: Chemical Masks, Carbon Cones, High Visibility Jackets, '
      'Breathing Apparatus, Safety Boots, Hand Gloves, Traffic Baton etc.';
  static const securityEquipment =
      'SECURITY EQUIPMENT: Burglar Alarms, Metal Detectors, Bomb Detectors, Under Car '
      'Search Mirror, Motion Detectors, Security Personnel Kits etc';
  static const solarEquipment =
      'SOLAR EQUIPMENT: Inverters, Solar Panels, Deep Cycle Batteries, Charge Controllers etc';

  static const headOffice =
      'HEAD OFFICE: YY12, Kazaure Road, By Lagos Street Round About, Kaduna.';
  static const headOfficeTel = 'Tel: 08033489452';
  static const branchOffice =
      'BRANCH OFFICE: Plot 45, Sir Patrick Ibrahim Yakowa Way By Milton School, Kamazou Kaduna.';
  static const branchOfficeTel = '08170577595';
  static const email = 'mtekfiresafetyltd@gmail.com';
  static const website = 'www.mtekLtd.com.ng';

  /// OWNER DECISION (2026-08-29): every document carries the FULL
  /// dual-office header — the receipt's old compact "Kaduna I Office"
  /// block is superseded.
  static const dualOfficeBlock =
      'HEAD OFFICE: YY12, Kazaure Road, By Lagos Street Round About, Kaduna. '
      'Tel: 08033489452\n'
      'BRANCH OFFICE: Plot 45, Sir Patrick Ibrahim Yakowa Way By Milton School, '
      'Kamazou Kaduna. 08170577595\n'
      'E-mail: mtekfiresafetyltd@gmail.com · Website: www.mtekLtd.com.ng';

  /// Faint watermark micro-text repeated across document backgrounds
  /// (owner request, 2026-08-29) — mirrors the security pattern on the
  /// physical carbon-copy books.
  static const watermarkBrandText = 'M-TEK FIRE & SAFETY LTD.';
  static const watermarkRcText = 'RC 1082534';

  static const receiptDisclaimer =
      'No guarantee cover on tested goods and services. Purchased tested goods and '
      'services cannot be returned.\nWe bear no liability on part paid and abandoned '
      'goods. This document is invalid without stamp and seal of this company.';

  static const invoiceDisclaimer =
      'No guarantee cover on tested goods and services. We bear no liability on part '
      'paid and abandoned goods. This document is invalid without stamp and seal of this company.';

  /// MILS fine print (transcribed from photo — owner to confirm wording).
  static const milsCaution =
      'Caution: Payment can only commence upon the payment of at least 50% value of the '
      'maintenance charges. No equipment is collected for repair before payment. '
      'Expired/Unserviceable old equipment should be exchanged with new ones after the '
      'expiration of the collection date. Goods left 3 months after will be considered '
      'as abandoned goods and the company shall bear no liability on any abandoned equipment.';
}
