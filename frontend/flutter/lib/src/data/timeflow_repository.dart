import 'dart:convert';
import 'dart:math';

import 'package:sqflite/sqflite.dart';

import '../models/models.dart';
import '../utils/project_color.dart';
import 'database_helper.dart';

class ValidationException implements Exception {
  ValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TimerConflictException implements Exception {
  TimerConflictException(this.message);

  final String message;

  @override
  String toString() => message;
}

class TimeFlowRepository {
  TimeFlowRepository({AppDatabase? database})
    : _database = database ?? AppDatabase.instance;

  static const int minimumValidSessionSeconds = 60;
  static const int pauseBudgetSeconds = RunningTimerInfo.pauseBudgetSeconds;
  static const int backupFormatVersion = 1;

  final AppDatabase _database;

  Future<Database> get _db async => _database.database;

  Future<List<ProjectGroup>> fetchGroups() async {
    final Database db = await _db;
    await _ensureSchemaColumns(db);
    final Set<String> groupColumns = await _tableColumns(db, 'project_groups');
    final List<String> whereParts = <String>[];
    if (groupColumns.contains('is_deleted')) {
      whereParts.add('COALESCE(is_deleted, 0) = 0');
    }

    final List<Map<String, Object?>> maps = await db.query(
      'project_groups',
      where: whereParts.isEmpty ? null : whereParts.join(' AND '),
      orderBy: 'sort_order ASC, id ASC',
    );
    return maps.map(ProjectGroup.fromMap).toList();
  }

  Future<List<ProjectGroupBundle>> fetchProjectBundles() async {
    final Database db = await _db;
    await _ensureSchemaColumns(db);
    final Set<String> groupColumns = await _tableColumns(db, 'project_groups');
    final Set<String> projectColumns = await _tableColumns(db, 'projects');

    final List<String> groupWhereParts = <String>[];
    if (groupColumns.contains('is_deleted')) {
      groupWhereParts.add('COALESCE(is_deleted, 0) = 0');
    }

    final List<Map<String, Object?>> groupRows = await db.query(
      'project_groups',
      where: groupWhereParts.isEmpty ? null : groupWhereParts.join(' AND '),
      orderBy: 'sort_order ASC, id ASC',
    );

    final List<String> projectWhereParts = <String>[];
    if (projectColumns.contains('is_deleted')) {
      projectWhereParts.add('COALESCE(is_deleted, 0) = 0');
    }
    if (projectColumns.contains('is_enabled')) {
      projectWhereParts.add('COALESCE(is_enabled, 1) = 1');
    }

    final List<Map<String, Object?>> projectRows = await db.query(
      'projects',
      where: projectWhereParts.isEmpty ? null : projectWhereParts.join(' AND '),
      orderBy: 'sort_order ASC, id ASC',
    );

    final List<ProjectGroup> groups = groupRows
        .map(ProjectGroup.fromMap)
        .toList();
    final List<ProjectItem> projects = projectRows
        .map(ProjectItem.fromMap)
        .toList();

    final Map<int, List<ProjectItem>> groupedProjects =
        <int, List<ProjectItem>>{};
    for (final ProjectItem project in projects) {
      groupedProjects
          .putIfAbsent(project.groupId, () => <ProjectItem>[])
          .add(project);
    }

    return groups
        .map(
          (ProjectGroup group) => ProjectGroupBundle(
            group: group,
            projects: groupedProjects[group.id] ?? <ProjectItem>[],
          ),
        )
        .toList();
  }

  Future<int> createGroup(String name) async {
    final String normalizedName = _normalizeName(name);
    final Database db = await _db;

    return db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      await _assertGroupNameUnique(tx, normalizedName);
      final Set<String> groupColumns = await _tableColumns(
        tx,
        'project_groups',
      );
      final String maxSortSql = groupColumns.contains('is_deleted')
          ? 'SELECT COALESCE(MAX(sort_order), -1) FROM project_groups WHERE COALESCE(is_deleted, 0) = 0'
          : 'SELECT COALESCE(MAX(sort_order), -1) FROM project_groups';

      final int currentMaxOrder =
          Sqflite.firstIntValue(await tx.rawQuery(maxSortSql)) ?? -1;

      final String now = _nowUtcString();
      final Map<String, Object?> insertData = <String, Object?>{
        'name': normalizedName,
        'sort_order': currentMaxOrder + 1,
        'created_at': now,
        'updated_at': now,
      };
      if (groupColumns.contains('is_deleted')) {
        insertData['is_deleted'] = 0;
      }
      return tx.insert('project_groups', insertData);
    });
  }

  Future<void> updateGroup({required int groupId, required String name}) async {
    final String normalizedName = _normalizeName(name);
    final Database db = await _db;

    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final List<Map<String, Object?>> existing = await tx.query(
        'project_groups',
        where: 'id = ?',
        whereArgs: <Object?>[groupId],
        limit: 1,
      );
      if (existing.isEmpty) {
        throw ValidationException('代办集不存在');
      }

      await _assertGroupNameUnique(tx, normalizedName, excludeGroupId: groupId);

      await tx.update(
        'project_groups',
        <String, Object?>{
          'name': normalizedName,
          'updated_at': _nowUtcString(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[groupId],
      );
    });
  }

  Future<void> deleteGroup(int groupId) async {
    final Database db = await _db;

    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final Set<String> groupColumns = await _tableColumns(
        tx,
        'project_groups',
      );
      final Set<String> projectColumns = await _tableColumns(tx, 'projects');
      final List<Map<String, Object?>> rows = await tx.query(
        'project_groups',
        where: 'id = ?',
        whereArgs: <Object?>[groupId],
        limit: 1,
      );
      if (rows.isEmpty) {
        return;
      }

      final List<Map<String, Object?>> projectRows = await tx.query(
        'projects',
        columns: <String>['id'],
        where: projectColumns.contains('is_deleted')
            ? 'group_id = ? AND COALESCE(is_deleted, 0) = 0'
            : 'group_id = ?',
        whereArgs: <Object?>[groupId],
      );

      for (final Map<String, Object?> row in projectRows) {
        final int projectId = (row['id'] as num).toInt();
        await _stopTimerIfProjectRunning(tx, projectId);

        final int sessionCount =
            Sqflite.firstIntValue(
              await tx.rawQuery(
                'SELECT COUNT(*) FROM focus_sessions WHERE project_id = ?',
                <Object?>[projectId],
              ),
            ) ??
            0;
        if (sessionCount > 0 && projectColumns.contains('is_deleted')) {
          final Map<String, Object?> updateData = <String, Object?>{
            'is_deleted': 1,
            'updated_at': _nowUtcString(),
          };
          if (projectColumns.contains('is_enabled')) {
            updateData['is_enabled'] = 0;
          }
          await tx.update(
            'projects',
            updateData,
            where: 'id = ?',
            whereArgs: <Object?>[projectId],
          );
          continue;
        }

        await tx.delete(
          'projects',
          where: 'id = ?',
          whereArgs: <Object?>[projectId],
        );
      }

      if (groupColumns.contains('is_deleted')) {
        await tx.update(
          'project_groups',
          <String, Object?>{'is_deleted': 1, 'updated_at': _nowUtcString()},
          where: 'id = ?',
          whereArgs: <Object?>[groupId],
        );
      } else {
        await tx.delete(
          'project_groups',
          where: 'id = ?',
          whereArgs: <Object?>[groupId],
        );
      }
    });
  }

  Future<int> createProject({
    required String name,
    required int groupId,
    String timerMode = 'forward',
    int countdownSeconds = 1500,
    bool enableVibration = true,
    bool enableRingtone = true,
  }) async {
    final String normalizedName = _normalizeName(name);
    final int normalizedCountdown = _normalizeCountdownSeconds(
      countdownSeconds,
    );
    final Database db = await _db;

    return db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      await _assertGroupExists(tx, groupId);
      await _assertProjectNameUnique(
        tx,
        groupId: groupId,
        name: normalizedName,
      );
      final Set<String> projectColumns = await _tableColumns(tx, 'projects');
      final String maxSortSql = projectColumns.contains('is_deleted')
          ? 'SELECT COALESCE(MAX(sort_order), -1) FROM projects WHERE group_id = ? AND COALESCE(is_deleted, 0) = 0'
          : 'SELECT COALESCE(MAX(sort_order), -1) FROM projects WHERE group_id = ?';

      final int maxOrder =
          Sqflite.firstIntValue(
            await tx.rawQuery(maxSortSql, <Object?>[groupId]),
          ) ??
          -1;

      final String now = _nowUtcString();
      final Map<String, Object?> insertData = <String, Object?>{
        'name': normalizedName,
        'group_id': groupId,
        'timer_mode': timerMode,
        'sort_order': maxOrder + 1,
        'created_at': now,
        'updated_at': now,
      };

      if (projectColumns.contains('color_value')) {
        insertData['color_value'] = await _allocateProjectColorValue(tx);
      }
      if (projectColumns.contains('countdown_seconds')) {
        insertData['countdown_seconds'] = normalizedCountdown;
      }
      if (projectColumns.contains('enable_vibration')) {
        insertData['enable_vibration'] = enableVibration ? 1 : 0;
      }
      if (projectColumns.contains('enable_ringtone')) {
        insertData['enable_ringtone'] = enableRingtone ? 1 : 0;
      }
      if (projectColumns.contains('is_enabled')) {
        insertData['is_enabled'] = 1;
      }
      if (projectColumns.contains('is_deleted')) {
        insertData['is_deleted'] = 0;
      }

      return tx.insert('projects', insertData);
    });
  }

  Future<void> updateProject({
    required int projectId,
    required String name,
    required int groupId,
    required String timerMode,
    required int countdownSeconds,
    required bool enableVibration,
    required bool enableRingtone,
  }) async {
    final String normalizedName = _normalizeName(name);
    final int normalizedCountdown = _normalizeCountdownSeconds(
      countdownSeconds,
    );
    final Database db = await _db;

    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final List<Map<String, Object?>> existingRows = await tx.query(
        'projects',
        where: 'id = ?',
        whereArgs: <Object?>[projectId],
        limit: 1,
      );
      if (existingRows.isEmpty) {
        throw ValidationException('代办不存在');
      }

      await _assertGroupExists(tx, groupId);
      await _assertProjectNameUnique(
        tx,
        groupId: groupId,
        name: normalizedName,
        excludeProjectId: projectId,
      );

      final Set<String> projectColumns = await _tableColumns(tx, 'projects');
      final Map<String, Object?> updateData = <String, Object?>{
        'name': normalizedName,
        'group_id': groupId,
        'timer_mode': timerMode,
        'updated_at': _nowUtcString(),
      };
      if (projectColumns.contains('countdown_seconds')) {
        updateData['countdown_seconds'] = normalizedCountdown;
      }
      if (projectColumns.contains('enable_vibration')) {
        updateData['enable_vibration'] = enableVibration ? 1 : 0;
      }
      if (projectColumns.contains('enable_ringtone')) {
        updateData['enable_ringtone'] = enableRingtone ? 1 : 0;
      }

      await tx.update(
        'projects',
        updateData,
        where: 'id = ?',
        whereArgs: <Object?>[projectId],
      );
    });
  }

  Future<void> deleteProject(int projectId) async {
    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final Set<String> projectColumns = await _tableColumns(tx, 'projects');
      await _stopTimerIfProjectRunning(tx, projectId);

      final int sessionCount =
          Sqflite.firstIntValue(
            await tx.rawQuery(
              'SELECT COUNT(*) FROM focus_sessions WHERE project_id = ?',
              <Object?>[projectId],
            ),
          ) ??
          0;
      if (sessionCount > 0 && projectColumns.contains('is_deleted')) {
        final Map<String, Object?> updateData = <String, Object?>{
          'is_deleted': 1,
          'updated_at': _nowUtcString(),
        };
        if (projectColumns.contains('is_enabled')) {
          updateData['is_enabled'] = 0;
        }
        await tx.update(
          'projects',
          updateData,
          where: 'id = ?',
          whereArgs: <Object?>[projectId],
        );
        return;
      }

      await tx.delete(
        'projects',
        where: 'id = ?',
        whereArgs: <Object?>[projectId],
      );
    });
  }

  Future<RunningTimerInfo?> getRunningTimer() async {
    final Database db = await _db;
    return db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      await _materializePauseStateIfExpired(tx, DateTime.now().toUtc());

      final List<Map<String, Object?>> rows = await tx.query(
        'current_timer',
        limit: 1,
      );
      if (rows.isEmpty) {
        return null;
      }

      final CurrentTimer timer = CurrentTimer.fromMap(rows.first);
      final List<Map<String, Object?>> projectRows = await tx.query(
        'projects',
        where: 'id = ?',
        whereArgs: <Object?>[timer.projectId],
        limit: 1,
      );

      if (projectRows.isEmpty) {
        await tx.delete('current_timer', where: 'id = 1');
        return null;
      }

      return RunningTimerInfo(
        timer: timer,
        project: ProjectItem.fromMap(projectRows.first),
      );
    });
  }

  Future<void> startTimer(int projectId) async {
    final Database db = await _db;

    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final List<Map<String, Object?>> runningRows = await tx.query(
        'current_timer',
        limit: 1,
      );
      if (runningRows.isNotEmpty) {
        throw TimerConflictException('当前已有代办正在计时，请先结束');
      }

      final List<Map<String, Object?>> projectRows = await tx.query(
        'projects',
        where: 'id = ?',
        whereArgs: <Object?>[projectId],
        limit: 1,
      );

      if (projectRows.isEmpty) {
        throw ValidationException('代办不存在或不可用');
      }

      final ProjectItem project = ProjectItem.fromMap(projectRows.first);
      final String now = _nowUtcString();
      await tx.insert('current_timer', <String, Object?>{
        'id': 1,
        'project_id': projectId,
        'start_time': now,
        'status': 'running',
        'last_sync_time': now,
        'timer_mode': project.timerMode,
        'target_seconds': project.timerMode == 'countdown'
            ? project.countdownSeconds
            : null,
        'paused_seconds_total': 0,
        'pause_started_at': null,
      });
    });
  }

  Future<FocusSession?> stopTimer() async {
    final Database db = await _db;
    return db.transaction((Transaction tx) {
      return _stopTimerInternal(tx, DateTime.now().toUtc());
    });
  }

  Future<void> startPause() async {
    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      await _materializePauseStateIfExpired(tx, DateTime.now().toUtc());

      final List<Map<String, Object?>> rows = await tx.query(
        'current_timer',
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ValidationException('当前没有进行中的计时');
      }

      final Map<String, Object?> timerRow = rows.first;
      final String? pauseStarted = timerRow['pause_started_at'] as String?;
      if (pauseStarted != null && pauseStarted.trim().isNotEmpty) {
        throw ValidationException('当前已在暂停中');
      }

      final int usedSeconds = _readPauseUsedSeconds(timerRow);
      if (usedSeconds >= pauseBudgetSeconds) {
        throw ValidationException('本次计时暂停额度已用尽');
      }

      final String now = _nowUtcString();
      await tx.update('current_timer', <String, Object?>{
        'pause_started_at': now,
        'last_sync_time': now,
      }, where: 'id = 1');
    });
  }

  Future<void> endPause() async {
    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final List<Map<String, Object?>> rows = await tx.query(
        'current_timer',
        limit: 1,
      );
      if (rows.isEmpty) {
        throw ValidationException('当前没有进行中的计时');
      }
      await _consumeAndClearPause(tx, rows.first, DateTime.now().toUtc());
    });
  }

  Future<AggregateStats> fetchAggregateStats({DateTime? streakEndDate}) async {
    final Database db = await _db;
    final DateTime baseDate = streakEndDate ?? DateTime.now();
    final DateTime normalizedEndDate = DateTime(
      baseDate.year,
      baseDate.month,
      baseDate.day,
    );
    final List<Map<String, Object?>> rows = await db.rawQuery('''
      SELECT
        COUNT(*) AS session_count,
        COALESCE(SUM(duration_seconds), 0) AS total_seconds,
        COUNT(DISTINCT record_date) AS active_days
      FROM focus_sessions
      WHERE status = 'completed'
    ''');

    final Map<String, Object?> row = rows.first;
    final int consecutiveDays = await _fetchConsecutiveActiveDays(
      db,
      endDate: normalizedEndDate,
    );

    return AggregateStats(
      sessionCount: (row['session_count'] as num?)?.toInt() ?? 0,
      totalSeconds: (row['total_seconds'] as num?)?.toInt() ?? 0,
      activeDays: max(0, (row['active_days'] as num?)?.toInt() ?? 0),
      consecutiveDays: consecutiveDays,
    );
  }

  Future<DayStats> fetchDayStats(DateTime date) async {
    final Database db = await _db;
    final String key = _dateKey(date);

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT
        COUNT(*) AS session_count,
        COALESCE(SUM(duration_seconds), 0) AS total_seconds
      FROM focus_sessions
      WHERE status = 'completed' AND record_date = ?
    ''',
      <Object?>[key],
    );

    final Map<String, Object?> row = rows.first;

    return DayStats(
      date: DateTime(date.year, date.month, date.day),
      sessionCount: (row['session_count'] as num?)?.toInt() ?? 0,
      totalSeconds: (row['total_seconds'] as num?)?.toInt() ?? 0,
    );
  }

  Future<DistributionStats> fetchDistribution(
    DateTime startDate,
    DateTime endDate,
  ) async {
    final DateTime normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final DateTime normalizedEnd = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    );

    final Database db = await _db;
    await _ensureSchemaColumns(db);
    final bool hasProjectColor = (await _tableColumns(
      db,
      'projects',
    )).contains('color_value');

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT
        fs.project_id AS project_id,
        COALESCE(p.name, '已删除代办') AS project_name,
        ${hasProjectColor ? 'p.color_value AS color_value,' : ''}
        COALESCE(SUM(fs.duration_seconds), 0) AS total_seconds
      FROM focus_sessions fs
      LEFT JOIN projects p ON p.id = fs.project_id
      WHERE fs.status = 'completed'
        AND fs.record_date >= ?
        AND fs.record_date <= ?
      GROUP BY fs.project_id, p.name
      ORDER BY total_seconds DESC
    ''',
      <Object?>[_dateKey(normalizedStart), _dateKey(normalizedEnd)],
    );

    final List<ProjectDistributionItem> items = rows
        .map((Map<String, Object?> row) {
          final int projectId = (row['project_id'] as num?)?.toInt() ?? 0;
          return ProjectDistributionItem(
            projectId: projectId,
            projectName: row['project_name'] as String? ?? '已删除代办',
            colorValue:
                (row['color_value'] as num?)?.toInt() ??
                autoProjectColorValueById(projectId),
            totalSeconds: (row['total_seconds'] as num?)?.toInt() ?? 0,
          );
        })
        .where((ProjectDistributionItem item) => item.totalSeconds > 0)
        .toList();

    final int totalSeconds = items.fold<int>(
      0,
      (int sum, ProjectDistributionItem item) => sum + item.totalSeconds,
    );

    final int dayCount = normalizedEnd.difference(normalizedStart).inDays + 1;
    final int averagePerDay = dayCount <= 0
        ? 0
        : (totalSeconds / dayCount).round();

    return DistributionStats(
      startDate: normalizedStart,
      endDate: normalizedEnd,
      totalSeconds: totalSeconds,
      averagePerDaySeconds: averagePerDay,
      items: items,
    );
  }

  Future<MonthHourDistributionStats> fetchMonthHourDistribution(
    DateTime month,
  ) async {
    final DateTime monthStart = DateTime(month.year, month.month, 1);
    final DateTime monthEndExclusive = DateTime(month.year, month.month + 1, 1);
    final Database db = await _db;

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT start_time, end_time
      FROM focus_sessions
      WHERE status = 'completed'
        AND end_time > ?
        AND start_time < ?
    ''',
      <Object?>[
        monthStart.toUtc().toIso8601String(),
        monthEndExclusive.toUtc().toIso8601String(),
      ],
    );

    final List<int> buckets = List<int>.filled(24, 0);

    for (final Map<String, Object?> row in rows) {
      final String? startRaw = row['start_time'] as String?;
      final String? endRaw = row['end_time'] as String?;
      if (startRaw == null || endRaw == null) {
        continue;
      }

      DateTime segmentStart;
      DateTime segmentEnd;
      try {
        segmentStart = DateTime.parse(startRaw).toLocal();
        segmentEnd = DateTime.parse(endRaw).toLocal();
      } catch (_) {
        continue;
      }
      if (!segmentEnd.isAfter(segmentStart)) {
        continue;
      }

      if (segmentStart.isBefore(monthStart)) {
        segmentStart = monthStart;
      }
      if (segmentEnd.isAfter(monthEndExclusive)) {
        segmentEnd = monthEndExclusive;
      }
      if (!segmentEnd.isAfter(segmentStart)) {
        continue;
      }

      DateTime cursor = segmentStart;
      while (cursor.isBefore(segmentEnd)) {
        final DateTime hourStart = DateTime(
          cursor.year,
          cursor.month,
          cursor.day,
          cursor.hour,
        );
        final DateTime nextHour = hourStart.add(const Duration(hours: 1));
        final DateTime partEnd = nextHour.isBefore(segmentEnd)
            ? nextHour
            : segmentEnd;
        final int seconds = partEnd.difference(cursor).inSeconds;
        if (seconds > 0) {
          buckets[hourStart.hour] += seconds;
        }
        cursor = partEnd;
      }
    }

    final int totalSeconds = buckets.fold<int>(
      0,
      (int sum, int value) => sum + value,
    );
    // Display starts from 1:00, but trimming blank edges is anchored at 4:00.
    // This keeps sleep-time blank segments (usually near 4:00) as the cut boundary.
    const int displayStartHour = 0;
    const int trimAnchorHour = 4;
    final List<int> displayHours = List<int>.generate(
      24,
      (int index) => (displayStartHour + index) % 24,
    );
    final List<int> trimHours = List<int>.generate(
      24,
      (int index) => (trimAnchorHour + index) % 24,
    );

    int first = 0;
    int last = trimHours.length - 1;
    while (first <= last && buckets[trimHours[first]] == 0) {
      first += 1;
    }
    while (last >= first && buckets[trimHours[last]] == 0) {
      last -= 1;
    }

    final List<MonthHourBucketItem> items = <MonthHourBucketItem>[];
    if (first <= last) {
      final Set<int> includedHours = <int>{
        for (int i = first; i <= last; i++) trimHours[i],
      };
      for (final int hour in displayHours) {
        if (!includedHours.contains(hour)) {
          continue;
        }
        items.add(MonthHourBucketItem(hour: hour, totalSeconds: buckets[hour]));
      }
    }

    return MonthHourDistributionStats(
      month: monthStart,
      items: items,
      totalSeconds: totalSeconds,
    );
  }

  Future<MonthDailyStats> fetchMonthDailyStats(DateTime month) async {
    final DateTime monthStart = DateTime(month.year, month.month, 1);
    final DateTime monthEnd = DateTime(month.year, month.month + 1, 0);
    final int daysInMonth = monthEnd.day;
    final Database db = await _db;

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT record_date, COALESCE(SUM(duration_seconds), 0) AS total_seconds
      FROM focus_sessions
      WHERE status = 'completed'
        AND record_date >= ?
        AND record_date <= ?
      GROUP BY record_date
      ORDER BY record_date ASC
    ''',
      <Object?>[_dateKey(monthStart), _dateKey(monthEnd)],
    );

    final List<int> daySeconds = List<int>.filled(daysInMonth, 0);
    for (final Map<String, Object?> row in rows) {
      final String? key = row['record_date'] as String?;
      if (key == null || key.length < 10) {
        continue;
      }
      final int? day = int.tryParse(key.substring(8, 10));
      if (day == null || day < 1 || day > daysInMonth) {
        continue;
      }
      daySeconds[day - 1] = (row['total_seconds'] as num?)?.toInt() ?? 0;
    }

    final List<MonthDailyPoint> points = List<MonthDailyPoint>.generate(
      daysInMonth,
      (int index) =>
          MonthDailyPoint(day: index + 1, totalSeconds: daySeconds[index]),
      growable: false,
    );

    final int totalSeconds = daySeconds.fold<int>(
      0,
      (int sum, int value) => sum + value,
    );

    return MonthDailyStats(
      month: monthStart,
      points: points,
      totalSeconds: totalSeconds,
    );
  }

  Future<YearMonthlyStats> fetchYearMonthlyStats(DateTime year) async {
    final DateTime yearStart = DateTime(year.year, 1, 1);
    final DateTime yearEnd = DateTime(year.year, 12, 31);
    final Database db = await _db;

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT SUBSTR(record_date, 1, 7) AS year_month,
             COALESCE(SUM(duration_seconds), 0) AS total_seconds
      FROM focus_sessions
      WHERE status = 'completed'
        AND record_date >= ?
        AND record_date <= ?
      GROUP BY year_month
      ORDER BY year_month ASC
    ''',
      <Object?>[_dateKey(yearStart), _dateKey(yearEnd)],
    );

    final List<int> monthSeconds = List<int>.filled(12, 0);
    for (final Map<String, Object?> row in rows) {
      final String? key = row['year_month'] as String?;
      if (key == null || key.length < 7) {
        continue;
      }
      final int? monthValue = int.tryParse(key.substring(5, 7));
      if (monthValue == null || monthValue < 1 || monthValue > 12) {
        continue;
      }
      monthSeconds[monthValue - 1] =
          (row['total_seconds'] as num?)?.toInt() ?? 0;
    }

    final List<YearMonthlyPoint> points = List<YearMonthlyPoint>.generate(
      12,
      (int index) =>
          YearMonthlyPoint(month: index + 1, totalSeconds: monthSeconds[index]),
      growable: false,
    );

    final int totalSeconds = monthSeconds.fold<int>(
      0,
      (int sum, int value) => sum + value,
    );

    return YearMonthlyStats(
      year: yearStart,
      points: points,
      totalSeconds: totalSeconds,
    );
  }

  Future<List<HistoryItem>> fetchHistoryByDate(DateTime date) async {
    final Database db = await _db;
    await _ensureSchemaColumns(db);
    final bool hasProjectColor = (await _tableColumns(
      db,
      'projects',
    )).contains('color_value');
    final String key = _dateKey(date);

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT
        fs.id AS id,
        fs.project_id AS project_id,
        fs.start_time AS start_time,
        fs.end_time AS end_time,
        fs.duration_seconds AS duration_seconds,
        fs.status AS status,
        fs.note AS note,
        fs.note_pending AS note_pending,
        fs.record_date AS record_date,
        fs.created_at AS created_at,
        fs.updated_at AS updated_at,
        COALESCE(p.name, '已删除代办') AS project_name
        ${hasProjectColor ? ', p.color_value AS color_value' : ''}
      FROM focus_sessions fs
      LEFT JOIN projects p ON p.id = fs.project_id
      WHERE fs.status = 'completed' AND fs.record_date = ?
      ORDER BY fs.start_time DESC
    ''',
      <Object?>[key],
    );

    return rows.map((Map<String, Object?> row) {
      final int projectId = (row['project_id'] as num?)?.toInt() ?? 0;
      return HistoryItem(
        session: FocusSession.fromMap(row),
        projectName: row['project_name'] as String? ?? '已删除代办',
        colorValue:
            (row['color_value'] as num?)?.toInt() ??
            autoProjectColorValueById(projectId),
      );
    }).toList();
  }

  Future<List<HistoryItem>> fetchHistoryInRange(
    DateTime startDate,
    DateTime endDate,
  ) async {
    final Database db = await _db;
    await _ensureSchemaColumns(db);
    final bool hasProjectColor = (await _tableColumns(
      db,
      'projects',
    )).contains('color_value');

    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT
        fs.id AS id,
        fs.project_id AS project_id,
        fs.start_time AS start_time,
        fs.end_time AS end_time,
        fs.duration_seconds AS duration_seconds,
        fs.status AS status,
        fs.note AS note,
        fs.note_pending AS note_pending,
        fs.record_date AS record_date,
        fs.created_at AS created_at,
        fs.updated_at AS updated_at,
        COALESCE(p.name, '已删除代办') AS project_name
        ${hasProjectColor ? ', p.color_value AS color_value' : ''}
      FROM focus_sessions fs
      LEFT JOIN projects p ON p.id = fs.project_id
      WHERE fs.status = 'completed'
        AND fs.record_date >= ?
        AND fs.record_date <= ?
      ORDER BY fs.start_time DESC
    ''',
      <Object?>[_dateKey(startDate), _dateKey(endDate)],
    );

    return rows.map((Map<String, Object?> row) {
      final int projectId = (row['project_id'] as num?)?.toInt() ?? 0;
      return HistoryItem(
        session: FocusSession.fromMap(row),
        projectName: row['project_name'] as String? ?? '已删除代办',
        colorValue:
            (row['color_value'] as num?)?.toInt() ??
            autoProjectColorValueById(projectId),
      );
    }).toList();
  }

  Future<Set<String>> fetchRecordedDateKeysInRange(
    DateTime startDate,
    DateTime endDate,
  ) async {
    final DateTime normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final DateTime normalizedEnd = DateTime(
      endDate.year,
      endDate.month,
      endDate.day,
    );
    final Database db = await _db;
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT DISTINCT record_date
      FROM focus_sessions
      WHERE status = 'completed'
        AND record_date >= ?
        AND record_date <= ?
    ''',
      <Object?>[_dateKey(normalizedStart), _dateKey(normalizedEnd)],
    );

    return rows
        .map((Map<String, Object?> row) => row['record_date'] as String?)
        .whereType<String>()
        .toSet();
  }

  Future<void> deleteFocusSession(int sessionId) async {
    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      await tx.delete(
        'focus_sessions',
        where: 'id = ?',
        whereArgs: <Object?>[sessionId],
      );
    });
  }

  Future<String?> updateFocusSessionNote({
    required int sessionId,
    required String note,
  }) async {
    final String? normalizedNote = _normalizeSessionNote(note);
    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);
      final int updatedRows = await tx.update(
        'focus_sessions',
        <String, Object?>{
          'note': normalizedNote,
          'note_pending': 0,
          'updated_at': _nowUtcString(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[sessionId],
      );
      if (updatedRows == 0) {
        throw ValidationException('专注记录不存在');
      }
    });
    return normalizedNote;
  }

  Future<String> exportBackupJson() async {
    final Database db = await _db;
    await _ensureSchemaColumns(db);

    final List<Map<String, Object?>> groups = await db.query(
      'project_groups',
      orderBy: 'id ASC',
    );
    final List<Map<String, Object?>> projects = await db.query(
      'projects',
      orderBy: 'id ASC',
    );
    final List<Map<String, Object?>> sessions = await db.query(
      'focus_sessions',
      orderBy: 'id ASC',
    );
    final List<Map<String, Object?>> timers = await db.query(
      'current_timer',
      orderBy: 'id ASC',
    );

    final Map<String, Object?> payload = <String, Object?>{
      'format': 'timeflow_backup',
      'version': backupFormatVersion,
      'exported_at': _nowUtcString(),
      'schema_version': 9,
      'data': <String, Object?>{
        'project_groups': groups
            .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
            .toList(growable: false),
        'projects': projects
            .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
            .toList(growable: false),
        'focus_sessions': sessions
            .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
            .toList(growable: false),
        'current_timer': timers
            .map((Map<String, Object?> row) => Map<String, Object?>.from(row))
            .toList(growable: false),
      },
    };

    return const JsonEncoder.withIndent('  ').convert(payload);
  }

  Future<void> importBackupJson(String jsonText) async {
    final Object? decoded = jsonDecode(jsonText);
    if (decoded is! Map) {
      throw ValidationException('备份文件格式错误');
    }
    final Map<String, dynamic> payload = Map<String, dynamic>.from(
      decoded.cast<String, dynamic>(),
    );
    final Object? format = payload['format'];
    if (format != null && format != 'timeflow_backup') {
      throw ValidationException('该文件不是计流备份文件');
    }

    final Object? dataObject = payload['data'];
    final Map<String, dynamic> data = dataObject is Map
        ? Map<String, dynamic>.from(dataObject.cast<String, dynamic>())
        : payload;
    if (!data.containsKey('project_groups') ||
        !data.containsKey('projects') ||
        !data.containsKey('focus_sessions')) {
      throw ValidationException('备份文件缺少核心数据字段');
    }

    final List<Map<String, Object?>> groupRows = _readBackupRows(
      data['project_groups'],
      field: 'project_groups',
    );
    final List<Map<String, Object?>> projectRows = _readBackupRows(
      data['projects'],
      field: 'projects',
    );
    final List<Map<String, Object?>> sessionRows = _readBackupRows(
      data['focus_sessions'],
      field: 'focus_sessions',
    );
    final List<Map<String, Object?>> timerRows = _readBackupRows(
      data['current_timer'],
      field: 'current_timer',
    );

    final Database db = await _db;
    await db.transaction((Transaction tx) async {
      await _ensureSchemaColumns(tx);

      final Set<String> groupColumns = await _tableColumns(
        tx,
        'project_groups',
      );
      final Set<String> projectColumns = await _tableColumns(tx, 'projects');
      final Set<String> sessionColumns = await _tableColumns(
        tx,
        'focus_sessions',
      );
      final String now = _nowUtcString();

      final List<Map<String, Object?>> normalizedGroups = groupRows
          .map((Map<String, Object?> row) {
            final int id = _readIntValue(
              row['id'],
              field: 'project_groups.id',
              defaultValue: 0,
            );
            if (id <= 0) {
              throw ValidationException('备份文件中存在无效代办集 ID');
            }
            final String name = _readStringValue(
              row['name'],
              field: 'project_groups.name',
            );
            final Map<String, Object?> mapped = <String, Object?>{
              'id': id,
              'name': name,
              'sort_order': _readIntValue(
                row['sort_order'],
                field: 'project_groups.sort_order',
                defaultValue: 0,
              ),
              'created_at': _readStringValue(
                row['created_at'],
                field: 'project_groups.created_at',
                defaultValue: now,
              ),
              'updated_at': _readStringValue(
                row['updated_at'],
                field: 'project_groups.updated_at',
                defaultValue: now,
              ),
            };
            if (groupColumns.contains('is_deleted')) {
              mapped['is_deleted'] = _readBoolAsInt(
                row['is_deleted'],
                field: 'project_groups.is_deleted',
                defaultValue: 0,
              );
            }
            return mapped;
          })
          .toList(growable: false);

      final Set<int> groupIds = normalizedGroups
          .map((Map<String, Object?> row) => row['id'] as int)
          .toSet();

      final List<Map<String, Object?>> normalizedProjects = projectRows
          .map((Map<String, Object?> row) {
            final int id = _readIntValue(
              row['id'],
              field: 'projects.id',
              defaultValue: 0,
            );
            if (id <= 0) {
              throw ValidationException('备份文件中存在无效代办 ID');
            }
            final int groupId = _readIntValue(
              row['group_id'],
              field: 'projects.group_id',
              defaultValue: 0,
            );
            if (!groupIds.contains(groupId)) {
              throw ValidationException('备份文件中的代办引用了不存在的待办集');
            }

            final String timerModeRaw = _readStringValue(
              row['timer_mode'],
              field: 'projects.timer_mode',
              defaultValue: 'forward',
            );
            final String timerMode = timerModeRaw == 'countdown'
                ? 'countdown'
                : 'forward';
            final int countdownSeconds = _normalizeCountdownSeconds(
              _readIntValue(
                row['countdown_seconds'],
                field: 'projects.countdown_seconds',
                defaultValue: 1500,
              ),
            );
            final Map<String, Object?> mapped = <String, Object?>{
              'id': id,
              'name': _readStringValue(row['name'], field: 'projects.name'),
              'group_id': groupId,
              'timer_mode': timerMode,
              'countdown_seconds': countdownSeconds,
              'sort_order': _readIntValue(
                row['sort_order'],
                field: 'projects.sort_order',
                defaultValue: 0,
              ),
              'created_at': _readStringValue(
                row['created_at'],
                field: 'projects.created_at',
                defaultValue: now,
              ),
              'updated_at': _readStringValue(
                row['updated_at'],
                field: 'projects.updated_at',
                defaultValue: now,
              ),
            };
            if (projectColumns.contains('color_value')) {
              mapped['color_value'] = _readNullableIntValue(
                row['color_value'],
                field: 'projects.color_value',
              );
            }
            if (projectColumns.contains('enable_vibration')) {
              mapped['enable_vibration'] = _readBoolAsInt(
                row['enable_vibration'],
                field: 'projects.enable_vibration',
                defaultValue: 1,
              );
            }
            if (projectColumns.contains('enable_ringtone')) {
              mapped['enable_ringtone'] = _readBoolAsInt(
                row['enable_ringtone'],
                field: 'projects.enable_ringtone',
                defaultValue: 1,
              );
            }
            if (projectColumns.contains('is_enabled')) {
              mapped['is_enabled'] = _readBoolAsInt(
                row['is_enabled'],
                field: 'projects.is_enabled',
                defaultValue: 1,
              );
            }
            if (projectColumns.contains('is_deleted')) {
              mapped['is_deleted'] = _readBoolAsInt(
                row['is_deleted'],
                field: 'projects.is_deleted',
                defaultValue: 0,
              );
            }
            return mapped;
          })
          .toList(growable: false);

      final Set<int> projectIds = normalizedProjects
          .map((Map<String, Object?> row) => row['id'] as int)
          .toSet();

      final List<Map<String, Object?>> normalizedSessions = sessionRows
          .map((Map<String, Object?> row) {
            final int id = _readIntValue(
              row['id'],
              field: 'focus_sessions.id',
              defaultValue: 0,
            );
            if (id <= 0) {
              throw ValidationException('备份文件中存在无效专注记录 ID');
            }
            final int projectId = _readIntValue(
              row['project_id'],
              field: 'focus_sessions.project_id',
              defaultValue: 0,
            );
            if (!projectIds.contains(projectId)) {
              throw ValidationException('备份文件中的专注记录引用了不存在的代办');
            }

            final String startTime = _readStringValue(
              row['start_time'],
              field: 'focus_sessions.start_time',
              defaultValue: now,
            );
            final String endTime = _readStringValue(
              row['end_time'],
              field: 'focus_sessions.end_time',
              defaultValue: now,
            );
            final String recordDate = _readStringValue(
              row['record_date'],
              field: 'focus_sessions.record_date',
              defaultValue: _dateKey(
                DateTime.tryParse(startTime) ?? DateTime.now(),
              ),
            );

            final Map<String, Object?> mapped = <String, Object?>{
              'id': id,
              'project_id': projectId,
              'start_time': startTime,
              'end_time': endTime,
              'duration_seconds': max(
                0,
                _readIntValue(
                  row['duration_seconds'],
                  field: 'focus_sessions.duration_seconds',
                  defaultValue: 0,
                ),
              ),
              'status': _readStringValue(
                row['status'],
                field: 'focus_sessions.status',
                defaultValue: 'completed',
              ),
              'record_date': recordDate,
              'created_at': _readStringValue(
                row['created_at'],
                field: 'focus_sessions.created_at',
                defaultValue: now,
              ),
              'updated_at': _readStringValue(
                row['updated_at'],
                field: 'focus_sessions.updated_at',
                defaultValue: now,
              ),
            };
            if (sessionColumns.contains('note')) {
              mapped['note'] = _readNullableStringValue(
                row['note'],
                field: 'focus_sessions.note',
              );
            }
            if (sessionColumns.contains('note_pending')) {
              mapped['note_pending'] = _readBoolAsInt(
                row['note_pending'],
                field: 'focus_sessions.note_pending',
                defaultValue: 0,
              );
            }
            return mapped;
          })
          .toList(growable: false);

      Map<String, Object?>? normalizedTimer;
      if (timerRows.isNotEmpty) {
        final Map<String, Object?> row = timerRows.first;
        final int projectId = _readIntValue(
          row['project_id'],
          field: 'current_timer.project_id',
          defaultValue: 0,
        );
        if (projectIds.contains(projectId)) {
          final String timerModeRaw = _readStringValue(
            row['timer_mode'],
            field: 'current_timer.timer_mode',
            defaultValue: 'forward',
          );
          normalizedTimer = <String, Object?>{
            'id': 1,
            'project_id': projectId,
            'start_time': _readStringValue(
              row['start_time'],
              field: 'current_timer.start_time',
              defaultValue: now,
            ),
            'status': _readStringValue(
              row['status'],
              field: 'current_timer.status',
              defaultValue: 'running',
            ),
            'last_sync_time': _readStringValue(
              row['last_sync_time'],
              field: 'current_timer.last_sync_time',
              defaultValue: now,
            ),
            'timer_mode': timerModeRaw == 'countdown' ? 'countdown' : 'forward',
            'target_seconds': _readNullableIntValue(
              row['target_seconds'],
              field: 'current_timer.target_seconds',
            ),
            'paused_seconds_total': _readIntValue(
              row['paused_seconds_total'],
              field: 'current_timer.paused_seconds_total',
              defaultValue: 0,
            ).clamp(0, pauseBudgetSeconds),
            'pause_started_at': _readNullableStringValue(
              row['pause_started_at'],
              field: 'current_timer.pause_started_at',
            ),
          };
        }
      }

      await tx.delete('current_timer');
      await tx.delete('focus_sessions');
      await tx.delete('projects');
      await tx.delete('project_groups');

      for (final Map<String, Object?> row in normalizedGroups) {
        await tx.insert(
          'project_groups',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final Map<String, Object?> row in normalizedProjects) {
        await tx.insert(
          'projects',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      for (final Map<String, Object?> row in normalizedSessions) {
        await tx.insert(
          'focus_sessions',
          row,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      if (normalizedTimer != null) {
        await tx.insert(
          'current_timer',
          normalizedTimer,
          conflictAlgorithm: ConflictAlgorithm.replace,
        );
      }

      await _syncAutoIncrement(tx, 'project_groups');
      await _syncAutoIncrement(tx, 'projects');
      await _syncAutoIncrement(tx, 'focus_sessions');

      await _ensureProjectActiveUniqueIndex(tx);
      await _backfillProjectColorValues(tx);
      await _normalizeProjectColorConflicts(tx);
    });
  }

  Future<void> _assertGroupExists(Transaction tx, int groupId) async {
    final Set<String> columns = await _tableColumns(tx, 'project_groups');
    final String where = columns.contains('is_deleted')
        ? 'id = ? AND COALESCE(is_deleted, 0) = 0'
        : 'id = ?';
    final List<Map<String, Object?>> rows = await tx.query(
      'project_groups',
      where: where,
      whereArgs: <Object?>[groupId],
      limit: 1,
    );
    if (rows.isEmpty) {
      throw ValidationException('代办集不存在');
    }
  }

  Future<void> _assertGroupNameUnique(
    Transaction tx,
    String name, {
    int? excludeGroupId,
  }) async {
    final Set<String> columns = await _tableColumns(tx, 'project_groups');
    String where = 'name = ?';
    final List<Object?> args = <Object?>[name];
    if (columns.contains('is_deleted')) {
      where = '$where AND COALESCE(is_deleted, 0) = 0';
    }
    if (excludeGroupId != null) {
      where = '$where AND id != ?';
      args.add(excludeGroupId);
    }

    final List<Map<String, Object?>> rows = await tx.query(
      'project_groups',
      where: where,
      whereArgs: args,
      limit: 1,
    );

    if (rows.isNotEmpty) {
      throw ValidationException('代办集名称已存在');
    }
  }

  Future<void> _assertProjectNameUnique(
    Transaction tx, {
    required int groupId,
    required String name,
    int? excludeProjectId,
  }) async {
    final Set<String> columns = await _tableColumns(tx, 'projects');
    String where = 'group_id = ? AND name = ?';
    final List<Object?> whereArgs = <Object?>[groupId, name];
    if (columns.contains('is_deleted')) {
      where = '$where AND COALESCE(is_deleted, 0) = 0';
    }

    if (excludeProjectId != null) {
      where = '$where AND id != ?';
      whereArgs.add(excludeProjectId);
    }

    final List<Map<String, Object?>> rows = await tx.query(
      'projects',
      where: where,
      whereArgs: whereArgs,
      limit: 1,
    );

    if (rows.isNotEmpty) {
      throw ValidationException('同一代办集下代办名不能重复');
    }
  }

  Future<Set<String>> _tableColumns(DatabaseExecutor db, String table) async {
    final List<Map<String, Object?>> rows = await db.rawQuery(
      'PRAGMA table_info($table)',
    );
    return rows
        .map((Map<String, Object?> row) => row['name'] as String?)
        .whereType<String>()
        .toSet();
  }

  Future<void> _ensureSchemaColumns(DatabaseExecutor db) async {
    final Set<String> groupColumns = await _tableColumns(db, 'project_groups');
    if (!groupColumns.contains('is_deleted')) {
      await db.execute(
        'ALTER TABLE project_groups ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;',
      );
    }

    final Set<String> projectColumns = await _tableColumns(db, 'projects');
    if (!projectColumns.contains('countdown_seconds')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN countdown_seconds INTEGER NOT NULL DEFAULT 1500;',
      );
    }
    if (!projectColumns.contains('color_value')) {
      await db.execute('ALTER TABLE projects ADD COLUMN color_value INTEGER;');
    }
    if (!projectColumns.contains('enable_vibration')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN enable_vibration INTEGER NOT NULL DEFAULT 1;',
      );
    }
    if (!projectColumns.contains('enable_ringtone')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN enable_ringtone INTEGER NOT NULL DEFAULT 1;',
      );
    }
    if (!projectColumns.contains('is_enabled')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN is_enabled INTEGER NOT NULL DEFAULT 1;',
      );
    }
    if (!projectColumns.contains('is_deleted')) {
      await db.execute(
        'ALTER TABLE projects ADD COLUMN is_deleted INTEGER NOT NULL DEFAULT 0;',
      );
    }
    final Set<String> sessionColumns = await _tableColumns(
      db,
      'focus_sessions',
    );
    if (!sessionColumns.contains('note')) {
      await db.execute('ALTER TABLE focus_sessions ADD COLUMN note TEXT;');
    }
    if (!sessionColumns.contains('note_pending')) {
      await db.execute(
        'ALTER TABLE focus_sessions ADD COLUMN note_pending INTEGER NOT NULL DEFAULT 0;',
      );
    }
    final Set<String> timerColumns = await _tableColumns(db, 'current_timer');
    if (!timerColumns.contains('paused_seconds_total')) {
      await db.execute(
        'ALTER TABLE current_timer ADD COLUMN paused_seconds_total INTEGER NOT NULL DEFAULT 0;',
      );
    }
    if (!timerColumns.contains('pause_started_at')) {
      await db.execute(
        'ALTER TABLE current_timer ADD COLUMN pause_started_at TEXT;',
      );
    }

    await _ensureProjectActiveUniqueIndex(db);
    await _backfillProjectColorValues(db);
    await _normalizeProjectColorConflicts(db);
  }

  Future<void> _ensureProjectActiveUniqueIndex(DatabaseExecutor db) async {
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

  Future<void> _backfillProjectColorValues(DatabaseExecutor db) async {
    final Set<String> columns = await _tableColumns(db, 'projects');
    if (!columns.contains('color_value')) {
      return;
    }

    final List<Map<String, Object?>> rows = await db.query(
      'projects',
      columns: <String>['id', 'color_value'],
      where: 'color_value IS NULL',
    );

    for (final Map<String, Object?> row in rows) {
      final int id = (row['id'] as num).toInt();
      await db.update(
        'projects',
        <String, Object?>{'color_value': autoProjectColorValueById(id)},
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
    }
  }

  Future<void> _normalizeProjectColorConflicts(DatabaseExecutor db) async {
    final Set<String> columns = await _tableColumns(db, 'projects');
    if (!columns.contains('color_value')) {
      return;
    }

    final bool hasDeleted = columns.contains('is_deleted');
    final Set<int> unavailable = <int>{};

    if (hasDeleted) {
      final List<Map<String, Object?>> reservedRows = await db.rawQuery('''
        SELECT p.color_value AS color_value
        FROM projects p
        WHERE p.color_value IS NOT NULL
          AND COALESCE(p.is_deleted, 0) = 1
          AND EXISTS (
            SELECT 1
            FROM focus_sessions fs
            WHERE fs.project_id = p.id
            LIMIT 1
          )
      ''');
      unavailable.addAll(
        reservedRows
            .map(
              (Map<String, Object?> row) =>
                  (row['color_value'] as num?)?.toInt(),
            )
            .whereType<int>(),
      );
    }

    final List<Map<String, Object?>> activeRows = await db.rawQuery(
      hasDeleted
          ? '''
        SELECT id, color_value
        FROM projects
        WHERE COALESCE(is_deleted, 0) = 0
        ORDER BY sort_order ASC, id ASC
      '''
          : '''
        SELECT id, color_value
        FROM projects
        ORDER BY sort_order ASC, id ASC
      ''',
    );

    for (final Map<String, Object?> row in activeRows) {
      final int id = (row['id'] as num).toInt();
      final int? color = (row['color_value'] as num?)?.toInt();
      if (color != null && !unavailable.contains(color)) {
        unavailable.add(color);
        continue;
      }

      final int replacement = _pickAvailableColorValue(
        seed: id,
        unavailable: unavailable,
      );
      await db.update(
        'projects',
        <String, Object?>{
          'color_value': replacement,
          'updated_at': _nowUtcString(),
        },
        where: 'id = ?',
        whereArgs: <Object?>[id],
      );
      unavailable.add(replacement);
    }
  }

  int _pickAvailableColorValue({
    required int seed,
    required Set<int> unavailable,
  }) {
    int candidate = autoProjectColorValueById(seed);
    if (!unavailable.contains(candidate)) {
      return candidate;
    }

    for (int i = 1; i <= 720; i++) {
      candidate = generatedProjectColorValueBySeed(seed + i);
      if (!unavailable.contains(candidate)) {
        return candidate;
      }
    }

    return generatedProjectColorValueBySeed(
      seed + DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<int> _allocateProjectColorValue(Transaction tx) async {
    final Set<int> unavailable = <int>{};
    final Set<String> columns = await _tableColumns(tx, 'projects');
    final bool hasDeleted = columns.contains('is_deleted');
    final bool hasColor = columns.contains('color_value');
    if (hasColor) {
      final List<Map<String, Object?>> activeRows = await tx.rawQuery(
        hasDeleted
            ? '''
          SELECT color_value
          FROM projects
          WHERE color_value IS NOT NULL
            AND COALESCE(is_deleted, 0) = 0
        '''
            : '''
          SELECT color_value
          FROM projects
          WHERE color_value IS NOT NULL
        ''',
      );
      unavailable.addAll(
        activeRows
            .map(
              (Map<String, Object?> row) =>
                  (row['color_value'] as num?)?.toInt(),
            )
            .whereType<int>(),
      );

      if (hasDeleted) {
        final List<Map<String, Object?>> reservedRows = await tx.rawQuery('''
          SELECT p.color_value AS color_value
          FROM projects p
          WHERE p.color_value IS NOT NULL
            AND COALESCE(p.is_deleted, 0) = 1
            AND EXISTS (
              SELECT 1
              FROM focus_sessions fs
              WHERE fs.project_id = p.id
              LIMIT 1
            )
        ''');
        unavailable.addAll(
          reservedRows
              .map(
                (Map<String, Object?> row) =>
                    (row['color_value'] as num?)?.toInt(),
              )
              .whereType<int>(),
        );
      }
    }

    final int nextProjectId =
        (Sqflite.firstIntValue(
              await tx.rawQuery('SELECT COALESCE(MAX(id), 0) FROM projects'),
            ) ??
            0) +
        1;

    int candidate = autoProjectColorValueById(nextProjectId);
    if (!unavailable.contains(candidate)) {
      return candidate;
    }

    for (int i = 1; i <= 720; i++) {
      candidate = generatedProjectColorValueBySeed(nextProjectId + i);
      if (!unavailable.contains(candidate)) {
        return candidate;
      }
    }

    return generatedProjectColorValueBySeed(
      nextProjectId + DateTime.now().millisecondsSinceEpoch,
    );
  }

  Future<void> _stopTimerIfProjectRunning(Transaction tx, int projectId) async {
    final List<Map<String, Object?>> rows = await tx.query(
      'current_timer',
      where: 'project_id = ? AND status = ?',
      whereArgs: <Object?>[projectId, 'running'],
      limit: 1,
    );
    if (rows.isEmpty) {
      return;
    }
    await _stopTimerInternal(tx, DateTime.now().toUtc());
  }

  Future<FocusSession?> _stopTimerInternal(
    Transaction tx,
    DateTime endedAtUtc,
  ) async {
    final List<Map<String, Object?>> rows = await tx.query(
      'current_timer',
      limit: 1,
    );

    if (rows.isEmpty) {
      return null;
    }

    final Map<String, Object?> timerRow = rows.first;
    final int projectId = (timerRow['project_id'] as num).toInt();
    final DateTime startedAtUtc = DateTime.parse(
      timerRow['start_time'] as String,
    ).toUtc();
    final int grossDuration = endedAtUtc.difference(startedAtUtc).inSeconds;
    final int pausedSeconds = _computePausedSecondsUntil(timerRow, endedAtUtc);
    final int duration = max(0, grossDuration - pausedSeconds);

    await tx.delete('current_timer', where: 'id = 1');

    if (duration < minimumValidSessionSeconds) {
      return null;
    }

    final DateTime startedLocal = startedAtUtc.toLocal();
    final String now = _nowUtcString();

    final int sessionId = await tx.insert('focus_sessions', <String, Object?>{
      'project_id': projectId,
      'start_time': startedAtUtc.toIso8601String(),
      'end_time': endedAtUtc.toIso8601String(),
      'duration_seconds': duration,
      'status': 'completed',
      'note': null,
      'note_pending': 1,
      'record_date': _dateKey(startedLocal),
      'created_at': now,
      'updated_at': now,
    });

    final List<Map<String, Object?>> sessionRows = await tx.query(
      'focus_sessions',
      where: 'id = ?',
      whereArgs: <Object?>[sessionId],
      limit: 1,
    );

    return FocusSession.fromMap(sessionRows.first);
  }

  int _readPauseUsedSeconds(Map<String, Object?> row) {
    return ((row['paused_seconds_total'] as num?)?.toInt() ?? 0).clamp(
      0,
      pauseBudgetSeconds,
    );
  }

  DateTime? _readPauseStartedAtUtc(Map<String, Object?> row) {
    final String? raw = row['pause_started_at'] as String?;
    if (raw == null || raw.trim().isEmpty) {
      return null;
    }
    return DateTime.parse(raw).toUtc();
  }

  int _elapsedPauseSecondsSince({
    required DateTime pauseStartedAtUtc,
    required DateTime nowUtc,
  }) {
    final int elapsed = nowUtc.difference(pauseStartedAtUtc).inSeconds;
    return elapsed <= 0 ? 0 : elapsed;
  }

  int _computePausedSecondsUntil(Map<String, Object?> row, DateTime nowUtc) {
    final int usedSeconds = _readPauseUsedSeconds(row);
    final DateTime? pauseStartedAtUtc = _readPauseStartedAtUtc(row);
    if (pauseStartedAtUtc == null) {
      return usedSeconds;
    }
    final int remaining = max(0, pauseBudgetSeconds - usedSeconds);
    if (remaining == 0) {
      return pauseBudgetSeconds;
    }
    final int elapsed = _elapsedPauseSecondsSince(
      pauseStartedAtUtc: pauseStartedAtUtc,
      nowUtc: nowUtc,
    );
    return usedSeconds + min(remaining, elapsed);
  }

  Future<void> _consumeAndClearPause(
    Transaction tx,
    Map<String, Object?> row,
    DateTime nowUtc,
  ) async {
    final DateTime? pauseStartedAtUtc = _readPauseStartedAtUtc(row);
    if (pauseStartedAtUtc == null) {
      return;
    }
    final int usedSeconds = _readPauseUsedSeconds(row);
    final int remaining = max(0, pauseBudgetSeconds - usedSeconds);
    final int elapsed = _elapsedPauseSecondsSince(
      pauseStartedAtUtc: pauseStartedAtUtc,
      nowUtc: nowUtc,
    );
    final int consumed = min(remaining, elapsed);
    final int totalUsed = (usedSeconds + consumed).clamp(0, pauseBudgetSeconds);

    await tx.update('current_timer', <String, Object?>{
      'paused_seconds_total': totalUsed,
      'pause_started_at': null,
      'last_sync_time': _nowUtcString(),
    }, where: 'id = 1');
  }

  Future<void> _materializePauseStateIfExpired(
    Transaction tx,
    DateTime nowUtc,
  ) async {
    final List<Map<String, Object?>> rows = await tx.query(
      'current_timer',
      limit: 1,
    );
    if (rows.isEmpty) {
      return;
    }
    final Map<String, Object?> row = rows.first;
    final DateTime? pauseStartedAtUtc = _readPauseStartedAtUtc(row);
    if (pauseStartedAtUtc == null) {
      return;
    }

    final int usedSeconds = _readPauseUsedSeconds(row);
    final int remaining = max(0, pauseBudgetSeconds - usedSeconds);
    if (remaining == 0) {
      await tx.update('current_timer', <String, Object?>{
        'paused_seconds_total': pauseBudgetSeconds,
        'pause_started_at': null,
        'last_sync_time': _nowUtcString(),
      }, where: 'id = 1');
      return;
    }

    final int elapsed = _elapsedPauseSecondsSince(
      pauseStartedAtUtc: pauseStartedAtUtc,
      nowUtc: nowUtc,
    );
    if (elapsed < remaining) {
      return;
    }

    await tx.update('current_timer', <String, Object?>{
      'paused_seconds_total': (usedSeconds + remaining).clamp(
        0,
        pauseBudgetSeconds,
      ),
      'pause_started_at': null,
      'last_sync_time': _nowUtcString(),
    }, where: 'id = 1');
  }

  String _normalizeName(String value) {
    final String trimmed = value.trim();
    if (trimmed.isEmpty) {
      throw ValidationException('名称不能为空');
    }
    if (trimmed.length > 20) {
      throw ValidationException('名称长度需在 1~20 字');
    }
    return trimmed;
  }

  int _normalizeCountdownSeconds(int value) {
    if (value < 60) {
      return 60;
    }
    // Upper bound prevents extreme values caused by bad input.
    if (value > 5 * 60 * 60) {
      return 5 * 60 * 60;
    }
    return value;
  }

  String? _normalizeSessionNote(String value) {
    final String normalized = value.trim();
    if (normalized.isEmpty) {
      return null;
    }
    if (normalized.length > 50) {
      throw ValidationException('心得最多 50 字');
    }
    return normalized;
  }

  String _nowUtcString() => DateTime.now().toUtc().toIso8601String();

  String _dateKey(DateTime date) {
    final DateTime local = date.toLocal();
    final String month = local.month.toString().padLeft(2, '0');
    final String day = local.day.toString().padLeft(2, '0');
    return '${local.year}-$month-$day';
  }

  Future<int> _fetchConsecutiveActiveDays(
    Database db, {
    required DateTime endDate,
  }) async {
    final String endKey = _dateKey(endDate);
    final List<Map<String, Object?>> rows = await db.rawQuery(
      '''
      SELECT DISTINCT record_date
      FROM focus_sessions
      WHERE status = 'completed'
        AND record_date <= ?
      ORDER BY record_date DESC
    ''',
      <Object?>[endKey],
    );
    if (rows.isEmpty) {
      return 0;
    }

    final Set<String> keys = rows
        .map((Map<String, Object?> row) => row['record_date'] as String?)
        .whereType<String>()
        .toSet();

    int streak = 0;
    DateTime cursor = DateTime(endDate.year, endDate.month, endDate.day);
    while (keys.contains(_dateKey(cursor))) {
      streak += 1;
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  List<Map<String, Object?>> _readBackupRows(
    Object? source, {
    required String field,
  }) {
    if (source == null) {
      return <Map<String, Object?>>[];
    }
    if (source is! List) {
      throw ValidationException('备份文件字段错误：$field');
    }
    return source
        .map((Object? row) {
          if (row is! Map) {
            throw ValidationException('备份文件字段错误：$field');
          }
          final Map<String, Object?> mapped = <String, Object?>{};
          row.forEach((Object? key, Object? value) {
            mapped[key.toString()] = value;
          });
          return mapped;
        })
        .toList(growable: false);
  }

  int _readIntValue(
    Object? value, {
    required String field,
    required int defaultValue,
  }) {
    if (value == null) {
      return defaultValue;
    }
    if (value is int) {
      return value;
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    if (value is num) {
      return value.toInt();
    }
    if (value is String) {
      final int? parsed = int.tryParse(value.trim());
      if (parsed != null) {
        return parsed;
      }
    }
    throw ValidationException('备份文件数值字段错误：$field');
  }

  int? _readNullableIntValue(Object? value, {required String field}) {
    if (value == null) {
      return null;
    }
    return _readIntValue(value, field: field, defaultValue: 0);
  }

  String? _readNullableStringValue(Object? value, {required String field}) {
    if (value == null) {
      return null;
    }
    final String text = _readStringValue(value, field: field).trim();
    if (text.isEmpty) {
      return null;
    }
    return text;
  }

  String _readStringValue(
    Object? value, {
    required String field,
    String? defaultValue,
  }) {
    if (value == null) {
      if (defaultValue != null) {
        return defaultValue;
      }
      throw ValidationException('备份文件文本字段缺失：$field');
    }
    if (value is String) {
      return value;
    }
    if (value is num || value is bool) {
      return value.toString();
    }
    throw ValidationException('备份文件文本字段错误：$field');
  }

  int _readBoolAsInt(
    Object? value, {
    required String field,
    required int defaultValue,
  }) {
    if (value == null) {
      return defaultValue;
    }
    if (value is bool) {
      return value ? 1 : 0;
    }
    final int intValue = _readIntValue(value, field: field, defaultValue: 0);
    return intValue == 0 ? 0 : 1;
  }

  Future<void> _syncAutoIncrement(DatabaseExecutor db, String table) async {
    final int maxId =
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COALESCE(MAX(id), 0) FROM $table'),
        ) ??
        0;
    final int exists =
        Sqflite.firstIntValue(
          await db.rawQuery(
            'SELECT COUNT(*) FROM sqlite_sequence WHERE name = ?',
            <Object?>[table],
          ),
        ) ??
        0;
    if (exists > 0) {
      await db.update(
        'sqlite_sequence',
        <String, Object?>{'seq': maxId},
        where: 'name = ?',
        whereArgs: <Object?>[table],
      );
      return;
    }
    await db.insert('sqlite_sequence', <String, Object?>{
      'name': table,
      'seq': maxId,
    });
  }
}
