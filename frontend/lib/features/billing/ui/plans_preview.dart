import 'package:flutter/widgets.dart';

import '../../../core/theme/every_theme.dart';
import '../../../core/ui/adaptive.dart';

/// A plan as the Plans block shows it.
typedef PlanOffer = ({String id, String name, String price, String blurb, List<String> points});

/// The plans EveryAI will sell. Static: checkout isn't wired to them yet.
const planOffers = <PlanOffer>[
  (
    id: 'plus',
    name: 'Plus',
    price: '~\$20/mo',
    blurb: 'For everyday chat and coding.',
    points: ['Every model in the shop', 'Included monthly usage', 'Code sessions on your computer'],
  ),
  (
    id: 'super',
    name: 'Super',
    price: '~\$100/mo',
    blurb: 'For heavy use and long agent runs.',
    points: ['Several times the included usage', 'Max and Ultra harness tiers', 'Priority on busy models'],
  ),
  (
    id: 'payg',
    name: 'Pay as you go',
    price: 'Credits',
    blurb: 'No subscription: buy credits, spend them at cost plus a small margin.',
    points: ['Top up any amount', 'Free models stay free', 'Credits don\'t expire'],
  ),
];

/// Settings → Billing → Plans: the plans on offer, side by side (stacked on
/// narrow widths). The Choose buttons only say it's coming.
class PlansPreview extends StatelessWidget {
  const PlansPreview({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const AdaptiveSectionHeader('Plans'),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Text('Requires an account.', style: theme.type.caption.tint(theme.textMuted)),
          ),
          LayoutBuilder(
            builder: (context, box) {
              final cards = [for (final p in planOffers) _PlanCard(p)];
              if (box.maxWidth < 620) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [for (final c in cards) Padding(padding: const EdgeInsets.only(bottom: 10), child: c)],
                );
              }
              return IntrinsicHeight(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    for (final (i, c) in cards.indexed) ...[if (i > 0) const SizedBox(width: 10), Expanded(child: c)],
                  ],
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _PlanCard extends StatelessWidget {
  const _PlanCard(this.plan);

  final PlanOffer plan;

  @override
  Widget build(BuildContext context) {
    final theme = EveryTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: theme.surfaceRaised,
        borderRadius: BorderRadius.circular(EveryTheme.cardRadius),
        border: Border.all(color: theme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(plan.name, style: theme.type.headline.tint(theme.text)),
          const SizedBox(height: 2),
          Text(plan.price, style: theme.type.title.tint(theme.text)),
          const SizedBox(height: 6),
          Text(plan.blurb, style: theme.type.caption.tint(theme.textMuted)),
          const SizedBox(height: 8),
          for (final p in plan.points)
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text('· $p', style: theme.type.callout.tint(theme.text)),
            ),
          const SizedBox(height: 10),
          AdaptiveButton(
            key: ValueKey('plans.choose.${plan.id}'),
            label: 'Choose ${plan.name}',
            emphasis: plan.id == 'plus' ? ButtonEmphasis.primary : ButtonEmphasis.secondary,
            onPressed: () => showAdaptiveToast(context, '${plan.name} is coming soon.'),
          ),
        ],
      ),
    );
  }
}
