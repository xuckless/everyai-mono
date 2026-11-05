// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'bridges.dart' show SshEnv, SshRemote;
import 'ssh_tunnel_stub.dart' if (dart.library.io) 'ssh_tunnel_io.dart' as impl;

/// A reverse forward from an ssh remote to a port on this computer: the
/// remote's `127.0.0.1:[remotePort]` reaches the host's loopback port. How an
/// agent on the remote reaches the MCP host (only loopback listens).
abstract interface class SshTunnel {
  int get remotePort;
  Future<void> close();
}

/// Opens one tunnel to [env] for [localPort] (one per session, closed with
/// it): `ssh -N -R 0:127.0.0.1:<port>`, the remote picking the port, which
/// ssh prints. Keys and the agent only, like the bridge.
Future<SshTunnel> openSshTunnel(SshEnv env, int localPort) => impl.openSshTunnel(env, localPort);

/// ssh's arguments for [openSshTunnel]. A forward that fails ends ssh
/// (ExitOnForwardFailure), so a tunnel that started is a working one.
List<String> sshTunnelArgs(SshRemote remote, int localPort) => [
  '-N',
  '-T',
  '-o',
  'BatchMode=yes',
  '-o',
  'ExitOnForwardFailure=yes',
  '-o',
  'ConnectTimeout=5',
  if (remote.port != null) ...['-p', '${remote.port}'],
  '-R',
  '0:127.0.0.1:$localPort',
  '--',
  remote.destination,
];

/// The port in ssh's `Allocated port N for remote forward to …`, or null.
int? allocatedPort(String line) =>
    int.tryParse(RegExp(r'Allocated port (\d+) for remote forward').firstMatch(line)?.group(1) ?? '');
