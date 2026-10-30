import 'sidecar.dart';

final class _Unsupported implements Sidecar {
  @override
  bool get started => false;

  @override
  Future<AgentServerEndpoint> endpoint() => Future.error(const SidecarError('The coding agent runs on desktop only.'));

  @override
  Stream<void> get restarts => const Stream.empty();

  @override
  Future<void> stop() async {}
}

Sidecar createSidecar() => _Unsupported();

Future<String> createSampleProject() => Future.error(const SidecarError('Sample projects need a desktop file system.'));
