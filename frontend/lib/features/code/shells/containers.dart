// Copyright 2026 xuckless and Syed Ali. Licensed under FSL-1.1-ALv2; see LICENCE.md and NOTICE.

import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../domain/local_ports.dart';
import 'containers_stub.dart' if (dart.library.io) 'containers_io.dart' as impl;

/// A Docker or Podman container that belongs to a session.
@immutable
final class SessionContainer {
  const SessionContainer({
    required this.id,
    required this.name,
    required this.image,
    required this.status,
    required this.cli,
    this.ports = const [],
    this.why = '',
  });

  final String id;
  final String name;
  final String image;

  /// `running`, `exited`…
  final String status;

  /// The CLI that lists it (`docker`, `podman`), which the row's actions run.
  final String cli;

  /// Host ports it publishes (pid 0: the container runtime's).
  final List<ListeningPort> ports;

  /// Why it counts as the session's ("compose project in this folder", "mounts this folder", "started here").
  final String why;

  String get shortId => id.length > 12 ? id.substring(0, 12) : id;
}

/// The containers of `docker inspect` output [json] that belong to a session working in [worktree]: a compose
/// project whose working_dir is inside it, a bind mount from inside it, or an id or name in [hints] (ones its
/// commands printed or named). [cli] is the CLI that listed them.
List<SessionContainer> sessionContainersIn(
  String json, {
  required String worktree,
  Set<String> hints = const {},
  String cli = 'docker',
}) {
  Object? decoded;
  try {
    decoded = jsonDecode(json);
  } on FormatException {
    return const [];
  }
  if (decoded is! List) return const [];
  String norm(String p) => p.endsWith('/') ? p.substring(0, p.length - 1) : p;
  final root = norm(worktree);
  bool inside(String? p) => p != null && (norm(p) == root || p.startsWith('$root/'));
  Map<String, Object?> obj(Object? v) => v is Map ? v.cast<String, Object?>() : const <String, Object?>{};
  List<Object?> arr(Object? v) => v is List ? v : const <Object?>[];
  final out = <SessionContainer>[];
  for (final c in [for (final m in decoded) obj(m)]) {
    final id = '${c['Id'] ?? ''}';
    final name = '${c['Name'] ?? ''}'.replaceFirst('/', '');
    final config = obj(c['Config']);
    final labels = obj(config['Labels']);
    final mounts = arr(c['Mounts']).map(obj);
    final String why;
    if (inside(labels['com.docker.compose.project.working_dir'] as String?)) {
      why = 'compose project in this folder';
    } else if (mounts.any((m) => m['Type'] == 'bind' && inside(m['Source'] as String?))) {
      why = 'mounts this folder';
    } else if (hints.any((h) => h.isNotEmpty && (id.startsWith(h) || name == h))) {
      why = 'started in this session';
    } else {
      continue;
    }
    final state = obj(c['State']);
    final net = obj(c['NetworkSettings']);
    final bound = obj(net['Ports']);
    final ports = <ListeningPort>[];
    for (final binds in bound.values) {
      for (final b in arr(binds).map(obj)) {
        final port = int.tryParse('${b['HostPort'] ?? ''}');
        if (port == null) continue;
        final host = '${b['HostIp'] ?? ''}';
        final l = ListeningPort(pid: 0, port: port, host: host.isEmpty ? '*' : host);
        if (!ports.contains(l)) ports.add(l);
      }
    }
    out.add(
      SessionContainer(
        id: id,
        name: name,
        image: '${config['Image'] ?? ''}',
        status: '${state['Status'] ?? ''}',
        cli: cli,
        ports: ports,
        why: why,
      ),
    );
  }
  return out;
}

/// Container ids and names a container command printed or named: the full or short hex id `docker run -d` prints,
/// and the value of `--name`. Empty for other commands.
Set<String> containerHintsOf(String command, String output) {
  if (!RegExp(r'\b(docker|podman)\b[\s\S]*\b(run|create|start|up)\b').hasMatch(command)) return const {};
  return {
    for (final m in RegExp(r'^\s*([0-9a-f]{12}|[0-9a-f]{64})\s*$', multiLine: true).allMatches(output)) m.group(1)!,
    for (final m in RegExp(r'--name[= ]+([A-Za-z0-9][A-Za-z0-9_.-]*)').allMatches(command)) m.group(1)!,
  };
}

/// The running containers of a session working in [worktree] (see [sessionContainersIn]), from whichever of docker
/// and podman is installed and answering. Empty when neither is.
Future<List<SessionContainer>> listSessionContainers({required String worktree, Set<String> hints = const {}}) =>
    impl.listSessionContainers(worktree: worktree, hints: hints);

/// Stops container [c].
Future<bool> stopContainer(SessionContainer c) => impl.stopContainer(c);
