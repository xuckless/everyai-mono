import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../billing/billing_providers.dart' show billingProvider;

/// The billing plans that include the Ultra tier.
const ultraPlans = {'max'};

bool ultraAllowedOn(String planId) => ultraPlans.contains(planId);

/// Whether the signed-in plan includes the Ultra tier (`/v1/billing`).
final ultraAccessProvider = FutureProvider.autoDispose<bool>((ref) async {
  final billing = await ref.watch(billingProvider.future);
  return ultraAllowedOn(billing.plan.id);
});
