import 'dart:math';

int? parsePaise(String value) {
  final text = value.trim();
  if (!RegExp(r'^\d{1,8}(\.\d{1,2})?$').hasMatch(text)) return null;
  final parts = text.split('.');
  final amount = int.parse(parts[0]) * 100 +
      (parts.length == 2 ? int.parse(parts[1].padRight(2, '0')) : 0);
  return amount <= 1000000000 ? amount : null;
}

String money(int paise) {
  final absolute = paise.abs();
  final whole = (absolute ~/ 100).toString();
  final formatted = whole.replaceAllMapped(
      RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (match) => '${match[1]!},');
  return '${paise < 0 ? '−' : ''}₹$formatted.${(absolute % 100).toString().padLeft(2, '0')}';
}

String newRequestId() {
  final random = Random.secure();
  final bytes = List<int>.generate(16, (_) => random.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return [
    hex.substring(0, 8),
    hex.substring(8, 12),
    hex.substring(12, 16),
    hex.substring(16, 20),
    hex.substring(20)
  ].join('-');
}

/// Positive means the friend owes this user. Repayments reduce the payer's debt.
int balanceFor(List<Map<String, dynamic>> entries, String user) =>
    entries.fold(0, (total, row) {
      final amount = (row['amount_paise'] as num).toInt();
      final mine = row['payer_id'] == user;
      if (row['kind'] == 'repayment') return total + (mine ? amount : -amount);
      final otherShare = amount - (row['payer_share_paise'] as num).toInt();
      return total + (mine ? otherShare : -otherShare);
    });
