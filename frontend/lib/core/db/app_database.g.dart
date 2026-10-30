// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'app_database.dart';

// ignore_for_file: type=lint
class $ConversationsTable extends Conversations with TableInfo<$ConversationsTable, ConversationRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $ConversationsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _titleMeta = const VerificationMeta('title');
  @override
  late final GeneratedColumn<String> title = GeneratedColumn<String>(
    'title',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta('modelId');
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _updatedAtMeta = const VerificationMeta('updatedAt');
  @override
  late final GeneratedColumn<DateTime> updatedAt = GeneratedColumn<DateTime>(
    'updated_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _pinnedMeta = const VerificationMeta('pinned');
  @override
  late final GeneratedColumn<bool> pinned = GeneratedColumn<bool>(
    'pinned',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways('CHECK ("pinned" IN (0, 1))'),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _archivedMeta = const VerificationMeta('archived');
  @override
  late final GeneratedColumn<bool> archived = GeneratedColumn<bool>(
    'archived',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways('CHECK ("archived" IN (0, 1))'),
    defaultValue: const Constant(false),
  );
  @override
  List<GeneratedColumn> get $columns => [id, title, modelId, createdAt, updatedAt, pinned, archived];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'conversations';
  @override
  VerificationContext validateIntegrity(Insertable<ConversationRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('title')) {
      context.handle(_titleMeta, title.isAcceptableOrUnknown(data['title']!, _titleMeta));
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('model_id')) {
      context.handle(_modelIdMeta, modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta));
    } else if (isInserting) {
      context.missing(_modelIdMeta);
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta, createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    if (data.containsKey('updated_at')) {
      context.handle(_updatedAtMeta, updatedAt.isAcceptableOrUnknown(data['updated_at']!, _updatedAtMeta));
    } else if (isInserting) {
      context.missing(_updatedAtMeta);
    }
    if (data.containsKey('pinned')) {
      context.handle(_pinnedMeta, pinned.isAcceptableOrUnknown(data['pinned']!, _pinnedMeta));
    }
    if (data.containsKey('archived')) {
      context.handle(_archivedMeta, archived.isAcceptableOrUnknown(data['archived']!, _archivedMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  ConversationRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return ConversationRow(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      title: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}title'])!,
      modelId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}model_id'])!,
      createdAt: attachedDatabase.typeMapping.read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
      updatedAt: attachedDatabase.typeMapping.read(DriftSqlType.dateTime, data['${effectivePrefix}updated_at'])!,
      pinned: attachedDatabase.typeMapping.read(DriftSqlType.bool, data['${effectivePrefix}pinned'])!,
      archived: attachedDatabase.typeMapping.read(DriftSqlType.bool, data['${effectivePrefix}archived'])!,
    );
  }

  @override
  $ConversationsTable createAlias(String alias) {
    return $ConversationsTable(attachedDatabase, alias);
  }
}

class ConversationRow extends DataClass implements Insertable<ConversationRow> {
  final String id;
  final String title;
  final String modelId;
  final DateTime createdAt;
  final DateTime updatedAt;
  final bool pinned;
  final bool archived;
  const ConversationRow({
    required this.id,
    required this.title,
    required this.modelId,
    required this.createdAt,
    required this.updatedAt,
    required this.pinned,
    required this.archived,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['title'] = Variable<String>(title);
    map['model_id'] = Variable<String>(modelId);
    map['created_at'] = Variable<DateTime>(createdAt);
    map['updated_at'] = Variable<DateTime>(updatedAt);
    map['pinned'] = Variable<bool>(pinned);
    map['archived'] = Variable<bool>(archived);
    return map;
  }

  ConversationsCompanion toCompanion(bool nullToAbsent) {
    return ConversationsCompanion(
      id: Value(id),
      title: Value(title),
      modelId: Value(modelId),
      createdAt: Value(createdAt),
      updatedAt: Value(updatedAt),
      pinned: Value(pinned),
      archived: Value(archived),
    );
  }

  factory ConversationRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return ConversationRow(
      id: serializer.fromJson<String>(json['id']),
      title: serializer.fromJson<String>(json['title']),
      modelId: serializer.fromJson<String>(json['modelId']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
      updatedAt: serializer.fromJson<DateTime>(json['updatedAt']),
      pinned: serializer.fromJson<bool>(json['pinned']),
      archived: serializer.fromJson<bool>(json['archived']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'title': serializer.toJson<String>(title),
      'modelId': serializer.toJson<String>(modelId),
      'createdAt': serializer.toJson<DateTime>(createdAt),
      'updatedAt': serializer.toJson<DateTime>(updatedAt),
      'pinned': serializer.toJson<bool>(pinned),
      'archived': serializer.toJson<bool>(archived),
    };
  }

  ConversationRow copyWith({
    String? id,
    String? title,
    String? modelId,
    DateTime? createdAt,
    DateTime? updatedAt,
    bool? pinned,
    bool? archived,
  }) => ConversationRow(
    id: id ?? this.id,
    title: title ?? this.title,
    modelId: modelId ?? this.modelId,
    createdAt: createdAt ?? this.createdAt,
    updatedAt: updatedAt ?? this.updatedAt,
    pinned: pinned ?? this.pinned,
    archived: archived ?? this.archived,
  );
  ConversationRow copyWithCompanion(ConversationsCompanion data) {
    return ConversationRow(
      id: data.id.present ? data.id.value : this.id,
      title: data.title.present ? data.title.value : this.title,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
      updatedAt: data.updatedAt.present ? data.updatedAt.value : this.updatedAt,
      pinned: data.pinned.present ? data.pinned.value : this.pinned,
      archived: data.archived.present ? data.archived.value : this.archived,
    );
  }

  @override
  String toString() {
    return (StringBuffer('ConversationRow(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('modelId: $modelId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('pinned: $pinned, ')
          ..write('archived: $archived')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, title, modelId, createdAt, updatedAt, pinned, archived);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is ConversationRow &&
          other.id == this.id &&
          other.title == this.title &&
          other.modelId == this.modelId &&
          other.createdAt == this.createdAt &&
          other.updatedAt == this.updatedAt &&
          other.pinned == this.pinned &&
          other.archived == this.archived);
}

class ConversationsCompanion extends UpdateCompanion<ConversationRow> {
  final Value<String> id;
  final Value<String> title;
  final Value<String> modelId;
  final Value<DateTime> createdAt;
  final Value<DateTime> updatedAt;
  final Value<bool> pinned;
  final Value<bool> archived;
  final Value<int> rowid;
  const ConversationsCompanion({
    this.id = const Value.absent(),
    this.title = const Value.absent(),
    this.modelId = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.updatedAt = const Value.absent(),
    this.pinned = const Value.absent(),
    this.archived = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  ConversationsCompanion.insert({
    required String id,
    required String title,
    required String modelId,
    required DateTime createdAt,
    required DateTime updatedAt,
    this.pinned = const Value.absent(),
    this.archived = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       title = Value(title),
       modelId = Value(modelId),
       createdAt = Value(createdAt),
       updatedAt = Value(updatedAt);
  static Insertable<ConversationRow> custom({
    Expression<String>? id,
    Expression<String>? title,
    Expression<String>? modelId,
    Expression<DateTime>? createdAt,
    Expression<DateTime>? updatedAt,
    Expression<bool>? pinned,
    Expression<bool>? archived,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (title != null) 'title': title,
      if (modelId != null) 'model_id': modelId,
      if (createdAt != null) 'created_at': createdAt,
      if (updatedAt != null) 'updated_at': updatedAt,
      if (pinned != null) 'pinned': pinned,
      if (archived != null) 'archived': archived,
      if (rowid != null) 'rowid': rowid,
    });
  }

  ConversationsCompanion copyWith({
    Value<String>? id,
    Value<String>? title,
    Value<String>? modelId,
    Value<DateTime>? createdAt,
    Value<DateTime>? updatedAt,
    Value<bool>? pinned,
    Value<bool>? archived,
    Value<int>? rowid,
  }) {
    return ConversationsCompanion(
      id: id ?? this.id,
      title: title ?? this.title,
      modelId: modelId ?? this.modelId,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      pinned: pinned ?? this.pinned,
      archived: archived ?? this.archived,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (updatedAt.present) {
      map['updated_at'] = Variable<DateTime>(updatedAt.value);
    }
    if (pinned.present) {
      map['pinned'] = Variable<bool>(pinned.value);
    }
    if (archived.present) {
      map['archived'] = Variable<bool>(archived.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('ConversationsCompanion(')
          ..write('id: $id, ')
          ..write('title: $title, ')
          ..write('modelId: $modelId, ')
          ..write('createdAt: $createdAt, ')
          ..write('updatedAt: $updatedAt, ')
          ..write('pinned: $pinned, ')
          ..write('archived: $archived, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagesTable extends Messages with TableInfo<$MessagesTable, MessageRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _conversationIdMeta = const VerificationMeta('conversationId');
  @override
  late final GeneratedColumn<String> conversationId = GeneratedColumn<String>(
    'conversation_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES conversations (id) ON DELETE CASCADE'),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _modelIdMeta = const VerificationMeta('modelId');
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _statusMeta = const VerificationMeta('status');
  @override
  late final GeneratedColumn<String> status = GeneratedColumn<String>(
    'status',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _errorMeta = const VerificationMeta('error');
  @override
  late final GeneratedColumn<String> error = GeneratedColumn<String>(
    'error',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _createdAtMeta = const VerificationMeta('createdAt');
  @override
  late final GeneratedColumn<DateTime> createdAt = GeneratedColumn<DateTime>(
    'created_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, conversationId, role, modelId, status, error, createdAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'messages';
  @override
  VerificationContext validateIntegrity(Insertable<MessageRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('conversation_id')) {
      context.handle(
        _conversationIdMeta,
        conversationId.isAcceptableOrUnknown(data['conversation_id']!, _conversationIdMeta),
      );
    } else if (isInserting) {
      context.missing(_conversationIdMeta);
    }
    if (data.containsKey('role')) {
      context.handle(_roleMeta, role.isAcceptableOrUnknown(data['role']!, _roleMeta));
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    if (data.containsKey('model_id')) {
      context.handle(_modelIdMeta, modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta));
    }
    if (data.containsKey('status')) {
      context.handle(_statusMeta, status.isAcceptableOrUnknown(data['status']!, _statusMeta));
    } else if (isInserting) {
      context.missing(_statusMeta);
    }
    if (data.containsKey('error')) {
      context.handle(_errorMeta, error.isAcceptableOrUnknown(data['error']!, _errorMeta));
    }
    if (data.containsKey('created_at')) {
      context.handle(_createdAtMeta, createdAt.isAcceptableOrUnknown(data['created_at']!, _createdAtMeta));
    } else if (isInserting) {
      context.missing(_createdAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  MessageRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessageRow(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      conversationId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}conversation_id'],
      )!,
      role: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}role'])!,
      modelId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}model_id']),
      status: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}status'])!,
      error: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}error']),
      createdAt: attachedDatabase.typeMapping.read(DriftSqlType.dateTime, data['${effectivePrefix}created_at'])!,
    );
  }

  @override
  $MessagesTable createAlias(String alias) {
    return $MessagesTable(attachedDatabase, alias);
  }
}

class MessageRow extends DataClass implements Insertable<MessageRow> {
  final String id;
  final String conversationId;

  /// `user` | `assistant` | `system`
  final String role;
  final String? modelId;

  /// `complete` | `failed` | `cancelled` (streaming messages are only persisted when they finish)
  final String status;
  final String? error;
  final DateTime createdAt;
  const MessageRow({
    required this.id,
    required this.conversationId,
    required this.role,
    this.modelId,
    required this.status,
    this.error,
    required this.createdAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['conversation_id'] = Variable<String>(conversationId);
    map['role'] = Variable<String>(role);
    if (!nullToAbsent || modelId != null) {
      map['model_id'] = Variable<String>(modelId);
    }
    map['status'] = Variable<String>(status);
    if (!nullToAbsent || error != null) {
      map['error'] = Variable<String>(error);
    }
    map['created_at'] = Variable<DateTime>(createdAt);
    return map;
  }

  MessagesCompanion toCompanion(bool nullToAbsent) {
    return MessagesCompanion(
      id: Value(id),
      conversationId: Value(conversationId),
      role: Value(role),
      modelId: modelId == null && nullToAbsent ? const Value.absent() : Value(modelId),
      status: Value(status),
      error: error == null && nullToAbsent ? const Value.absent() : Value(error),
      createdAt: Value(createdAt),
    );
  }

  factory MessageRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessageRow(
      id: serializer.fromJson<String>(json['id']),
      conversationId: serializer.fromJson<String>(json['conversationId']),
      role: serializer.fromJson<String>(json['role']),
      modelId: serializer.fromJson<String?>(json['modelId']),
      status: serializer.fromJson<String>(json['status']),
      error: serializer.fromJson<String?>(json['error']),
      createdAt: serializer.fromJson<DateTime>(json['createdAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'conversationId': serializer.toJson<String>(conversationId),
      'role': serializer.toJson<String>(role),
      'modelId': serializer.toJson<String?>(modelId),
      'status': serializer.toJson<String>(status),
      'error': serializer.toJson<String?>(error),
      'createdAt': serializer.toJson<DateTime>(createdAt),
    };
  }

  MessageRow copyWith({
    String? id,
    String? conversationId,
    String? role,
    Value<String?> modelId = const Value.absent(),
    String? status,
    Value<String?> error = const Value.absent(),
    DateTime? createdAt,
  }) => MessageRow(
    id: id ?? this.id,
    conversationId: conversationId ?? this.conversationId,
    role: role ?? this.role,
    modelId: modelId.present ? modelId.value : this.modelId,
    status: status ?? this.status,
    error: error.present ? error.value : this.error,
    createdAt: createdAt ?? this.createdAt,
  );
  MessageRow copyWithCompanion(MessagesCompanion data) {
    return MessageRow(
      id: data.id.present ? data.id.value : this.id,
      conversationId: data.conversationId.present ? data.conversationId.value : this.conversationId,
      role: data.role.present ? data.role.value : this.role,
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
      status: data.status.present ? data.status.value : this.status,
      error: data.error.present ? data.error.value : this.error,
      createdAt: data.createdAt.present ? data.createdAt.value : this.createdAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessageRow(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('modelId: $modelId, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, conversationId, role, modelId, status, error, createdAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessageRow &&
          other.id == this.id &&
          other.conversationId == this.conversationId &&
          other.role == this.role &&
          other.modelId == this.modelId &&
          other.status == this.status &&
          other.error == this.error &&
          other.createdAt == this.createdAt);
}

class MessagesCompanion extends UpdateCompanion<MessageRow> {
  final Value<String> id;
  final Value<String> conversationId;
  final Value<String> role;
  final Value<String?> modelId;
  final Value<String> status;
  final Value<String?> error;
  final Value<DateTime> createdAt;
  final Value<int> rowid;
  const MessagesCompanion({
    this.id = const Value.absent(),
    this.conversationId = const Value.absent(),
    this.role = const Value.absent(),
    this.modelId = const Value.absent(),
    this.status = const Value.absent(),
    this.error = const Value.absent(),
    this.createdAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagesCompanion.insert({
    required String id,
    required String conversationId,
    required String role,
    this.modelId = const Value.absent(),
    required String status,
    this.error = const Value.absent(),
    required DateTime createdAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       conversationId = Value(conversationId),
       role = Value(role),
       status = Value(status),
       createdAt = Value(createdAt);
  static Insertable<MessageRow> custom({
    Expression<String>? id,
    Expression<String>? conversationId,
    Expression<String>? role,
    Expression<String>? modelId,
    Expression<String>? status,
    Expression<String>? error,
    Expression<DateTime>? createdAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (conversationId != null) 'conversation_id': conversationId,
      if (role != null) 'role': role,
      if (modelId != null) 'model_id': modelId,
      if (status != null) 'status': status,
      if (error != null) 'error': error,
      if (createdAt != null) 'created_at': createdAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagesCompanion copyWith({
    Value<String>? id,
    Value<String>? conversationId,
    Value<String>? role,
    Value<String?>? modelId,
    Value<String>? status,
    Value<String?>? error,
    Value<DateTime>? createdAt,
    Value<int>? rowid,
  }) {
    return MessagesCompanion(
      id: id ?? this.id,
      conversationId: conversationId ?? this.conversationId,
      role: role ?? this.role,
      modelId: modelId ?? this.modelId,
      status: status ?? this.status,
      error: error ?? this.error,
      createdAt: createdAt ?? this.createdAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (conversationId.present) {
      map['conversation_id'] = Variable<String>(conversationId.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (status.present) {
      map['status'] = Variable<String>(status.value);
    }
    if (error.present) {
      map['error'] = Variable<String>(error.value);
    }
    if (createdAt.present) {
      map['created_at'] = Variable<DateTime>(createdAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagesCompanion(')
          ..write('id: $id, ')
          ..write('conversationId: $conversationId, ')
          ..write('role: $role, ')
          ..write('modelId: $modelId, ')
          ..write('status: $status, ')
          ..write('error: $error, ')
          ..write('createdAt: $createdAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $BlobsTable extends Blobs with TableInfo<$BlobsTable, BlobRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $BlobsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bytesMeta = const VerificationMeta('bytes');
  @override
  late final GeneratedColumn<Uint8List> bytes = GeneratedColumn<Uint8List>(
    'bytes',
    aliasedName,
    false,
    type: DriftSqlType.blob,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _mimeTypeMeta = const VerificationMeta('mimeType');
  @override
  late final GeneratedColumn<String> mimeType = GeneratedColumn<String>(
    'mime_type',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, bytes, mimeType];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'blobs';
  @override
  VerificationContext validateIntegrity(Insertable<BlobRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('bytes')) {
      context.handle(_bytesMeta, bytes.isAcceptableOrUnknown(data['bytes']!, _bytesMeta));
    } else if (isInserting) {
      context.missing(_bytesMeta);
    }
    if (data.containsKey('mime_type')) {
      context.handle(_mimeTypeMeta, mimeType.isAcceptableOrUnknown(data['mime_type']!, _mimeTypeMeta));
    } else if (isInserting) {
      context.missing(_mimeTypeMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  BlobRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return BlobRow(
      id: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}id'])!,
      bytes: attachedDatabase.typeMapping.read(DriftSqlType.blob, data['${effectivePrefix}bytes'])!,
      mimeType: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}mime_type'])!,
    );
  }

  @override
  $BlobsTable createAlias(String alias) {
    return $BlobsTable(attachedDatabase, alias);
  }
}

class BlobRow extends DataClass implements Insertable<BlobRow> {
  final String id;
  final Uint8List bytes;
  final String mimeType;
  const BlobRow({required this.id, required this.bytes, required this.mimeType});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['bytes'] = Variable<Uint8List>(bytes);
    map['mime_type'] = Variable<String>(mimeType);
    return map;
  }

  BlobsCompanion toCompanion(bool nullToAbsent) {
    return BlobsCompanion(id: Value(id), bytes: Value(bytes), mimeType: Value(mimeType));
  }

  factory BlobRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return BlobRow(
      id: serializer.fromJson<String>(json['id']),
      bytes: serializer.fromJson<Uint8List>(json['bytes']),
      mimeType: serializer.fromJson<String>(json['mimeType']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'bytes': serializer.toJson<Uint8List>(bytes),
      'mimeType': serializer.toJson<String>(mimeType),
    };
  }

  BlobRow copyWith({String? id, Uint8List? bytes, String? mimeType}) =>
      BlobRow(id: id ?? this.id, bytes: bytes ?? this.bytes, mimeType: mimeType ?? this.mimeType);
  BlobRow copyWithCompanion(BlobsCompanion data) {
    return BlobRow(
      id: data.id.present ? data.id.value : this.id,
      bytes: data.bytes.present ? data.bytes.value : this.bytes,
      mimeType: data.mimeType.present ? data.mimeType.value : this.mimeType,
    );
  }

  @override
  String toString() {
    return (StringBuffer('BlobRow(')
          ..write('id: $id, ')
          ..write('bytes: $bytes, ')
          ..write('mimeType: $mimeType')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, $driftBlobEquality.hash(bytes), mimeType);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is BlobRow &&
          other.id == this.id &&
          $driftBlobEquality.equals(other.bytes, this.bytes) &&
          other.mimeType == this.mimeType);
}

class BlobsCompanion extends UpdateCompanion<BlobRow> {
  final Value<String> id;
  final Value<Uint8List> bytes;
  final Value<String> mimeType;
  final Value<int> rowid;
  const BlobsCompanion({
    this.id = const Value.absent(),
    this.bytes = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  BlobsCompanion.insert({
    required String id,
    required Uint8List bytes,
    required String mimeType,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       bytes = Value(bytes),
       mimeType = Value(mimeType);
  static Insertable<BlobRow> custom({
    Expression<String>? id,
    Expression<Uint8List>? bytes,
    Expression<String>? mimeType,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (bytes != null) 'bytes': bytes,
      if (mimeType != null) 'mime_type': mimeType,
      if (rowid != null) 'rowid': rowid,
    });
  }

  BlobsCompanion copyWith({Value<String>? id, Value<Uint8List>? bytes, Value<String>? mimeType, Value<int>? rowid}) {
    return BlobsCompanion(
      id: id ?? this.id,
      bytes: bytes ?? this.bytes,
      mimeType: mimeType ?? this.mimeType,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (bytes.present) {
      map['bytes'] = Variable<Uint8List>(bytes.value);
    }
    if (mimeType.present) {
      map['mime_type'] = Variable<String>(mimeType.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('BlobsCompanion(')
          ..write('id: $id, ')
          ..write('bytes: $bytes, ')
          ..write('mimeType: $mimeType, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $MessagePartsTable extends MessageParts with TableInfo<$MessagePartsTable, MessagePartRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $MessagePartsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _messageIdMeta = const VerificationMeta('messageId');
  @override
  late final GeneratedColumn<String> messageId = GeneratedColumn<String>(
    'message_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
    defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES messages (id) ON DELETE CASCADE'),
  );
  static const VerificationMeta _idxMeta = const VerificationMeta('idx');
  @override
  late final GeneratedColumn<int> idx = GeneratedColumn<int>(
    'idx',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _kindMeta = const VerificationMeta('kind');
  @override
  late final GeneratedColumn<String> kind = GeneratedColumn<String>(
    'kind',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _bodyMeta = const VerificationMeta('body');
  @override
  late final GeneratedColumn<String> body = GeneratedColumn<String>(
    'body',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _blobIdMeta = const VerificationMeta('blobId');
  @override
  late final GeneratedColumn<String> blobId = GeneratedColumn<String>(
    'blob_id',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways('REFERENCES blobs (id)'),
  );
  static const VerificationMeta _mimeTypeMeta = const VerificationMeta('mimeType');
  @override
  late final GeneratedColumn<String> mimeType = GeneratedColumn<String>(
    'mime_type',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [messageId, idx, kind, body, blobId, mimeType];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'message_parts';
  @override
  VerificationContext validateIntegrity(Insertable<MessagePartRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('message_id')) {
      context.handle(_messageIdMeta, messageId.isAcceptableOrUnknown(data['message_id']!, _messageIdMeta));
    } else if (isInserting) {
      context.missing(_messageIdMeta);
    }
    if (data.containsKey('idx')) {
      context.handle(_idxMeta, idx.isAcceptableOrUnknown(data['idx']!, _idxMeta));
    } else if (isInserting) {
      context.missing(_idxMeta);
    }
    if (data.containsKey('kind')) {
      context.handle(_kindMeta, kind.isAcceptableOrUnknown(data['kind']!, _kindMeta));
    } else if (isInserting) {
      context.missing(_kindMeta);
    }
    if (data.containsKey('body')) {
      context.handle(_bodyMeta, body.isAcceptableOrUnknown(data['body']!, _bodyMeta));
    }
    if (data.containsKey('blob_id')) {
      context.handle(_blobIdMeta, blobId.isAcceptableOrUnknown(data['blob_id']!, _blobIdMeta));
    }
    if (data.containsKey('mime_type')) {
      context.handle(_mimeTypeMeta, mimeType.isAcceptableOrUnknown(data['mime_type']!, _mimeTypeMeta));
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {messageId, idx};
  @override
  MessagePartRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return MessagePartRow(
      messageId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}message_id'])!,
      idx: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}idx'])!,
      kind: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}kind'])!,
      body: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}body']),
      blobId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}blob_id']),
      mimeType: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}mime_type']),
    );
  }

  @override
  $MessagePartsTable createAlias(String alias) {
    return $MessagePartsTable(attachedDatabase, alias);
  }
}

class MessagePartRow extends DataClass implements Insertable<MessagePartRow> {
  final String messageId;
  final int idx;

  /// `text` | `image` | `tool_call` | `artifact`
  final String kind;
  final String? body;
  final String? blobId;
  final String? mimeType;
  const MessagePartRow({
    required this.messageId,
    required this.idx,
    required this.kind,
    this.body,
    this.blobId,
    this.mimeType,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['message_id'] = Variable<String>(messageId);
    map['idx'] = Variable<int>(idx);
    map['kind'] = Variable<String>(kind);
    if (!nullToAbsent || body != null) {
      map['body'] = Variable<String>(body);
    }
    if (!nullToAbsent || blobId != null) {
      map['blob_id'] = Variable<String>(blobId);
    }
    if (!nullToAbsent || mimeType != null) {
      map['mime_type'] = Variable<String>(mimeType);
    }
    return map;
  }

  MessagePartsCompanion toCompanion(bool nullToAbsent) {
    return MessagePartsCompanion(
      messageId: Value(messageId),
      idx: Value(idx),
      kind: Value(kind),
      body: body == null && nullToAbsent ? const Value.absent() : Value(body),
      blobId: blobId == null && nullToAbsent ? const Value.absent() : Value(blobId),
      mimeType: mimeType == null && nullToAbsent ? const Value.absent() : Value(mimeType),
    );
  }

  factory MessagePartRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return MessagePartRow(
      messageId: serializer.fromJson<String>(json['messageId']),
      idx: serializer.fromJson<int>(json['idx']),
      kind: serializer.fromJson<String>(json['kind']),
      body: serializer.fromJson<String?>(json['body']),
      blobId: serializer.fromJson<String?>(json['blobId']),
      mimeType: serializer.fromJson<String?>(json['mimeType']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'messageId': serializer.toJson<String>(messageId),
      'idx': serializer.toJson<int>(idx),
      'kind': serializer.toJson<String>(kind),
      'body': serializer.toJson<String?>(body),
      'blobId': serializer.toJson<String?>(blobId),
      'mimeType': serializer.toJson<String?>(mimeType),
    };
  }

  MessagePartRow copyWith({
    String? messageId,
    int? idx,
    String? kind,
    Value<String?> body = const Value.absent(),
    Value<String?> blobId = const Value.absent(),
    Value<String?> mimeType = const Value.absent(),
  }) => MessagePartRow(
    messageId: messageId ?? this.messageId,
    idx: idx ?? this.idx,
    kind: kind ?? this.kind,
    body: body.present ? body.value : this.body,
    blobId: blobId.present ? blobId.value : this.blobId,
    mimeType: mimeType.present ? mimeType.value : this.mimeType,
  );
  MessagePartRow copyWithCompanion(MessagePartsCompanion data) {
    return MessagePartRow(
      messageId: data.messageId.present ? data.messageId.value : this.messageId,
      idx: data.idx.present ? data.idx.value : this.idx,
      kind: data.kind.present ? data.kind.value : this.kind,
      body: data.body.present ? data.body.value : this.body,
      blobId: data.blobId.present ? data.blobId.value : this.blobId,
      mimeType: data.mimeType.present ? data.mimeType.value : this.mimeType,
    );
  }

  @override
  String toString() {
    return (StringBuffer('MessagePartRow(')
          ..write('messageId: $messageId, ')
          ..write('idx: $idx, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('blobId: $blobId, ')
          ..write('mimeType: $mimeType')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(messageId, idx, kind, body, blobId, mimeType);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is MessagePartRow &&
          other.messageId == this.messageId &&
          other.idx == this.idx &&
          other.kind == this.kind &&
          other.body == this.body &&
          other.blobId == this.blobId &&
          other.mimeType == this.mimeType);
}

class MessagePartsCompanion extends UpdateCompanion<MessagePartRow> {
  final Value<String> messageId;
  final Value<int> idx;
  final Value<String> kind;
  final Value<String?> body;
  final Value<String?> blobId;
  final Value<String?> mimeType;
  final Value<int> rowid;
  const MessagePartsCompanion({
    this.messageId = const Value.absent(),
    this.idx = const Value.absent(),
    this.kind = const Value.absent(),
    this.body = const Value.absent(),
    this.blobId = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  MessagePartsCompanion.insert({
    required String messageId,
    required int idx,
    required String kind,
    this.body = const Value.absent(),
    this.blobId = const Value.absent(),
    this.mimeType = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : messageId = Value(messageId),
       idx = Value(idx),
       kind = Value(kind);
  static Insertable<MessagePartRow> custom({
    Expression<String>? messageId,
    Expression<int>? idx,
    Expression<String>? kind,
    Expression<String>? body,
    Expression<String>? blobId,
    Expression<String>? mimeType,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (messageId != null) 'message_id': messageId,
      if (idx != null) 'idx': idx,
      if (kind != null) 'kind': kind,
      if (body != null) 'body': body,
      if (blobId != null) 'blob_id': blobId,
      if (mimeType != null) 'mime_type': mimeType,
      if (rowid != null) 'rowid': rowid,
    });
  }

  MessagePartsCompanion copyWith({
    Value<String>? messageId,
    Value<int>? idx,
    Value<String>? kind,
    Value<String?>? body,
    Value<String?>? blobId,
    Value<String?>? mimeType,
    Value<int>? rowid,
  }) {
    return MessagePartsCompanion(
      messageId: messageId ?? this.messageId,
      idx: idx ?? this.idx,
      kind: kind ?? this.kind,
      body: body ?? this.body,
      blobId: blobId ?? this.blobId,
      mimeType: mimeType ?? this.mimeType,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (messageId.present) {
      map['message_id'] = Variable<String>(messageId.value);
    }
    if (idx.present) {
      map['idx'] = Variable<int>(idx.value);
    }
    if (kind.present) {
      map['kind'] = Variable<String>(kind.value);
    }
    if (body.present) {
      map['body'] = Variable<String>(body.value);
    }
    if (blobId.present) {
      map['blob_id'] = Variable<String>(blobId.value);
    }
    if (mimeType.present) {
      map['mime_type'] = Variable<String>(mimeType.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('MessagePartsCompanion(')
          ..write('messageId: $messageId, ')
          ..write('idx: $idx, ')
          ..write('kind: $kind, ')
          ..write('body: $body, ')
          ..write('blobId: $blobId, ')
          ..write('mimeType: $mimeType, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LibraryModelsTable extends LibraryModels with TableInfo<$LibraryModelsTable, LibraryModelRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LibraryModelsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _modelIdMeta = const VerificationMeta('modelId');
  @override
  late final GeneratedColumn<String> modelId = GeneratedColumn<String>(
    'model_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta('position');
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [modelId, position];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'library_models';
  @override
  VerificationContext validateIntegrity(Insertable<LibraryModelRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('model_id')) {
      context.handle(_modelIdMeta, modelId.isAcceptableOrUnknown(data['model_id']!, _modelIdMeta));
    } else if (isInserting) {
      context.missing(_modelIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(_positionMeta, position.isAcceptableOrUnknown(data['position']!, _positionMeta));
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {modelId};
  @override
  LibraryModelRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LibraryModelRow(
      modelId: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}model_id'])!,
      position: attachedDatabase.typeMapping.read(DriftSqlType.int, data['${effectivePrefix}position'])!,
    );
  }

  @override
  $LibraryModelsTable createAlias(String alias) {
    return $LibraryModelsTable(attachedDatabase, alias);
  }
}

class LibraryModelRow extends DataClass implements Insertable<LibraryModelRow> {
  final String modelId;
  final int position;
  const LibraryModelRow({required this.modelId, required this.position});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['model_id'] = Variable<String>(modelId);
    map['position'] = Variable<int>(position);
    return map;
  }

  LibraryModelsCompanion toCompanion(bool nullToAbsent) {
    return LibraryModelsCompanion(modelId: Value(modelId), position: Value(position));
  }

  factory LibraryModelRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LibraryModelRow(
      modelId: serializer.fromJson<String>(json['modelId']),
      position: serializer.fromJson<int>(json['position']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'modelId': serializer.toJson<String>(modelId),
      'position': serializer.toJson<int>(position),
    };
  }

  LibraryModelRow copyWith({String? modelId, int? position}) =>
      LibraryModelRow(modelId: modelId ?? this.modelId, position: position ?? this.position);
  LibraryModelRow copyWithCompanion(LibraryModelsCompanion data) {
    return LibraryModelRow(
      modelId: data.modelId.present ? data.modelId.value : this.modelId,
      position: data.position.present ? data.position.value : this.position,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LibraryModelRow(')
          ..write('modelId: $modelId, ')
          ..write('position: $position')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(modelId, position);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LibraryModelRow && other.modelId == this.modelId && other.position == this.position);
}

class LibraryModelsCompanion extends UpdateCompanion<LibraryModelRow> {
  final Value<String> modelId;
  final Value<int> position;
  final Value<int> rowid;
  const LibraryModelsCompanion({
    this.modelId = const Value.absent(),
    this.position = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LibraryModelsCompanion.insert({required String modelId, required int position, this.rowid = const Value.absent()})
    : modelId = Value(modelId),
      position = Value(position);
  static Insertable<LibraryModelRow> custom({
    Expression<String>? modelId,
    Expression<int>? position,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (modelId != null) 'model_id': modelId,
      if (position != null) 'position': position,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LibraryModelsCompanion copyWith({Value<String>? modelId, Value<int>? position, Value<int>? rowid}) {
    return LibraryModelsCompanion(
      modelId: modelId ?? this.modelId,
      position: position ?? this.position,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (modelId.present) {
      map['model_id'] = Variable<String>(modelId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LibraryModelsCompanion(')
          ..write('modelId: $modelId, ')
          ..write('position: $position, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $KeyValuesTable extends KeyValues with TableInfo<$KeyValuesTable, KeyValueRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $KeyValuesTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _keyMeta = const VerificationMeta('key');
  @override
  late final GeneratedColumn<String> key = GeneratedColumn<String>(
    'key',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _valueMeta = const VerificationMeta('value');
  @override
  late final GeneratedColumn<String> value = GeneratedColumn<String>(
    'value',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [key, value];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'key_values';
  @override
  VerificationContext validateIntegrity(Insertable<KeyValueRow> instance, {bool isInserting = false}) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(_keyMeta, key.isAcceptableOrUnknown(data['key']!, _keyMeta));
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(_valueMeta, value.isAcceptableOrUnknown(data['value']!, _valueMeta));
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  KeyValueRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return KeyValueRow(
      key: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}key'])!,
      value: attachedDatabase.typeMapping.read(DriftSqlType.string, data['${effectivePrefix}value'])!,
    );
  }

  @override
  $KeyValuesTable createAlias(String alias) {
    return $KeyValuesTable(attachedDatabase, alias);
  }
}

class KeyValueRow extends DataClass implements Insertable<KeyValueRow> {
  final String key;
  final String value;
  const KeyValueRow({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  KeyValuesCompanion toCompanion(bool nullToAbsent) {
    return KeyValuesCompanion(key: Value(key), value: Value(value));
  }

  factory KeyValueRow.fromJson(Map<String, dynamic> json, {ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return KeyValueRow(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{'key': serializer.toJson<String>(key), 'value': serializer.toJson<String>(value)};
  }

  KeyValueRow copyWith({String? key, String? value}) => KeyValueRow(key: key ?? this.key, value: value ?? this.value);
  KeyValueRow copyWithCompanion(KeyValuesCompanion data) {
    return KeyValueRow(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('KeyValueRow(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) || (other is KeyValueRow && other.key == this.key && other.value == this.value);
}

class KeyValuesCompanion extends UpdateCompanion<KeyValueRow> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const KeyValuesCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  KeyValuesCompanion.insert({required String key, required String value, this.rowid = const Value.absent()})
    : key = Value(key),
      value = Value(value);
  static Insertable<KeyValueRow> custom({Expression<String>? key, Expression<String>? value, Expression<int>? rowid}) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  KeyValuesCompanion copyWith({Value<String>? key, Value<String>? value, Value<int>? rowid}) {
    return KeyValuesCompanion(key: key ?? this.key, value: value ?? this.value, rowid: rowid ?? this.rowid);
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (key.present) {
      map['key'] = Variable<String>(key.value);
    }
    if (value.present) {
      map['value'] = Variable<String>(value.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('KeyValuesCompanion(')
          ..write('key: $key, ')
          ..write('value: $value, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

abstract class _$AppDatabase extends GeneratedDatabase {
  _$AppDatabase(QueryExecutor e) : super(e);
  $AppDatabaseManager get managers => $AppDatabaseManager(this);
  late final $ConversationsTable conversations = $ConversationsTable(this);
  late final $MessagesTable messages = $MessagesTable(this);
  late final $BlobsTable blobs = $BlobsTable(this);
  late final $MessagePartsTable messageParts = $MessagePartsTable(this);
  late final $LibraryModelsTable libraryModels = $LibraryModelsTable(this);
  late final $KeyValuesTable keyValues = $KeyValuesTable(this);
  late final Index messagesByConversation = Index(
    'messages_by_conversation',
    'CREATE INDEX messages_by_conversation ON messages (conversation_id, created_at)',
  );
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    conversations,
    messages,
    blobs,
    messageParts,
    libraryModels,
    keyValues,
    messagesByConversation,
  ];
  @override
  StreamQueryUpdateRules get streamUpdateRules => const StreamQueryUpdateRules([
    WritePropagation(
      on: TableUpdateQuery.onTableName('conversations', limitUpdateKind: UpdateKind.delete),
      result: [TableUpdate('messages', kind: UpdateKind.delete)],
    ),
    WritePropagation(
      on: TableUpdateQuery.onTableName('messages', limitUpdateKind: UpdateKind.delete),
      result: [TableUpdate('message_parts', kind: UpdateKind.delete)],
    ),
  ]);
  @override
  DriftDatabaseOptions get options => const DriftDatabaseOptions(storeDateTimeAsText: true);
}

typedef $$ConversationsTableCreateCompanionBuilder = ConversationsCompanion Function({
  required String id,
  required String title,
  required String modelId,
  required DateTime createdAt,
  required DateTime updatedAt,
  Value<bool> pinned,
  Value<bool> archived,
  Value<int> rowid,
});
typedef $$ConversationsTableUpdateCompanionBuilder = ConversationsCompanion Function({
  Value<String> id,
  Value<String> title,
  Value<String> modelId,
  Value<DateTime> createdAt,
  Value<DateTime> updatedAt,
  Value<bool> pinned,
  Value<bool> archived,
  Value<int> rowid,
});

final class $$ConversationsTableReferences extends BaseReferences<_$AppDatabase, $ConversationsTable, ConversationRow> {
  $$ConversationsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagesTable, List<MessageRow>> _messagesRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.messages, aliasName: 'conversations__id__messages__conversation_id');

  $$MessagesTableProcessedTableManager get messagesRefs {
    final manager = $$MessagesTableTableManager(
      $_db,
      $_db.messages,
    ).filter((f) => f.conversationId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagesRefsTable($_db));
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$ConversationsTableFilterComposer extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => ColumnFilters(column));

  ColumnFilters<bool> get archived =>
      $composableBuilder(column: $table.archived, builder: (column) => ColumnFilters(column));

  Expression<bool> messagesRefs(Expression<bool> Function($$MessagesTableFilterComposer f) f) {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.conversationId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ConversationsTableOrderingComposer extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get updatedAt =>
      $composableBuilder(column: $table.updatedAt, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get pinned =>
      $composableBuilder(column: $table.pinned, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<bool> get archived =>
      $composableBuilder(column: $table.archived, builder: (column) => ColumnOrderings(column));
}

class $$ConversationsTableAnnotationComposer extends Composer<_$AppDatabase, $ConversationsTable> {
  $$ConversationsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get title => $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get modelId => $composableBuilder(column: $table.modelId, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt => $composableBuilder(column: $table.createdAt, builder: (column) => column);

  GeneratedColumn<DateTime> get updatedAt => $composableBuilder(column: $table.updatedAt, builder: (column) => column);

  GeneratedColumn<bool> get pinned => $composableBuilder(column: $table.pinned, builder: (column) => column);

  GeneratedColumn<bool> get archived => $composableBuilder(column: $table.archived, builder: (column) => column);

  Expression<T> messagesRefs<T extends Object>(Expression<T> Function($$MessagesTableAnnotationComposer a) f) {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.conversationId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$ConversationsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $ConversationsTable,
          ConversationRow,
          $$ConversationsTableFilterComposer,
          $$ConversationsTableOrderingComposer,
          $$ConversationsTableAnnotationComposer,
          $$ConversationsTableCreateCompanionBuilder,
          $$ConversationsTableUpdateCompanionBuilder,
          (ConversationRow, $$ConversationsTableReferences),
          ConversationRow,
          PrefetchHooks Function({bool messagesRefs})
        > {
  $$ConversationsTableTableManager(_$AppDatabase db, $ConversationsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$ConversationsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$ConversationsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$ConversationsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> modelId = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<DateTime> updatedAt = const Value.absent(),
                Value<bool> pinned = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion(
                id: id,
                title: title,
                modelId: modelId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                pinned: pinned,
                archived: archived,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String title,
                required String modelId,
                required DateTime createdAt,
                required DateTime updatedAt,
                Value<bool> pinned = const Value.absent(),
                Value<bool> archived = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => ConversationsCompanion.insert(
                id: id,
                title: title,
                modelId: modelId,
                createdAt: createdAt,
                updatedAt: updatedAt,
                pinned: pinned,
                archived: archived,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$ConversationsTable, ConversationRow>(table),
                  $$ConversationsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messagesRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagesRefs) db.messages],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagesRefs)
                    await $_getPrefetchedDataByColumns<
                      ConversationRow,
                      $ConversationsTable,
                      MessageRow,
                      $MessagesTable
                    >(
                      currentTable: table,
                      referencedTable: $$ConversationsTableReferences._messagesRefsTable(db),
                      managerFromTypedResult: (p0) => $$ConversationsTableReferences(db, table, p0).messagesRefs,
                      currentColumn: 'id',
                      referencedColumn: 'conversation_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$ConversationsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $ConversationsTable,
      ConversationRow,
      $$ConversationsTableFilterComposer,
      $$ConversationsTableOrderingComposer,
      $$ConversationsTableAnnotationComposer,
      $$ConversationsTableCreateCompanionBuilder,
      $$ConversationsTableUpdateCompanionBuilder,
      (ConversationRow, $$ConversationsTableReferences),
      ConversationRow,
      PrefetchHooks Function({bool messagesRefs})
    >;
typedef $$MessagesTableCreateCompanionBuilder = MessagesCompanion Function({
  required String id,
  required String conversationId,
  required String role,
  Value<String?> modelId,
  required String status,
  Value<String?> error,
  required DateTime createdAt,
  Value<int> rowid,
});
typedef $$MessagesTableUpdateCompanionBuilder = MessagesCompanion Function({
  Value<String> id,
  Value<String> conversationId,
  Value<String> role,
  Value<String?> modelId,
  Value<String> status,
  Value<String?> error,
  Value<DateTime> createdAt,
  Value<int> rowid,
});

final class $$MessagesTableReferences extends BaseReferences<_$AppDatabase, $MessagesTable, MessageRow> {
  $$MessagesTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $ConversationsTable _conversationIdTable(_$AppDatabase db) =>
      db.conversations.createAlias('messages__conversation_id__conversations__id');

  $$ConversationsTableProcessedTableManager get conversationId {
    final $_column = $_itemColumn<String>('conversation_id')!;

    final manager = $$ConversationsTableTableManager($_db, $_db.conversations).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_conversationIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: [item]));
  }

  static MultiTypedResultKey<$MessagePartsTable, List<MessagePartRow>> _messagePartsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.messageParts, aliasName: 'messages__id__message_parts__message_id');

  $$MessagePartsTableProcessedTableManager get messagePartsRefs {
    final manager = $$MessagePartsTableTableManager(
      $_db,
      $_db.messageParts,
    ).filter((f) => f.messageId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagePartsRefsTable($_db));
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$MessagesTableFilterComposer extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get role => $composableBuilder(column: $table.role, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => ColumnFilters(column));

  ColumnFilters<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => ColumnFilters(column));

  $$ConversationsTableFilterComposer get conversationId {
    final $$ConversationsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$ConversationsTableFilterComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<bool> messagePartsRefs(Expression<bool> Function($$MessagePartsTableFilterComposer f) f) {
    final $$MessagePartsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.messageId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagePartsTableFilterComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableOrderingComposer extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get status =>
      $composableBuilder(column: $table.status, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get error =>
      $composableBuilder(column: $table.error, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<DateTime> get createdAt =>
      $composableBuilder(column: $table.createdAt, builder: (column) => ColumnOrderings(column));

  $$ConversationsTableOrderingComposer get conversationId {
    final $$ConversationsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$ConversationsTableOrderingComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagesTableAnnotationComposer extends Composer<_$AppDatabase, $MessagesTable> {
  $$MessagesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get role => $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get modelId => $composableBuilder(column: $table.modelId, builder: (column) => column);

  GeneratedColumn<String> get status => $composableBuilder(column: $table.status, builder: (column) => column);

  GeneratedColumn<String> get error => $composableBuilder(column: $table.error, builder: (column) => column);

  GeneratedColumn<DateTime> get createdAt => $composableBuilder(column: $table.createdAt, builder: (column) => column);

  $$ConversationsTableAnnotationComposer get conversationId {
    final $$ConversationsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.conversationId,
      referencedTable: $db.conversations,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$ConversationsTableAnnotationComposer(
            $db: $db,
            $table: $db.conversations,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  Expression<T> messagePartsRefs<T extends Object>(Expression<T> Function($$MessagePartsTableAnnotationComposer a) f) {
    final $$MessagePartsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.messageId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagePartsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$MessagesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagesTable,
          MessageRow,
          $$MessagesTableFilterComposer,
          $$MessagesTableOrderingComposer,
          $$MessagesTableAnnotationComposer,
          $$MessagesTableCreateCompanionBuilder,
          $$MessagesTableUpdateCompanionBuilder,
          (MessageRow, $$MessagesTableReferences),
          MessageRow,
          PrefetchHooks Function({bool conversationId, bool messagePartsRefs})
        > {
  $$MessagesTableTableManager(_$AppDatabase db, $MessagesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$MessagesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$MessagesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$MessagesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> conversationId = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String?> modelId = const Value.absent(),
                Value<String> status = const Value.absent(),
                Value<String?> error = const Value.absent(),
                Value<DateTime> createdAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion(
                id: id,
                conversationId: conversationId,
                role: role,
                modelId: modelId,
                status: status,
                error: error,
                createdAt: createdAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String conversationId,
                required String role,
                Value<String?> modelId = const Value.absent(),
                required String status,
                Value<String?> error = const Value.absent(),
                required DateTime createdAt,
                Value<int> rowid = const Value.absent(),
              }) => MessagesCompanion.insert(
                id: id,
                conversationId: conversationId,
                role: role,
                modelId: modelId,
                status: status,
                error: error,
                createdAt: createdAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map((e) => (e.readTable<$MessagesTable, MessageRow>(table), $$MessagesTableReferences(db, table, e)))
              .toList(),
          prefetchHooksCallback: ({conversationId = false, messagePartsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagePartsRefs) db.messageParts],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (conversationId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.conversationId,
                        referencedTable: $$MessagesTableReferences._conversationIdTable(db),
                        referencedColumn: $$MessagesTableReferences._conversationIdTable(db).id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagePartsRefs)
                    await $_getPrefetchedDataByColumns<MessageRow, $MessagesTable, MessagePartRow, $MessagePartsTable>(
                      currentTable: table,
                      referencedTable: $$MessagesTableReferences._messagePartsRefsTable(db),
                      managerFromTypedResult: (p0) => $$MessagesTableReferences(db, table, p0).messagePartsRefs,
                      currentColumn: 'id',
                      referencedColumn: 'message_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$MessagesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagesTable,
      MessageRow,
      $$MessagesTableFilterComposer,
      $$MessagesTableOrderingComposer,
      $$MessagesTableAnnotationComposer,
      $$MessagesTableCreateCompanionBuilder,
      $$MessagesTableUpdateCompanionBuilder,
      (MessageRow, $$MessagesTableReferences),
      MessageRow,
      PrefetchHooks Function({bool conversationId, bool messagePartsRefs})
    >;
typedef $$BlobsTableCreateCompanionBuilder = BlobsCompanion Function({
  required String id,
  required Uint8List bytes,
  required String mimeType,
  Value<int> rowid,
});
typedef $$BlobsTableUpdateCompanionBuilder = BlobsCompanion Function({
  Value<String> id,
  Value<Uint8List> bytes,
  Value<String> mimeType,
  Value<int> rowid,
});

final class $$BlobsTableReferences extends BaseReferences<_$AppDatabase, $BlobsTable, BlobRow> {
  $$BlobsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static MultiTypedResultKey<$MessagePartsTable, List<MessagePartRow>> _messagePartsRefsTable(_$AppDatabase db) =>
      MultiTypedResultKey.fromTable(db.messageParts, aliasName: 'blobs__id__message_parts__blob_id');

  $$MessagePartsTableProcessedTableManager get messagePartsRefs {
    final manager = $$MessagePartsTableTableManager(
      $_db,
      $_db.messageParts,
    ).filter((f) => f.blobId.id.sqlEquals($_itemColumn<String>('id')!));

    final cache = $_typedResult.readTableOrNull(_messagePartsRefsTable($_db));
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: cache));
  }
}

class $$BlobsTableFilterComposer extends Composer<_$AppDatabase, $BlobsTable> {
  $$BlobsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnFilters(column));

  ColumnFilters<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => ColumnFilters(column));

  Expression<bool> messagePartsRefs(Expression<bool> Function($$MessagePartsTableFilterComposer f) f) {
    final $$MessagePartsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.blobId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagePartsTableFilterComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BlobsTableOrderingComposer extends Composer<_$AppDatabase, $BlobsTable> {
  $$BlobsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(column: $table.id, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<Uint8List> get bytes =>
      $composableBuilder(column: $table.bytes, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => ColumnOrderings(column));
}

class $$BlobsTableAnnotationComposer extends Composer<_$AppDatabase, $BlobsTable> {
  $$BlobsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id => $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<Uint8List> get bytes => $composableBuilder(column: $table.bytes, builder: (column) => column);

  GeneratedColumn<String> get mimeType => $composableBuilder(column: $table.mimeType, builder: (column) => column);

  Expression<T> messagePartsRefs<T extends Object>(Expression<T> Function($$MessagePartsTableAnnotationComposer a) f) {
    final $$MessagePartsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.id,
      referencedTable: $db.messageParts,
      getReferencedColumn: (t) => t.blobId,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagePartsTableAnnotationComposer(
            $db: $db,
            $table: $db.messageParts,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return f(composer);
  }
}

class $$BlobsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $BlobsTable,
          BlobRow,
          $$BlobsTableFilterComposer,
          $$BlobsTableOrderingComposer,
          $$BlobsTableAnnotationComposer,
          $$BlobsTableCreateCompanionBuilder,
          $$BlobsTableUpdateCompanionBuilder,
          (BlobRow, $$BlobsTableReferences),
          BlobRow,
          PrefetchHooks Function({bool messagePartsRefs})
        > {
  $$BlobsTableTableManager(_$AppDatabase db, $BlobsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$BlobsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$BlobsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$BlobsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> id = const Value.absent(),
            Value<Uint8List> bytes = const Value.absent(),
            Value<String> mimeType = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => BlobsCompanion(id: id, bytes: bytes, mimeType: mimeType, rowid: rowid),
          createCompanionCallback: ({
            required String id,
            required Uint8List bytes,
            required String mimeType,
            Value<int> rowid = const Value.absent(),
          }) => BlobsCompanion.insert(id: id, bytes: bytes, mimeType: mimeType, rowid: rowid),
          withReferenceMapper: (p0) =>
              p0.map((e) => (e.readTable<$BlobsTable, BlobRow>(table), $$BlobsTableReferences(db, table, e))).toList(),
          prefetchHooksCallback: ({messagePartsRefs = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [if (messagePartsRefs) db.messageParts],
              addJoins: null,
              getPrefetchedDataCallback: (items) async {
                return [
                  if (messagePartsRefs)
                    await $_getPrefetchedDataByColumns<BlobRow, $BlobsTable, MessagePartRow, $MessagePartsTable>(
                      currentTable: table,
                      referencedTable: $$BlobsTableReferences._messagePartsRefsTable(db),
                      managerFromTypedResult: (p0) => $$BlobsTableReferences(db, table, p0).messagePartsRefs,
                      currentColumn: 'id',
                      referencedColumn: 'blob_id',
                      typedResults: items,
                    ),
                ];
              },
            );
          },
        ),
      );
}

typedef $$BlobsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $BlobsTable,
      BlobRow,
      $$BlobsTableFilterComposer,
      $$BlobsTableOrderingComposer,
      $$BlobsTableAnnotationComposer,
      $$BlobsTableCreateCompanionBuilder,
      $$BlobsTableUpdateCompanionBuilder,
      (BlobRow, $$BlobsTableReferences),
      BlobRow,
      PrefetchHooks Function({bool messagePartsRefs})
    >;
typedef $$MessagePartsTableCreateCompanionBuilder = MessagePartsCompanion Function({
  required String messageId,
  required int idx,
  required String kind,
  Value<String?> body,
  Value<String?> blobId,
  Value<String?> mimeType,
  Value<int> rowid,
});
typedef $$MessagePartsTableUpdateCompanionBuilder = MessagePartsCompanion Function({
  Value<String> messageId,
  Value<int> idx,
  Value<String> kind,
  Value<String?> body,
  Value<String?> blobId,
  Value<String?> mimeType,
  Value<int> rowid,
});

final class $$MessagePartsTableReferences extends BaseReferences<_$AppDatabase, $MessagePartsTable, MessagePartRow> {
  $$MessagePartsTableReferences(super.$_db, super.$_table, super.$_typedResult);

  static $MessagesTable _messageIdTable(_$AppDatabase db) =>
      db.messages.createAlias('message_parts__message_id__messages__id');

  $$MessagesTableProcessedTableManager get messageId {
    final $_column = $_itemColumn<String>('message_id')!;

    final manager = $$MessagesTableTableManager($_db, $_db.messages).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_messageIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: [item]));
  }

  static $BlobsTable _blobIdTable(_$AppDatabase db) => db.blobs.createAlias('message_parts__blob_id__blobs__id');

  $$BlobsTableProcessedTableManager? get blobId {
    final $_column = $_itemColumn<String>('blob_id');
    if ($_column == null) return null;
    final manager = $$BlobsTableTableManager($_db, $_db.blobs).filter((f) => f.id.sqlEquals($_column));
    final item = $_typedResult.readTableOrNull(_blobIdTable($_db));
    if (item == null) return manager;
    return ProcessedTableManager(manager.$state.copyWith(prefetchedData: [item]));
  }
}

class $$MessagePartsTableFilterComposer extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get idx => $composableBuilder(column: $table.idx, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get kind => $composableBuilder(column: $table.kind, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get body => $composableBuilder(column: $table.body, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => ColumnFilters(column));

  $$MessagesTableFilterComposer get messageId {
    final $$MessagesTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagesTableFilterComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BlobsTableFilterComposer get blobId {
    final $$BlobsTableFilterComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.blobId,
      referencedTable: $db.blobs,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$BlobsTableFilterComposer(
            $db: $db,
            $table: $db.blobs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableOrderingComposer extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get idx => $composableBuilder(column: $table.idx, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get kind =>
      $composableBuilder(column: $table.kind, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get body =>
      $composableBuilder(column: $table.body, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get mimeType =>
      $composableBuilder(column: $table.mimeType, builder: (column) => ColumnOrderings(column));

  $$MessagesTableOrderingComposer get messageId {
    final $$MessagesTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagesTableOrderingComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BlobsTableOrderingComposer get blobId {
    final $$BlobsTableOrderingComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.blobId,
      referencedTable: $db.blobs,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$BlobsTableOrderingComposer(
            $db: $db,
            $table: $db.blobs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableAnnotationComposer extends Composer<_$AppDatabase, $MessagePartsTable> {
  $$MessagePartsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get idx => $composableBuilder(column: $table.idx, builder: (column) => column);

  GeneratedColumn<String> get kind => $composableBuilder(column: $table.kind, builder: (column) => column);

  GeneratedColumn<String> get body => $composableBuilder(column: $table.body, builder: (column) => column);

  GeneratedColumn<String> get mimeType => $composableBuilder(column: $table.mimeType, builder: (column) => column);

  $$MessagesTableAnnotationComposer get messageId {
    final $$MessagesTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.messageId,
      referencedTable: $db.messages,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$MessagesTableAnnotationComposer(
            $db: $db,
            $table: $db.messages,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }

  $$BlobsTableAnnotationComposer get blobId {
    final $$BlobsTableAnnotationComposer composer = $composerBuilder(
      composer: this,
      getCurrentColumn: (t) => t.blobId,
      referencedTable: $db.blobs,
      getReferencedColumn: (t) => t.id,
      builder: (joinBuilder, {$addJoinBuilderToRootComposer, $removeJoinBuilderFromRootComposer}) =>
          $$BlobsTableAnnotationComposer(
            $db: $db,
            $table: $db.blobs,
            $addJoinBuilderToRootComposer: $addJoinBuilderToRootComposer,
            joinBuilder: joinBuilder,
            $removeJoinBuilderFromRootComposer: $removeJoinBuilderFromRootComposer,
          ),
    );
    return composer;
  }
}

class $$MessagePartsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $MessagePartsTable,
          MessagePartRow,
          $$MessagePartsTableFilterComposer,
          $$MessagePartsTableOrderingComposer,
          $$MessagePartsTableAnnotationComposer,
          $$MessagePartsTableCreateCompanionBuilder,
          $$MessagePartsTableUpdateCompanionBuilder,
          (MessagePartRow, $$MessagePartsTableReferences),
          MessagePartRow,
          PrefetchHooks Function({bool messageId, bool blobId})
        > {
  $$MessagePartsTableTableManager(_$AppDatabase db, $MessagePartsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$MessagePartsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$MessagePartsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$MessagePartsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> messageId = const Value.absent(),
                Value<int> idx = const Value.absent(),
                Value<String> kind = const Value.absent(),
                Value<String?> body = const Value.absent(),
                Value<String?> blobId = const Value.absent(),
                Value<String?> mimeType = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagePartsCompanion(
                messageId: messageId,
                idx: idx,
                kind: kind,
                body: body,
                blobId: blobId,
                mimeType: mimeType,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String messageId,
                required int idx,
                required String kind,
                Value<String?> body = const Value.absent(),
                Value<String?> blobId = const Value.absent(),
                Value<String?> mimeType = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => MessagePartsCompanion.insert(
                messageId: messageId,
                idx: idx,
                kind: kind,
                body: body,
                blobId: blobId,
                mimeType: mimeType,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$MessagePartsTable, MessagePartRow>(table),
                  $$MessagePartsTableReferences(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: ({messageId = false, blobId = false}) {
            return PrefetchHooks(
              db: db,
              explicitlyWatchedTables: [],
              addJoins:
                  <
                    T extends TableManagerState<
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic,
                      dynamic
                    >
                  >(state) {
                    if (messageId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.messageId,
                        referencedTable: $$MessagePartsTableReferences._messageIdTable(db),
                        referencedColumn: $$MessagePartsTableReferences._messageIdTable(db).id,
                      ) as T;
                    }
                    if (blobId) {
                      state = state.withJoin(
                        currentTable: table,
                        currentColumn: table.blobId,
                        referencedTable: $$MessagePartsTableReferences._blobIdTable(db),
                        referencedColumn: $$MessagePartsTableReferences._blobIdTable(db).id,
                      ) as T;
                    }

                    return state;
                  },
              getPrefetchedDataCallback: (items) async {
                return [];
              },
            );
          },
        ),
      );
}

typedef $$MessagePartsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $MessagePartsTable,
      MessagePartRow,
      $$MessagePartsTableFilterComposer,
      $$MessagePartsTableOrderingComposer,
      $$MessagePartsTableAnnotationComposer,
      $$MessagePartsTableCreateCompanionBuilder,
      $$MessagePartsTableUpdateCompanionBuilder,
      (MessagePartRow, $$MessagePartsTableReferences),
      MessagePartRow,
      PrefetchHooks Function({bool messageId, bool blobId})
    >;
typedef $$LibraryModelsTableCreateCompanionBuilder = LibraryModelsCompanion Function({
  required String modelId,
  required int position,
  Value<int> rowid,
});
typedef $$LibraryModelsTableUpdateCompanionBuilder = LibraryModelsCompanion Function({
  Value<String> modelId,
  Value<int> position,
  Value<int> rowid,
});

class $$LibraryModelsTableFilterComposer extends Composer<_$AppDatabase, $LibraryModelsTable> {
  $$LibraryModelsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnFilters(column));

  ColumnFilters<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => ColumnFilters(column));
}

class $$LibraryModelsTableOrderingComposer extends Composer<_$AppDatabase, $LibraryModelsTable> {
  $$LibraryModelsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get modelId =>
      $composableBuilder(column: $table.modelId, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => ColumnOrderings(column));
}

class $$LibraryModelsTableAnnotationComposer extends Composer<_$AppDatabase, $LibraryModelsTable> {
  $$LibraryModelsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get modelId => $composableBuilder(column: $table.modelId, builder: (column) => column);

  GeneratedColumn<int> get position => $composableBuilder(column: $table.position, builder: (column) => column);
}

class $$LibraryModelsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LibraryModelsTable,
          LibraryModelRow,
          $$LibraryModelsTableFilterComposer,
          $$LibraryModelsTableOrderingComposer,
          $$LibraryModelsTableAnnotationComposer,
          $$LibraryModelsTableCreateCompanionBuilder,
          $$LibraryModelsTableUpdateCompanionBuilder,
          (LibraryModelRow, BaseReferences<_$AppDatabase, $LibraryModelsTable, LibraryModelRow>),
          LibraryModelRow,
          PrefetchHooks Function()
        > {
  $$LibraryModelsTableTableManager(_$AppDatabase db, $LibraryModelsTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$LibraryModelsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$LibraryModelsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$LibraryModelsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> modelId = const Value.absent(),
            Value<int> position = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => LibraryModelsCompanion(modelId: modelId, position: position, rowid: rowid),
          createCompanionCallback: ({
            required String modelId,
            required int position,
            Value<int> rowid = const Value.absent(),
          }) => LibraryModelsCompanion.insert(modelId: modelId, position: position, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LibraryModelsTable, LibraryModelRow>(table),
                  BaseReferences<_$AppDatabase, $LibraryModelsTable, LibraryModelRow>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LibraryModelsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LibraryModelsTable,
      LibraryModelRow,
      $$LibraryModelsTableFilterComposer,
      $$LibraryModelsTableOrderingComposer,
      $$LibraryModelsTableAnnotationComposer,
      $$LibraryModelsTableCreateCompanionBuilder,
      $$LibraryModelsTableUpdateCompanionBuilder,
      (LibraryModelRow, BaseReferences<_$AppDatabase, $LibraryModelsTable, LibraryModelRow>),
      LibraryModelRow,
      PrefetchHooks Function()
    >;
typedef $$KeyValuesTableCreateCompanionBuilder = KeyValuesCompanion Function({
  required String key,
  required String value,
  Value<int> rowid,
});
typedef $$KeyValuesTableUpdateCompanionBuilder = KeyValuesCompanion Function({
  Value<String> key,
  Value<String> value,
  Value<int> rowid,
});

class $$KeyValuesTableFilterComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(column: $table.key, builder: (column) => ColumnFilters(column));

  ColumnFilters<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnFilters(column));
}

class $$KeyValuesTableOrderingComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => ColumnOrderings(column));

  ColumnOrderings<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => ColumnOrderings(column));
}

class $$KeyValuesTableAnnotationComposer extends Composer<_$AppDatabase, $KeyValuesTable> {
  $$KeyValuesTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key => $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value => $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$KeyValuesTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $KeyValuesTable,
          KeyValueRow,
          $$KeyValuesTableFilterComposer,
          $$KeyValuesTableOrderingComposer,
          $$KeyValuesTableAnnotationComposer,
          $$KeyValuesTableCreateCompanionBuilder,
          $$KeyValuesTableUpdateCompanionBuilder,
          (KeyValueRow, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValueRow>),
          KeyValueRow,
          PrefetchHooks Function()
        > {
  $$KeyValuesTableTableManager(_$AppDatabase db, $KeyValuesTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () => $$KeyValuesTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () => $$KeyValuesTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () => $$KeyValuesTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback: ({
            Value<String> key = const Value.absent(),
            Value<String> value = const Value.absent(),
            Value<int> rowid = const Value.absent(),
          }) => KeyValuesCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback: ({
            required String key,
            required String value,
            Value<int> rowid = const Value.absent(),
          }) => KeyValuesCompanion.insert(key: key, value: value, rowid: rowid),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$KeyValuesTable, KeyValueRow>(table),
                  BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValueRow>(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$KeyValuesTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $KeyValuesTable,
      KeyValueRow,
      $$KeyValuesTableFilterComposer,
      $$KeyValuesTableOrderingComposer,
      $$KeyValuesTableAnnotationComposer,
      $$KeyValuesTableCreateCompanionBuilder,
      $$KeyValuesTableUpdateCompanionBuilder,
      (KeyValueRow, BaseReferences<_$AppDatabase, $KeyValuesTable, KeyValueRow>),
      KeyValueRow,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$ConversationsTableTableManager get conversations => $$ConversationsTableTableManager(_db, _db.conversations);
  $$MessagesTableTableManager get messages => $$MessagesTableTableManager(_db, _db.messages);
  $$BlobsTableTableManager get blobs => $$BlobsTableTableManager(_db, _db.blobs);
  $$MessagePartsTableTableManager get messageParts => $$MessagePartsTableTableManager(_db, _db.messageParts);
  $$LibraryModelsTableTableManager get libraryModels => $$LibraryModelsTableTableManager(_db, _db.libraryModels);
  $$KeyValuesTableTableManager get keyValues => $$KeyValuesTableTableManager(_db, _db.keyValues);
}
