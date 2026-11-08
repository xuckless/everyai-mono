export '../../core/format/money.dart' show formatMicros;

import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/net/api_client.dart';
import '../../core/net/api_error.dart';
import '../../core/providers.dart';

@immutable
final class Plan {
  const Plan({
    required this.id,
    required this.name,
    required this.priceCents,
    required this.includedMicros,
    required this.blurb,
  });

  static Plan? fromJson(Object? json) => switch (json) {
    {
      'id': final String id,
      'name': final String name,
      'price_cents': final num price,
      'included_micros': final num included,
    } =>
      Plan(
        id: id,
        name: name,
        priceCents: price.toInt(),
        includedMicros: included.toInt(),
        blurb: json['blurb'] as String? ?? '',
      ),
    _ => null,
  };

  final String id;
  final String name;
  final int priceCents;

  /// Usage included each month, in millionths of a dollar.
  final int includedMicros;
  final String blurb;
}

@immutable
final class UsageRow {
  const UsageRow({
    required this.at,
    required this.kind,
    required this.model,
    required this.promptTokens,
    required this.completionTokens,
    required this.cachedTokens,
    required this.chargedMicros,
  });

  final DateTime at;
  final String kind;
  final String model;
  final int promptTokens;
  final int completionTokens;
  final int cachedTokens;
  final int chargedMicros;
}

/// `GET /v1/billing`.
@immutable
final class BillingSummary {
  const BillingSummary({
    required this.plan,
    required this.plans,
    required this.periodEnd,
    required this.includedMicros,
    required this.usedMicros,
    required this.walletMicros,
    required this.monthTokens,
    required this.monthCachedTokens,
    required this.recent,
  });

  factory BillingSummary.fromJson(Map<String, Object?> j) {
    int n(String k) => (j[k] as num?)?.toInt() ?? 0;
    return BillingSummary(
      plan: Plan.fromJson(j['plan'])!,
      plans: ((j['plans'] as List<Object?>?) ?? const []).map(Plan.fromJson).nonNulls.toList(growable: false),
      periodEnd: DateTime.fromMillisecondsSinceEpoch(n('period_end') * 1000),
      includedMicros: n('included_micros'),
      usedMicros: n('used_micros'),
      walletMicros: n('wallet_micros'),
      monthTokens: n('month_tokens'),
      monthCachedTokens: n('month_cached_tokens'),
      recent: [
        for (final r in (j['recent'] as List<Object?>?) ?? const [])
          if (r case final Map<String, Object?> m)
            UsageRow(
              at: DateTime.fromMillisecondsSinceEpoch(((m['created_at'] as num?)?.toInt() ?? 0) * 1000),
              kind: m['kind'] as String? ?? '',
              model: m['model'] as String? ?? '',
              promptTokens: (m['prompt_tokens'] as num?)?.toInt() ?? 0,
              completionTokens: (m['completion_tokens'] as num?)?.toInt() ?? 0,
              cachedTokens: (m['cached_tokens'] as num?)?.toInt() ?? 0,
              chargedMicros: (m['charged_micros'] as num?)?.toInt() ?? 0,
            ),
      ],
    );
  }

  final Plan plan;
  final List<Plan> plans;
  final DateTime periodEnd;
  final int includedMicros;
  final int usedMicros;
  final int walletMicros;
  final int monthTokens;
  final int monthCachedTokens;
  final List<UsageRow> recent;

  int get quotaLeftMicros => (includedMicros - usedMicros).clamp(0, includedMicros);
  double get quotaUsedFraction => includedMicros == 0 ? 0 : (usedMicros / includedMicros).clamp(0, 1);

  /// Share of this month's prompt tokens served from the prompt cache.
  double get cacheShare => monthTokens == 0 ? 0 : monthCachedTokens / monthTokens;
}

final billingProvider = AsyncNotifierProvider.autoDispose<BillingController, BillingSummary>(BillingController.new);

class BillingController extends AsyncNotifier<BillingSummary> {
  ApiClient get _api => ref.read(apiClientProvider);
  bool get _authenticated => true;

  @override
  Future<BillingSummary> build() async =>
      BillingSummary.fromJson(await _api.getJson('v1/billing', authenticated: _authenticated));

  /// Fetches the summary again. A failed reload keeps the summary already shown (the card doesn't vanish).
  Future<void> reload() async {
    final next = await AsyncValue.guard(build);
    if (!ref.mounted || (next.hasError && state.hasValue)) return;
    state = next;
  }

  /// The checkout in flight and what it buys: a second tap on the same one gets its answer instead of buying again;
  /// a different one waits until it's done (it would otherwise get the first one's answer).
  ({String what, Future<String> done})? _checkingOut;

  /// Starts a Stripe Checkout (opens the browser), or, when the backend has no
  /// Stripe keys, applies the purchase at once. Returns a message for the UI.
  Future<String> topUp(int cents) => _checkout({'kind': 'topup', 'amount_cents': cents});

  Future<String> choosePlan(String planId) => _checkout({'kind': 'subscription', 'plan': planId});

  Future<String> _checkout(Map<String, Object?> body) {
    final what = jsonEncode(body);
    if (_checkingOut case (what: final open, :final done)) {
      return open == what ? done : Future.value('Another checkout is still opening. Try again in a moment.');
    }
    final done = _runCheckout(body).whenComplete(() => _checkingOut = null);
    _checkingOut = (what: what, done: done);
    return done;
  }

  Future<String> _runCheckout(Map<String, Object?> body) async {
    try {
      final json = await _api.postJson('v1/billing/checkout', body, authenticated: _authenticated);
      if (json case {'url': final String url}) {
        await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
        return 'Finish checkout in your browser, then come back.';
      }
      await reload();
      return 'Done.';
    } on ApiError catch (e) {
      return e.message;
    }
  }
}
