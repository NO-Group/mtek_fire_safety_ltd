/// International phone validation shared by registration, customers and
/// documents. Phone numbers must include a leading + and country calling code.
String? internationalPhoneError(String value, {bool required = false}) {
  final text = value.trim();
  if (text.isEmpty) return required ? 'Enter a phone number with country code, e.g. +2348033498452' : null;
  final compact = text.replaceAll(RegExp(r'[\s()\-]'), '');
  if (!RegExp(r'^\+[1-9]\d{7,14}$').hasMatch(compact)) {
    return 'Include country code, e.g. +2348033498452';
  }
  return null;
}

String normalizeInternationalPhone(String value) =>
    value.trim().replaceAll(RegExp(r'[\s()\-]'), '');
