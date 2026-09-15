import 'package:intl/intl.dart';

/// All money in the ledger is bigint paisa (plan section 2, invariant 1).
/// This is the only place that divides by 100 -- never format paisa directly
/// anywhere else in the app.
String formatPaisa(int paisa, {String currency = 'NPR'}) {
  final rupees = paisa / 100;
  final formatted = NumberFormat('#,##0.00', 'en_US').format(rupees);
  final symbol = currency == 'NPR' ? 'Rs. ' : '$currency ';
  return '$symbol$formatted';
}

String formatPaisaSigned(int paisa, {required bool isCredit, String currency = 'NPR'}) {
  final sign = isCredit ? '+' : '-';
  return '$sign${formatPaisa(paisa, currency: currency)}';
}

/// Parse what a human typed into a rupees field into bigint paisa
/// (invariant 1). Returns null if the text isn't a well-formed amount, so
/// the caller can show a validation message rather than silently recording
/// a wrong number.
///
/// Deliberately string arithmetic rather than `double.parse(text) * 100`:
/// the double route turns 1234.35 into 123434.99999999999, and `.round()`
/// papering over that is exactly the "format only at the render boundary"
/// rule (plan section 2) being broken at the input boundary instead. Money
/// must never round-trip through a float, in either direction.
int? parsePaisa(String text) {
  // Grouping separators are what a person types when reading an amount off
  // a bank statement; a leading currency symbol is what they get from
  // copy-paste.
  final cleaned = text.trim().replaceAll(',', '').replaceAll(RegExp(r'^(Rs\.?|NPR)\s*'), '');
  if (cleaned.isEmpty) return null;
  if (!RegExp(r'^\d+(\.\d{1,2})?$').hasMatch(cleaned)) return null;

  final parts = cleaned.split('.');
  final rupees = int.tryParse(parts[0]);
  if (rupees == null) return null;
  final paisa = parts.length == 1 ? 0 : int.parse(parts[1].padRight(2, '0'));
  return rupees * 100 + paisa;
}

/// The inverse, for pre-filling an editable amount field. No currency
/// symbol and no grouping separators -- this goes back into a TextField,
/// not onto a label.
String paisaToEditableRupees(int paisa) => (paisa / 100).toStringAsFixed(2);
