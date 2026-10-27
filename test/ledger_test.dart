import 'package:flutter_test/flutter_test.dart';
import 'package:two_tally/ledger.dart';

void main() {
  test('currency parser uses exact paise and rejects invalid amounts', () {
    expect(parsePaise('350.25'), 35025);
    expect(parsePaise('0.01'), 1);
    expect(parsePaise(' 10.5 '), 1050);
    expect(parsePaise('0'), 0);
    for (final invalid in [
      '1.001',
      '1e3',
      '-5',
      'NaN',
      '1,000',
      '10000000.01',
      ''
    ]) {
      expect(parsePaise(invalid), isNull, reason: invalid);
    }
  });
  test('custom shares and repayments produce zero-sum balances', () {
    final entries = <Map<String, dynamic>>[
      {
        'payer_id': 'a',
        'amount_paise': 35000,
        'payer_share_paise': 17500,
        'kind': 'expense'
      },
      {
        'payer_id': 'b',
        'amount_paise': 10000,
        'payer_share_paise': 3000,
        'kind': 'expense'
      },
      {
        'payer_id': 'b',
        'amount_paise': 10500,
        'payer_share_paise': 0,
        'kind': 'repayment'
      },
    ];
    expect(balanceFor(entries.take(2).toList(), 'a'), 10500);
    expect(balanceFor(entries, 'a'), 0);
    expect(balanceFor(entries, 'b'), 0);
  });
  test('odd paise belongs to payer and custom zero shares are valid', () {
    final entries = <Map<String, dynamic>>[
      {
        'payer_id': 'a',
        'amount_paise': 101,
        'payer_share_paise': 51,
        'kind': 'expense'
      },
      {
        'payer_id': 'b',
        'amount_paise': 200,
        'payer_share_paise': 0,
        'kind': 'expense'
      },
    ];
    expect(balanceFor(entries, 'a'), -150);
    expect(balanceFor(entries, 'b'), 150);
    expect(money(101), '₹1.01');
  });
  test('request IDs are UUID v4 and unique', () {
    final ids = List.generate(100, (_) => newRequestId());
    expect(ids.toSet().length, 100);
    expect(
        ids.every((id) => RegExp(
                r'^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$')
            .hasMatch(id)),
        true);
  });
}
