// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'chrome_download_stub.dart' if (dart.library.io) 'chrome_download_io.dart' as impl;

/// Whether a Chromium-family browser is there for the Preview and the browser tool (installed, set with
/// EVERYAI_CHROME, or downloaded by [downloadChromeForTesting]).
bool get chromeAvailable => impl.chromeAvailable;

/// Looks for a Chrome for Testing EveryAI downloaded earlier, so the browser tool finds it (once per app run).
Future<void> loadDownloadedChrome() => impl.loadDownloadedChrome();

/// Downloads the pinned Chrome for Testing (see `chrome_pin.dart`) into the app's data folder, checks its SHA-256,
/// and unpacks it; [onProgress] gets 0…1. Throws when there is no build for this platform, the download fails or
/// its hash doesn't match.
Future<void> downloadChromeForTesting({void Function(double progress)? onProgress}) =>
    impl.downloadChromeForTesting(onProgress: onProgress);
