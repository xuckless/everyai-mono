import 'containers.dart';

Future<List<SessionContainer>> listSessionContainers({required String worktree, Set<String> hints = const {}}) async =>
    const [];

Future<bool> stopContainer(SessionContainer c) async => false;
