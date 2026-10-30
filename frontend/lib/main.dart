import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:macos_ui/macos_ui.dart' as mac;
import 'package:window_manager/window_manager.dart';

import 'app/app.dart';
import 'core/db/app_database.dart';
import 'core/preferences.dart';
import 'core/providers.dart';
import 'features/chat/data/chat_cleanup.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb) {
    switch (defaultTargetPlatform) {
      case TargetPlatform.macOS:
        // Unified toolbar, translucent sidebar and full-size content view.
        await const mac.MacosWindowUtilsConfig().apply();
      case TargetPlatform.windows || TargetPlatform.linux:
        await windowManager.ensureInitialized();
        await windowManager.waitUntilReadyToShow(
          const WindowOptions(title: 'EveryAI', minimumSize: Size(380, 520), size: Size(1200, 800), center: true),
          () async {
            await windowManager.show();
            await windowManager.focus();
          },
        );
      default:
        break;
    }
  }

  final db = AppDatabase();
  final preferences = await Preferences.load(db);
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
