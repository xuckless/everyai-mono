import 'package:drift/drift.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/app_database.dart';
import '../../core/preferences.dart';
import '../../core/providers.dart';
import 'domain/model_catalog.dart';

final modelCatalogProvider = Provider<ModelCatalog>((ref) => builtInCatalog);

/// Model new chats start with. Persisted.
final defaultModelProvider = NotifierProvider<DefaultModel, ModelSpec>(DefaultModel.new);

final class DefaultModel extends Notifier<ModelSpec> {
  static const _key = 'default_model';

  @override
  ModelSpec build() {
    final catalog = ref.watch(modelCatalogProvider);
    final saved = ref.watch(preferencesProvider)[_key];
    return (saved == null ? null : catalog[ModelId(saved)]) ?? catalog.defaultModel;
  }

  void set(ModelSpec model) {
    ref.read(preferencesProvider)[_key] = model.id.value;
    state = model;
  }
}

/// The user's library: models pinned to the sidebar, in order. Persisted.
final libraryProvider = AsyncNotifierProvider<Library, List<ModelSpec>>(Library.new);

final class Library extends AsyncNotifier<List<ModelSpec>> {
  AppDatabase get _db => ref.read(databaseProvider);

  @override
  Future<List<ModelSpec>> build() async {
    final catalog = ref.watch(modelCatalogProvider);
    final rows = await (_db.select(_db.libraryModels)..orderBy([(r) => OrderingTerm.asc(r.position)])).get();
    if (rows.isEmpty) {
      // First run: one flagship per provider that works today.
      return [
        for (final p in ModelProvider.values)
          if (catalog.flagship(p) case final s? when s.available) s,
      ];
    }
    return rows.map((r) => catalog[ModelId(r.modelId)]).nonNulls.toList(growable: false);
  }

  bool contains(ModelId id) => state.value?.any((s) => s.id == id) ?? false;

  Future<void> toggle(ModelSpec model) async {
    final current = [...?state.value];
    final index = current.indexWhere((s) => s.id == model.id);
    if (index == -1) {
      current.add(model);
    } else {
      current.removeAt(index);
    }
    state = AsyncData(List.unmodifiable(current));
    await _db.transaction(() async {
      await _db.delete(_db.libraryModels).go();
      for (final (i, s) in current.indexed) {
        await _db.into(_db.libraryModels).insert(LibraryModelsCompanion.insert(modelId: s.id.value, position: i));
      }
    });
  }
}
