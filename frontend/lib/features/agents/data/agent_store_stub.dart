import '../domain/agent_definition.dart';
import 'agent_store.dart' show AgentRoots;

Future<AgentRoots> roots(List<({String id, String path})> projects) async =>
    (global: null, projects: const <({String id, String path})>[]);

Future<List<AgentDefinition>> scan(AgentRoots roots) async => const [];

Future<String> create(String dir, String name, String text) => throw StateError('Agents need a file system.');

Future<void> write(String path, String text) => throw StateError('Agents need a file system.');

Future<void> delete(String path) async {}
