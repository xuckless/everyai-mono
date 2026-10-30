import '../../models/domain/model_catalog.dart';

/// How hard a reasoning model thinks before it answers (the composer's
/// thinking menu). Kept per conversation; sent as the request's `effort`.
enum ReasoningEffort {
  auto('Auto', 'The model decides'),
  low('Low', 'Quick, light thinking'),
  medium('Medium', 'Balanced'),
  high('High', 'Thinks longer on hard problems'),
  max('Max', 'Thinks as long as it needs; slowest, costs most');

  const ReasoningEffort(this.label, this.description);
  final String label;
  final String description;

  /// The request's `effort` value; null leaves the provider's default.
  String? get wire => this == auto ? null : name;

  /// What a turn with [model] sends: models without reasoning get none.
  String? wireFor(ModelSpec model) => model.reasoning ? wire : null;

  static ReasoningEffort parse(String? name) =>
      ReasoningEffort.values.where((e) => e.name == name).firstOrNull ?? ReasoningEffort.auto;

  /// The preferences key holding [conversationId]'s effort.
  static String prefKey(String conversationId) => 'chat.effort.$conversationId';
}
