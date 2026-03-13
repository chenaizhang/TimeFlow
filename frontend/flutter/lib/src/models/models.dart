import 'package:flutter/material.dart';

import '../utils/project_color.dart';

enum RangeType { day, week, month, custom }

class ProjectGroup {
  const ProjectGroup({
    required this.id,
    required this.name,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final String name;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory ProjectGroup.fromMap(Map<String, Object?> map) {
    return ProjectGroup(
      id: map['id'] as int,
      name: map['name'] as String,
      sortOrder: map['sort_order'] as int? ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      updatedAt: DateTime.parse(map['updated_at'] as String).toLocal(),
    );
  }
}

class ProjectItem {
  const ProjectItem({
    required this.id,
    required this.name,
    required this.groupId,
    required this.timerMode,
    required this.countdownSeconds,
    int? colorValue,
    bool? enableVibration,
    bool? enableRingtone,
    required this.sortOrder,
    required this.createdAt,
    required this.updatedAt,
  }) : _colorValue = colorValue,
       _enableVibration = enableVibration,
       _enableRingtone = enableRingtone;

  final int id;
  final String name;
  final int groupId;
  final String timerMode;
  final int countdownSeconds;
  final int? _colorValue;
  final bool? _enableVibration;
  final bool? _enableRingtone;
  final int sortOrder;
  final DateTime createdAt;
  final DateTime updatedAt;

  int get colorValue => _colorValue ?? autoProjectColorValueById(id);
  Color get color => Color(colorValue);
  bool get enableVibration => _enableVibration ?? true;
  bool get enableRingtone => _enableRingtone ?? true;

  factory ProjectItem.fromMap(Map<String, Object?> map) {
    return ProjectItem(
      id: map['id'] as int,
      name: map['name'] as String,
      groupId: map['group_id'] as int,
      timerMode: map['timer_mode'] as String? ?? 'forward',
      countdownSeconds: (() {
        final int value = (map['countdown_seconds'] as num?)?.toInt() ?? 1500;
        return value < 60 ? 1500 : value;
      })(),
      colorValue: (map['color_value'] as num?)?.toInt(),
      enableVibration: ((map['enable_vibration'] as num?)?.toInt() ?? 1) != 0,
      enableRingtone: ((map['enable_ringtone'] as num?)?.toInt() ?? 1) != 0,
      sortOrder: map['sort_order'] as int? ?? 0,
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      updatedAt: DateTime.parse(map['updated_at'] as String).toLocal(),
    );
  }
}

class FocusSession {
  const FocusSession({
    required this.id,
    required this.projectId,
    required this.startTime,
    required this.endTime,
    required this.durationSeconds,
    required this.status,
    required this.note,
    required this.notePending,
    required this.recordDate,
    required this.createdAt,
    required this.updatedAt,
  });

  final int id;
  final int projectId;
  final DateTime startTime;
  final DateTime endTime;
  final int durationSeconds;
  final String status;
  final String? note;
  final bool notePending;
  final DateTime recordDate;
  final DateTime createdAt;
  final DateTime updatedAt;

  factory FocusSession.fromMap(Map<String, Object?> map) {
    final String? rawNote = map['note'] as String?;
    final String? normalizedNote = rawNote?.trim();
    return FocusSession(
      id: map['id'] as int,
      projectId: map['project_id'] as int,
      startTime: DateTime.parse(map['start_time'] as String).toLocal(),
      endTime: DateTime.parse(map['end_time'] as String).toLocal(),
      durationSeconds: map['duration_seconds'] as int,
      status: map['status'] as String,
      note: (normalizedNote == null || normalizedNote.isEmpty)
          ? null
          : normalizedNote,
      notePending: ((map['note_pending'] as num?)?.toInt() ?? 0) != 0,
      recordDate: DateTime.parse('${map['record_date']}T00:00:00').toLocal(),
      createdAt: DateTime.parse(map['created_at'] as String).toLocal(),
      updatedAt: DateTime.parse(map['updated_at'] as String).toLocal(),
    );
  }
}

class CurrentTimer {
  const CurrentTimer({
    required this.id,
    required this.projectId,
    required this.startTime,
    required this.status,
    required this.lastSyncTime,
    required this.timerMode,
    required this.targetSeconds,
    required this.pausedSecondsTotal,
    required this.pauseStartedAt,
  });

  final int id;
  final int projectId;
  final DateTime startTime;
  final String status;
  final DateTime lastSyncTime;
  final String timerMode;
  final int? targetSeconds;
  final int pausedSecondsTotal;
  final DateTime? pauseStartedAt;

  bool get isPaused => pauseStartedAt != null;

  factory CurrentTimer.fromMap(Map<String, Object?> map) {
    return CurrentTimer(
      id: map['id'] as int,
      projectId: map['project_id'] as int,
      startTime: DateTime.parse(map['start_time'] as String).toLocal(),
      status: map['status'] as String,
      lastSyncTime: DateTime.parse(map['last_sync_time'] as String).toLocal(),
      timerMode: map['timer_mode'] as String? ?? 'forward',
      targetSeconds: map['target_seconds'] as int?,
      pausedSecondsTotal: ((map['paused_seconds_total'] as num?)?.toInt() ?? 0)
          .clamp(0, RunningTimerInfo.pauseBudgetSeconds),
      pauseStartedAt: () {
        final String? raw = map['pause_started_at'] as String?;
        if (raw == null || raw.trim().isEmpty) {
          return null;
        }
        return DateTime.parse(raw).toLocal();
      }(),
    );
  }
}

class ProjectGroupBundle {
  const ProjectGroupBundle({required this.group, required this.projects});

  final ProjectGroup group;
  final List<ProjectItem> projects;
}

class RunningTimerInfo {
  const RunningTimerInfo({required this.timer, required this.project});

  static const int pauseBudgetSeconds = 180;

  final CurrentTimer timer;
  final ProjectItem project;

  bool get isCountdown =>
      (timer.timerMode == 'countdown') || project.timerMode == 'countdown';

  int get countdownTargetSeconds {
    final int timerTarget = timer.targetSeconds ?? 0;
    if (timerTarget >= 60) {
      return timerTarget;
    }
    if (project.countdownSeconds >= 60) {
      return project.countdownSeconds;
    }
    return 1500;
  }
}

class AggregateStats {
  const AggregateStats({
    required this.sessionCount,
    required this.totalSeconds,
    required this.activeDays,
    required this.consecutiveDays,
  });

  final int sessionCount;
  final int totalSeconds;
  final int activeDays;
  final int consecutiveDays;

  int get averagePerActiveDaySeconds {
    if (activeDays == 0) {
      return 0;
    }
    return (totalSeconds / activeDays).round();
  }
}

class DayStats {
  const DayStats({
    required this.date,
    required this.sessionCount,
    required this.totalSeconds,
  });

  final DateTime date;
  final int sessionCount;
  final int totalSeconds;
}

class ProjectDistributionItem {
  const ProjectDistributionItem({
    required this.projectId,
    required this.projectName,
    required this.colorValue,
    required this.totalSeconds,
  });

  final int projectId;
  final String projectName;
  final int colorValue;
  final int totalSeconds;

  Color get color => Color(colorValue);
}

class DistributionStats {
  const DistributionStats({
    required this.startDate,
    required this.endDate,
    required this.totalSeconds,
    required this.averagePerDaySeconds,
    required this.items,
  });

  final DateTime startDate;
  final DateTime endDate;
  final int totalSeconds;
  final int averagePerDaySeconds;
  final List<ProjectDistributionItem> items;
}

class MonthHourBucketItem {
  const MonthHourBucketItem({required this.hour, required this.totalSeconds});

  final int hour;
  final int totalSeconds;
}

class MonthHourDistributionStats {
  const MonthHourDistributionStats({
    required this.month,
    required this.items,
    required this.totalSeconds,
  });

  final DateTime month;
  final List<MonthHourBucketItem> items;
  final int totalSeconds;
}

class MonthDailyPoint {
  const MonthDailyPoint({required this.day, required this.totalSeconds});

  final int day;
  final int totalSeconds;

  double get hours => totalSeconds / 3600;
}

class MonthDailyStats {
  const MonthDailyStats({
    required this.month,
    required this.points,
    required this.totalSeconds,
  });

  final DateTime month;
  final List<MonthDailyPoint> points;
  final int totalSeconds;
}

class YearMonthlyPoint {
  const YearMonthlyPoint({required this.month, required this.totalSeconds});

  final int month;
  final int totalSeconds;

  double get hours => totalSeconds / 3600;
}

class YearMonthlyStats {
  const YearMonthlyStats({
    required this.year,
    required this.points,
    required this.totalSeconds,
  });

  final DateTime year;
  final List<YearMonthlyPoint> points;
  final int totalSeconds;
}

class HistoryItem {
  const HistoryItem({
    required this.session,
    required this.projectName,
    required this.colorValue,
  });

  final FocusSession session;
  final String projectName;
  final int colorValue;

  Color get color => Color(colorValue);
}
