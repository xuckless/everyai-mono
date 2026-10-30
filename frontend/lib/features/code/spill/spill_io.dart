import 'dart:async';
import 'dart:io';

import '../domain/spill.dart';
import '../settings/settings.dart';

final _excluded = <String>{};

String? saveSpill(String workingDir, String name, String text) {
  try {
    final dir = Directory('$workingDir/$spillDir')..createSync(recursive: true);
    File('${dir.path}/$name').writeAsStringSync(text);
    if (_excluded.add(workingDir)) {
      unawaited(excludeFromGit(workingDir, const ['/$spillDir/']).catchError((Object _) {}));
    }
    return '$spillDir/$name';
  } on Object {
    return null;
  }
}
