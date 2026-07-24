import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  static AppDatabase? _instance;
  static Database? _db;

  AppDatabase._();

  static AppDatabase get instance => _instance ??= AppDatabase._();

  Future<Database> get database async {
    _db ??= await _initDb();
    return _db!;
  }

  Future<Database> _initDb() async {
    final dir = await getApplicationDocumentsDirectory();
    final path = p.join(dir.path, 'nas_player.db');
    return openDatabase(
      path,
      version: 2,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT 'Unknown Artist',
        album TEXT NOT NULL DEFAULT 'Unknown Album',
        title_lc TEXT NOT NULL DEFAULT '',
        artist_lc TEXT NOT NULL DEFAULT '',
        album_lc TEXT NOT NULL DEFAULT '',
        duration_ms INTEGER NOT NULL DEFAULT 0,
        file_path TEXT NOT NULL,
        nas_path TEXT,
        artwork_path TEXT,
        format TEXT NOT NULL DEFAULT '',
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        source TEXT NOT NULL DEFAULT 'local',
        folder_path TEXT NOT NULL DEFAULT '',
        date_modified INTEGER,
        indexed_at INTEGER NOT NULL DEFAULT 0
      )
    ''');

    await db.execute('''
      CREATE TABLE playlists (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        created_at INTEGER NOT NULL,
        updated_at INTEGER NOT NULL,
        cover_art_path TEXT
      )
    ''');

    await db.execute('''
      CREATE TABLE playlist_tracks (
        row_id INTEGER PRIMARY KEY AUTOINCREMENT,
        playlist_id TEXT NOT NULL REFERENCES playlists(id) ON DELETE CASCADE,
        track_path TEXT NOT NULL,
        track_id TEXT NOT NULL,
        position INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE nas_configs (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL,
        base_url TEXT NOT NULL,
        vendor TEXT NOT NULL DEFAULT 'unknown',
        is_active INTEGER NOT NULL DEFAULT 0,
        added_at INTEGER NOT NULL
      )
    ''');

    await _createV2Tables(db);
    await _createIndexes(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute("ALTER TABLE tracks ADD COLUMN title_lc TEXT NOT NULL DEFAULT ''");
      await db.execute("ALTER TABLE tracks ADD COLUMN artist_lc TEXT NOT NULL DEFAULT ''");
      await db.execute("ALTER TABLE tracks ADD COLUMN album_lc TEXT NOT NULL DEFAULT ''");
      await db.execute('ALTER TABLE tracks ADD COLUMN nas_path TEXT');
      await db.execute('ALTER TABLE tracks ADD COLUMN date_modified INTEGER');
      await db.execute('''
        UPDATE tracks SET title_lc = LOWER(title),
                          artist_lc = LOWER(artist),
                          album_lc = LOWER(album)
      ''');
      await _createV2Tables(db);
      await _createIndexes(db);
    }
  }

  Future<void> _createV2Tables(Database db) async {
    await db.execute('''
      CREATE TABLE IF NOT EXISTS play_history (
        row_id INTEGER PRIMARY KEY AUTOINCREMENT,
        track_id TEXT NOT NULL,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT '',
        album TEXT NOT NULL DEFAULT '',
        file_path TEXT NOT NULL,
        nas_path TEXT,
        source TEXT NOT NULL DEFAULT 'local',
        played_at INTEGER NOT NULL
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS downloads (
        nas_path TEXT PRIMARY KEY,
        nas_id TEXT NOT NULL,
        local_path TEXT NOT NULL,
        title TEXT NOT NULL DEFAULT '',
        size_bytes INTEGER,
        status TEXT NOT NULL DEFAULT 'pending',
        downloaded_at INTEGER
      )
    ''');

    await db.execute('''
      CREATE TABLE IF NOT EXISTS nas_index (
        nas_id TEXT NOT NULL,
        path TEXT NOT NULL,
        name TEXT NOT NULL,
        parent_path TEXT NOT NULL,
        is_directory INTEGER NOT NULL DEFAULT 0,
        size_bytes INTEGER,
        modified_at INTEGER,
        indexed_at INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY (nas_id, path)
      )
    ''');
  }

  Future<void> _createIndexes(Database db) async {
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tracks_folder ON tracks(folder_path)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tracks_title_lc ON tracks(title_lc)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_tracks_album ON tracks(album)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_playlist_tracks_pl ON playlist_tracks(playlist_id)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_history_played ON play_history(played_at)');
    await db.execute(
        'CREATE INDEX IF NOT EXISTS idx_nas_index_parent ON nas_index(nas_id, parent_path)');
  }

  // ── LIKE helpers ────────────────────────────────────────────────────────────

  /// Escape SQL LIKE wildcards so user-supplied text matches literally.
  static String escapeLike(String value) => value
      .replaceAll(r'\', r'\\')
      .replaceAll('%', r'\%')
      .replaceAll('_', r'\_');

  /// Anchored folder prefix: matches the folder itself and its subfolders,
  /// but never sibling folders sharing a name prefix (Music vs Music2).
  static String _folderPrefix(String folderPath) {
    var normalized = folderPath;
    if (normalized.endsWith('/') || normalized.endsWith(r'\')) {
      normalized = normalized.substring(0, normalized.length - 1);
    }
    final sep = normalized.contains(r'\') ? r'\' : '/';
    return '${escapeLike(normalized + sep)}%';
  }

  // ── Tracks ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getTracksForFolder(
    String folderPath, {
    int? limit,
    int? offset,
  }) async {
    final db = await database;
    return db.query(
      'tracks',
      where: r"folder_path LIKE ? ESCAPE '\'",
      whereArgs: [_folderPrefix(folderPath)],
      orderBy: 'file_path ASC',
      limit: limit,
      offset: offset,
    );
  }

  Future<int> countTracksForFolder(String folderPath) async {
    final db = await database;
    final rows = await db.rawQuery(
      r"SELECT COUNT(*) AS c FROM tracks WHERE folder_path LIKE ? ESCAPE '\'",
      [_folderPrefix(folderPath)],
    );
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<List<Map<String, Object?>>> searchTracks(
    String query, {
    String? folderPath,
  }) async {
    final db = await database;
    final q = '%${escapeLike(query.toLowerCase())}%';
    final folderClause = folderPath != null
        ? r" AND folder_path LIKE ? ESCAPE '\'"
        : '';
    return db.rawQuery(
      '''SELECT * FROM tracks
         WHERE (title_lc LIKE ? ESCAPE '\\'
            OR artist_lc LIKE ? ESCAPE '\\'
            OR album_lc LIKE ? ESCAPE '\\')$folderClause
         ORDER BY title ASC''',
      [q, q, q, if (folderPath != null) _folderPrefix(folderPath)],
    );
  }

  Future<List<Map<String, Object?>>> getAllTracks(
      {int? limit, int? offset}) async {
    final db = await database;
    return db.query('tracks',
        orderBy: 'file_path ASC', limit: limit, offset: offset);
  }

  Future<void> upsertTrack(Map<String, Object?> track) async {
    final db = await database;
    await db.insert('tracks', track,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<void> upsertTracks(List<Map<String, Object?>> tracks) async {
    final db = await database;
    final batch = db.batch();
    for (final t in tracks) {
      batch.insert('tracks', t, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    await batch.commit(noResult: true);
  }

  /// Atomically replace a folder's index: the old rows are deleted and the
  /// new rows inserted in one transaction, so an interrupted scan can never
  /// leave the folder half-indexed or empty.
  Future<void> replaceTracksForFolder(
      String folderPath, List<Map<String, Object?>> tracks) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete(
        'tracks',
        where: r"folder_path LIKE ? ESCAPE '\'",
        whereArgs: [_folderPrefix(folderPath)],
      );
      final batch = txn.batch();
      for (final t in tracks) {
        batch.insert('tracks', t, conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<int> deleteTracksForFolder(String folderPath) async {
    final db = await database;
    return db.delete(
      'tracks',
      where: r"folder_path LIKE ? ESCAPE '\'",
      whereArgs: [_folderPrefix(folderPath)],
    );
  }

  Future<List<Map<String, Object?>>> getTracksByPaths(
      List<String> paths) async {
    if (paths.isEmpty) return [];
    final db = await database;

    // Chunk to stay under SQLite's 999 host-variable limit on Android 11
    // and older (each path binds twice: file_path IN + nas_path IN).
    const chunkSize = 400;
    final results = <Map<String, Object?>>[];
    for (var i = 0; i < paths.length; i += chunkSize) {
      final chunk = paths.sublist(
          i, i + chunkSize > paths.length ? paths.length : i + chunkSize);
      final placeholders = List.filled(chunk.length, '?').join(',');
      results.addAll(await db.rawQuery(
        'SELECT * FROM tracks WHERE file_path IN ($placeholders) '
        'OR nas_path IN ($placeholders)',
        [...chunk, ...chunk],
      ));
    }
    return results;
  }

  Future<List<String>> getDistinctFolders({int limit = 500}) async {
    final db = await database;
    final rows = await db.rawQuery(
        "SELECT DISTINCT folder_path FROM tracks WHERE folder_path != '' "
        'ORDER BY folder_path ASC LIMIT ?',
        [limit]);
    return rows.map((r) => r['folder_path'] as String).toList();
  }

  Future<List<String>> getDistinctAlbums() async {
    final db = await database;
    final rows = await db.rawQuery(
        "SELECT DISTINCT album FROM tracks WHERE album != '' ORDER BY album ASC");
    return rows.map((r) => r['album'] as String).toList();
  }

  Future<List<String>> getDistinctArtists() async {
    final db = await database;
    final rows = await db.rawQuery(
        "SELECT DISTINCT artist FROM tracks WHERE artist != '' ORDER BY artist ASC");
    return rows.map((r) => r['artist'] as String).toList();
  }

  Future<List<Map<String, Object?>>> getTracksForAlbum(String album) async {
    final db = await database;
    return db.query('tracks',
        where: 'album = ?', whereArgs: [album], orderBy: 'file_path ASC');
  }

  Future<List<Map<String, Object?>>> getTracksForArtist(String artist) async {
    final db = await database;
    return db.query('tracks',
        where: 'artist = ?', whereArgs: [artist], orderBy: 'album ASC, file_path ASC');
  }

  // ── Playlists ───────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getAllPlaylists() async {
    final db = await database;
    return db.query('playlists', orderBy: 'updated_at DESC');
  }

  Future<void> insertPlaylist(Map<String, Object?> playlist) async {
    final db = await database;
    await db.insert('playlists', playlist,
        conflictAlgorithm: ConflictAlgorithm.abort);
  }

  /// Update playlist metadata in place. Never uses INSERT OR REPLACE — with
  /// foreign keys enabled, REPLACE would cascade-delete the playlist's tracks.
  Future<void> updatePlaylist(String id, Map<String, Object?> values) async {
    final db = await database;
    await db.update('playlists', values, where: 'id = ?', whereArgs: [id]);
  }

  Future<int> deletePlaylist(String id) async {
    final db = await database;
    return db.delete('playlists', where: 'id = ?', whereArgs: [id]);
  }

  // ── Playlist tracks ─────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getPlaylistTracks(
      String playlistId) async {
    final db = await database;
    return db.query(
      'playlist_tracks',
      where: 'playlist_id = ?',
      whereArgs: [playlistId],
      orderBy: 'position ASC',
    );
  }

  Future<void> replacePlaylistTracks(
      String playlistId, List<Map<String, Object?>> tracks) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('playlist_tracks',
          where: 'playlist_id = ?', whereArgs: [playlistId]);
      final batch = txn.batch();
      for (final t in tracks) {
        batch.insert('playlist_tracks', t);
      }
      await batch.commit(noResult: true);
    });
  }

  // ── NAS configs ─────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getAllNasConfigs() async {
    final db = await database;
    return db.query('nas_configs');
  }

  Future<void> upsertNasConfig(Map<String, Object?> config) async {
    final db = await database;
    await db.insert('nas_configs', config,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<int> deleteNasConfig(String id) async {
    final db = await database;
    return db.delete('nas_configs', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> setActiveNasConfig(String id) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.update('nas_configs', {'is_active': 0});
      await txn.update('nas_configs', {'is_active': 1},
          where: 'id = ?', whereArgs: [id]);
    });
  }

  // ── Play history ────────────────────────────────────────────────────────────

  Future<void> insertPlayEvent(Map<String, Object?> event) async {
    final db = await database;
    await db.insert('play_history', event);
    // Keep history bounded.
    await db.rawDelete('''
      DELETE FROM play_history WHERE row_id NOT IN (
        SELECT row_id FROM play_history ORDER BY played_at DESC LIMIT 5000
      )
    ''');
  }

  Future<List<Map<String, Object?>>> getRecentPlays({int limit = 100}) async {
    final db = await database;
    return db.query('play_history', orderBy: 'played_at DESC', limit: limit);
  }

  Future<List<Map<String, Object?>>> getMostPlayed({int limit = 50}) async {
    final db = await database;
    return db.rawQuery('''
      SELECT track_id, title, artist, album, file_path, nas_path, source,
             COUNT(*) AS play_count, MAX(played_at) AS last_played
      FROM play_history
      GROUP BY track_id
      ORDER BY play_count DESC, last_played DESC
      LIMIT ?
    ''', [limit]);
  }

  Future<void> clearHistory() async {
    final db = await database;
    await db.delete('play_history');
  }

  // ── Downloads ───────────────────────────────────────────────────────────────

  Future<void> upsertDownload(Map<String, Object?> download) async {
    final db = await database;
    await db.insert('downloads', download,
        conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<List<Map<String, Object?>>> getAllDownloads() async {
    final db = await database;
    return db.query('downloads', orderBy: 'downloaded_at DESC');
  }

  Future<Map<String, Object?>?> getDownloadForNasPath(String nasPath) async {
    final db = await database;
    final rows = await db.query('downloads',
        where: 'nas_path = ?', whereArgs: [nasPath], limit: 1);
    return rows.isEmpty ? null : rows.first;
  }

  Future<void> deleteDownload(String nasPath) async {
    final db = await database;
    await db.delete('downloads', where: 'nas_path = ?', whereArgs: [nasPath]);
  }

  // ── NAS index cache ─────────────────────────────────────────────────────────

  Future<void> replaceNasIndexForParent(String nasId, String parentPath,
      List<Map<String, Object?>> entries) async {
    final db = await database;
    await db.transaction((txn) async {
      await txn.delete('nas_index',
          where: 'nas_id = ? AND parent_path = ?',
          whereArgs: [nasId, parentPath]);
      final batch = txn.batch();
      for (final e in entries) {
        batch.insert('nas_index', e,
            conflictAlgorithm: ConflictAlgorithm.replace);
      }
      await batch.commit(noResult: true);
    });
  }

  Future<List<Map<String, Object?>>> getNasIndexForParent(
      String nasId, String parentPath) async {
    final db = await database;
    return db.query(
      'nas_index',
      where: 'nas_id = ? AND parent_path = ?',
      whereArgs: [nasId, parentPath],
      orderBy: 'is_directory DESC, name COLLATE NOCASE ASC',
    );
  }

  Future<void> clearNasIndex(String nasId) async {
    final db = await database;
    await db.delete('nas_index', where: 'nas_id = ?', whereArgs: [nasId]);
  }

  /// Filename search over the cached NAS index (files only).
  Future<List<Map<String, Object?>>> searchNasIndex(
      String nasId, String query) async {
    final db = await database;
    final q = '%${escapeLike(query.toLowerCase())}%';
    return db.rawQuery(
      r"SELECT * FROM nas_index WHERE nas_id = ? AND is_directory = 0 "
      r"AND LOWER(name) LIKE ? ESCAPE '\' ORDER BY name ASC LIMIT 500",
      [nasId, q],
    );
  }

  Future<int> countNasIndex(String nasId) async {
    final db = await database;
    final rows = await db.rawQuery(
        'SELECT COUNT(*) AS c FROM nas_index WHERE nas_id = ? AND is_directory = 0',
        [nasId]);
    return (rows.first['c'] as int?) ?? 0;
  }

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
