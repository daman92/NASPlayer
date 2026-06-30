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
      version: 1,
      onCreate: _onCreate,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE tracks (
        id TEXT PRIMARY KEY,
        title TEXT NOT NULL,
        artist TEXT NOT NULL DEFAULT 'Unknown Artist',
        album TEXT NOT NULL DEFAULT 'Unknown Album',
        duration_ms INTEGER NOT NULL DEFAULT 0,
        file_path TEXT NOT NULL,
        artwork_path TEXT,
        format TEXT NOT NULL DEFAULT '',
        bit_depth INTEGER,
        sample_rate INTEGER,
        bitrate INTEGER,
        source TEXT NOT NULL DEFAULT 'local',
        folder_path TEXT NOT NULL DEFAULT '',
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

    await db.execute('PRAGMA foreign_keys = ON');
  }

  // ── Tracks ─────────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getTracksForFolder(String folderPath) async {
    final db = await database;
    return db.query(
      'tracks',
      where: 'folder_path LIKE ?',
      whereArgs: ['$folderPath%'],
      orderBy: 'file_path ASC',
    );
  }

  Future<List<Map<String, Object?>>> searchTracks(String query) async {
    final db = await database;
    final q = '%${query.toLowerCase()}%';
    return db.rawQuery(
      '''SELECT * FROM tracks
         WHERE LOWER(title) LIKE ? OR LOWER(artist) LIKE ? OR LOWER(album) LIKE ?
         ORDER BY title ASC''',
      [q, q, q],
    );
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

  Future<int> deleteTracksForFolder(String folderPath) async {
    final db = await database;
    return db.delete('tracks',
        where: 'folder_path LIKE ?', whereArgs: ['$folderPath%']);
  }

  // ── Playlists ───────────────────────────────────────────────────────────────

  Future<List<Map<String, Object?>>> getAllPlaylists() async {
    final db = await database;
    return db.query('playlists', orderBy: 'updated_at DESC');
  }

  Future<void> upsertPlaylist(Map<String, Object?> playlist) async {
    final db = await database;
    await db.insert('playlists', playlist,
        conflictAlgorithm: ConflictAlgorithm.replace);
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

  Future<void> close() async {
    final db = _db;
    if (db != null) {
      await db.close();
      _db = null;
    }
  }
}
