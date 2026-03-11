import 'package:intl/intl.dart';

String formatClock(Duration duration) {
  final Duration safeDuration = duration.isNegative ? Duration.zero : duration;
  final int hours = safeDuration.inHours;
  final int minutes = safeDuration.inMinutes.remainder(60);
  final int seconds = safeDuration.inSeconds.remainder(60);
  return '${hours.toString().padLeft(2, '0')}:'
      '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

String formatDurationSeconds(
  int seconds, {
  bool showSeconds = false,
  bool compact = false,
}) {
  return _formatDurationSecondsInternal(
    seconds,
    showSeconds: showSeconds,
    compact: compact,
    hideMinutesWhenHoursGte1000: true,
  );
}

String formatDurationSecondsKeepMinutes(
  int seconds, {
  bool showSeconds = false,
  bool compact = false,
}) {
  return _formatDurationSecondsInternal(
    seconds,
    showSeconds: showSeconds,
    compact: compact,
    hideMinutesWhenHoursGte1000: false,
  );
}

String _formatDurationSecondsInternal(
  int seconds, {
  required bool showSeconds,
  required bool compact,
  required bool hideMinutesWhenHoursGte1000,
}) {
  if (seconds <= 0) {
    return showSeconds ? '0秒' : '0分';
  }

  final int hours = seconds ~/ 3600;
  final int minutes = (seconds % 3600) ~/ 60;
  final int sec = seconds % 60;
  final bool hideMinutes = hideMinutesWhenHoursGte1000 && hours >= 1000;

  if (compact) {
    if (showSeconds) {
      if (hideMinutes) {
        return '${hours}h';
      }
      return '${hours}h ${minutes}m ${sec}s';
    }
    if (hideMinutes) {
      return '${hours}h';
    }
    return '${hours}h ${minutes}m';
  }

  if (showSeconds) {
    if (hours > 0) {
      if (hideMinutes) {
        return '$hours小时';
      }
      return '$hours小时$minutes分$sec秒';
    }
    if (minutes > 0) {
      return '$minutes分$sec秒';
    }
    return '$sec秒';
  }

  if (hours == 0) {
    return '$minutes分钟';
  }
  if (hideMinutes) {
    return '$hours小时';
  }
  return '$hours小时$minutes分钟';
}

String formatPercent(double value) {
  return '${(value * 100).toStringAsFixed(1)}%';
}

String formatDate(DateTime date) {
  return DateFormat('yyyy-MM-dd').format(date);
}

String formatDateLabel(DateTime date) {
  return DateFormat('M月d日 EEE', 'zh_CN').format(date);
}

String formatDateTime(DateTime dateTime) {
  return DateFormat('yyyy-MM-dd HH:mm').format(dateTime);
}

String formatTime(DateTime dateTime) {
  return DateFormat('HH:mm').format(dateTime);
}

String formatDateRange(DateTime start, DateTime end) {
  final DateFormat formatter = DateFormat('yyyy-MM-dd');
  final String startText = formatter.format(start);
  final String endText = formatter.format(end);
  if (startText == endText) {
    return startText;
  }
  return '$startText ~ $endText';
}

DateTime dayStart(DateTime date) => DateTime(date.year, date.month, date.day);

DateTime dayEnd(DateTime date) =>
    DateTime(date.year, date.month, date.day, 23, 59, 59);
