import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/db/app_database.dart';
import 'core/platform/window_state.dart';
import 'core/preferences.dart';
import 'core/providers.dart';
import 'features/chat/data/chat_cleanup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = AppDatabase();
  final preferences = await Preferences.load(db);

  if (!kIsWeb) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        // Unified toolbar, translucent sidebar and full-size content view.
        await const mac.MacosWindowUtilsConfig().apply();
      case TargetPlatform.windows || TargetPlatform.linux:
        await windowManager.ensureInitialized();
        final saved = WindowBounds.decode(preferences[WindowBounds.key]);
        await windowManager.waitUntilReadyToShow(
          WindowOptions(
            title: 'EveryAI',
            minimumSize: WindowBounds.minimum,
            size: saved?.rect.size ?? const Size(1200, 800),
            center: saved == null,
          ),
          () async {
            if (saved != null) await windowManager.setPosition(saved.rect.topLeft);
            if (saved?.maximized ?? false) await windowManager.maximize();
            WindowStateSaver(preferences).start();
            await windowManager.show();
            await windowManager.focus();
          },
        );
      default:
        break;
    }
  }

  // Per-chat settings of chats deleted since (or before) the last launch.
  unawaited(sweepChatPreferences(db, preferences));
  // Pictures of deleted chats; a moment after launch so it never competes with the first frames.
  unawaited(Future<void>.delayed(const Duration(seconds: 5), () => collectBlobGarbage(db)));

  runApp(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(db), preferencesProvider.overrideWithValue(preferences)],
      child: const EveryApp(),
    ),
  );
}
