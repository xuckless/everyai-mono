// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

String? axePath() => null;

Future<String> ensureAxe({void Function(double progress)? onProgress}) =>
    Future.error(UnsupportedError('iOS Simulators need macOS'));

Future<String> installAxe({void Function(double progress)? onProgress}) => ensureAxe();
