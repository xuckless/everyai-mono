// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import '../harness/harness.dart' show HarnessError;
import 'bridges.dart' show SshEnv;
import 'ssh_tunnel.dart';

Future<SshTunnel> openSshTunnel(SshEnv env, int localPort) async =>
    throw const HarnessError('Tunnels need the desktop app.');
