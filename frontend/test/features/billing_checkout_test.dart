import 'package:every_ai/core/config/billing_flag.dart';
import 'dart:async';
import 'dart:convert';

import 'package:every_ai/core/net/api_client.dart';
import 'package:every_ai/core/providers.dart';
import 'package:every_ai/features/billing/billing_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  // Written for metered credits; the parked default has billing_parked_test.dart.
  setUp(() => BillingFlag.enabled = true);
  tearDown(() => BillingFlag.enabled = false);

  test('a double tap buys once; a different checkout meanwhile is refused, not given the first answer', () async {
    final checkouts = <Object?>[];
    final answer = Completer<void>();
    final api = ApiClient(
      baseUrl: Uri.parse('http://test/'),
      client: MockClient((req) async {
        if (req.url.path.endsWith('/checkout')) {
          checkouts.add(jsonDecode(req.body));
          await answer.future;
          return http.Response(jsonEncode({'ok': true}), 200);
        }
        return http.Response(jsonEncode({'error': 'none'}), 500);
      }),
    );
    final c = ProviderContainer(overrides: [apiClientProvider.overrideWithValue(api)]);
    addTearDown(c.dispose);
    final sub = c.listen(billingProvider, (_, _) {});
    addTearDown(sub.close);
    final billing = c.read(billingProvider.notifier);

    final first = billing.topUp(1000), again = billing.topUp(1000);
    final plan = await billing.choosePlan('max');
    expect(plan, contains('Another checkout'));
    answer.complete();
    expect(await first, await again);
    expect(checkouts, hasLength(1));
  });
}
