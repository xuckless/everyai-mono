bool get chromeAvailable => false;

Future<void> loadDownloadedChrome() async {}

Future<void> downloadChromeForTesting({void Function(double progress)? onProgress}) async =>
    throw UnsupportedError('desktop only');
