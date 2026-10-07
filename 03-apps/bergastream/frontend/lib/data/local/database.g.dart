// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'database.dart';

// ignore_for_file: type=lint
class $LocalTracksTable extends LocalTracks
    with TableInfo<$LocalTracksTable, LocalTrack> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalTracksTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _providerMeta = const VerificationMeta(
    'provider',
  );
  @override
  late final GeneratedColumn<String> provider = GeneratedColumn<String>(
    'provider',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _externalIdMeta = const VerificationMeta(
    'externalId',
  );
  @override
  late final GeneratedColumn<String> externalId = GeneratedColumn<String>(
    'external_id',
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
  static const VerificationMeta _artistMeta = const VerificationMeta('artist');
  @override
  late final GeneratedColumn<String> artist = GeneratedColumn<String>(
    'artist',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _albumMeta = const VerificationMeta('album');
  @override
  late final GeneratedColumn<String> album = GeneratedColumn<String>(
    'album',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _durationSecondsMeta = const VerificationMeta(
    'durationSeconds',
  );
  @override
  late final GeneratedColumn<int> durationSeconds = GeneratedColumn<int>(
    'duration_seconds',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _isrcMeta = const VerificationMeta('isrc');
  @override
  late final GeneratedColumn<String> isrc = GeneratedColumn<String>(
    'isrc',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverUrlMeta = const VerificationMeta(
    'coverUrl',
  );
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
    'cover_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverPathMeta = const VerificationMeta(
    'coverPath',
  );
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
    'cover_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _audioPathMeta = const VerificationMeta(
    'audioPath',
  );
  @override
  late final GeneratedColumn<String> audioPath = GeneratedColumn<String>(
    'audio_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _sizeBytesMeta = const VerificationMeta(
    'sizeBytes',
  );
  @override
  late final GeneratedColumn<int> sizeBytes = GeneratedColumn<int>(
    'size_bytes',
    aliasedName,
    true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
  );
  @override
  late final GeneratedColumnWithTypeConverter<DownloadState, int>
  downloadState = GeneratedColumn<int>(
    'download_state',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  ).withConverter<DownloadState>($LocalTracksTable.$converterdownloadState);
  static const VerificationMeta _attemptsMeta = const VerificationMeta(
    'attempts',
  );
  @override
  late final GeneratedColumn<int> attempts = GeneratedColumn<int>(
    'attempts',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultValue: const Constant(0),
  );
  static const VerificationMeta _downloadedAtMeta = const VerificationMeta(
    'downloadedAt',
  );
  @override
  late final GeneratedColumn<DateTime> downloadedAt = GeneratedColumn<DateTime>(
    'downloaded_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _lastPlayedAtMeta = const VerificationMeta(
    'lastPlayedAt',
  );
  @override
  late final GeneratedColumn<DateTime> lastPlayedAt = GeneratedColumn<DateTime>(
    'last_played_at',
    aliasedName,
    true,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    provider,
    externalId,
    title,
    artist,
    album,
    durationSeconds,
    isrc,
    coverUrl,
    coverPath,
    audioPath,
    sizeBytes,
    downloadState,
    attempts,
    downloadedAt,
    lastPlayedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_tracks';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalTrack> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('provider')) {
      context.handle(
        _providerMeta,
        provider.isAcceptableOrUnknown(data['provider']!, _providerMeta),
      );
    } else if (isInserting) {
      context.missing(_providerMeta);
    }
    if (data.containsKey('external_id')) {
      context.handle(
        _externalIdMeta,
        externalId.isAcceptableOrUnknown(data['external_id']!, _externalIdMeta),
      );
    } else if (isInserting) {
      context.missing(_externalIdMeta);
    }
    if (data.containsKey('title')) {
      context.handle(
        _titleMeta,
        title.isAcceptableOrUnknown(data['title']!, _titleMeta),
      );
    } else if (isInserting) {
      context.missing(_titleMeta);
    }
    if (data.containsKey('artist')) {
      context.handle(
        _artistMeta,
        artist.isAcceptableOrUnknown(data['artist']!, _artistMeta),
      );
    } else if (isInserting) {
      context.missing(_artistMeta);
    }
    if (data.containsKey('album')) {
      context.handle(
        _albumMeta,
        album.isAcceptableOrUnknown(data['album']!, _albumMeta),
      );
    }
    if (data.containsKey('duration_seconds')) {
      context.handle(
        _durationSecondsMeta,
        durationSeconds.isAcceptableOrUnknown(
          data['duration_seconds']!,
          _durationSecondsMeta,
        ),
      );
    }
    if (data.containsKey('isrc')) {
      context.handle(
        _isrcMeta,
        isrc.isAcceptableOrUnknown(data['isrc']!, _isrcMeta),
      );
    }
    if (data.containsKey('cover_url')) {
      context.handle(
        _coverUrlMeta,
        coverUrl.isAcceptableOrUnknown(data['cover_url']!, _coverUrlMeta),
      );
    }
    if (data.containsKey('cover_path')) {
      context.handle(
        _coverPathMeta,
        coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta),
      );
    }
    if (data.containsKey('audio_path')) {
      context.handle(
        _audioPathMeta,
        audioPath.isAcceptableOrUnknown(data['audio_path']!, _audioPathMeta),
      );
    }
    if (data.containsKey('size_bytes')) {
      context.handle(
        _sizeBytesMeta,
        sizeBytes.isAcceptableOrUnknown(data['size_bytes']!, _sizeBytesMeta),
      );
    }
    if (data.containsKey('attempts')) {
      context.handle(
        _attemptsMeta,
        attempts.isAcceptableOrUnknown(data['attempts']!, _attemptsMeta),
      );
    }
    if (data.containsKey('downloaded_at')) {
      context.handle(
        _downloadedAtMeta,
        downloadedAt.isAcceptableOrUnknown(
          data['downloaded_at']!,
          _downloadedAtMeta,
        ),
      );
    }
    if (data.containsKey('last_played_at')) {
      context.handle(
        _lastPlayedAtMeta,
        lastPlayedAt.isAcceptableOrUnknown(
          data['last_played_at']!,
          _lastPlayedAtMeta,
        ),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalTrack map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalTrack(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      provider: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}provider'],
      )!,
      externalId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}external_id'],
      )!,
      title: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}title'],
      )!,
      artist: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}artist'],
      )!,
      album: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}album'],
      )!,
      durationSeconds: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}duration_seconds'],
      )!,
      isrc: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}isrc'],
      ),
      coverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_url'],
      ),
      coverPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_path'],
      ),
      audioPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}audio_path'],
      ),
      sizeBytes: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}size_bytes'],
      ),
      downloadState: $LocalTracksTable.$converterdownloadState.fromSql(
        attachedDatabase.typeMapping.read(
          DriftSqlType.int,
          data['${effectivePrefix}download_state'],
        )!,
      ),
      attempts: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}attempts'],
      )!,
      downloadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}downloaded_at'],
      ),
      lastPlayedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}last_played_at'],
      ),
    );
  }

  @override
  $LocalTracksTable createAlias(String alias) {
    return $LocalTracksTable(attachedDatabase, alias);
  }

  static JsonTypeConverter2<DownloadState, int, int> $converterdownloadState =
      const EnumIndexConverter<DownloadState>(DownloadState.values);
}

class LocalTrack extends DataClass implements Insertable<LocalTrack> {
  /// Id da faixa no servidor.
  final String id;
  final String provider;
  final String externalId;
  final String title;
  final String artist;
  final String album;
  final int durationSeconds;
  final String? isrc;
  final String? coverUrl;
  final String? coverPath;
  final String? audioPath;
  final int? sizeBytes;
  final DownloadState downloadState;
  final int attempts;
  final DateTime? downloadedAt;
  final DateTime? lastPlayedAt;
  const LocalTrack({
    required this.id,
    required this.provider,
    required this.externalId,
    required this.title,
    required this.artist,
    required this.album,
    required this.durationSeconds,
    this.isrc,
    this.coverUrl,
    this.coverPath,
    this.audioPath,
    this.sizeBytes,
    required this.downloadState,
    required this.attempts,
    this.downloadedAt,
    this.lastPlayedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['provider'] = Variable<String>(provider);
    map['external_id'] = Variable<String>(externalId);
    map['title'] = Variable<String>(title);
    map['artist'] = Variable<String>(artist);
    map['album'] = Variable<String>(album);
    map['duration_seconds'] = Variable<int>(durationSeconds);
    if (!nullToAbsent || isrc != null) {
      map['isrc'] = Variable<String>(isrc);
    }
    if (!nullToAbsent || coverUrl != null) {
      map['cover_url'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    if (!nullToAbsent || audioPath != null) {
      map['audio_path'] = Variable<String>(audioPath);
    }
    if (!nullToAbsent || sizeBytes != null) {
      map['size_bytes'] = Variable<int>(sizeBytes);
    }
    {
      map['download_state'] = Variable<int>(
        $LocalTracksTable.$converterdownloadState.toSql(downloadState),
      );
    }
    map['attempts'] = Variable<int>(attempts);
    if (!nullToAbsent || downloadedAt != null) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt);
    }
    if (!nullToAbsent || lastPlayedAt != null) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt);
    }
    return map;
  }

  LocalTracksCompanion toCompanion(bool nullToAbsent) {
    return LocalTracksCompanion(
      id: Value(id),
      provider: Value(provider),
      externalId: Value(externalId),
      title: Value(title),
      artist: Value(artist),
      album: Value(album),
      durationSeconds: Value(durationSeconds),
      isrc: isrc == null && nullToAbsent ? const Value.absent() : Value(isrc),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      audioPath: audioPath == null && nullToAbsent
          ? const Value.absent()
          : Value(audioPath),
      sizeBytes: sizeBytes == null && nullToAbsent
          ? const Value.absent()
          : Value(sizeBytes),
      downloadState: Value(downloadState),
      attempts: Value(attempts),
      downloadedAt: downloadedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(downloadedAt),
      lastPlayedAt: lastPlayedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(lastPlayedAt),
    );
  }

  factory LocalTrack.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalTrack(
      id: serializer.fromJson<String>(json['id']),
      provider: serializer.fromJson<String>(json['provider']),
      externalId: serializer.fromJson<String>(json['externalId']),
      title: serializer.fromJson<String>(json['title']),
      artist: serializer.fromJson<String>(json['artist']),
      album: serializer.fromJson<String>(json['album']),
      durationSeconds: serializer.fromJson<int>(json['durationSeconds']),
      isrc: serializer.fromJson<String?>(json['isrc']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      audioPath: serializer.fromJson<String?>(json['audioPath']),
      sizeBytes: serializer.fromJson<int?>(json['sizeBytes']),
      downloadState: $LocalTracksTable.$converterdownloadState.fromJson(
        serializer.fromJson<int>(json['downloadState']),
      ),
      attempts: serializer.fromJson<int>(json['attempts']),
      downloadedAt: serializer.fromJson<DateTime?>(json['downloadedAt']),
      lastPlayedAt: serializer.fromJson<DateTime?>(json['lastPlayedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'provider': serializer.toJson<String>(provider),
      'externalId': serializer.toJson<String>(externalId),
      'title': serializer.toJson<String>(title),
      'artist': serializer.toJson<String>(artist),
      'album': serializer.toJson<String>(album),
      'durationSeconds': serializer.toJson<int>(durationSeconds),
      'isrc': serializer.toJson<String?>(isrc),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'coverPath': serializer.toJson<String?>(coverPath),
      'audioPath': serializer.toJson<String?>(audioPath),
      'sizeBytes': serializer.toJson<int?>(sizeBytes),
      'downloadState': serializer.toJson<int>(
        $LocalTracksTable.$converterdownloadState.toJson(downloadState),
      ),
      'attempts': serializer.toJson<int>(attempts),
      'downloadedAt': serializer.toJson<DateTime?>(downloadedAt),
      'lastPlayedAt': serializer.toJson<DateTime?>(lastPlayedAt),
    };
  }

  LocalTrack copyWith({
    String? id,
    String? provider,
    String? externalId,
    String? title,
    String? artist,
    String? album,
    int? durationSeconds,
    Value<String?> isrc = const Value.absent(),
    Value<String?> coverUrl = const Value.absent(),
    Value<String?> coverPath = const Value.absent(),
    Value<String?> audioPath = const Value.absent(),
    Value<int?> sizeBytes = const Value.absent(),
    DownloadState? downloadState,
    int? attempts,
    Value<DateTime?> downloadedAt = const Value.absent(),
    Value<DateTime?> lastPlayedAt = const Value.absent(),
  }) => LocalTrack(
    id: id ?? this.id,
    provider: provider ?? this.provider,
    externalId: externalId ?? this.externalId,
    title: title ?? this.title,
    artist: artist ?? this.artist,
    album: album ?? this.album,
    durationSeconds: durationSeconds ?? this.durationSeconds,
    isrc: isrc.present ? isrc.value : this.isrc,
    coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
    coverPath: coverPath.present ? coverPath.value : this.coverPath,
    audioPath: audioPath.present ? audioPath.value : this.audioPath,
    sizeBytes: sizeBytes.present ? sizeBytes.value : this.sizeBytes,
    downloadState: downloadState ?? this.downloadState,
    attempts: attempts ?? this.attempts,
    downloadedAt: downloadedAt.present ? downloadedAt.value : this.downloadedAt,
    lastPlayedAt: lastPlayedAt.present ? lastPlayedAt.value : this.lastPlayedAt,
  );
  LocalTrack copyWithCompanion(LocalTracksCompanion data) {
    return LocalTrack(
      id: data.id.present ? data.id.value : this.id,
      provider: data.provider.present ? data.provider.value : this.provider,
      externalId: data.externalId.present
          ? data.externalId.value
          : this.externalId,
      title: data.title.present ? data.title.value : this.title,
      artist: data.artist.present ? data.artist.value : this.artist,
      album: data.album.present ? data.album.value : this.album,
      durationSeconds: data.durationSeconds.present
          ? data.durationSeconds.value
          : this.durationSeconds,
      isrc: data.isrc.present ? data.isrc.value : this.isrc,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      audioPath: data.audioPath.present ? data.audioPath.value : this.audioPath,
      sizeBytes: data.sizeBytes.present ? data.sizeBytes.value : this.sizeBytes,
      downloadState: data.downloadState.present
          ? data.downloadState.value
          : this.downloadState,
      attempts: data.attempts.present ? data.attempts.value : this.attempts,
      downloadedAt: data.downloadedAt.present
          ? data.downloadedAt.value
          : this.downloadedAt,
      lastPlayedAt: data.lastPlayedAt.present
          ? data.lastPlayedAt.value
          : this.lastPlayedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalTrack(')
          ..write('id: $id, ')
          ..write('provider: $provider, ')
          ..write('externalId: $externalId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('isrc: $isrc, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('coverPath: $coverPath, ')
          ..write('audioPath: $audioPath, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('downloadState: $downloadState, ')
          ..write('attempts: $attempts, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    provider,
    externalId,
    title,
    artist,
    album,
    durationSeconds,
    isrc,
    coverUrl,
    coverPath,
    audioPath,
    sizeBytes,
    downloadState,
    attempts,
    downloadedAt,
    lastPlayedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalTrack &&
          other.id == this.id &&
          other.provider == this.provider &&
          other.externalId == this.externalId &&
          other.title == this.title &&
          other.artist == this.artist &&
          other.album == this.album &&
          other.durationSeconds == this.durationSeconds &&
          other.isrc == this.isrc &&
          other.coverUrl == this.coverUrl &&
          other.coverPath == this.coverPath &&
          other.audioPath == this.audioPath &&
          other.sizeBytes == this.sizeBytes &&
          other.downloadState == this.downloadState &&
          other.attempts == this.attempts &&
          other.downloadedAt == this.downloadedAt &&
          other.lastPlayedAt == this.lastPlayedAt);
}

class LocalTracksCompanion extends UpdateCompanion<LocalTrack> {
  final Value<String> id;
  final Value<String> provider;
  final Value<String> externalId;
  final Value<String> title;
  final Value<String> artist;
  final Value<String> album;
  final Value<int> durationSeconds;
  final Value<String?> isrc;
  final Value<String?> coverUrl;
  final Value<String?> coverPath;
  final Value<String?> audioPath;
  final Value<int?> sizeBytes;
  final Value<DownloadState> downloadState;
  final Value<int> attempts;
  final Value<DateTime?> downloadedAt;
  final Value<DateTime?> lastPlayedAt;
  final Value<int> rowid;
  const LocalTracksCompanion({
    this.id = const Value.absent(),
    this.provider = const Value.absent(),
    this.externalId = const Value.absent(),
    this.title = const Value.absent(),
    this.artist = const Value.absent(),
    this.album = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.isrc = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.audioPath = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    this.downloadState = const Value.absent(),
    this.attempts = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalTracksCompanion.insert({
    required String id,
    required String provider,
    required String externalId,
    required String title,
    required String artist,
    this.album = const Value.absent(),
    this.durationSeconds = const Value.absent(),
    this.isrc = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.audioPath = const Value.absent(),
    this.sizeBytes = const Value.absent(),
    required DownloadState downloadState,
    this.attempts = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.lastPlayedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       provider = Value(provider),
       externalId = Value(externalId),
       title = Value(title),
       artist = Value(artist),
       downloadState = Value(downloadState);
  static Insertable<LocalTrack> custom({
    Expression<String>? id,
    Expression<String>? provider,
    Expression<String>? externalId,
    Expression<String>? title,
    Expression<String>? artist,
    Expression<String>? album,
    Expression<int>? durationSeconds,
    Expression<String>? isrc,
    Expression<String>? coverUrl,
    Expression<String>? coverPath,
    Expression<String>? audioPath,
    Expression<int>? sizeBytes,
    Expression<int>? downloadState,
    Expression<int>? attempts,
    Expression<DateTime>? downloadedAt,
    Expression<DateTime>? lastPlayedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (provider != null) 'provider': provider,
      if (externalId != null) 'external_id': externalId,
      if (title != null) 'title': title,
      if (artist != null) 'artist': artist,
      if (album != null) 'album': album,
      if (durationSeconds != null) 'duration_seconds': durationSeconds,
      if (isrc != null) 'isrc': isrc,
      if (coverUrl != null) 'cover_url': coverUrl,
      if (coverPath != null) 'cover_path': coverPath,
      if (audioPath != null) 'audio_path': audioPath,
      if (sizeBytes != null) 'size_bytes': sizeBytes,
      if (downloadState != null) 'download_state': downloadState,
      if (attempts != null) 'attempts': attempts,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (lastPlayedAt != null) 'last_played_at': lastPlayedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalTracksCompanion copyWith({
    Value<String>? id,
    Value<String>? provider,
    Value<String>? externalId,
    Value<String>? title,
    Value<String>? artist,
    Value<String>? album,
    Value<int>? durationSeconds,
    Value<String?>? isrc,
    Value<String?>? coverUrl,
    Value<String?>? coverPath,
    Value<String?>? audioPath,
    Value<int?>? sizeBytes,
    Value<DownloadState>? downloadState,
    Value<int>? attempts,
    Value<DateTime?>? downloadedAt,
    Value<DateTime?>? lastPlayedAt,
    Value<int>? rowid,
  }) {
    return LocalTracksCompanion(
      id: id ?? this.id,
      provider: provider ?? this.provider,
      externalId: externalId ?? this.externalId,
      title: title ?? this.title,
      artist: artist ?? this.artist,
      album: album ?? this.album,
      durationSeconds: durationSeconds ?? this.durationSeconds,
      isrc: isrc ?? this.isrc,
      coverUrl: coverUrl ?? this.coverUrl,
      coverPath: coverPath ?? this.coverPath,
      audioPath: audioPath ?? this.audioPath,
      sizeBytes: sizeBytes ?? this.sizeBytes,
      downloadState: downloadState ?? this.downloadState,
      attempts: attempts ?? this.attempts,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      lastPlayedAt: lastPlayedAt ?? this.lastPlayedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (provider.present) {
      map['provider'] = Variable<String>(provider.value);
    }
    if (externalId.present) {
      map['external_id'] = Variable<String>(externalId.value);
    }
    if (title.present) {
      map['title'] = Variable<String>(title.value);
    }
    if (artist.present) {
      map['artist'] = Variable<String>(artist.value);
    }
    if (album.present) {
      map['album'] = Variable<String>(album.value);
    }
    if (durationSeconds.present) {
      map['duration_seconds'] = Variable<int>(durationSeconds.value);
    }
    if (isrc.present) {
      map['isrc'] = Variable<String>(isrc.value);
    }
    if (coverUrl.present) {
      map['cover_url'] = Variable<String>(coverUrl.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (audioPath.present) {
      map['audio_path'] = Variable<String>(audioPath.value);
    }
    if (sizeBytes.present) {
      map['size_bytes'] = Variable<int>(sizeBytes.value);
    }
    if (downloadState.present) {
      map['download_state'] = Variable<int>(
        $LocalTracksTable.$converterdownloadState.toSql(downloadState.value),
      );
    }
    if (attempts.present) {
      map['attempts'] = Variable<int>(attempts.value);
    }
    if (downloadedAt.present) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt.value);
    }
    if (lastPlayedAt.present) {
      map['last_played_at'] = Variable<DateTime>(lastPlayedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalTracksCompanion(')
          ..write('id: $id, ')
          ..write('provider: $provider, ')
          ..write('externalId: $externalId, ')
          ..write('title: $title, ')
          ..write('artist: $artist, ')
          ..write('album: $album, ')
          ..write('durationSeconds: $durationSeconds, ')
          ..write('isrc: $isrc, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('coverPath: $coverPath, ')
          ..write('audioPath: $audioPath, ')
          ..write('sizeBytes: $sizeBytes, ')
          ..write('downloadState: $downloadState, ')
          ..write('attempts: $attempts, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('lastPlayedAt: $lastPlayedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPlaylistsTable extends LocalPlaylists
    with TableInfo<$LocalPlaylistsTable, LocalPlaylistRow> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPlaylistsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<String> id = GeneratedColumn<String>(
    'id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _nameMeta = const VerificationMeta('name');
  @override
  late final GeneratedColumn<String> name = GeneratedColumn<String>(
    'name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _coverUrlMeta = const VerificationMeta(
    'coverUrl',
  );
  @override
  late final GeneratedColumn<String> coverUrl = GeneratedColumn<String>(
    'cover_url',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _coverPathMeta = const VerificationMeta(
    'coverPath',
  );
  @override
  late final GeneratedColumn<String> coverPath = GeneratedColumn<String>(
    'cover_path',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _ownerMeta = const VerificationMeta('owner');
  @override
  late final GeneratedColumn<String> owner = GeneratedColumn<String>(
    'owner',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant(''),
  );
  static const VerificationMeta _roleMeta = const VerificationMeta('role');
  @override
  late final GeneratedColumn<String> role = GeneratedColumn<String>(
    'role',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
    defaultValue: const Constant('owner'),
  );
  static const VerificationMeta _serverUpdatedAtMeta = const VerificationMeta(
    'serverUpdatedAt',
  );
  @override
  late final GeneratedColumn<String> serverUpdatedAt = GeneratedColumn<String>(
    'server_updated_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _pausedMeta = const VerificationMeta('paused');
  @override
  late final GeneratedColumn<bool> paused = GeneratedColumn<bool>(
    'paused',
    aliasedName,
    false,
    type: DriftSqlType.bool,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'CHECK ("paused" IN (0, 1))',
    ),
    defaultValue: const Constant(false),
  );
  static const VerificationMeta _downloadedAtMeta = const VerificationMeta(
    'downloadedAt',
  );
  @override
  late final GeneratedColumn<DateTime> downloadedAt = GeneratedColumn<DateTime>(
    'downloaded_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [
    id,
    name,
    coverUrl,
    coverPath,
    owner,
    role,
    serverUpdatedAt,
    paused,
    downloadedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_playlists';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalPlaylistRow> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    } else if (isInserting) {
      context.missing(_idMeta);
    }
    if (data.containsKey('name')) {
      context.handle(
        _nameMeta,
        name.isAcceptableOrUnknown(data['name']!, _nameMeta),
      );
    } else if (isInserting) {
      context.missing(_nameMeta);
    }
    if (data.containsKey('cover_url')) {
      context.handle(
        _coverUrlMeta,
        coverUrl.isAcceptableOrUnknown(data['cover_url']!, _coverUrlMeta),
      );
    }
    if (data.containsKey('cover_path')) {
      context.handle(
        _coverPathMeta,
        coverPath.isAcceptableOrUnknown(data['cover_path']!, _coverPathMeta),
      );
    }
    if (data.containsKey('owner')) {
      context.handle(
        _ownerMeta,
        owner.isAcceptableOrUnknown(data['owner']!, _ownerMeta),
      );
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    }
    if (data.containsKey('server_updated_at')) {
      context.handle(
        _serverUpdatedAtMeta,
        serverUpdatedAt.isAcceptableOrUnknown(
          data['server_updated_at']!,
          _serverUpdatedAtMeta,
        ),
      );
    }
    if (data.containsKey('paused')) {
      context.handle(
        _pausedMeta,
        paused.isAcceptableOrUnknown(data['paused']!, _pausedMeta),
      );
    }
    if (data.containsKey('downloaded_at')) {
      context.handle(
        _downloadedAtMeta,
        downloadedAt.isAcceptableOrUnknown(
          data['downloaded_at']!,
          _downloadedAtMeta,
        ),
      );
    } else if (isInserting) {
      context.missing(_downloadedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  LocalPlaylistRow map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPlaylistRow(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}id'],
      )!,
      name: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}name'],
      )!,
      coverUrl: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_url'],
      ),
      coverPath: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}cover_path'],
      ),
      owner: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}owner'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
      serverUpdatedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}server_updated_at'],
      ),
      paused: attachedDatabase.typeMapping.read(
        DriftSqlType.bool,
        data['${effectivePrefix}paused'],
      )!,
      downloadedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}downloaded_at'],
      )!,
    );
  }

  @override
  $LocalPlaylistsTable createAlias(String alias) {
    return $LocalPlaylistsTable(attachedDatabase, alias);
  }
}

class LocalPlaylistRow extends DataClass
    implements Insertable<LocalPlaylistRow> {
  /// Id da playlist no servidor.
  final String id;
  final String name;
  final String? coverUrl;
  final String? coverPath;
  final String owner;
  final String role;

  /// `updated_at` do servidor quando foi sincronizada (Passo 11).
  final String? serverUpdatedAt;
  final bool paused;
  final DateTime downloadedAt;
  const LocalPlaylistRow({
    required this.id,
    required this.name,
    this.coverUrl,
    this.coverPath,
    required this.owner,
    required this.role,
    this.serverUpdatedAt,
    required this.paused,
    required this.downloadedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<String>(id);
    map['name'] = Variable<String>(name);
    if (!nullToAbsent || coverUrl != null) {
      map['cover_url'] = Variable<String>(coverUrl);
    }
    if (!nullToAbsent || coverPath != null) {
      map['cover_path'] = Variable<String>(coverPath);
    }
    map['owner'] = Variable<String>(owner);
    map['role'] = Variable<String>(role);
    if (!nullToAbsent || serverUpdatedAt != null) {
      map['server_updated_at'] = Variable<String>(serverUpdatedAt);
    }
    map['paused'] = Variable<bool>(paused);
    map['downloaded_at'] = Variable<DateTime>(downloadedAt);
    return map;
  }

  LocalPlaylistsCompanion toCompanion(bool nullToAbsent) {
    return LocalPlaylistsCompanion(
      id: Value(id),
      name: Value(name),
      coverUrl: coverUrl == null && nullToAbsent
          ? const Value.absent()
          : Value(coverUrl),
      coverPath: coverPath == null && nullToAbsent
          ? const Value.absent()
          : Value(coverPath),
      owner: Value(owner),
      role: Value(role),
      serverUpdatedAt: serverUpdatedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(serverUpdatedAt),
      paused: Value(paused),
      downloadedAt: Value(downloadedAt),
    );
  }

  factory LocalPlaylistRow.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPlaylistRow(
      id: serializer.fromJson<String>(json['id']),
      name: serializer.fromJson<String>(json['name']),
      coverUrl: serializer.fromJson<String?>(json['coverUrl']),
      coverPath: serializer.fromJson<String?>(json['coverPath']),
      owner: serializer.fromJson<String>(json['owner']),
      role: serializer.fromJson<String>(json['role']),
      serverUpdatedAt: serializer.fromJson<String?>(json['serverUpdatedAt']),
      paused: serializer.fromJson<bool>(json['paused']),
      downloadedAt: serializer.fromJson<DateTime>(json['downloadedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<String>(id),
      'name': serializer.toJson<String>(name),
      'coverUrl': serializer.toJson<String?>(coverUrl),
      'coverPath': serializer.toJson<String?>(coverPath),
      'owner': serializer.toJson<String>(owner),
      'role': serializer.toJson<String>(role),
      'serverUpdatedAt': serializer.toJson<String?>(serverUpdatedAt),
      'paused': serializer.toJson<bool>(paused),
      'downloadedAt': serializer.toJson<DateTime>(downloadedAt),
    };
  }

  LocalPlaylistRow copyWith({
    String? id,
    String? name,
    Value<String?> coverUrl = const Value.absent(),
    Value<String?> coverPath = const Value.absent(),
    String? owner,
    String? role,
    Value<String?> serverUpdatedAt = const Value.absent(),
    bool? paused,
    DateTime? downloadedAt,
  }) => LocalPlaylistRow(
    id: id ?? this.id,
    name: name ?? this.name,
    coverUrl: coverUrl.present ? coverUrl.value : this.coverUrl,
    coverPath: coverPath.present ? coverPath.value : this.coverPath,
    owner: owner ?? this.owner,
    role: role ?? this.role,
    serverUpdatedAt: serverUpdatedAt.present
        ? serverUpdatedAt.value
        : this.serverUpdatedAt,
    paused: paused ?? this.paused,
    downloadedAt: downloadedAt ?? this.downloadedAt,
  );
  LocalPlaylistRow copyWithCompanion(LocalPlaylistsCompanion data) {
    return LocalPlaylistRow(
      id: data.id.present ? data.id.value : this.id,
      name: data.name.present ? data.name.value : this.name,
      coverUrl: data.coverUrl.present ? data.coverUrl.value : this.coverUrl,
      coverPath: data.coverPath.present ? data.coverPath.value : this.coverPath,
      owner: data.owner.present ? data.owner.value : this.owner,
      role: data.role.present ? data.role.value : this.role,
      serverUpdatedAt: data.serverUpdatedAt.present
          ? data.serverUpdatedAt.value
          : this.serverUpdatedAt,
      paused: data.paused.present ? data.paused.value : this.paused,
      downloadedAt: data.downloadedAt.present
          ? data.downloadedAt.value
          : this.downloadedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaylistRow(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('coverPath: $coverPath, ')
          ..write('owner: $owner, ')
          ..write('role: $role, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('paused: $paused, ')
          ..write('downloadedAt: $downloadedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(
    id,
    name,
    coverUrl,
    coverPath,
    owner,
    role,
    serverUpdatedAt,
    paused,
    downloadedAt,
  );
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPlaylistRow &&
          other.id == this.id &&
          other.name == this.name &&
          other.coverUrl == this.coverUrl &&
          other.coverPath == this.coverPath &&
          other.owner == this.owner &&
          other.role == this.role &&
          other.serverUpdatedAt == this.serverUpdatedAt &&
          other.paused == this.paused &&
          other.downloadedAt == this.downloadedAt);
}

class LocalPlaylistsCompanion extends UpdateCompanion<LocalPlaylistRow> {
  final Value<String> id;
  final Value<String> name;
  final Value<String?> coverUrl;
  final Value<String?> coverPath;
  final Value<String> owner;
  final Value<String> role;
  final Value<String?> serverUpdatedAt;
  final Value<bool> paused;
  final Value<DateTime> downloadedAt;
  final Value<int> rowid;
  const LocalPlaylistsCompanion({
    this.id = const Value.absent(),
    this.name = const Value.absent(),
    this.coverUrl = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.owner = const Value.absent(),
    this.role = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.paused = const Value.absent(),
    this.downloadedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPlaylistsCompanion.insert({
    required String id,
    required String name,
    this.coverUrl = const Value.absent(),
    this.coverPath = const Value.absent(),
    this.owner = const Value.absent(),
    this.role = const Value.absent(),
    this.serverUpdatedAt = const Value.absent(),
    this.paused = const Value.absent(),
    required DateTime downloadedAt,
    this.rowid = const Value.absent(),
  }) : id = Value(id),
       name = Value(name),
       downloadedAt = Value(downloadedAt);
  static Insertable<LocalPlaylistRow> custom({
    Expression<String>? id,
    Expression<String>? name,
    Expression<String>? coverUrl,
    Expression<String>? coverPath,
    Expression<String>? owner,
    Expression<String>? role,
    Expression<String>? serverUpdatedAt,
    Expression<bool>? paused,
    Expression<DateTime>? downloadedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (name != null) 'name': name,
      if (coverUrl != null) 'cover_url': coverUrl,
      if (coverPath != null) 'cover_path': coverPath,
      if (owner != null) 'owner': owner,
      if (role != null) 'role': role,
      if (serverUpdatedAt != null) 'server_updated_at': serverUpdatedAt,
      if (paused != null) 'paused': paused,
      if (downloadedAt != null) 'downloaded_at': downloadedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPlaylistsCompanion copyWith({
    Value<String>? id,
    Value<String>? name,
    Value<String?>? coverUrl,
    Value<String?>? coverPath,
    Value<String>? owner,
    Value<String>? role,
    Value<String?>? serverUpdatedAt,
    Value<bool>? paused,
    Value<DateTime>? downloadedAt,
    Value<int>? rowid,
  }) {
    return LocalPlaylistsCompanion(
      id: id ?? this.id,
      name: name ?? this.name,
      coverUrl: coverUrl ?? this.coverUrl,
      coverPath: coverPath ?? this.coverPath,
      owner: owner ?? this.owner,
      role: role ?? this.role,
      serverUpdatedAt: serverUpdatedAt ?? this.serverUpdatedAt,
      paused: paused ?? this.paused,
      downloadedAt: downloadedAt ?? this.downloadedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<String>(id.value);
    }
    if (name.present) {
      map['name'] = Variable<String>(name.value);
    }
    if (coverUrl.present) {
      map['cover_url'] = Variable<String>(coverUrl.value);
    }
    if (coverPath.present) {
      map['cover_path'] = Variable<String>(coverPath.value);
    }
    if (owner.present) {
      map['owner'] = Variable<String>(owner.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (serverUpdatedAt.present) {
      map['server_updated_at'] = Variable<String>(serverUpdatedAt.value);
    }
    if (paused.present) {
      map['paused'] = Variable<bool>(paused.value);
    }
    if (downloadedAt.present) {
      map['downloaded_at'] = Variable<DateTime>(downloadedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaylistsCompanion(')
          ..write('id: $id, ')
          ..write('name: $name, ')
          ..write('coverUrl: $coverUrl, ')
          ..write('coverPath: $coverPath, ')
          ..write('owner: $owner, ')
          ..write('role: $role, ')
          ..write('serverUpdatedAt: $serverUpdatedAt, ')
          ..write('paused: $paused, ')
          ..write('downloadedAt: $downloadedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalPlaylistItemsTable extends LocalPlaylistItems
    with TableInfo<$LocalPlaylistItemsTable, LocalPlaylistItem> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalPlaylistItemsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _playlistIdMeta = const VerificationMeta(
    'playlistId',
  );
  @override
  late final GeneratedColumn<String> playlistId = GeneratedColumn<String>(
    'playlist_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _trackIdMeta = const VerificationMeta(
    'trackId',
  );
  @override
  late final GeneratedColumn<String> trackId = GeneratedColumn<String>(
    'track_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _positionMeta = const VerificationMeta(
    'position',
  );
  @override
  late final GeneratedColumn<int> position = GeneratedColumn<int>(
    'position',
    aliasedName,
    false,
    type: DriftSqlType.int,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _addedByMeta = const VerificationMeta(
    'addedBy',
  );
  @override
  late final GeneratedColumn<String> addedBy = GeneratedColumn<String>(
    'added_by',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  static const VerificationMeta _addedAtMeta = const VerificationMeta(
    'addedAt',
  );
  @override
  late final GeneratedColumn<String> addedAt = GeneratedColumn<String>(
    'added_at',
    aliasedName,
    true,
    type: DriftSqlType.string,
    requiredDuringInsert: false,
  );
  @override
  List<GeneratedColumn> get $columns => [
    playlistId,
    trackId,
    position,
    addedBy,
    addedAt,
  ];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_playlist_items';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalPlaylistItem> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('playlist_id')) {
      context.handle(
        _playlistIdMeta,
        playlistId.isAcceptableOrUnknown(data['playlist_id']!, _playlistIdMeta),
      );
    } else if (isInserting) {
      context.missing(_playlistIdMeta);
    }
    if (data.containsKey('track_id')) {
      context.handle(
        _trackIdMeta,
        trackId.isAcceptableOrUnknown(data['track_id']!, _trackIdMeta),
      );
    } else if (isInserting) {
      context.missing(_trackIdMeta);
    }
    if (data.containsKey('position')) {
      context.handle(
        _positionMeta,
        position.isAcceptableOrUnknown(data['position']!, _positionMeta),
      );
    } else if (isInserting) {
      context.missing(_positionMeta);
    }
    if (data.containsKey('added_by')) {
      context.handle(
        _addedByMeta,
        addedBy.isAcceptableOrUnknown(data['added_by']!, _addedByMeta),
      );
    }
    if (data.containsKey('added_at')) {
      context.handle(
        _addedAtMeta,
        addedAt.isAcceptableOrUnknown(data['added_at']!, _addedAtMeta),
      );
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {playlistId, trackId};
  @override
  LocalPlaylistItem map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalPlaylistItem(
      playlistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}playlist_id'],
      )!,
      trackId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}track_id'],
      )!,
      position: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}position'],
      )!,
      addedBy: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}added_by'],
      ),
      addedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}added_at'],
      ),
    );
  }

  @override
  $LocalPlaylistItemsTable createAlias(String alias) {
    return $LocalPlaylistItemsTable(attachedDatabase, alias);
  }
}

class LocalPlaylistItem extends DataClass
    implements Insertable<LocalPlaylistItem> {
  final String playlistId;
  final String trackId;
  final int position;
  final String? addedBy;
  final String? addedAt;
  const LocalPlaylistItem({
    required this.playlistId,
    required this.trackId,
    required this.position,
    this.addedBy,
    this.addedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['playlist_id'] = Variable<String>(playlistId);
    map['track_id'] = Variable<String>(trackId);
    map['position'] = Variable<int>(position);
    if (!nullToAbsent || addedBy != null) {
      map['added_by'] = Variable<String>(addedBy);
    }
    if (!nullToAbsent || addedAt != null) {
      map['added_at'] = Variable<String>(addedAt);
    }
    return map;
  }

  LocalPlaylistItemsCompanion toCompanion(bool nullToAbsent) {
    return LocalPlaylistItemsCompanion(
      playlistId: Value(playlistId),
      trackId: Value(trackId),
      position: Value(position),
      addedBy: addedBy == null && nullToAbsent
          ? const Value.absent()
          : Value(addedBy),
      addedAt: addedAt == null && nullToAbsent
          ? const Value.absent()
          : Value(addedAt),
    );
  }

  factory LocalPlaylistItem.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalPlaylistItem(
      playlistId: serializer.fromJson<String>(json['playlistId']),
      trackId: serializer.fromJson<String>(json['trackId']),
      position: serializer.fromJson<int>(json['position']),
      addedBy: serializer.fromJson<String?>(json['addedBy']),
      addedAt: serializer.fromJson<String?>(json['addedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'playlistId': serializer.toJson<String>(playlistId),
      'trackId': serializer.toJson<String>(trackId),
      'position': serializer.toJson<int>(position),
      'addedBy': serializer.toJson<String?>(addedBy),
      'addedAt': serializer.toJson<String?>(addedAt),
    };
  }

  LocalPlaylistItem copyWith({
    String? playlistId,
    String? trackId,
    int? position,
    Value<String?> addedBy = const Value.absent(),
    Value<String?> addedAt = const Value.absent(),
  }) => LocalPlaylistItem(
    playlistId: playlistId ?? this.playlistId,
    trackId: trackId ?? this.trackId,
    position: position ?? this.position,
    addedBy: addedBy.present ? addedBy.value : this.addedBy,
    addedAt: addedAt.present ? addedAt.value : this.addedAt,
  );
  LocalPlaylistItem copyWithCompanion(LocalPlaylistItemsCompanion data) {
    return LocalPlaylistItem(
      playlistId: data.playlistId.present
          ? data.playlistId.value
          : this.playlistId,
      trackId: data.trackId.present ? data.trackId.value : this.trackId,
      position: data.position.present ? data.position.value : this.position,
      addedBy: data.addedBy.present ? data.addedBy.value : this.addedBy,
      addedAt: data.addedAt.present ? data.addedAt.value : this.addedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaylistItem(')
          ..write('playlistId: $playlistId, ')
          ..write('trackId: $trackId, ')
          ..write('position: $position, ')
          ..write('addedBy: $addedBy, ')
          ..write('addedAt: $addedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode =>
      Object.hash(playlistId, trackId, position, addedBy, addedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalPlaylistItem &&
          other.playlistId == this.playlistId &&
          other.trackId == this.trackId &&
          other.position == this.position &&
          other.addedBy == this.addedBy &&
          other.addedAt == this.addedAt);
}

class LocalPlaylistItemsCompanion extends UpdateCompanion<LocalPlaylistItem> {
  final Value<String> playlistId;
  final Value<String> trackId;
  final Value<int> position;
  final Value<String?> addedBy;
  final Value<String?> addedAt;
  final Value<int> rowid;
  const LocalPlaylistItemsCompanion({
    this.playlistId = const Value.absent(),
    this.trackId = const Value.absent(),
    this.position = const Value.absent(),
    this.addedBy = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalPlaylistItemsCompanion.insert({
    required String playlistId,
    required String trackId,
    required int position,
    this.addedBy = const Value.absent(),
    this.addedAt = const Value.absent(),
    this.rowid = const Value.absent(),
  }) : playlistId = Value(playlistId),
       trackId = Value(trackId),
       position = Value(position);
  static Insertable<LocalPlaylistItem> custom({
    Expression<String>? playlistId,
    Expression<String>? trackId,
    Expression<int>? position,
    Expression<String>? addedBy,
    Expression<String>? addedAt,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (playlistId != null) 'playlist_id': playlistId,
      if (trackId != null) 'track_id': trackId,
      if (position != null) 'position': position,
      if (addedBy != null) 'added_by': addedBy,
      if (addedAt != null) 'added_at': addedAt,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalPlaylistItemsCompanion copyWith({
    Value<String>? playlistId,
    Value<String>? trackId,
    Value<int>? position,
    Value<String?>? addedBy,
    Value<String?>? addedAt,
    Value<int>? rowid,
  }) {
    return LocalPlaylistItemsCompanion(
      playlistId: playlistId ?? this.playlistId,
      trackId: trackId ?? this.trackId,
      position: position ?? this.position,
      addedBy: addedBy ?? this.addedBy,
      addedAt: addedAt ?? this.addedAt,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (playlistId.present) {
      map['playlist_id'] = Variable<String>(playlistId.value);
    }
    if (trackId.present) {
      map['track_id'] = Variable<String>(trackId.value);
    }
    if (position.present) {
      map['position'] = Variable<int>(position.value);
    }
    if (addedBy.present) {
      map['added_by'] = Variable<String>(addedBy.value);
    }
    if (addedAt.present) {
      map['added_at'] = Variable<String>(addedAt.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalPlaylistItemsCompanion(')
          ..write('playlistId: $playlistId, ')
          ..write('trackId: $trackId, ')
          ..write('position: $position, ')
          ..write('addedBy: $addedBy, ')
          ..write('addedAt: $addedAt, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $LocalCollaboratorsTable extends LocalCollaborators
    with TableInfo<$LocalCollaboratorsTable, LocalCollaborator> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $LocalCollaboratorsTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _playlistIdMeta = const VerificationMeta(
    'playlistId',
  );
  @override
  late final GeneratedColumn<String> playlistId = GeneratedColumn<String>(
    'playlist_id',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _userNameMeta = const VerificationMeta(
    'userName',
  );
  @override
  late final GeneratedColumn<String> userName = GeneratedColumn<String>(
    'user_name',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
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
  @override
  List<GeneratedColumn> get $columns => [playlistId, userName, role];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'local_collaborators';
  @override
  VerificationContext validateIntegrity(
    Insertable<LocalCollaborator> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('playlist_id')) {
      context.handle(
        _playlistIdMeta,
        playlistId.isAcceptableOrUnknown(data['playlist_id']!, _playlistIdMeta),
      );
    } else if (isInserting) {
      context.missing(_playlistIdMeta);
    }
    if (data.containsKey('user_name')) {
      context.handle(
        _userNameMeta,
        userName.isAcceptableOrUnknown(data['user_name']!, _userNameMeta),
      );
    } else if (isInserting) {
      context.missing(_userNameMeta);
    }
    if (data.containsKey('role')) {
      context.handle(
        _roleMeta,
        role.isAcceptableOrUnknown(data['role']!, _roleMeta),
      );
    } else if (isInserting) {
      context.missing(_roleMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {playlistId, userName};
  @override
  LocalCollaborator map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return LocalCollaborator(
      playlistId: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}playlist_id'],
      )!,
      userName: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}user_name'],
      )!,
      role: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}role'],
      )!,
    );
  }

  @override
  $LocalCollaboratorsTable createAlias(String alias) {
    return $LocalCollaboratorsTable(attachedDatabase, alias);
  }
}

class LocalCollaborator extends DataClass
    implements Insertable<LocalCollaborator> {
  final String playlistId;
  final String userName;
  final String role;
  const LocalCollaborator({
    required this.playlistId,
    required this.userName,
    required this.role,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['playlist_id'] = Variable<String>(playlistId);
    map['user_name'] = Variable<String>(userName);
    map['role'] = Variable<String>(role);
    return map;
  }

  LocalCollaboratorsCompanion toCompanion(bool nullToAbsent) {
    return LocalCollaboratorsCompanion(
      playlistId: Value(playlistId),
      userName: Value(userName),
      role: Value(role),
    );
  }

  factory LocalCollaborator.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return LocalCollaborator(
      playlistId: serializer.fromJson<String>(json['playlistId']),
      userName: serializer.fromJson<String>(json['userName']),
      role: serializer.fromJson<String>(json['role']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'playlistId': serializer.toJson<String>(playlistId),
      'userName': serializer.toJson<String>(userName),
      'role': serializer.toJson<String>(role),
    };
  }

  LocalCollaborator copyWith({
    String? playlistId,
    String? userName,
    String? role,
  }) => LocalCollaborator(
    playlistId: playlistId ?? this.playlistId,
    userName: userName ?? this.userName,
    role: role ?? this.role,
  );
  LocalCollaborator copyWithCompanion(LocalCollaboratorsCompanion data) {
    return LocalCollaborator(
      playlistId: data.playlistId.present
          ? data.playlistId.value
          : this.playlistId,
      userName: data.userName.present ? data.userName.value : this.userName,
      role: data.role.present ? data.role.value : this.role,
    );
  }

  @override
  String toString() {
    return (StringBuffer('LocalCollaborator(')
          ..write('playlistId: $playlistId, ')
          ..write('userName: $userName, ')
          ..write('role: $role')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(playlistId, userName, role);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is LocalCollaborator &&
          other.playlistId == this.playlistId &&
          other.userName == this.userName &&
          other.role == this.role);
}

class LocalCollaboratorsCompanion extends UpdateCompanion<LocalCollaborator> {
  final Value<String> playlistId;
  final Value<String> userName;
  final Value<String> role;
  final Value<int> rowid;
  const LocalCollaboratorsCompanion({
    this.playlistId = const Value.absent(),
    this.userName = const Value.absent(),
    this.role = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  LocalCollaboratorsCompanion.insert({
    required String playlistId,
    required String userName,
    required String role,
    this.rowid = const Value.absent(),
  }) : playlistId = Value(playlistId),
       userName = Value(userName),
       role = Value(role);
  static Insertable<LocalCollaborator> custom({
    Expression<String>? playlistId,
    Expression<String>? userName,
    Expression<String>? role,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (playlistId != null) 'playlist_id': playlistId,
      if (userName != null) 'user_name': userName,
      if (role != null) 'role': role,
      if (rowid != null) 'rowid': rowid,
    });
  }

  LocalCollaboratorsCompanion copyWith({
    Value<String>? playlistId,
    Value<String>? userName,
    Value<String>? role,
    Value<int>? rowid,
  }) {
    return LocalCollaboratorsCompanion(
      playlistId: playlistId ?? this.playlistId,
      userName: userName ?? this.userName,
      role: role ?? this.role,
      rowid: rowid ?? this.rowid,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (playlistId.present) {
      map['playlist_id'] = Variable<String>(playlistId.value);
    }
    if (userName.present) {
      map['user_name'] = Variable<String>(userName.value);
    }
    if (role.present) {
      map['role'] = Variable<String>(role.value);
    }
    if (rowid.present) {
      map['rowid'] = Variable<int>(rowid.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('LocalCollaboratorsCompanion(')
          ..write('playlistId: $playlistId, ')
          ..write('userName: $userName, ')
          ..write('role: $role, ')
          ..write('rowid: $rowid')
          ..write(')'))
        .toString();
  }
}

class $PendingPlaysTable extends PendingPlays
    with TableInfo<$PendingPlaysTable, PendingPlay> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $PendingPlaysTable(this.attachedDatabase, [this._alias]);
  static const VerificationMeta _idMeta = const VerificationMeta('id');
  @override
  late final GeneratedColumn<int> id = GeneratedColumn<int>(
    'id',
    aliasedName,
    false,
    hasAutoIncrement: true,
    type: DriftSqlType.int,
    requiredDuringInsert: false,
    defaultConstraints: GeneratedColumn.constraintIsAlways(
      'PRIMARY KEY AUTOINCREMENT',
    ),
  );
  static const VerificationMeta _trackJsonMeta = const VerificationMeta(
    'trackJson',
  );
  @override
  late final GeneratedColumn<String> trackJson = GeneratedColumn<String>(
    'track_json',
    aliasedName,
    false,
    type: DriftSqlType.string,
    requiredDuringInsert: true,
  );
  static const VerificationMeta _playedAtMeta = const VerificationMeta(
    'playedAt',
  );
  @override
  late final GeneratedColumn<DateTime> playedAt = GeneratedColumn<DateTime>(
    'played_at',
    aliasedName,
    false,
    type: DriftSqlType.dateTime,
    requiredDuringInsert: true,
  );
  @override
  List<GeneratedColumn> get $columns => [id, trackJson, playedAt];
  @override
  String get aliasedName => _alias ?? actualTableName;
  @override
  String get actualTableName => $name;
  static const String $name = 'pending_plays';
  @override
  VerificationContext validateIntegrity(
    Insertable<PendingPlay> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('id')) {
      context.handle(_idMeta, id.isAcceptableOrUnknown(data['id']!, _idMeta));
    }
    if (data.containsKey('track_json')) {
      context.handle(
        _trackJsonMeta,
        trackJson.isAcceptableOrUnknown(data['track_json']!, _trackJsonMeta),
      );
    } else if (isInserting) {
      context.missing(_trackJsonMeta);
    }
    if (data.containsKey('played_at')) {
      context.handle(
        _playedAtMeta,
        playedAt.isAcceptableOrUnknown(data['played_at']!, _playedAtMeta),
      );
    } else if (isInserting) {
      context.missing(_playedAtMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {id};
  @override
  PendingPlay map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return PendingPlay(
      id: attachedDatabase.typeMapping.read(
        DriftSqlType.int,
        data['${effectivePrefix}id'],
      )!,
      trackJson: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}track_json'],
      )!,
      playedAt: attachedDatabase.typeMapping.read(
        DriftSqlType.dateTime,
        data['${effectivePrefix}played_at'],
      )!,
    );
  }

  @override
  $PendingPlaysTable createAlias(String alias) {
    return $PendingPlaysTable(attachedDatabase, alias);
  }
}

class PendingPlay extends DataClass implements Insertable<PendingPlay> {
  final int id;
  final String trackJson;
  final DateTime playedAt;
  const PendingPlay({
    required this.id,
    required this.trackJson,
    required this.playedAt,
  });
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['id'] = Variable<int>(id);
    map['track_json'] = Variable<String>(trackJson);
    map['played_at'] = Variable<DateTime>(playedAt);
    return map;
  }

  PendingPlaysCompanion toCompanion(bool nullToAbsent) {
    return PendingPlaysCompanion(
      id: Value(id),
      trackJson: Value(trackJson),
      playedAt: Value(playedAt),
    );
  }

  factory PendingPlay.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return PendingPlay(
      id: serializer.fromJson<int>(json['id']),
      trackJson: serializer.fromJson<String>(json['trackJson']),
      playedAt: serializer.fromJson<DateTime>(json['playedAt']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'id': serializer.toJson<int>(id),
      'trackJson': serializer.toJson<String>(trackJson),
      'playedAt': serializer.toJson<DateTime>(playedAt),
    };
  }

  PendingPlay copyWith({int? id, String? trackJson, DateTime? playedAt}) =>
      PendingPlay(
        id: id ?? this.id,
        trackJson: trackJson ?? this.trackJson,
        playedAt: playedAt ?? this.playedAt,
      );
  PendingPlay copyWithCompanion(PendingPlaysCompanion data) {
    return PendingPlay(
      id: data.id.present ? data.id.value : this.id,
      trackJson: data.trackJson.present ? data.trackJson.value : this.trackJson,
      playedAt: data.playedAt.present ? data.playedAt.value : this.playedAt,
    );
  }

  @override
  String toString() {
    return (StringBuffer('PendingPlay(')
          ..write('id: $id, ')
          ..write('trackJson: $trackJson, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(id, trackJson, playedAt);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is PendingPlay &&
          other.id == this.id &&
          other.trackJson == this.trackJson &&
          other.playedAt == this.playedAt);
}

class PendingPlaysCompanion extends UpdateCompanion<PendingPlay> {
  final Value<int> id;
  final Value<String> trackJson;
  final Value<DateTime> playedAt;
  const PendingPlaysCompanion({
    this.id = const Value.absent(),
    this.trackJson = const Value.absent(),
    this.playedAt = const Value.absent(),
  });
  PendingPlaysCompanion.insert({
    this.id = const Value.absent(),
    required String trackJson,
    required DateTime playedAt,
  }) : trackJson = Value(trackJson),
       playedAt = Value(playedAt);
  static Insertable<PendingPlay> custom({
    Expression<int>? id,
    Expression<String>? trackJson,
    Expression<DateTime>? playedAt,
  }) {
    return RawValuesInsertable({
      if (id != null) 'id': id,
      if (trackJson != null) 'track_json': trackJson,
      if (playedAt != null) 'played_at': playedAt,
    });
  }

  PendingPlaysCompanion copyWith({
    Value<int>? id,
    Value<String>? trackJson,
    Value<DateTime>? playedAt,
  }) {
    return PendingPlaysCompanion(
      id: id ?? this.id,
      trackJson: trackJson ?? this.trackJson,
      playedAt: playedAt ?? this.playedAt,
    );
  }

  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    if (id.present) {
      map['id'] = Variable<int>(id.value);
    }
    if (trackJson.present) {
      map['track_json'] = Variable<String>(trackJson.value);
    }
    if (playedAt.present) {
      map['played_at'] = Variable<DateTime>(playedAt.value);
    }
    return map;
  }

  @override
  String toString() {
    return (StringBuffer('PendingPlaysCompanion(')
          ..write('id: $id, ')
          ..write('trackJson: $trackJson, ')
          ..write('playedAt: $playedAt')
          ..write(')'))
        .toString();
  }
}

class $AppStateTable extends AppState
    with TableInfo<$AppStateTable, AppStateEntry> {
  @override
  final GeneratedDatabase attachedDatabase;
  final String? _alias;
  $AppStateTable(this.attachedDatabase, [this._alias]);
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
  static const String $name = 'app_state';
  @override
  VerificationContext validateIntegrity(
    Insertable<AppStateEntry> instance, {
    bool isInserting = false,
  }) {
    final context = VerificationContext();
    final data = instance.toColumns(true);
    if (data.containsKey('key')) {
      context.handle(
        _keyMeta,
        key.isAcceptableOrUnknown(data['key']!, _keyMeta),
      );
    } else if (isInserting) {
      context.missing(_keyMeta);
    }
    if (data.containsKey('value')) {
      context.handle(
        _valueMeta,
        value.isAcceptableOrUnknown(data['value']!, _valueMeta),
      );
    } else if (isInserting) {
      context.missing(_valueMeta);
    }
    return context;
  }

  @override
  Set<GeneratedColumn> get $primaryKey => {key};
  @override
  AppStateEntry map(Map<String, dynamic> data, {String? tablePrefix}) {
    final effectivePrefix = tablePrefix != null ? '$tablePrefix.' : '';
    return AppStateEntry(
      key: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}key'],
      )!,
      value: attachedDatabase.typeMapping.read(
        DriftSqlType.string,
        data['${effectivePrefix}value'],
      )!,
    );
  }

  @override
  $AppStateTable createAlias(String alias) {
    return $AppStateTable(attachedDatabase, alias);
  }
}

class AppStateEntry extends DataClass implements Insertable<AppStateEntry> {
  final String key;
  final String value;
  const AppStateEntry({required this.key, required this.value});
  @override
  Map<String, Expression> toColumns(bool nullToAbsent) {
    final map = <String, Expression>{};
    map['key'] = Variable<String>(key);
    map['value'] = Variable<String>(value);
    return map;
  }

  AppStateCompanion toCompanion(bool nullToAbsent) {
    return AppStateCompanion(key: Value(key), value: Value(value));
  }

  factory AppStateEntry.fromJson(
    Map<String, dynamic> json, {
    ValueSerializer? serializer,
  }) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return AppStateEntry(
      key: serializer.fromJson<String>(json['key']),
      value: serializer.fromJson<String>(json['value']),
    );
  }
  @override
  Map<String, dynamic> toJson({ValueSerializer? serializer}) {
    serializer ??= driftRuntimeOptions.defaultSerializer;
    return <String, dynamic>{
      'key': serializer.toJson<String>(key),
      'value': serializer.toJson<String>(value),
    };
  }

  AppStateEntry copyWith({String? key, String? value}) =>
      AppStateEntry(key: key ?? this.key, value: value ?? this.value);
  AppStateEntry copyWithCompanion(AppStateCompanion data) {
    return AppStateEntry(
      key: data.key.present ? data.key.value : this.key,
      value: data.value.present ? data.value.value : this.value,
    );
  }

  @override
  String toString() {
    return (StringBuffer('AppStateEntry(')
          ..write('key: $key, ')
          ..write('value: $value')
          ..write(')'))
        .toString();
  }

  @override
  int get hashCode => Object.hash(key, value);
  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      (other is AppStateEntry &&
          other.key == this.key &&
          other.value == this.value);
}

class AppStateCompanion extends UpdateCompanion<AppStateEntry> {
  final Value<String> key;
  final Value<String> value;
  final Value<int> rowid;
  const AppStateCompanion({
    this.key = const Value.absent(),
    this.value = const Value.absent(),
    this.rowid = const Value.absent(),
  });
  AppStateCompanion.insert({
    required String key,
    required String value,
    this.rowid = const Value.absent(),
  }) : key = Value(key),
       value = Value(value);
  static Insertable<AppStateEntry> custom({
    Expression<String>? key,
    Expression<String>? value,
    Expression<int>? rowid,
  }) {
    return RawValuesInsertable({
      if (key != null) 'key': key,
      if (value != null) 'value': value,
      if (rowid != null) 'rowid': rowid,
    });
  }

  AppStateCompanion copyWith({
    Value<String>? key,
    Value<String>? value,
    Value<int>? rowid,
  }) {
    return AppStateCompanion(
      key: key ?? this.key,
      value: value ?? this.value,
      rowid: rowid ?? this.rowid,
    );
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
    return (StringBuffer('AppStateCompanion(')
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
  late final $LocalTracksTable localTracks = $LocalTracksTable(this);
  late final $LocalPlaylistsTable localPlaylists = $LocalPlaylistsTable(this);
  late final $LocalPlaylistItemsTable localPlaylistItems =
      $LocalPlaylistItemsTable(this);
  late final $LocalCollaboratorsTable localCollaborators =
      $LocalCollaboratorsTable(this);
  late final $PendingPlaysTable pendingPlays = $PendingPlaysTable(this);
  late final $AppStateTable appState = $AppStateTable(this);
  @override
  Iterable<TableInfo<Table, Object?>> get allTables =>
      allSchemaEntities.whereType<TableInfo<Table, Object?>>();
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => [
    localTracks,
    localPlaylists,
    localPlaylistItems,
    localCollaborators,
    pendingPlays,
    appState,
  ];
}

typedef $$LocalTracksTableCreateCompanionBuilder =
    LocalTracksCompanion Function({
      required String id,
      required String provider,
      required String externalId,
      required String title,
      required String artist,
      Value<String> album,
      Value<int> durationSeconds,
      Value<String?> isrc,
      Value<String?> coverUrl,
      Value<String?> coverPath,
      Value<String?> audioPath,
      Value<int?> sizeBytes,
      required DownloadState downloadState,
      Value<int> attempts,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> lastPlayedAt,
      Value<int> rowid,
    });
typedef $$LocalTracksTableUpdateCompanionBuilder =
    LocalTracksCompanion Function({
      Value<String> id,
      Value<String> provider,
      Value<String> externalId,
      Value<String> title,
      Value<String> artist,
      Value<String> album,
      Value<int> durationSeconds,
      Value<String?> isrc,
      Value<String?> coverUrl,
      Value<String?> coverPath,
      Value<String?> audioPath,
      Value<int?> sizeBytes,
      Value<DownloadState> downloadState,
      Value<int> attempts,
      Value<DateTime?> downloadedAt,
      Value<DateTime?> lastPlayedAt,
      Value<int> rowid,
    });

class $$LocalTracksTableFilterComposer
    extends Composer<_$AppDatabase, $LocalTracksTable> {
  $$LocalTracksTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get album => $composableBuilder(
    column: $table.album,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get isrc => $composableBuilder(
    column: $table.isrc,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnFilters(column),
  );

  ColumnWithTypeConverterFilters<DownloadState, DownloadState, int>
  get downloadState => $composableBuilder(
    column: $table.downloadState,
    builder: (column) => ColumnWithTypeConverterFilters(column),
  );

  ColumnFilters<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalTracksTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalTracksTable> {
  $$LocalTracksTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get provider => $composableBuilder(
    column: $table.provider,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get title => $composableBuilder(
    column: $table.title,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get artist => $composableBuilder(
    column: $table.artist,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get album => $composableBuilder(
    column: $table.album,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get isrc => $composableBuilder(
    column: $table.isrc,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get audioPath => $composableBuilder(
    column: $table.audioPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get sizeBytes => $composableBuilder(
    column: $table.sizeBytes,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get downloadState => $composableBuilder(
    column: $table.downloadState,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get attempts => $composableBuilder(
    column: $table.attempts,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalTracksTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalTracksTable> {
  $$LocalTracksTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get provider =>
      $composableBuilder(column: $table.provider, builder: (column) => column);

  GeneratedColumn<String> get externalId => $composableBuilder(
    column: $table.externalId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get title =>
      $composableBuilder(column: $table.title, builder: (column) => column);

  GeneratedColumn<String> get artist =>
      $composableBuilder(column: $table.artist, builder: (column) => column);

  GeneratedColumn<String> get album =>
      $composableBuilder(column: $table.album, builder: (column) => column);

  GeneratedColumn<int> get durationSeconds => $composableBuilder(
    column: $table.durationSeconds,
    builder: (column) => column,
  );

  GeneratedColumn<String> get isrc =>
      $composableBuilder(column: $table.isrc, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<String> get audioPath =>
      $composableBuilder(column: $table.audioPath, builder: (column) => column);

  GeneratedColumn<int> get sizeBytes =>
      $composableBuilder(column: $table.sizeBytes, builder: (column) => column);

  GeneratedColumnWithTypeConverter<DownloadState, int> get downloadState =>
      $composableBuilder(
        column: $table.downloadState,
        builder: (column) => column,
      );

  GeneratedColumn<int> get attempts =>
      $composableBuilder(column: $table.attempts, builder: (column) => column);

  GeneratedColumn<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => column,
  );

  GeneratedColumn<DateTime> get lastPlayedAt => $composableBuilder(
    column: $table.lastPlayedAt,
    builder: (column) => column,
  );
}

class $$LocalTracksTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalTracksTable,
          LocalTrack,
          $$LocalTracksTableFilterComposer,
          $$LocalTracksTableOrderingComposer,
          $$LocalTracksTableAnnotationComposer,
          $$LocalTracksTableCreateCompanionBuilder,
          $$LocalTracksTableUpdateCompanionBuilder,
          (
            LocalTrack,
            BaseReferences<_$AppDatabase, $LocalTracksTable, LocalTrack>,
          ),
          LocalTrack,
          PrefetchHooks Function()
        > {
  $$LocalTracksTableTableManager(_$AppDatabase db, $LocalTracksTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalTracksTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalTracksTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalTracksTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> provider = const Value.absent(),
                Value<String> externalId = const Value.absent(),
                Value<String> title = const Value.absent(),
                Value<String> artist = const Value.absent(),
                Value<String> album = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<String?> isrc = const Value.absent(),
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> coverPath = const Value.absent(),
                Value<String?> audioPath = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                Value<DownloadState> downloadState = const Value.absent(),
                Value<int> attempts = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalTracksCompanion(
                id: id,
                provider: provider,
                externalId: externalId,
                title: title,
                artist: artist,
                album: album,
                durationSeconds: durationSeconds,
                isrc: isrc,
                coverUrl: coverUrl,
                coverPath: coverPath,
                audioPath: audioPath,
                sizeBytes: sizeBytes,
                downloadState: downloadState,
                attempts: attempts,
                downloadedAt: downloadedAt,
                lastPlayedAt: lastPlayedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String provider,
                required String externalId,
                required String title,
                required String artist,
                Value<String> album = const Value.absent(),
                Value<int> durationSeconds = const Value.absent(),
                Value<String?> isrc = const Value.absent(),
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> coverPath = const Value.absent(),
                Value<String?> audioPath = const Value.absent(),
                Value<int?> sizeBytes = const Value.absent(),
                required DownloadState downloadState,
                Value<int> attempts = const Value.absent(),
                Value<DateTime?> downloadedAt = const Value.absent(),
                Value<DateTime?> lastPlayedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalTracksCompanion.insert(
                id: id,
                provider: provider,
                externalId: externalId,
                title: title,
                artist: artist,
                album: album,
                durationSeconds: durationSeconds,
                isrc: isrc,
                coverUrl: coverUrl,
                coverPath: coverPath,
                audioPath: audioPath,
                sizeBytes: sizeBytes,
                downloadState: downloadState,
                attempts: attempts,
                downloadedAt: downloadedAt,
                lastPlayedAt: lastPlayedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalTracksTable, LocalTrack>(table),
                  BaseReferences<_$AppDatabase, $LocalTracksTable, LocalTrack>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalTracksTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalTracksTable,
      LocalTrack,
      $$LocalTracksTableFilterComposer,
      $$LocalTracksTableOrderingComposer,
      $$LocalTracksTableAnnotationComposer,
      $$LocalTracksTableCreateCompanionBuilder,
      $$LocalTracksTableUpdateCompanionBuilder,
      (
        LocalTrack,
        BaseReferences<_$AppDatabase, $LocalTracksTable, LocalTrack>,
      ),
      LocalTrack,
      PrefetchHooks Function()
    >;
typedef $$LocalPlaylistsTableCreateCompanionBuilder =
    LocalPlaylistsCompanion Function({
      required String id,
      required String name,
      Value<String?> coverUrl,
      Value<String?> coverPath,
      Value<String> owner,
      Value<String> role,
      Value<String?> serverUpdatedAt,
      Value<bool> paused,
      required DateTime downloadedAt,
      Value<int> rowid,
    });
typedef $$LocalPlaylistsTableUpdateCompanionBuilder =
    LocalPlaylistsCompanion Function({
      Value<String> id,
      Value<String> name,
      Value<String?> coverUrl,
      Value<String?> coverPath,
      Value<String> owner,
      Value<String> role,
      Value<String?> serverUpdatedAt,
      Value<bool> paused,
      Value<DateTime> downloadedAt,
      Value<int> rowid,
    });

class $$LocalPlaylistsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalPlaylistsTable> {
  $$LocalPlaylistsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<bool> get paused => $composableBuilder(
    column: $table.paused,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalPlaylistsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalPlaylistsTable> {
  $$LocalPlaylistsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get name => $composableBuilder(
    column: $table.name,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverUrl => $composableBuilder(
    column: $table.coverUrl,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get coverPath => $composableBuilder(
    column: $table.coverPath,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get owner => $composableBuilder(
    column: $table.owner,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<bool> get paused => $composableBuilder(
    column: $table.paused,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalPlaylistsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalPlaylistsTable> {
  $$LocalPlaylistsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get name =>
      $composableBuilder(column: $table.name, builder: (column) => column);

  GeneratedColumn<String> get coverUrl =>
      $composableBuilder(column: $table.coverUrl, builder: (column) => column);

  GeneratedColumn<String> get coverPath =>
      $composableBuilder(column: $table.coverPath, builder: (column) => column);

  GeneratedColumn<String> get owner =>
      $composableBuilder(column: $table.owner, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);

  GeneratedColumn<String> get serverUpdatedAt => $composableBuilder(
    column: $table.serverUpdatedAt,
    builder: (column) => column,
  );

  GeneratedColumn<bool> get paused =>
      $composableBuilder(column: $table.paused, builder: (column) => column);

  GeneratedColumn<DateTime> get downloadedAt => $composableBuilder(
    column: $table.downloadedAt,
    builder: (column) => column,
  );
}

class $$LocalPlaylistsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalPlaylistsTable,
          LocalPlaylistRow,
          $$LocalPlaylistsTableFilterComposer,
          $$LocalPlaylistsTableOrderingComposer,
          $$LocalPlaylistsTableAnnotationComposer,
          $$LocalPlaylistsTableCreateCompanionBuilder,
          $$LocalPlaylistsTableUpdateCompanionBuilder,
          (
            LocalPlaylistRow,
            BaseReferences<
              _$AppDatabase,
              $LocalPlaylistsTable,
              LocalPlaylistRow
            >,
          ),
          LocalPlaylistRow,
          PrefetchHooks Function()
        > {
  $$LocalPlaylistsTableTableManager(
    _$AppDatabase db,
    $LocalPlaylistsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPlaylistsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPlaylistsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPlaylistsTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> id = const Value.absent(),
                Value<String> name = const Value.absent(),
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> coverPath = const Value.absent(),
                Value<String> owner = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String?> serverUpdatedAt = const Value.absent(),
                Value<bool> paused = const Value.absent(),
                Value<DateTime> downloadedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPlaylistsCompanion(
                id: id,
                name: name,
                coverUrl: coverUrl,
                coverPath: coverPath,
                owner: owner,
                role: role,
                serverUpdatedAt: serverUpdatedAt,
                paused: paused,
                downloadedAt: downloadedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String id,
                required String name,
                Value<String?> coverUrl = const Value.absent(),
                Value<String?> coverPath = const Value.absent(),
                Value<String> owner = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<String?> serverUpdatedAt = const Value.absent(),
                Value<bool> paused = const Value.absent(),
                required DateTime downloadedAt,
                Value<int> rowid = const Value.absent(),
              }) => LocalPlaylistsCompanion.insert(
                id: id,
                name: name,
                coverUrl: coverUrl,
                coverPath: coverPath,
                owner: owner,
                role: role,
                serverUpdatedAt: serverUpdatedAt,
                paused: paused,
                downloadedAt: downloadedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalPlaylistsTable, LocalPlaylistRow>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalPlaylistsTable,
                    LocalPlaylistRow
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalPlaylistsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalPlaylistsTable,
      LocalPlaylistRow,
      $$LocalPlaylistsTableFilterComposer,
      $$LocalPlaylistsTableOrderingComposer,
      $$LocalPlaylistsTableAnnotationComposer,
      $$LocalPlaylistsTableCreateCompanionBuilder,
      $$LocalPlaylistsTableUpdateCompanionBuilder,
      (
        LocalPlaylistRow,
        BaseReferences<_$AppDatabase, $LocalPlaylistsTable, LocalPlaylistRow>,
      ),
      LocalPlaylistRow,
      PrefetchHooks Function()
    >;
typedef $$LocalPlaylistItemsTableCreateCompanionBuilder =
    LocalPlaylistItemsCompanion Function({
      required String playlistId,
      required String trackId,
      required int position,
      Value<String?> addedBy,
      Value<String?> addedAt,
      Value<int> rowid,
    });
typedef $$LocalPlaylistItemsTableUpdateCompanionBuilder =
    LocalPlaylistItemsCompanion Function({
      Value<String> playlistId,
      Value<String> trackId,
      Value<int> position,
      Value<String?> addedBy,
      Value<String?> addedAt,
      Value<int> rowid,
    });

class $$LocalPlaylistItemsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalPlaylistItemsTable> {
  $$LocalPlaylistItemsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trackId => $composableBuilder(
    column: $table.trackId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get addedBy => $composableBuilder(
    column: $table.addedBy,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalPlaylistItemsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalPlaylistItemsTable> {
  $$LocalPlaylistItemsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trackId => $composableBuilder(
    column: $table.trackId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<int> get position => $composableBuilder(
    column: $table.position,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get addedBy => $composableBuilder(
    column: $table.addedBy,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get addedAt => $composableBuilder(
    column: $table.addedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalPlaylistItemsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalPlaylistItemsTable> {
  $$LocalPlaylistItemsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get trackId =>
      $composableBuilder(column: $table.trackId, builder: (column) => column);

  GeneratedColumn<int> get position =>
      $composableBuilder(column: $table.position, builder: (column) => column);

  GeneratedColumn<String> get addedBy =>
      $composableBuilder(column: $table.addedBy, builder: (column) => column);

  GeneratedColumn<String> get addedAt =>
      $composableBuilder(column: $table.addedAt, builder: (column) => column);
}

class $$LocalPlaylistItemsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalPlaylistItemsTable,
          LocalPlaylistItem,
          $$LocalPlaylistItemsTableFilterComposer,
          $$LocalPlaylistItemsTableOrderingComposer,
          $$LocalPlaylistItemsTableAnnotationComposer,
          $$LocalPlaylistItemsTableCreateCompanionBuilder,
          $$LocalPlaylistItemsTableUpdateCompanionBuilder,
          (
            LocalPlaylistItem,
            BaseReferences<
              _$AppDatabase,
              $LocalPlaylistItemsTable,
              LocalPlaylistItem
            >,
          ),
          LocalPlaylistItem,
          PrefetchHooks Function()
        > {
  $$LocalPlaylistItemsTableTableManager(
    _$AppDatabase db,
    $LocalPlaylistItemsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalPlaylistItemsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalPlaylistItemsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalPlaylistItemsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> playlistId = const Value.absent(),
                Value<String> trackId = const Value.absent(),
                Value<int> position = const Value.absent(),
                Value<String?> addedBy = const Value.absent(),
                Value<String?> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPlaylistItemsCompanion(
                playlistId: playlistId,
                trackId: trackId,
                position: position,
                addedBy: addedBy,
                addedAt: addedAt,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String playlistId,
                required String trackId,
                required int position,
                Value<String?> addedBy = const Value.absent(),
                Value<String?> addedAt = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalPlaylistItemsCompanion.insert(
                playlistId: playlistId,
                trackId: trackId,
                position: position,
                addedBy: addedBy,
                addedAt: addedAt,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalPlaylistItemsTable, LocalPlaylistItem>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalPlaylistItemsTable,
                    LocalPlaylistItem
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalPlaylistItemsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalPlaylistItemsTable,
      LocalPlaylistItem,
      $$LocalPlaylistItemsTableFilterComposer,
      $$LocalPlaylistItemsTableOrderingComposer,
      $$LocalPlaylistItemsTableAnnotationComposer,
      $$LocalPlaylistItemsTableCreateCompanionBuilder,
      $$LocalPlaylistItemsTableUpdateCompanionBuilder,
      (
        LocalPlaylistItem,
        BaseReferences<
          _$AppDatabase,
          $LocalPlaylistItemsTable,
          LocalPlaylistItem
        >,
      ),
      LocalPlaylistItem,
      PrefetchHooks Function()
    >;
typedef $$LocalCollaboratorsTableCreateCompanionBuilder =
    LocalCollaboratorsCompanion Function({
      required String playlistId,
      required String userName,
      required String role,
      Value<int> rowid,
    });
typedef $$LocalCollaboratorsTableUpdateCompanionBuilder =
    LocalCollaboratorsCompanion Function({
      Value<String> playlistId,
      Value<String> userName,
      Value<String> role,
      Value<int> rowid,
    });

class $$LocalCollaboratorsTableFilterComposer
    extends Composer<_$AppDatabase, $LocalCollaboratorsTable> {
  $$LocalCollaboratorsTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get userName => $composableBuilder(
    column: $table.userName,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnFilters(column),
  );
}

class $$LocalCollaboratorsTableOrderingComposer
    extends Composer<_$AppDatabase, $LocalCollaboratorsTable> {
  $$LocalCollaboratorsTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get userName => $composableBuilder(
    column: $table.userName,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get role => $composableBuilder(
    column: $table.role,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$LocalCollaboratorsTableAnnotationComposer
    extends Composer<_$AppDatabase, $LocalCollaboratorsTable> {
  $$LocalCollaboratorsTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get playlistId => $composableBuilder(
    column: $table.playlistId,
    builder: (column) => column,
  );

  GeneratedColumn<String> get userName =>
      $composableBuilder(column: $table.userName, builder: (column) => column);

  GeneratedColumn<String> get role =>
      $composableBuilder(column: $table.role, builder: (column) => column);
}

class $$LocalCollaboratorsTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $LocalCollaboratorsTable,
          LocalCollaborator,
          $$LocalCollaboratorsTableFilterComposer,
          $$LocalCollaboratorsTableOrderingComposer,
          $$LocalCollaboratorsTableAnnotationComposer,
          $$LocalCollaboratorsTableCreateCompanionBuilder,
          $$LocalCollaboratorsTableUpdateCompanionBuilder,
          (
            LocalCollaborator,
            BaseReferences<
              _$AppDatabase,
              $LocalCollaboratorsTable,
              LocalCollaborator
            >,
          ),
          LocalCollaborator,
          PrefetchHooks Function()
        > {
  $$LocalCollaboratorsTableTableManager(
    _$AppDatabase db,
    $LocalCollaboratorsTable table,
  ) : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$LocalCollaboratorsTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$LocalCollaboratorsTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$LocalCollaboratorsTableAnnotationComposer(
                $db: db,
                $table: table,
              ),
          updateCompanionCallback:
              ({
                Value<String> playlistId = const Value.absent(),
                Value<String> userName = const Value.absent(),
                Value<String> role = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => LocalCollaboratorsCompanion(
                playlistId: playlistId,
                userName: userName,
                role: role,
                rowid: rowid,
              ),
          createCompanionCallback:
              ({
                required String playlistId,
                required String userName,
                required String role,
                Value<int> rowid = const Value.absent(),
              }) => LocalCollaboratorsCompanion.insert(
                playlistId: playlistId,
                userName: userName,
                role: role,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$LocalCollaboratorsTable, LocalCollaborator>(
                    table,
                  ),
                  BaseReferences<
                    _$AppDatabase,
                    $LocalCollaboratorsTable,
                    LocalCollaborator
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$LocalCollaboratorsTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $LocalCollaboratorsTable,
      LocalCollaborator,
      $$LocalCollaboratorsTableFilterComposer,
      $$LocalCollaboratorsTableOrderingComposer,
      $$LocalCollaboratorsTableAnnotationComposer,
      $$LocalCollaboratorsTableCreateCompanionBuilder,
      $$LocalCollaboratorsTableUpdateCompanionBuilder,
      (
        LocalCollaborator,
        BaseReferences<
          _$AppDatabase,
          $LocalCollaboratorsTable,
          LocalCollaborator
        >,
      ),
      LocalCollaborator,
      PrefetchHooks Function()
    >;
typedef $$PendingPlaysTableCreateCompanionBuilder =
    PendingPlaysCompanion Function({
      Value<int> id,
      required String trackJson,
      required DateTime playedAt,
    });
typedef $$PendingPlaysTableUpdateCompanionBuilder =
    PendingPlaysCompanion Function({
      Value<int> id,
      Value<String> trackJson,
      Value<DateTime> playedAt,
    });

class $$PendingPlaysTableFilterComposer
    extends Composer<_$AppDatabase, $PendingPlaysTable> {
  $$PendingPlaysTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get trackJson => $composableBuilder(
    column: $table.trackJson,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnFilters(column),
  );
}

class $$PendingPlaysTableOrderingComposer
    extends Composer<_$AppDatabase, $PendingPlaysTable> {
  $$PendingPlaysTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<int> get id => $composableBuilder(
    column: $table.id,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get trackJson => $composableBuilder(
    column: $table.trackJson,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<DateTime> get playedAt => $composableBuilder(
    column: $table.playedAt,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$PendingPlaysTableAnnotationComposer
    extends Composer<_$AppDatabase, $PendingPlaysTable> {
  $$PendingPlaysTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<int> get id =>
      $composableBuilder(column: $table.id, builder: (column) => column);

  GeneratedColumn<String> get trackJson =>
      $composableBuilder(column: $table.trackJson, builder: (column) => column);

  GeneratedColumn<DateTime> get playedAt =>
      $composableBuilder(column: $table.playedAt, builder: (column) => column);
}

class $$PendingPlaysTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $PendingPlaysTable,
          PendingPlay,
          $$PendingPlaysTableFilterComposer,
          $$PendingPlaysTableOrderingComposer,
          $$PendingPlaysTableAnnotationComposer,
          $$PendingPlaysTableCreateCompanionBuilder,
          $$PendingPlaysTableUpdateCompanionBuilder,
          (
            PendingPlay,
            BaseReferences<_$AppDatabase, $PendingPlaysTable, PendingPlay>,
          ),
          PendingPlay,
          PrefetchHooks Function()
        > {
  $$PendingPlaysTableTableManager(_$AppDatabase db, $PendingPlaysTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$PendingPlaysTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$PendingPlaysTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$PendingPlaysTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                Value<String> trackJson = const Value.absent(),
                Value<DateTime> playedAt = const Value.absent(),
              }) => PendingPlaysCompanion(
                id: id,
                trackJson: trackJson,
                playedAt: playedAt,
              ),
          createCompanionCallback:
              ({
                Value<int> id = const Value.absent(),
                required String trackJson,
                required DateTime playedAt,
              }) => PendingPlaysCompanion.insert(
                id: id,
                trackJson: trackJson,
                playedAt: playedAt,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$PendingPlaysTable, PendingPlay>(table),
                  BaseReferences<
                    _$AppDatabase,
                    $PendingPlaysTable,
                    PendingPlay
                  >(db, table, e),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$PendingPlaysTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $PendingPlaysTable,
      PendingPlay,
      $$PendingPlaysTableFilterComposer,
      $$PendingPlaysTableOrderingComposer,
      $$PendingPlaysTableAnnotationComposer,
      $$PendingPlaysTableCreateCompanionBuilder,
      $$PendingPlaysTableUpdateCompanionBuilder,
      (
        PendingPlay,
        BaseReferences<_$AppDatabase, $PendingPlaysTable, PendingPlay>,
      ),
      PendingPlay,
      PrefetchHooks Function()
    >;
typedef $$AppStateTableCreateCompanionBuilder =
    AppStateCompanion Function({
      required String key,
      required String value,
      Value<int> rowid,
    });
typedef $$AppStateTableUpdateCompanionBuilder =
    AppStateCompanion Function({
      Value<String> key,
      Value<String> value,
      Value<int> rowid,
    });

class $$AppStateTableFilterComposer
    extends Composer<_$AppDatabase, $AppStateTable> {
  $$AppStateTableFilterComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnFilters<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnFilters(column),
  );

  ColumnFilters<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnFilters(column),
  );
}

class $$AppStateTableOrderingComposer
    extends Composer<_$AppDatabase, $AppStateTable> {
  $$AppStateTableOrderingComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  ColumnOrderings<String> get key => $composableBuilder(
    column: $table.key,
    builder: (column) => ColumnOrderings(column),
  );

  ColumnOrderings<String> get value => $composableBuilder(
    column: $table.value,
    builder: (column) => ColumnOrderings(column),
  );
}

class $$AppStateTableAnnotationComposer
    extends Composer<_$AppDatabase, $AppStateTable> {
  $$AppStateTableAnnotationComposer({
    required super.$db,
    required super.$table,
    super.joinBuilder,
    super.$addJoinBuilderToRootComposer,
    super.$removeJoinBuilderFromRootComposer,
  });
  GeneratedColumn<String> get key =>
      $composableBuilder(column: $table.key, builder: (column) => column);

  GeneratedColumn<String> get value =>
      $composableBuilder(column: $table.value, builder: (column) => column);
}

class $$AppStateTableTableManager
    extends
        RootTableManager<
          _$AppDatabase,
          $AppStateTable,
          AppStateEntry,
          $$AppStateTableFilterComposer,
          $$AppStateTableOrderingComposer,
          $$AppStateTableAnnotationComposer,
          $$AppStateTableCreateCompanionBuilder,
          $$AppStateTableUpdateCompanionBuilder,
          (
            AppStateEntry,
            BaseReferences<_$AppDatabase, $AppStateTable, AppStateEntry>,
          ),
          AppStateEntry,
          PrefetchHooks Function()
        > {
  $$AppStateTableTableManager(_$AppDatabase db, $AppStateTable table)
    : super(
        TableManagerState(
          db: db,
          table: table,
          createFilteringComposer: () =>
              $$AppStateTableFilterComposer($db: db, $table: table),
          createOrderingComposer: () =>
              $$AppStateTableOrderingComposer($db: db, $table: table),
          createComputedFieldComposer: () =>
              $$AppStateTableAnnotationComposer($db: db, $table: table),
          updateCompanionCallback:
              ({
                Value<String> key = const Value.absent(),
                Value<String> value = const Value.absent(),
                Value<int> rowid = const Value.absent(),
              }) => AppStateCompanion(key: key, value: value, rowid: rowid),
          createCompanionCallback:
              ({
                required String key,
                required String value,
                Value<int> rowid = const Value.absent(),
              }) => AppStateCompanion.insert(
                key: key,
                value: value,
                rowid: rowid,
              ),
          withReferenceMapper: (p0) => p0
              .map(
                (e) => (
                  e.readTable<$AppStateTable, AppStateEntry>(table),
                  BaseReferences<_$AppDatabase, $AppStateTable, AppStateEntry>(
                    db,
                    table,
                    e,
                  ),
                ),
              )
              .toList(),
          prefetchHooksCallback: null,
        ),
      );
}

typedef $$AppStateTableProcessedTableManager =
    ProcessedTableManager<
      _$AppDatabase,
      $AppStateTable,
      AppStateEntry,
      $$AppStateTableFilterComposer,
      $$AppStateTableOrderingComposer,
      $$AppStateTableAnnotationComposer,
      $$AppStateTableCreateCompanionBuilder,
      $$AppStateTableUpdateCompanionBuilder,
      (
        AppStateEntry,
        BaseReferences<_$AppDatabase, $AppStateTable, AppStateEntry>,
      ),
      AppStateEntry,
      PrefetchHooks Function()
    >;

class $AppDatabaseManager {
  final _$AppDatabase _db;
  $AppDatabaseManager(this._db);
  $$LocalTracksTableTableManager get localTracks =>
      $$LocalTracksTableTableManager(_db, _db.localTracks);
  $$LocalPlaylistsTableTableManager get localPlaylists =>
      $$LocalPlaylistsTableTableManager(_db, _db.localPlaylists);
  $$LocalPlaylistItemsTableTableManager get localPlaylistItems =>
      $$LocalPlaylistItemsTableTableManager(_db, _db.localPlaylistItems);
  $$LocalCollaboratorsTableTableManager get localCollaborators =>
      $$LocalCollaboratorsTableTableManager(_db, _db.localCollaborators);
  $$PendingPlaysTableTableManager get pendingPlays =>
      $$PendingPlaysTableTableManager(_db, _db.pendingPlays);
  $$AppStateTableTableManager get appState =>
      $$AppStateTableTableManager(_db, _db.appState);
}
