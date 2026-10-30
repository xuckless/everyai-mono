import 'db_location_stub.dart' if (dart.library.io) 'db_location_io.dart' as impl;

/// The folder the local database lives in (native platforms).
Future<Object> databaseDirectory() => impl.databaseDirectory();
