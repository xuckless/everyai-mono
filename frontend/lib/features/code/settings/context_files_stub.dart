import 'context_files.dart';

ContextFs diskFs() => const _NoFs();

String? homeDir() => null;

final class _NoFs implements ContextFs {
  const _NoFs();

  @override
  Future<String?> read(String path) async => null;

  @override
  Future<bool> isDirectory(String path) async => false;
}
