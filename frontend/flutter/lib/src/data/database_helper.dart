import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

class AppDatabase {
  AppDatabase._();

  static final AppDatabase instance = AppDatabase._();
  Database? _database;

  Future<Database> get database async {
    if (_database != null) {
      return _database!;
    }
    _database = await _open();
    return _database!;
  }

  Future<Database> _open() async {
    final String dbPath = await getDatabasesPath();
    final String path = p.join(dbPath, 'timeflow_v0_1.db');
    return openDatabase(
      path,
      version: 6,
      onConfigure: (Database db) async {
        await db.execute('PRAGMA foreign_keys = ON;');
      },
      onCreate: _onCreate,
      onUpgrade: _onUpgrade,
    );
  }

  Future<void> _onCreate(Database db, int version) async {
    await db.execute('''
      CREATE TABLE project_groups (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        sort_order INTEGER NOT NULL DEFAULT 0,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL
      );
    ''');

    await db.execute('''
      CREATE TABLE projects (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        name TEXT NOT NULL,
        group_id INTEGER NOT NULL,
        timer_mode TEXT NOT NULL DEFAULT 'forward',
        countdown_seconds INTEGER NOT NULL DEFAULT 1500,
        color_value INTEGER,
        enable_vibration INTEGER NOT NULL DEFAULT 1,
        enable_ringtone INTEGER NOT NULL DEFAULT 1,
        is_enabled INTEGER NOT NULL DEFAULT 1,
        is_deleted INTEGER NOT NULL DEFAULT 0,
        sort_order INTEGER NOT NULL DEFAULT 0,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (group_id) REFERENCES project_groups(id)
      );
    ''');

    await db.execute('''
      CREATE UNIQUE INDEX idx_projects_name_group_active
      ON projects(name, group_id)
      WHERE is_deleted = 0;
    ''');

    await db.execute('''
      CREATE TABLE focus_sessions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        project_id INTEGER NOT NULL,
        start_time TEXT NOT NULL,
        end_time TEXT NOT NULL,
        duration_seconds INTEGER NOT NULL,
        status TEXT NOT NULL,
        record_date TEXT NOT NULL,
        created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL,
        FOREIGN KEY (project_id) REFERENCES projects(id)
      );
    ''');

    await db.execute('''
      CREATE INDEX idx_focus_sessions_record_date
      ON focus_sessions(record_date);
    ''');

    await db.execute('''
      CREATE INDEX idx_focus_sessions_project_date
      ON focus_sessions(project_id, record_date);
    ''');

    await db.execute('''
      CREATE TABLE current_timer (
        id INTEGER PRIMARY KEY CHECK (id = 1),
        project_id INTEGER NOT NULL,
        start_time TEXT NOT NULL,
        status TEXT NOT NULL,
        last_sync_time TEXT NOT NULL,
        timer_mode TEXT NOT NULL DEFAULT 'forward',
        target_seconds INTEGER,
        FOREIGN KEY (project_id) REFERENCES projects(id)
      );
    ''');

    await _seedInitialData(db);
  }

  Future<void> _onUpgrade(Database db, int oldVersion, int newVersion) async {
    if (oldVersion < 2) {
      await db.execute(
        "ALTER TABLE current_timer ADD COLUMN timer_mode TEXT NOT NULL DEFAULT 'forward';",
      );
      await db.execute(
        "ALTER TABLE current_timer ADD COLUMN target_seconds INTEGER;",
      );
    }
    if (oldVersion < 3) {
      // Keep backward compatibility for existing local DBs.
      // New installs use the new schema in onCreate.
    }
    if (oldVersion < 4) {
      final bool hasCountdown = await _hasColumn(
        db,
        table: 'projects',
        column: 'countdown_seconds',
      );
      if (!hasCountdown) {
        await db.execute(
          "ALTER TABLE projects ADD COLUMN countdown_seconds INTEGER NOT NULL DEFAULT 1500;",
        );
      }
    }
    if (oldVersion < 5) {
      final bool hasVibration = await _hasColumn(
        db,
        table: 'projects',
        column: 'enable_vibration',
      );
      if (!hasVibration) {
        await db.execute(
          'ALTER TABLE projects ADD COLUMN enable_vibration INTEGER NOT NULL DEFAULT 1;',
        );
      }

      final bool hasRingtone = await _hasColumn(
        db,
        table: 'projects',
        column: 'enable_ringtone',
      );
      if (!hasRingtone) {
        await db.execute(
          'ALTER TABLE projects ADD COLUMN enable_ringtone INTEGER NOT NULL DEFAULT 1;',
        );
      }
    }
    if (oldVersion < 6) {
      final bool hasGroupDeleted = await _hasColumn(
        db,
        table: 'project_groups',
        column: 'is_deleted',
      );
      if (!hasGroupDeleted) {
        await db.execute(
          'ALTER TABLE project_groups ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;',
        );
      }

      final bool hasProjectDeleted = await _hasColumn(
        db,
        table: 'projects',
        column: 'is_deleted',
      );
      if (!hasProjectDeleted) {
        await db.execute(
          'ALTER TABLE projects ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;',
        );
      }

      final bool hasProjectEnabled = await _hasColumn(
        db,
        table: 'projects',
        column: 'is_enabled',
      );
      if (!hasProjectEnabled) {
        await db.execute(
          'ALTER TABLE projects ADD COLUMN is_enabled INTEGER NOT NULL DEFAULT 1;',
        );
      }

      final bool hasColorValue = await _hasColumn(
        db,
        table: 'projects',
        column: 'color_value',
      );
      if (!hasColorValue) {
        await db.execute(
          'ALTER TABLE projects ADD COLUMN color_value INTEGER;',
        );
      }
    }

    await _ensureProjectActiveUniqueIndex(db);
  }

  Future<void> _seedInitialData(Database db) async {
    final String now = DateTime.now().toUtc().toIso8601String();
    final int groupId = await db.insert('project_groups', <String, Object?>{
      'name': '考研',
      'sort_order': 0,
      'is_deleted': 0,
      'created_at': now,
      'updated_at': now,
    });

    final List<Map<String, Object?>> defaults = <Map<String, Object?>>[
      <String, Object?>{
        'name': '数学',
        'group_id': groupId,
        'timer_mode': 'forward',
        'countdown_seconds': 1500,
        'color_value': 0xFF2563EB,
        'enable_vibration': 1,
        'enable_ringtone': 1,
        'is_enabled': 1,
        'is_deleted': 0,
        'sort_order': 0,
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'name': '英语',
        'group_id': groupId,
        'timer_mode': 'forward',
        'countdown_seconds': 1500,
        'color_value': 0xFF14B8A6,
        'enable_vibration': 1,
        'enable_ringtone': 1,
        'is_enabled': 1,
        'is_deleted': 0,
        'sort_order': 1,
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'name': '政治',
        'group_id': groupId,
        'timer_mode': 'countdown',
        'countdown_seconds': 1800,
        'color_value': 0xFFF59E0B,
        'enable_vibration': 1,
        'enable_ringtone': 1,
        'is_enabled': 1,
        'is_deleted': 0,
        'sort_order': 2,
        'created_at': now,
        'updated_at': now,
      },
      <String, Object?>{
        'name': '专业课',
        'group_id': groupId,
        'timer_mode': 'forward',
        'countdown_seconds': 1500,
        'color_value': 0xFFDB2777,
        'enable_vibration': 1,
        'enable_ringtone': 1,
        'is_enabled': 1,
        'is_deleted': 0,
        'sort_order': 3,
        'created_at': now,
        'updated_at': now,
      },
    ];

    for (final Map<String, Object?> project in defaults) {
      await db.insert('projects', project);
    }
  }

  Future<bool> _hasColumn(
    Database db, {
    required String table,
    required String column,
  }) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'PRAGMA table_info($table)',
    );
    return rows.any((Map<String, Object?> row) => row['name'] == column);
  }

  Future<void> _ensureProjectActiveUniqueIndex(Database db) async {
    final List<Map<String, Object?>> indexes = await db.rawQuery(
      'PRAGMA index_list(projects)',
    );
    final Set<String> names = indexes
        .map((Map<String, Object?> row) => row['name'] as String?)
        .whereType<String>()
        .toSet();

    if (names.contains('idx_projects_name_group')) {
      await db.execute('DROP INDEX IF EXISTS idx_projects_name_group;');
    }

    await db.execute('''
      CREATE UNIQUE INDEX IF NOT EXISTS idx_projects_name_group_active
      ON projects(name, group_id)
      WHERE COALESCE(is_deleted, 0) = 0;
    ''');
  }
}
