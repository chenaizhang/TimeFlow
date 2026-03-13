import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/cupertino.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:file_picker/file_picker.dart';
import 'package:image_gallery_saver/image_gallery_saver.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:screenshot/screenshot.dart';
import 'package:share_plus/share_plus.dart';

import '../../data/timeflow_repository.dart';
import '../../models/models.dart';
import '../../state/app_model.dart';
import '../../utils/time_format.dart';
import 'history_screen.dart';

enum _StatsMenuAction { exportJson, importJson }

class StatsScreen extends StatefulWidget {
  const StatsScreen({super.key});

  @override
  State<StatsScreen> createState() => _StatsScreenState();
}

class _StatsScreenState extends State<StatsScreen> {
  late final TimeFlowRepository _repository;
  AppModel? _model;

  DateTime _selectedDay = _today();
  DateTime _selectedHourMonth = _monthStart(_today());
  DateTime _selectedDailyMonth = _monthStart(_today());
  DateTime _selectedYear = _yearStart(_today());
  RangeType _rangeType = RangeType.day;
  DateTimeRange? _customRange;

  AggregateStats _aggregateStats = const AggregateStats(
    sessionCount: 0,
    totalSeconds: 0,
    activeDays: 0,
    consecutiveDays: 0,
  );
  DayStats _dayStats = DayStats(
    date: _today(),
    sessionCount: 0,
    totalSeconds: 0,
  );
  DistributionStats _distributionStats = DistributionStats(
    startDate: _today(),
    endDate: _today(),
    totalSeconds: 0,
    averagePerDaySeconds: 0,
    items: const <ProjectDistributionItem>[],
  );
  MonthHourDistributionStats _monthHourStats = MonthHourDistributionStats(
    month: _monthStart(_today()),
    items: const <MonthHourBucketItem>[],
    totalSeconds: 0,
  );
  MonthDailyStats _monthDailyStats = MonthDailyStats(
    month: _monthStart(_today()),
    points: const <MonthDailyPoint>[],
    totalSeconds: 0,
  );
  YearMonthlyStats _yearMonthlyStats = YearMonthlyStats(
    year: _yearStart(_today()),
    points: const <YearMonthlyPoint>[],
    totalSeconds: 0,
  );

  bool _loading = true;
  String? _error;
  int _lastDataVersion = -1;
  int? _selectedDistributionProjectId;
  bool _customRangeButtonAnimating = false;
  bool _sharingPoster = false;
  bool _pieInteracting = false;
  bool _backupBusy = false;
  final ScreenshotController _posterController = ScreenshotController();

  @override
  void initState() {
    super.initState();
    _repository = context.read<TimeFlowRepository>();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final AppModel model = context.read<AppModel>();
    if (_model == model) {
      return;
    }
    _model?.removeListener(_onModelChanged);
    _model = model;
    _model?.addListener(_onModelChanged);
    _lastDataVersion = model.dataVersion;
    _loadAll();
  }

  @override
  void dispose() {
    _model?.removeListener(_onModelChanged);
    super.dispose();
  }

  void _onModelChanged() {
    final AppModel? model = _model;
    if (model == null) {
      return;
    }
    if (_lastDataVersion == model.dataVersion) {
      return;
    }
    _lastDataVersion = model.dataVersion;
    _loadAll();
  }

  Future<void> _loadAll() async {
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final DateTimeRange range = _resolveRange();

      final List<Object> results = await Future.wait<Object>(<Future<Object>>[
        _repository.fetchAggregateStats(streakEndDate: _selectedDay),
        _repository.fetchDayStats(_selectedDay),
        _repository.fetchDistribution(range.start, range.end),
        _repository.fetchMonthHourDistribution(_selectedHourMonth),
        _repository.fetchMonthDailyStats(_selectedDailyMonth),
        _repository.fetchYearMonthlyStats(_selectedYear),
      ]);

      if (!mounted) {
        return;
      }

      final DistributionStats rawDistribution = results[2] as DistributionStats;
      final DistributionStats distribution = _alignDistributionColorsToProjects(
        rawDistribution,
      );
      int? selectedProjectId = _selectedDistributionProjectId;
      if (distribution.items.isEmpty) {
        selectedProjectId = null;
      } else if (selectedProjectId != null &&
          !distribution.items.any(
            (ProjectDistributionItem item) =>
                item.projectId == selectedProjectId,
          )) {
        selectedProjectId = null;
      }

      setState(() {
        _aggregateStats = results[0] as AggregateStats;
        _dayStats = results[1] as DayStats;
        _distributionStats = distribution;
        _monthHourStats = results[3] as MonthHourDistributionStats;
        _monthDailyStats = results[4] as MonthDailyStats;
        _yearMonthlyStats = results[5] as YearMonthlyStats;
        _selectedDistributionProjectId = selectedProjectId;
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  DistributionStats _alignDistributionColorsToProjects(
    DistributionStats stats,
  ) {
    if (stats.items.isEmpty) {
      return stats;
    }

    final AppModel? model = _model;
    final Map<int, int> activeColorByProjectId = <int, int>{};
    final Set<int> activeProjectIds = <int>{};
    if (model != null) {
      for (final ProjectGroupBundle bundle in model.bundles) {
        for (final ProjectItem project in bundle.projects) {
          activeColorByProjectId[project.id] = project.colorValue;
          activeProjectIds.add(project.id);
        }
      }
    }

    bool changed = false;
    final List<ProjectDistributionItem> normalized = stats.items
        .map((ProjectDistributionItem item) {
          final int? activeColor = activeColorByProjectId[item.projectId];
          if (activeColor == null || activeColor == item.colorValue) {
            return item;
          }
          changed = true;
          return ProjectDistributionItem(
            projectId: item.projectId,
            projectName: item.projectName,
            colorValue: activeColor,
            totalSeconds: item.totalSeconds,
          );
        })
        .toList(growable: false);

    final Map<String, ProjectDistributionItem> mergedByName =
        <String, ProjectDistributionItem>{};
    final List<String> order = <String>[];

    for (final ProjectDistributionItem item in normalized) {
      final String key = item.projectName.trim().isEmpty
          ? item.projectName
          : item.projectName.trim();
      final ProjectDistributionItem? existing = mergedByName[key];
      if (existing == null) {
        mergedByName[key] = ProjectDistributionItem(
          projectId: item.projectId,
          projectName: key,
          colorValue: item.colorValue,
          totalSeconds: item.totalSeconds,
        );
        order.add(key);
        continue;
      }

      changed = true;
      final bool existingActive = activeProjectIds.contains(existing.projectId);
      final bool incomingActive = activeProjectIds.contains(item.projectId);
      final bool preferIncoming =
          (!existingActive && incomingActive) ||
          (existingActive == incomingActive &&
              item.totalSeconds > existing.totalSeconds);
      final ProjectDistributionItem representative = preferIncoming
          ? item
          : existing;

      mergedByName[key] = ProjectDistributionItem(
        projectId: representative.projectId,
        projectName: key,
        colorValue: representative.colorValue,
        totalSeconds: existing.totalSeconds + item.totalSeconds,
      );
    }

    final List<ProjectDistributionItem> mergedItems =
        order.map((String key) => mergedByName[key]!).toList(growable: false)
          ..sort(
            (ProjectDistributionItem a, ProjectDistributionItem b) =>
                b.totalSeconds.compareTo(a.totalSeconds),
          );

    if (!changed) {
      return stats;
    }

    return DistributionStats(
      startDate: stats.startDate,
      endDate: stats.endDate,
      totalSeconds: stats.totalSeconds,
      averagePerDaySeconds: stats.averagePerDaySeconds,
      items: mergedItems,
    );
  }

  DateTimeRange _resolveRange() {
    final DateTime baseDay = DateTime(
      _selectedDay.year,
      _selectedDay.month,
      _selectedDay.day,
    );

    switch (_rangeType) {
      case RangeType.day:
        return DateTimeRange(start: baseDay, end: baseDay);
      case RangeType.week:
        final int weekday = baseDay.weekday;
        final DateTime start = baseDay.subtract(Duration(days: weekday - 1));
        final DateTime end = start.add(const Duration(days: 6));
        return DateTimeRange(start: start, end: end);
      case RangeType.month:
        final DateTime start = DateTime(baseDay.year, baseDay.month, 1);
        final DateTime end = DateTime(baseDay.year, baseDay.month + 1, 0);
        return DateTimeRange(start: start, end: end);
      case RangeType.custom:
        if (_customRange != null) {
          return DateTimeRange(
            start: DateTime(
              _customRange!.start.year,
              _customRange!.start.month,
              _customRange!.start.day,
            ),
            end: DateTime(
              _customRange!.end.year,
              _customRange!.end.month,
              _customRange!.end.day,
            ),
          );
        }
        return DateTimeRange(start: baseDay, end: baseDay);
    }
  }

  @override
  Widget build(BuildContext context) {
    final DateTime minSelectableDay = _minSelectableDate();
    final DateTime maxSelectableDay = _today();
    final DateTime minSelectableMonth = _monthStart(minSelectableDay);
    final DateTime maxSelectableMonth = _monthStart(maxSelectableDay);
    final DateTime minSelectableYear = _yearStart(minSelectableDay);
    final DateTime maxSelectableYear = _yearStart(maxSelectableDay);
    final bool canGoPreviousDay = _selectedDay.isAfter(minSelectableDay);
    final bool canGoNextDay = _selectedDay.isBefore(maxSelectableDay);
    final bool canGoPreviousHourMonth = _selectedHourMonth.isAfter(
      minSelectableMonth,
    );
    final bool canGoNextHourMonth = _selectedHourMonth.isBefore(
      maxSelectableMonth,
    );
    final bool canGoPreviousDailyMonth = _selectedDailyMonth.isAfter(
      minSelectableMonth,
    );
    final bool canGoNextDailyMonth = _selectedDailyMonth.isBefore(
      maxSelectableMonth,
    );
    final bool canGoPreviousYear = _selectedYear.isAfter(minSelectableYear);
    final bool canGoNextYear = _selectedYear.isBefore(maxSelectableYear);

    return Scaffold(
      appBar: AppBar(
        title: const Text('统计数据'),
        actions: <Widget>[
          PopupMenuButton<_StatsMenuAction>(
            tooltip: '更多',
            icon: const Icon(Icons.more_vert_rounded),
            enabled: !_backupBusy,
            onSelected: _handleMenuAction,
            itemBuilder: (BuildContext context) =>
                const <PopupMenuEntry<_StatsMenuAction>>[
                  PopupMenuItem<_StatsMenuAction>(
                    value: _StatsMenuAction.exportJson,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.file_upload_outlined),
                      title: Text('导出备份'),
                    ),
                  ),
                  PopupMenuItem<_StatsMenuAction>(
                    value: _StatsMenuAction.importJson,
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.file_download_outlined),
                      title: Text('导入备份'),
                    ),
                  ),
                ],
          ),
        ],
      ),
      body: ListView(
        physics: _pieInteracting
            ? const NeverScrollableScrollPhysics()
            : const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 24),
        children: <Widget>[
          SizedBox(
            height: 2,
            child: AnimatedOpacity(
              opacity: _loading ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
          if (_error != null) ...<Widget>[
            _SectionCard(child: Text('加载失败：$_error')),
            const SizedBox(height: 10),
          ],
          _AggregateCard(stats: _aggregateStats),
          const SizedBox(height: 12),
          _DayCard(
            date: _selectedDay,
            stats: _dayStats,
            onPreviousDay: canGoPreviousDay
                ? () => _shiftSelectedDay(-1)
                : null,
            onNextDay: canGoNextDay ? () => _shiftSelectedDay(1) : null,
            onPickDate: _pickDay,
          ),
          const SizedBox(height: 12),
          _DistributionCard(
            rangeType: _rangeType,
            stats: _distributionStats,
            selectedProjectId: _selectedDistributionProjectId,
            customAnimating: _customRangeButtonAnimating,
            sharing: _sharingPoster,
            onShare: _handleSharePoster,
            onTypeChanged: _handleRangeTypeChanged,
            onOpenHistory: () {
              Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => HistoryScreen(initialDate: _selectedDay),
                ),
              );
            },
            onSelectProject: (int? projectId) {
              setState(() {
                _selectedDistributionProjectId = projectId;
              });
            },
            onPieInteractionChanged: (bool interacting) {
              if (!mounted || _pieInteracting == interacting) {
                return;
              }
              setState(() {
                _pieInteracting = interacting;
              });
            },
          ),
          const SizedBox(height: 12),
          _MonthHourDistributionCard(
            month: _selectedHourMonth,
            stats: _monthHourStats,
            onPreviousMonth: canGoPreviousHourMonth
                ? () => _shiftHourMonth(-1)
                : null,
            onNextMonth: canGoNextHourMonth ? () => _shiftHourMonth(1) : null,
            onPickMonth: _pickHourMonth,
          ),
          const SizedBox(height: 12),
          _MonthDailyLineCard(
            month: _selectedDailyMonth,
            stats: _monthDailyStats,
            onPreviousMonth: canGoPreviousDailyMonth
                ? () => _shiftDailyMonth(-1)
                : null,
            onNextMonth: canGoNextDailyMonth ? () => _shiftDailyMonth(1) : null,
            onPickMonth: _pickDailyMonth,
          ),
          const SizedBox(height: 12),
          _YearlyLineCard(
            year: _selectedYear,
            stats: _yearMonthlyStats,
            onPreviousYear: canGoPreviousYear
                ? () => _shiftSelectedYear(-1)
                : null,
            onNextYear: canGoNextYear ? () => _shiftSelectedYear(1) : null,
            onPickYear: _pickYear,
          ),
        ],
      ),
    );
  }

  Future<void> _handleMenuAction(_StatsMenuAction action) async {
    if (_backupBusy) {
      return;
    }
    switch (action) {
      case _StatsMenuAction.exportJson:
        await _exportBackupJson();
      case _StatsMenuAction.importJson:
        await _importBackupJson();
    }
  }

  Future<void> _exportBackupJson() async {
    setState(() {
      _backupBusy = true;
    });
    try {
      final String jsonText = await _repository.exportBackupJson();
      final Directory directory = await getTemporaryDirectory();
      final DateTime now = DateTime.now();
      final String stamp =
          '${now.year.toString().padLeft(4, '0')}'
          '${now.month.toString().padLeft(2, '0')}'
          '${now.day.toString().padLeft(2, '0')}_'
          '${now.hour.toString().padLeft(2, '0')}'
          '${now.minute.toString().padLeft(2, '0')}'
          '${now.second.toString().padLeft(2, '0')}';
      final File file = File('${directory.path}/计流备份_$stamp.json');
      await file.writeAsString(jsonText, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(file.path, mimeType: 'application/json')],
          text: '计流数据备份文件',
          sharePositionOrigin: _resolveSharePositionOrigin(),
        ),
      );
      if (mounted) {
        _showMessage('已打开系统分享，可保存到文件或发送到新设备');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('导出失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
        });
      }
    }
  }

  Future<void> _importBackupJson() async {
    final bool confirmed = await _confirmImportJson();
    if (!confirmed || !mounted) {
      return;
    }

    setState(() {
      _backupBusy = true;
    });
    try {
      final FilePickerResult? result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const <String>['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) {
        return;
      }
      final PlatformFile pickedFile = result.files.first;
      final Uint8List? bytes = pickedFile.bytes;
      final String? path = pickedFile.path;

      String text;
      if (bytes != null) {
        text = utf8.decode(bytes, allowMalformed: true);
      } else if (path != null && path.isNotEmpty) {
        text = await File(path).readAsString();
      } else {
        throw ValidationException('无法读取所选文件');
      }

      await _repository.importBackupJson(text);
      await _model?.refreshAll();
      if (mounted) {
        await _loadAll();
      }
      if (mounted) {
        _showMessage('导入成功');
      }
    } catch (error) {
      if (mounted) {
        _showMessage('导入失败：$error');
      }
    } finally {
      if (mounted) {
        setState(() {
          _backupBusy = false;
        });
      }
    }
  }

  Future<bool> _confirmImportJson() async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) {
        return AlertDialog(
          title: const Text('导入备份'),
          content: const Text('导入会覆盖当前本地所有数据（含待办集、代办、专注记录和正在计时状态），是否继续？'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('继续导入'),
            ),
          ],
        );
      },
    );
    return confirmed ?? false;
  }

  void _showMessage(String message) {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  Rect _resolveSharePositionOrigin() {
    final RenderObject? renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      final Offset topLeft = renderObject.localToGlobal(Offset.zero);
      final Size size = renderObject.size;
      final double width = size.width > 0 ? size.width : 1;
      final double height = size.height > 0 ? size.height : 1;
      return Rect.fromLTWH(topLeft.dx, topLeft.dy, width, height);
    }

    final Size viewport = MediaQuery.sizeOf(context);
    final double width = viewport.width > 0 ? viewport.width : 1;
    final double height = viewport.height > 0 ? viewport.height : 1;
    return Rect.fromLTWH(0, 0, width, height);
  }

  Size _resolvePosterTargetSize(int distributionItemCount) {
    final int count = distributionItemCount.clamp(0, 20);
    const double width = 860;
    final double height = (700 + (count * 26)).toDouble().clamp(780.0, 980.0);
    return Size(width, height);
  }

  DateTime _clampSelectableMonth(DateTime value) {
    final DateTime minMonth = _monthStart(_minSelectableDate());
    final DateTime maxMonth = _monthStart(_today());
    DateTime normalized = _monthStart(value);
    if (normalized.isBefore(minMonth)) {
      normalized = minMonth;
    }
    if (normalized.isAfter(maxMonth)) {
      normalized = maxMonth;
    }
    return normalized;
  }

  DateTime _clampSelectableYear(DateTime value) {
    final DateTime minYear = _yearStart(_minSelectableDate());
    final DateTime maxYear = _yearStart(_today());
    DateTime normalized = _yearStart(value);
    if (normalized.isBefore(minYear)) {
      normalized = minYear;
    }
    if (normalized.isAfter(maxYear)) {
      normalized = maxYear;
    }
    return normalized;
  }

  void _shiftHourMonth(int offsetMonths) {
    setState(() {
      _selectedHourMonth = _clampSelectableMonth(
        DateTime(
          _selectedHourMonth.year,
          _selectedHourMonth.month + offsetMonths,
          1,
        ),
      );
    });
    _loadAll();
  }

  void _shiftDailyMonth(int offsetMonths) {
    setState(() {
      _selectedDailyMonth = _clampSelectableMonth(
        DateTime(
          _selectedDailyMonth.year,
          _selectedDailyMonth.month + offsetMonths,
          1,
        ),
      );
    });
    _loadAll();
  }

  void _shiftSelectedYear(int offsetYears) {
    setState(() {
      _selectedYear = _clampSelectableYear(
        DateTime(_selectedYear.year + offsetYears, 1, 1),
      );
    });
    _loadAll();
  }

  void _shiftSelectedDay(int offsetDays) {
    setState(() {
      _selectedDay = _selectedDay.add(Duration(days: offsetDays));
    });
    _loadAll();
  }

  Future<DateTime?> _pickMonth(DateTime currentMonth, {String? title}) async {
    final DateTime firstDate = _minSelectableDate();
    final DateTime lastDate = _today();
    final DateTime initial = _clampSelectableMonth(currentMonth);

    final DateTime? picked = await showDialog<DateTime>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return _MonthPickerDialog(
          title: title ?? '选择月份',
          initialDate: initial,
          firstDate: firstDate,
          lastDate: lastDate,
        );
      },
    );
    if (picked == null) {
      return null;
    }
    return _clampSelectableMonth(picked);
  }

  Future<void> _pickHourMonth() async {
    final DateTime? picked = await _pickMonth(
      _selectedHourMonth,
      title: '选择本月专注时段分布月份',
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _selectedHourMonth = picked;
    });
    _loadAll();
  }

  Future<void> _pickDailyMonth() async {
    final DateTime? picked = await _pickMonth(
      _selectedDailyMonth,
      title: '选择月度专注统计月份',
    );
    if (!mounted || picked == null) {
      return;
    }
    setState(() {
      _selectedDailyMonth = picked;
    });
    _loadAll();
  }

  Future<void> _pickYear() async {
    final int minYear = _minSelectableDate().year;
    final int maxYear = _today().year;
    final int? pickedYear = await showDialog<int>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return _YearPickerDialog(
          title: '选择年度专注统计年份',
          initialYear: _selectedYear.year,
          minYear: minYear,
          maxYear: maxYear,
        );
      },
    );
    if (!mounted || pickedYear == null) {
      return;
    }
    setState(() {
      _selectedYear = _clampSelectableYear(DateTime(pickedYear, 1, 1));
    });
    _loadAll();
  }

  Future<void> _pickDay() async {
    final DateTime firstDate = _minSelectableDate();
    final DateTime lastDate = _today();
    DateTime initialDate = _selectedDay;
    if (initialDate.isBefore(firstDate)) {
      initialDate = firstDate;
    }
    if (initialDate.isAfter(lastDate)) {
      initialDate = lastDate;
    }

    final DateTime? picked = await showDialog<DateTime>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return _SingleDatePickerDialog(
          title: '选择日期',
          sectionTitle: '请选择日期：',
          initialDate: initialDate,
          firstDate: firstDate,
          lastDate: lastDate,
        );
      },
    );

    if (!mounted || picked == null) {
      return;
    }

    DateTime selected = DateTime(picked.year, picked.month, picked.day);
    if (selected.isBefore(firstDate)) {
      selected = firstDate;
    }
    if (selected.isAfter(lastDate)) {
      selected = lastDate;
    }

    setState(() {
      _selectedDay = selected;
    });
    _loadAll();
  }

  Future<void> _handleRangeTypeChanged(RangeType type) async {
    if (type != RangeType.custom) {
      setState(() {
        _rangeType = type;
        _customRangeButtonAnimating = false;
      });
      _loadAll();
      return;
    }

    final RangeType previousType = _rangeType;
    setState(() {
      _rangeType = type;
      _customRangeButtonAnimating = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 220));
    if (!mounted) {
      return;
    }

    final bool applied = await _pickCustomRange();
    if (!mounted) {
      return;
    }

    setState(() {
      if (!applied) {
        _rangeType = previousType;
      }
      _customRangeButtonAnimating = false;
    });
  }

  Future<bool> _pickCustomRange() async {
    final DateTime now = _today();
    final DateTime firstDate = _minSelectableDate();
    final DateTime lastDate = now;
    DateTime clampDate(DateTime value) {
      if (value.isBefore(firstDate)) {
        return firstDate;
      }
      if (value.isAfter(lastDate)) {
        return lastDate;
      }
      return value;
    }

    final DateTimeRange fallback = DateTimeRange(
      start: now.subtract(const Duration(days: 6)),
      end: now,
    );
    final DateTimeRange source = _customRange ?? fallback;
    DateTime initialStart = clampDate(
      DateTime(source.start.year, source.start.month, source.start.day),
    );
    DateTime initialEnd = clampDate(
      DateTime(source.end.year, source.end.month, source.end.day),
    );
    if (initialStart.isAfter(initialEnd)) {
      initialStart = initialEnd;
    }
    final DateTimeRange initial = DateTimeRange(
      start: initialStart,
      end: initialEnd,
    );

    final DateTimeRange? picked = await showDialog<DateTimeRange>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) {
        return _CustomRangePickerDialog(
          initialRange: DateTimeRange(
            start: DateTime(
              initial.start.year,
              initial.start.month,
              initial.start.day,
            ),
            end: DateTime(initial.end.year, initial.end.month, initial.end.day),
          ),
          firstDate: firstDate,
          lastDate: lastDate,
        );
      },
    );

    if (!mounted) {
      return false;
    }

    if (picked == null) {
      return false;
    }

    DateTime pickedStart = clampDate(
      DateTime(picked.start.year, picked.start.month, picked.start.day),
    );
    DateTime pickedEnd = clampDate(
      DateTime(picked.end.year, picked.end.month, picked.end.day),
    );
    if (pickedStart.isAfter(pickedEnd)) {
      pickedStart = pickedEnd;
    }

    setState(() {
      _customRange = DateTimeRange(start: pickedStart, end: pickedEnd);
      _rangeType = RangeType.custom;
    });
    _loadAll();
    return true;
  }

  static DateTime _today() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  static DateTime _monthStart(DateTime date) => DateTime(date.year, date.month);

  static DateTime _yearStart(DateTime date) => DateTime(date.year, 1, 1);

  static DateTime _minSelectableDate() => DateTime(2017, 1, 1);

  Future<void> _handleSharePoster() async {
    if (_sharingPoster) {
      return;
    }

    setState(() {
      _sharingPoster = true;
    });

    try {
      final ThemeData theme = Theme.of(context);
      final MediaQueryData mediaQuery = MediaQuery.of(
        context,
      ).copyWith(textScaler: const TextScaler.linear(1));
      final TextDirection textDirection = Directionality.of(context);
      final Size posterTargetSize = _resolvePosterTargetSize(
        _distributionStats.items.length,
      );
      final double screenshotAspectRatio =
          posterTargetSize.width / posterTargetSize.height;

      final Uint8List rawBytes = await _posterController.captureFromWidget(
        InheritedTheme.captureAll(
          context,
          Theme(
            data: theme,
            child: Directionality(
              textDirection: textDirection,
              child: MediaQuery(
                data: mediaQuery,
                child: Material(
                  color: Colors.transparent,
                  child: _FocusSharePoster(
                    posterSize: posterTargetSize,
                    day: _selectedDay,
                    aggregateStats: _aggregateStats,
                    dayStats: _dayStats,
                    distributionStats: _distributionStats,
                  ),
                ),
              ),
            ),
          ),
        ),
        delay: const Duration(milliseconds: 40),
        pixelRatio: 3,
        targetSize: posterTargetSize,
      );
      final Uint8List imageBytes = await _cropImageToAspect(
        rawBytes,
        screenshotAspectRatio,
      );

      if (!mounted) {
        return;
      }
      await _showShareActions(imageBytes, screenshotAspectRatio);
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('生成分享图失败：$error')));
    } finally {
      if (mounted) {
        setState(() {
          _sharingPoster = false;
        });
      }
    }
  }

  Future<void> _showShareActions(
    Uint8List imageBytes,
    double screenshotAspectRatio,
  ) async {
    await showDialog<void>(
      context: context,
      barrierColor: Colors.black.withValues(alpha: 0.4),
      builder: (BuildContext dialogContext) {
        final Size size = MediaQuery.sizeOf(dialogContext);
        final double dialogWidth = min(420.0, size.width - 28);
        final double previewMaxWidth = dialogWidth - 72;
        final double previewHeightByWidth =
            previewMaxWidth / screenshotAspectRatio;
        final double previewMaxHeight = size.height * 0.7;
        final double previewHeight = min(
          previewHeightByWidth,
          previewMaxHeight,
        );
        final double previewWidth = previewHeight * screenshotAspectRatio;
        final ColorScheme scheme = Theme.of(dialogContext).colorScheme;

        return Dialog(
          backgroundColor: Colors.transparent,
          insetPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 20,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(22),
          ),
          child: Container(
            width: dialogWidth,
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: scheme.outline.withValues(alpha: 0.18),
                width: 1,
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 14),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Text(
                        '分享',
                        style: Theme.of(dialogContext).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w700,
                              color: scheme.onSurface,
                            ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '保存到相册',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          await _savePosterToGallery(imageBytes);
                        },
                        icon: Icon(
                          Icons.download_rounded,
                          color: scheme.onSurface,
                        ),
                      ),
                      IconButton(
                        tooltip: '系统分享',
                        visualDensity: VisualDensity.compact,
                        onPressed: () async {
                          Navigator.of(dialogContext).pop();
                          await _sharePoster(imageBytes);
                        },
                        icon: Icon(
                          Icons.ios_share_rounded,
                          color: scheme.onSurface,
                        ),
                      ),
                      IconButton(
                        tooltip: '关闭',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => Navigator.of(dialogContext).pop(),
                        icon: Icon(
                          Icons.close_rounded,
                          color: scheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: previewWidth,
                      height: previewHeight,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(16),
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: scheme.surfaceContainerLow,
                          ),
                          child: Image.memory(
                            imageBytes,
                            fit: BoxFit.cover,
                            width: double.infinity,
                            height: double.infinity,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _savePosterToGallery(Uint8List imageBytes) async {
    try {
      final String name = 'jiliu_${DateTime.now().millisecondsSinceEpoch}';
      final dynamic result = await ImageGallerySaver.saveImage(
        imageBytes,
        quality: 100,
        name: name,
      );
      if (!mounted) {
        return;
      }
      final bool success = _isGallerySaveSuccess(result);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(success ? '图片已保存到相册' : '保存失败，请检查相册权限')),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('保存失败：$error')));
    }
  }

  Future<void> _sharePoster(Uint8List imageBytes) async {
    try {
      final Directory tempDir = await getTemporaryDirectory();
      final String filePath =
          '${tempDir.path}/jiliu_share_${DateTime.now().millisecondsSinceEpoch}.png';
      final File imageFile = File(filePath);
      await imageFile.writeAsBytes(imageBytes, flush: true);

      await SharePlus.instance.share(
        ShareParams(
          files: <XFile>[XFile(imageFile.path, mimeType: 'image/png')],
          text: '计流专注统计',
          sharePositionOrigin: _resolveSharePositionOrigin(),
        ),
      );
    } catch (error) {
      if (!mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('分享失败：$error')));
    }
  }

  bool _isGallerySaveSuccess(dynamic result) {
    if (result is Map<Object?, Object?>) {
      final dynamic flag =
          result['isSuccess'] ??
          result['success'] ??
          result['is_success'] ??
          result['result'];
      if (flag is bool) {
        return flag;
      }
      if (flag is num) {
        return flag != 0;
      }
      if (flag is String) {
        final String normalized = flag.toLowerCase();
        return normalized == 'true' || normalized == '1' || normalized == 'ok';
      }
    }
    return false;
  }

  Future<Uint8List> _cropImageToAspect(
    Uint8List imageBytes,
    double targetAspect,
  ) async {
    final ui.Codec codec = await ui.instantiateImageCodec(imageBytes);
    final ui.FrameInfo frame = await codec.getNextFrame();
    final ui.Image sourceImage = frame.image;
    final double safeAspect = targetAspect.clamp(0.45, 1.2).toDouble();

    try {
      final double sourceWidth = sourceImage.width.toDouble();
      final double sourceHeight = sourceImage.height.toDouble();
      final double sourceAspect = sourceWidth / sourceHeight;

      if ((sourceAspect - safeAspect).abs() < 0.001) {
        return imageBytes;
      }

      Rect srcRect = Rect.fromLTWH(0, 0, sourceWidth, sourceHeight);
      if (sourceAspect > safeAspect) {
        final double cropWidth = sourceHeight * safeAspect;
        final double left = (sourceWidth - cropWidth) / 2;
        srcRect = Rect.fromLTWH(left, 0, cropWidth, sourceHeight);
      } else {
        final double cropHeight = sourceWidth / safeAspect;
        final double top = (sourceHeight - cropHeight) / 2;
        srcRect = Rect.fromLTWH(0, top, sourceWidth, cropHeight);
      }

      final ui.PictureRecorder recorder = ui.PictureRecorder();
      final Canvas canvas = Canvas(recorder);
      final Rect dstRect = Rect.fromLTWH(0, 0, srcRect.width, srcRect.height);
      canvas.drawImageRect(
        sourceImage,
        srcRect,
        dstRect,
        Paint()..filterQuality = FilterQuality.high,
      );

      final ui.Image cropped = await recorder.endRecording().toImage(
        srcRect.width.round(),
        srcRect.height.round(),
      );
      try {
        final ByteData? data = await cropped.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (data == null) {
          return imageBytes;
        }
        return data.buffer.asUint8List();
      } finally {
        cropped.dispose();
      }
    } finally {
      sourceImage.dispose();
      codec.dispose();
    }
  }
}

class _AggregateCard extends StatelessWidget {
  const _AggregateCard({required this.stats});

  final AggregateStats stats;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('累计专注', style: Theme.of(context).textTheme.titleMedium),
            ],
          ),
          const SizedBox(height: 8),
          _MetricsRow(
            compactUnitText: true,
            metrics: <_MetricData>[
              _MetricData(label: '次数', value: '${stats.sessionCount}次'),
              _MetricData(
                label: '时长',
                value: formatDurationSeconds(stats.totalSeconds),
              ),
              _MetricData(
                label: '日均时长',
                value: formatDurationSecondsKeepMinutes(
                  stats.averagePerActiveDaySeconds,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.date,
    required this.stats,
    required this.onPreviousDay,
    required this.onNextDay,
    required this.onPickDate,
  });

  final DateTime date;
  final DayStats stats;
  final VoidCallback? onPreviousDay;
  final VoidCallback? onNextDay;
  final VoidCallback onPickDate;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('当日专注', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: onPreviousDay,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: onPickDate,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(
                      formatDate(date),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: onNextDay,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          _MetricsRow(
            columnCount: 2,
            metrics: <_MetricData>[
              _MetricData(label: '专注次数', value: '${stats.sessionCount}次'),
              _MetricData(
                label: '专注时长',
                value: formatDurationSeconds(stats.totalSeconds),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DistributionCard extends StatelessWidget {
  const _DistributionCard({
    required this.rangeType,
    required this.stats,
    required this.selectedProjectId,
    required this.customAnimating,
    required this.sharing,
    required this.onShare,
    required this.onTypeChanged,
    required this.onOpenHistory,
    required this.onSelectProject,
    required this.onPieInteractionChanged,
  });

  final RangeType rangeType;
  final DistributionStats stats;
  final int? selectedProjectId;
  final bool customAnimating;
  final bool sharing;
  final VoidCallback onShare;
  final ValueChanged<RangeType> onTypeChanged;
  final VoidCallback onOpenHistory;
  final ValueChanged<int?> onSelectProject;
  final ValueChanged<bool> onPieInteractionChanged;

  @override
  Widget build(BuildContext context) {
    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text(
                '专注时长分布',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    alignment: Alignment.centerLeft,
                    child: Text(
                      formatDateRange(stats.startDate, stats.endDate),
                      maxLines: 1,
                      softWrap: false,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: Theme.of(
                          context,
                        ).colorScheme.onSurface.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ),
              ),
              TextButton(
                onPressed: sharing ? null : onShare,
                child: sharing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('分享'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final double width = constraints.maxWidth;
              final bool compact = width < 360;
              final bool ultraCompact = width < 330;
              final EdgeInsetsGeometry segmentPadding = EdgeInsets.symmetric(
                horizontal: ultraCompact ? 4 : (compact ? 8 : 14),
                vertical: ultraCompact ? 8 : 10,
              );
              final TextStyle segmentTextStyle =
                  Theme.of(context).textTheme.labelLarge?.copyWith(
                    fontSize: ultraCompact ? 11 : (compact ? 12 : 14),
                    height: 1.0,
                  ) ??
                  TextStyle(fontSize: ultraCompact ? 11 : (compact ? 12 : 14));

              return SizedBox(
                width: double.infinity,
                child: SegmentedButton<RangeType>(
                  showSelectedIcon: false,
                  expandedInsets: EdgeInsets.zero,
                  style: ButtonStyle(
                    visualDensity: compact
                        ? VisualDensity.compact
                        : VisualDensity.standard,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    padding: WidgetStatePropertyAll<EdgeInsetsGeometry>(
                      segmentPadding,
                    ),
                    textStyle: WidgetStatePropertyAll<TextStyle>(
                      segmentTextStyle,
                    ),
                  ),
                  segments: <ButtonSegment<RangeType>>[
                    const ButtonSegment<RangeType>(
                      value: RangeType.day,
                      label: Text('日'),
                    ),
                    const ButtonSegment<RangeType>(
                      value: RangeType.week,
                      label: Text('周'),
                    ),
                    const ButtonSegment<RangeType>(
                      value: RangeType.month,
                      label: Text('月'),
                    ),
                    ButtonSegment<RangeType>(
                      value: RangeType.custom,
                      label: _CustomRangeLabel(
                        animated: customAnimating,
                        selected: rangeType == RangeType.custom,
                        compact: compact,
                        ultraCompact: ultraCompact,
                      ),
                    ),
                  ],
                  selected: <RangeType>{rangeType},
                  onSelectionChanged: (Set<RangeType> value) {
                    onTypeChanged(value.first);
                  },
                ),
              );
            },
          ),
          const SizedBox(height: 12),
          if (stats.items.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 12),
              child: Text('该时间范围内暂无有效记录'),
            )
          else ...<Widget>[
            SizedBox(
              height: 244,
              child: _PieCalloutChart(
                items: stats.items,
                totalSeconds: stats.totalSeconds,
                selectedProjectId: selectedProjectId,
                onSelectProject: onSelectProject,
                onInteractionChanged: onPieInteractionChanged,
              ),
            ),
            const SizedBox(height: 1),
            Center(
              child: Text(
                '总计 ${formatDurationSeconds(stats.totalSeconds)}  '
                '日均 ${formatDurationSecondsKeepMinutes(stats.averagePerDaySeconds)}',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 10),
            Center(
              child: FilledButton.tonal(
                onPressed: onOpenHistory,
                child: const Text('查看专注记录'),
              ),
            ),
            const SizedBox(height: 10),
            ...stats.items.map((ProjectDistributionItem item) {
              final bool isSelected = item.projectId == selectedProjectId;
              return Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Material(
                  color: isSelected
                      ? item.color.withValues(alpha: 0.12)
                      : Colors.transparent,
                  borderRadius: BorderRadius.circular(10),
                  child: ListTile(
                    onTap: () =>
                        onSelectProject(isSelected ? null : item.projectId),
                    dense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 6),
                    visualDensity: const VisualDensity(vertical: -3),
                    leading: CircleAvatar(
                      radius: 7,
                      backgroundColor: item.color,
                    ),
                    title: Text(
                      item.projectName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    trailing: Text(
                      formatDurationSeconds(item.totalSeconds),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: isSelected
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                    ),
                  ),
                ),
              );
            }),
          ],
        ],
      ),
    );
  }
}

class _MonthHourDistributionCard extends StatelessWidget {
  const _MonthHourDistributionCard({
    required this.month,
    required this.stats,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onPickMonth,
  });

  final DateTime month;
  final MonthHourDistributionStats stats;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;
  final VoidCallback onPickMonth;

  @override
  Widget build(BuildContext context) {
    final List<MonthHourBucketItem> items = stats.items;
    final bool hasData = items.any(
      (MonthHourBucketItem item) => item.totalSeconds > 0,
    );
    final double maxHours = hasData
        ? items
              .map((MonthHourBucketItem item) => item.totalSeconds / 3600)
              .reduce(max)
        : 0;
    final _AxisScale axisScale = _buildBarAxisScale(maxHours * 1.25);

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('本月专注时段分布', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: onPreviousMonth,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: onPickMonth,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_formatYearMonth(month)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: onNextMonth,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('该月暂无专注数据'),
            )
          else ...<Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Set<int> labelIndices = _buildHourAxisLabelIndices(
                  items: items,
                  availableWidth: constraints.maxWidth,
                );
                return SizedBox(
                  height: 220,
                  child: BarChart(
                    BarChartData(
                      minY: 0,
                      maxY: axisScale.maxValue,
                      gridData: FlGridData(
                        show: true,
                        horizontalInterval: axisScale.interval,
                        drawVerticalLine: false,
                        getDrawingHorizontalLine: (_) => FlLine(
                          color: Theme.of(
                            context,
                          ).dividerColor.withValues(alpha: 0.35),
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      barTouchData: BarTouchData(
                        enabled: true,
                        handleBuiltInTouches: false,
                        touchTooltipData: BarTouchTooltipData(
                          direction: TooltipDirection.top,
                          getTooltipColor: (_) => Colors.transparent,
                          tooltipPadding: EdgeInsets.zero,
                          tooltipMargin: 4,
                          fitInsideHorizontally: true,
                          fitInsideVertically: true,
                          getTooltipItem: (group, groupIndex, rod, rodIndex) {
                            if (groupIndex < 0 || groupIndex >= items.length) {
                              return null;
                            }
                            final MonthHourBucketItem item = items[groupIndex];
                            return BarTooltipItem(
                              _formatBarTopHours(item.totalSeconds),
                              Theme.of(context).textTheme.bodySmall?.copyWith(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    color: Theme.of(context)
                                        .colorScheme
                                        .onSurface
                                        .withValues(alpha: 0.45),
                                  ) ??
                                  const TextStyle(
                                    fontSize: 9,
                                    fontWeight: FontWeight.w500,
                                    color: Color(0x8A000000),
                                  ),
                            );
                          },
                        ),
                      ),
                      titlesData: FlTitlesData(
                        topTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        rightTitles: const AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 42,
                            interval: axisScale.interval,
                            getTitlesWidget: (double value, TitleMeta meta) {
                              if (value <= 0 ||
                                  (axisScale.maxValue - value).abs() < 0.0001 ||
                                  value > axisScale.maxValue + 0.0001) {
                                return const SizedBox.shrink();
                              }
                              return Text(
                                _formatBarAxisHours(
                                  value,
                                  interval: axisScale.interval,
                                ),
                                style: Theme.of(context).textTheme.bodySmall,
                              );
                            },
                          ),
                        ),
                        bottomTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 26,
                            getTitlesWidget: (double value, TitleMeta meta) {
                              final int index = value.round();
                              if (index < 0 || index >= items.length) {
                                return const SizedBox.shrink();
                              }
                              if (!labelIndices.contains(index)) {
                                return const SizedBox.shrink();
                              }
                              final int hour = items[index].hour;
                              return Padding(
                                padding: const EdgeInsets.only(top: 4),
                                child: Text(
                                  '$hour',
                                  style: Theme.of(context).textTheme.bodySmall,
                                ),
                              );
                            },
                          ),
                        ),
                      ),
                      barGroups: List<BarChartGroupData>.generate(
                        items.length,
                        (int index) {
                          final MonthHourBucketItem item = items[index];
                          final bool showTopLabel = item.totalSeconds > 0;
                          return BarChartGroupData(
                            x: index,
                            barsSpace: 0,
                            showingTooltipIndicators: showTopLabel
                                ? const <int>[0]
                                : const <int>[],
                            barRods: <BarChartRodData>[
                              BarChartRodData(
                                toY: item.totalSeconds / 3600,
                                width: items.length <= 10 ? 14 : 10,
                                borderRadius: const BorderRadius.all(
                                  Radius.circular(4),
                                ),
                                color: Theme.of(
                                  context,
                                ).colorScheme.primary.withValues(alpha: 0.8),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  _AxisScale _buildBarAxisScale(double suggestedMax) {
    final double safeMax = max(0.05, suggestedMax);
    final double range = _niceNumber(safeMax, round: false);
    final double interval = _niceNumber(range / 4, round: true);
    final double maxValue = (safeMax / interval).ceilToDouble() * interval;
    return _AxisScale(maxValue: maxValue, interval: interval);
  }

  double _niceNumber(double value, {required bool round}) {
    if (!value.isFinite || value <= 0) {
      return 1;
    }
    final double exponent = pow(10, (log(value) / ln10).floor()).toDouble();
    final double fraction = value / exponent;
    double niceFraction;
    if (round) {
      if (fraction < 1.5) {
        niceFraction = 1;
      } else if (fraction < 3) {
        niceFraction = 2;
      } else if (fraction < 7) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    } else {
      if (fraction <= 1) {
        niceFraction = 1;
      } else if (fraction <= 2) {
        niceFraction = 2;
      } else if (fraction <= 5) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    }
    return niceFraction * exponent;
  }

  Set<int> _buildHourAxisLabelIndices({
    required List<MonthHourBucketItem> items,
    required double availableWidth,
  }) {
    if (items.isEmpty) {
      return const <int>{};
    }

    const double estimatedLabelSlotWidth = 34;
    final double plotWidth = max(0, availableWidth - 48);
    final int maxLabelCount = max(
      2,
      (plotWidth / estimatedLabelSlotWidth).floor(),
    );
    final Set<int> labelIndices = <int>{0, items.length - 1};
    if (items.length <= maxLabelCount) {
      labelIndices.addAll(
        List<int>.generate(items.length, (int index) => index),
      );
      return labelIndices;
    }

    final int baseStep = max(1, (items.length / maxLabelCount).ceil());
    for (int index = 0; index < items.length; index += baseStep) {
      labelIndices.add(index);
    }

    final List<int> activeIndices = <int>[
      for (int index = 0; index < items.length; index += 1)
        if (items[index].totalSeconds > 0) index,
    ];
    if (activeIndices.length <= maxLabelCount) {
      labelIndices.addAll(activeIndices);
    } else if (activeIndices.isNotEmpty) {
      labelIndices
        ..add(activeIndices.first)
        ..add(activeIndices.last);
      final int activeStep = max(
        1,
        (activeIndices.length / maxLabelCount).ceil(),
      );
      for (int i = 0; i < activeIndices.length; i += activeStep) {
        labelIndices.add(activeIndices[i]);
      }
    }
    return labelIndices;
  }

  String _formatYearMonth(DateTime date) {
    final String monthText = date.month.toString().padLeft(2, '0');
    return '${date.year}-$monthText';
  }

  String _formatBarAxisHours(double value, {required double interval}) {
    final int decimals = interval >= 1
        ? 0
        : interval >= 0.1
        ? 1
        : 2;
    return '${_trimTrailingZeros(value.toStringAsFixed(decimals))}h';
  }

  String _formatBarTopHours(int seconds) {
    if (seconds <= 0) {
      return '0h';
    }
    if (seconds < 3600) {
      final int minutes = max(1, (seconds / 60).round());
      return '${minutes}m';
    }
    final double hours = seconds / 3600;
    final int decimals = hours < 1 ? 2 : (hours < 10 ? 1 : 0);
    return '${_trimTrailingZeros(hours.toStringAsFixed(decimals))}h';
  }

  String _trimTrailingZeros(String value) {
    if (!value.contains('.')) {
      return value;
    }
    return value.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}

class _MonthDailyLineCard extends StatefulWidget {
  const _MonthDailyLineCard({
    required this.month,
    required this.stats,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onPickMonth,
  });

  final DateTime month;
  final MonthDailyStats stats;
  final VoidCallback? onPreviousMonth;
  final VoidCallback? onNextMonth;
  final VoidCallback onPickMonth;

  @override
  State<_MonthDailyLineCard> createState() => _MonthDailyLineCardState();
}

class _MonthDailyLineCardState extends State<_MonthDailyLineCard> {
  late final ScrollController _lineScrollController;
  double _scrollOffset = 0;
  int? _guideDay;
  double? _guideHours;
  bool _openingHistory = false;
  int _pendingOpenToken = 0;

  @override
  void initState() {
    super.initState();
    _lineScrollController = ScrollController()..addListener(_handleScroll);
  }

  @override
  void dispose() {
    _lineScrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _MonthDailyLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool monthChanged =
        oldWidget.month.year != widget.month.year ||
        oldWidget.month.month != widget.month.month;
    if (!monthChanged) {
      return;
    }
    _cancelPendingHistoryOpen();
    if (_lineScrollController.hasClients) {
      _lineScrollController.jumpTo(0);
    }
    if (_scrollOffset == 0 && _guideDay == null && _guideHours == null) {
      return;
    }
    setState(() {
      _scrollOffset = 0;
      _guideDay = null;
      _guideHours = null;
    });
  }

  void _handleScroll() {
    final double next = _lineScrollController.offset;
    if ((next - _scrollOffset).abs() < 0.5) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _scrollOffset = next;
    });
  }

  void _setGuide(int day, double hours) {
    final double normalizedHours = max(0, hours);
    if (_guideDay == day &&
        _guideHours != null &&
        (_guideHours! - normalizedHours).abs() < 0.0001) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _guideDay = day;
      _guideHours = normalizedHours;
    });
  }

  void _clearGuide() {
    if (_guideDay == null && _guideHours == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _guideDay = null;
      _guideHours = null;
    });
  }

  void _openHistoryForDate(DateTime targetDate) {
    if (_openingHistory || !mounted) {
      return;
    }
    _openingHistory = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => HistoryScreen(initialDate: targetDate),
          ),
        )
        .whenComplete(() {
          _openingHistory = false;
          if (mounted) {
            _clearGuide();
          }
        });
  }

  void _cancelPendingHistoryOpen() {
    _pendingOpenToken++;
  }

  void _openHistoryForDateWithDelay(DateTime targetDate) {
    final int token = ++_pendingOpenToken;
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || token != _pendingOpenToken) {
        return;
      }
      _openHistoryForDate(targetDate);
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<MonthDailyPoint> points = widget.stats.points;
    final bool hasData = points.any(
      (MonthDailyPoint point) => point.totalSeconds > 0,
    );
    final double maxHours = hasData
        ? points.map((MonthDailyPoint point) => point.hours).reduce(max)
        : 0;
    final _AxisScale axisScale = _buildNiceAxisScale(maxHours * 1.12);
    final double chartMaxY = axisScale.maxValue;
    final double axisInterval = axisScale.interval;
    final Color lineColor = Theme.of(context).colorScheme.tertiary;
    final List<FlSpot> rawSpots = points
        .map(
          (MonthDailyPoint point) => FlSpot(point.day.toDouble(), point.hours),
        )
        .toList(growable: false);
    final Map<int, double> rawHoursByDay = <int, double>{
      for (final MonthDailyPoint point in points) point.day: point.hours,
    };
    final List<FlSpot> smoothSpots = _buildMonotoneSplineSpots(
      rawSpots,
      samplesPerSegment: 8,
    );

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('月度专注统计', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: widget.onPreviousMonth,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: widget.onPickMonth,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_formatYearMonth(widget.month)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: widget.onNextMonth,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('该月暂无专注数据'),
            )
          else ...<Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                const double chartHeight = 258;
                const double yAxisWidth = 44;
                const double axisChartGap = 4;
                const double bottomTitlesReservedSize = 30;
                final double chartMinY = -_computeLineChartBottomPaddingHours(
                  chartMaxY: chartMaxY,
                  plotHeight: chartHeight - bottomTitlesReservedSize,
                );
                final double viewportWidth = constraints.maxWidth;
                final double scrollViewportWidth = max(
                  0,
                  viewportWidth - yAxisWidth - axisChartGap,
                );
                final double chartWidth = max(
                  scrollViewportWidth,
                  points.length * 46.0,
                );
                const double lineMinX = 0.8;
                final double lineMaxX = points.length + 0.2;
                final double domainSpan = lineMaxX - lineMinX;
                final double maxScrollOffset = max(
                  0.0,
                  chartWidth - scrollViewportWidth,
                );
                final double effectiveScrollOffset =
                    _lineScrollController.hasClients
                    ? _lineScrollController.offset.clamp(0.0, maxScrollOffset)
                    : _scrollOffset.clamp(0.0, maxScrollOffset);
                if (_lineScrollController.hasClients &&
                    _lineScrollController.offset > maxScrollOffset + 0.5) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || !_lineScrollController.hasClients) {
                      return;
                    }
                    _lineScrollController.jumpTo(maxScrollOffset);
                  });
                }
                final double visibleMinX =
                    lineMinX +
                    (effectiveScrollOffset / chartWidth) * domainSpan;
                final double visibleMaxX =
                    lineMinX +
                    ((effectiveScrollOffset + scrollViewportWidth) /
                            chartWidth) *
                        domainSpan;
                const double dotRadiusPx = 3.7;
                final double dotRadiusX =
                    dotRadiusPx / (chartWidth / domainSpan);
                final TextStyle dateLabelStyle =
                    Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 10) ??
                    const TextStyle(fontSize: 10);
                final TextStyle valueLabelStyle =
                    Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.82),
                    ) ??
                    const TextStyle(fontSize: 9, fontWeight: FontWeight.w600);
                final Color dotFillColor = Theme.of(
                  context,
                ).colorScheme.surface;

                bool isPointVisibleInDomain(double x) {
                  return (x + dotRadiusX) >= visibleMinX &&
                      (x - dotRadiusX) <= visibleMaxX;
                }

                bool isPointFullyVisibleInDomain(double x) {
                  return (x - dotRadiusX) >= visibleMinX &&
                      (x + dotRadiusX) <= visibleMaxX;
                }

                bool canRenderValueLabel(int day, String valueText) {
                  if (valueText.isEmpty) {
                    return false;
                  }
                  final double dayX = day.toDouble();
                  return isPointFullyVisibleInDomain(dayX);
                }

                bool canRenderDayLabel(int day) {
                  final double dayX = day.toDouble();
                  // Date labels follow the same visibility rule as the dot:
                  // hide only when the dot is completely outside viewport.
                  return isPointVisibleInDomain(dayX);
                }

                int? resolveDayFromTouch(
                  FlTouchEvent event,
                  LineTouchResponse? response,
                ) {
                  double? domainX = response?.touchChartCoordinate.dx;
                  if (domainX == null || !domainX.isFinite) {
                    final Offset? localPosition = event.localPosition;
                    if (localPosition == null) {
                      return null;
                    }
                    final double chartX = localPosition.dx.clamp(
                      0.0,
                      chartWidth,
                    );
                    domainX = lineMinX + ((chartX / chartWidth) * domainSpan);
                  }
                  final int day = domainX.round();
                  if (day < 1 || day > points.length) {
                    return null;
                  }
                  if (!isPointVisibleInDomain(day.toDouble())) {
                    return null;
                  }
                  return day;
                }

                final bool showGuide =
                    _guideDay != null &&
                    _guideHours != null &&
                    isPointVisibleInDomain(_guideDay!.toDouble());
                final double guideY = (_guideHours ?? 0).clamp(
                  chartMinY,
                  chartMaxY,
                );

                return SizedBox(
                  height: chartHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(
                        width: yAxisWidth,
                        child: LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: 1,
                            minY: chartMinY,
                            maxY: chartMaxY,
                            gridData: const FlGridData(show: false),
                            borderData: FlBorderData(show: false),
                            lineBarsData: const <LineChartBarData>[],
                            lineTouchData: const LineTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              bottomTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: yAxisWidth - 4,
                                  interval: axisInterval,
                                  getTitlesWidget:
                                      (double value, TitleMeta meta) {
                                        if (value <= 0) {
                                          return const SizedBox.shrink();
                                        }
                                        return Text(
                                          _formatAxisHour(value, axisInterval),
                                          textAlign: TextAlign.right,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        );
                                      },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: axisChartGap),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _lineScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: SizedBox(
                            width: chartWidth,
                            height: chartHeight,
                            child: LineChart(
                              LineChartData(
                                minX: lineMinX,
                                maxX: lineMaxX,
                                minY: chartMinY,
                                maxY: chartMaxY,
                                clipData: const FlClipData(
                                  top: false,
                                  bottom: true,
                                  left: false,
                                  right: false,
                                ),
                                gridData: const FlGridData(show: false),
                                borderData: FlBorderData(show: false),
                                extraLinesData: ExtraLinesData(
                                  extraLinesOnTop: true,
                                  verticalLines: showGuide
                                      ? <VerticalLine>[
                                          VerticalLine(
                                            x: _guideDay!.toDouble(),
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.42),
                                            strokeWidth: 1.1,
                                            dashArray: <int>[5, 4],
                                          ),
                                        ]
                                      : const <VerticalLine>[],
                                  horizontalLines: showGuide
                                      ? <HorizontalLine>[
                                          HorizontalLine(
                                            y: guideY,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.34),
                                            strokeWidth: 1.0,
                                            dashArray: <int>[5, 4],
                                          ),
                                        ]
                                      : const <HorizontalLine>[],
                                ),
                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  rightTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  leftTitles: const AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: false,
                                      reservedSize: 0,
                                    ),
                                  ),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: bottomTitlesReservedSize,
                                      interval: 1,
                                      minIncluded: false,
                                      maxIncluded: false,
                                      getTitlesWidget:
                                          (double value, TitleMeta meta) {
                                            final int day = value.round();
                                            if ((value - day).abs() > 0.001) {
                                              return const SizedBox.shrink();
                                            }
                                            if (day < 1 ||
                                                day > points.length) {
                                              return const SizedBox.shrink();
                                            }
                                            if (!canRenderDayLabel(day)) {
                                              return const SizedBox.shrink();
                                            }
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                '$day日',
                                                style: dateLabelStyle,
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                ),
                                lineTouchData: LineTouchData(
                                  enabled: true,
                                  handleBuiltInTouches: false,
                                  touchSpotThreshold: 18,
                                  touchCallback:
                                      (
                                        FlTouchEvent event,
                                        LineTouchResponse? response,
                                      ) {
                                        if (event is FlLongPressStart ||
                                            event is FlLongPressMoveUpdate) {
                                          _cancelPendingHistoryOpen();
                                          final int? guideDay =
                                              resolveDayFromTouch(
                                                event,
                                                response,
                                              );
                                          if (guideDay == null) {
                                            _clearGuide();
                                          } else {
                                            _setGuide(
                                              guideDay,
                                              rawHoursByDay[guideDay] ?? 0,
                                            );
                                          }
                                          return;
                                        }

                                        if (event is FlLongPressEnd ||
                                            event is FlTapCancelEvent ||
                                            event is FlPanCancelEvent ||
                                            event is FlPanEndEvent ||
                                            event is FlPointerExitEvent) {
                                          _cancelPendingHistoryOpen();
                                          _clearGuide();
                                          return;
                                        }

                                        if (event is! FlTapUpEvent) {
                                          return;
                                        }
                                        final int? targetDay =
                                            resolveDayFromTouch(
                                              event,
                                              response,
                                            );
                                        if (targetDay == null) {
                                          _cancelPendingHistoryOpen();
                                          _clearGuide();
                                          return;
                                        }
                                        _setGuide(
                                          targetDay,
                                          rawHoursByDay[targetDay] ?? 0,
                                        );
                                        final DateTime today = DateTime.now();
                                        final DateTime todayDate = DateTime(
                                          today.year,
                                          today.month,
                                          today.day,
                                        );
                                        final DateTime targetDate = DateTime(
                                          widget.month.year,
                                          widget.month.month,
                                          targetDay,
                                        );
                                        if (targetDate.isAfter(todayDate)) {
                                          _cancelPendingHistoryOpen();
                                          return;
                                        }
                                        _openHistoryForDateWithDelay(
                                          targetDate,
                                        );
                                      },
                                ),
                                lineBarsData: <LineChartBarData>[
                                  LineChartBarData(
                                    isCurved: false,
                                    color: lineColor,
                                    barWidth: 2.8,
                                    isStrokeJoinRound: true,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      applyCutOffY: true,
                                      cutOffY: 0,
                                      color: lineColor.withValues(alpha: 0.12),
                                    ),
                                    spots: smoothSpots,
                                  ),
                                  LineChartBarData(
                                    // Render dots from raw daily points to avoid
                                    // any vertical drift caused by interpolation.
                                    isCurved: false,
                                    color: Colors.transparent,
                                    barWidth: 0,
                                    belowBarData: BarAreaData(show: false),
                                    aboveBarData: BarAreaData(show: false),
                                    dotData: FlDotData(
                                      show: true,
                                      getDotPainter:
                                          (
                                            FlSpot spot,
                                            double percent,
                                            LineChartBarData bar,
                                            int index,
                                          ) {
                                            final int day = spot.x.round();
                                            if ((spot.x - day).abs() > 0.001 ||
                                                day < 1 ||
                                                day > points.length) {
                                              return FlDotCirclePainter(
                                                radius: 0,
                                                color: Colors.transparent,
                                                strokeColor: Colors.transparent,
                                                strokeWidth: 0,
                                              );
                                            }
                                            final String valueText =
                                                '${(rawHoursByDay[day] ?? spot.y).toStringAsFixed(1)}h';
                                            if (!isPointFullyVisibleInDomain(
                                                  day.toDouble(),
                                                ) ||
                                                !canRenderValueLabel(
                                                  day,
                                                  valueText,
                                                )) {
                                              return FlDotCirclePainter(
                                                radius: 0,
                                                color: Colors.transparent,
                                                strokeColor: Colors.transparent,
                                                strokeWidth: 0,
                                              );
                                            }
                                            return _ValueDotPainter(
                                              radius: 2.8,
                                              fillColor: dotFillColor,
                                              strokeWidth: 1.8,
                                              strokeColor: lineColor,
                                              valueText: valueText,
                                              textStyle: valueLabelStyle,
                                            );
                                          },
                                    ),
                                    spots: rawSpots,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  _AxisScale _buildNiceAxisScale(double suggestedMax) {
    final double safeMax = max(0.5, suggestedMax);
    final double range = _niceNumber(safeMax, round: false);
    final double interval = _niceNumber(range / 4, round: true);
    final double maxValue = (safeMax / interval).ceilToDouble() * interval;
    return _AxisScale(maxValue: maxValue, interval: interval);
  }

  double _niceNumber(double value, {required bool round}) {
    if (!value.isFinite || value <= 0) {
      return 1;
    }
    final double exponent = pow(10, (log(value) / ln10).floor()).toDouble();
    final double fraction = value / exponent;
    double niceFraction;
    if (round) {
      if (fraction < 1.5) {
        niceFraction = 1;
      } else if (fraction < 3) {
        niceFraction = 2;
      } else if (fraction < 7) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    } else {
      if (fraction <= 1) {
        niceFraction = 1;
      } else if (fraction <= 2) {
        niceFraction = 2;
      } else if (fraction <= 5) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    }
    return niceFraction * exponent;
  }

  String _formatAxisHour(double value, double interval) {
    final bool oneDecimal =
        interval < 1 || (interval - interval.roundToDouble()).abs() > 0.001;
    final String valueText = oneDecimal
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(0);
    return '${valueText}h';
  }

  List<FlSpot> _buildMonotoneSplineSpots(
    List<FlSpot> input, {
    int samplesPerSegment = 8,
  }) {
    if (input.length <= 2) {
      return input
          .map((FlSpot spot) => FlSpot(spot.x, max(0, spot.y)))
          .toList(growable: false);
    }

    final int n = input.length;
    final List<double> h = List<double>.filled(n - 1, 0);
    final List<double> delta = List<double>.filled(n - 1, 0);
    for (int i = 0; i < n - 1; i++) {
      final double dx = input[i + 1].x - input[i].x;
      if (dx <= 0) {
        return input
            .map((FlSpot spot) => FlSpot(spot.x, max(0, spot.y)))
            .toList(growable: false);
      }
      h[i] = dx;
      delta[i] = (input[i + 1].y - input[i].y) / dx;
    }

    final List<double> m = List<double>.filled(n, 0);
    m[0] = delta[0];
    for (int i = 1; i < n - 1; i++) {
      final double prev = delta[i - 1];
      final double next = delta[i];
      if (prev == 0 || next == 0 || prev.sign != next.sign) {
        m[i] = 0;
      } else {
        m[i] = (prev + next) / 2;
      }
    }
    m[n - 1] = delta[n - 2];

    for (int i = 0; i < n - 1; i++) {
      if (delta[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      final double a = m[i] / delta[i];
      final double b = m[i + 1] / delta[i];
      final double s = (a * a) + (b * b);
      if (s > 9) {
        final double t = 3 / sqrt(s);
        m[i] = t * a * delta[i];
        m[i + 1] = t * b * delta[i];
      }
    }

    final int samples = max(2, samplesPerSegment);
    final List<FlSpot> output = <FlSpot>[];
    for (int i = 0; i < n - 1; i++) {
      final FlSpot p0 = input[i];
      final FlSpot p1 = input[i + 1];
      final double dx = h[i];
      if (i == 0) {
        output.add(FlSpot(p0.x, max(0, p0.y)));
      }
      for (int step = 1; step <= samples; step++) {
        final bool isSegmentEnd = step == samples;
        final double t = isSegmentEnd ? 1.0 : (step / samples);
        final double t2 = t * t;
        final double t3 = t2 * t;
        final double h00 = (2 * t3) - (3 * t2) + 1;
        final double h10 = t3 - (2 * t2) + t;
        final double h01 = (-2 * t3) + (3 * t2);
        final double h11 = t3 - t2;
        final double x = isSegmentEnd ? p1.x : (p0.x + (dx * t));
        double y =
            (h00 * p0.y) +
            (h10 * dx * m[i]) +
            (h01 * p1.y) +
            (h11 * dx * m[i + 1]);
        if (!y.isFinite) {
          y = p0.y + ((p1.y - p0.y) * t);
        }
        if (isSegmentEnd) {
          y = p1.y;
        }
        if (y < 0) {
          y = 0;
        }
        output.add(FlSpot(x, y));
      }
    }
    return output;
  }

  String _formatYearMonth(DateTime date) {
    final String monthText = date.month.toString().padLeft(2, '0');
    return '${date.year}-$monthText';
  }
}

class _YearlyLineCard extends StatefulWidget {
  const _YearlyLineCard({
    required this.year,
    required this.stats,
    required this.onPreviousYear,
    required this.onNextYear,
    required this.onPickYear,
  });

  final DateTime year;
  final YearMonthlyStats stats;
  final VoidCallback? onPreviousYear;
  final VoidCallback? onNextYear;
  final VoidCallback onPickYear;

  @override
  State<_YearlyLineCard> createState() => _YearlyLineCardState();
}

class _YearlyLineCardState extends State<_YearlyLineCard> {
  late final ScrollController _lineScrollController;
  double _scrollOffset = 0;
  int? _guideMonth;
  double? _guideHours;
  bool _openingHistory = false;
  int _pendingOpenToken = 0;

  @override
  void initState() {
    super.initState();
    _lineScrollController = ScrollController()..addListener(_handleScroll);
  }

  @override
  void dispose() {
    _lineScrollController
      ..removeListener(_handleScroll)
      ..dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _YearlyLineCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool yearChanged = oldWidget.year.year != widget.year.year;
    if (!yearChanged) {
      return;
    }
    _cancelPendingHistoryOpen();
    if (_lineScrollController.hasClients) {
      _lineScrollController.jumpTo(0);
    }
    if (_scrollOffset == 0 && _guideMonth == null && _guideHours == null) {
      return;
    }
    setState(() {
      _scrollOffset = 0;
      _guideMonth = null;
      _guideHours = null;
    });
  }

  void _handleScroll() {
    final double next = _lineScrollController.offset;
    if ((next - _scrollOffset).abs() < 0.5) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _scrollOffset = next;
    });
  }

  void _setGuide(int month, double hours) {
    final double normalizedHours = max(0, hours);
    if (_guideMonth == month &&
        _guideHours != null &&
        (_guideHours! - normalizedHours).abs() < 0.0001) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _guideMonth = month;
      _guideHours = normalizedHours;
    });
  }

  void _clearGuide() {
    if (_guideMonth == null && _guideHours == null) {
      return;
    }
    if (!mounted) {
      return;
    }
    setState(() {
      _guideMonth = null;
      _guideHours = null;
    });
  }

  void _openHistoryForDate(DateTime targetDate) {
    if (_openingHistory || !mounted) {
      return;
    }
    _openingHistory = true;
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => HistoryScreen(initialDate: targetDate),
          ),
        )
        .whenComplete(() {
          _openingHistory = false;
          if (mounted) {
            _clearGuide();
          }
        });
  }

  void _cancelPendingHistoryOpen() {
    _pendingOpenToken++;
  }

  void _openHistoryForDateWithDelay(DateTime targetDate) {
    final int token = ++_pendingOpenToken;
    Future<void>.delayed(const Duration(milliseconds: 100), () {
      if (!mounted || token != _pendingOpenToken) {
        return;
      }
      _openHistoryForDate(targetDate);
    });
  }

  @override
  Widget build(BuildContext context) {
    final List<YearMonthlyPoint> points = widget.stats.points;
    final bool hasData = points.any(
      (YearMonthlyPoint point) => point.totalSeconds > 0,
    );
    final double maxHours = hasData
        ? points.map((YearMonthlyPoint point) => point.hours).reduce(max)
        : 0;
    final _AxisScale axisScale = _buildNiceAxisScale(maxHours * 1.12);
    final double chartMaxY = axisScale.maxValue;
    final double axisInterval = axisScale.interval;
    final Color lineColor = Theme.of(context).colorScheme.tertiary;
    final List<FlSpot> rawSpots = points
        .map(
          (YearMonthlyPoint point) =>
              FlSpot(point.month.toDouble(), point.hours),
        )
        .toList(growable: false);
    final Map<int, double> rawHoursByMonth = <int, double>{
      for (final YearMonthlyPoint point in points) point.month: point.hours,
    };
    final List<FlSpot> smoothSpots = _buildMonotoneSplineSpots(
      rawSpots,
      samplesPerSegment: 8,
    );

    return _SectionCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Text('年度专注统计', style: Theme.of(context).textTheme.titleMedium),
              const Spacer(),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: widget.onPreviousYear,
                    icon: const Icon(Icons.chevron_left),
                  ),
                  TextButton(
                    onPressed: widget.onPickYear,
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 34),
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_formatYear(widget.year)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                      minWidth: 34,
                      minHeight: 34,
                    ),
                    onPressed: widget.onNextYear,
                    icon: const Icon(Icons.chevron_right),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (!hasData)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 20),
              child: Text('该年暂无专注数据'),
            )
          else ...<Widget>[
            LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                const double chartHeight = 258;
                const double yAxisWidth = 44;
                const double axisChartGap = 4;
                const double bottomTitlesReservedSize = 30;
                const double lineMinX = 0.8;
                const double lineMaxX = 12.2;
                final double chartMinY = -_computeLineChartBottomPaddingHours(
                  chartMaxY: chartMaxY,
                  plotHeight: chartHeight - bottomTitlesReservedSize,
                );
                final double viewportWidth = constraints.maxWidth;
                final double scrollViewportWidth = max(
                  0,
                  viewportWidth - yAxisWidth - axisChartGap,
                );
                final double chartWidth = max(
                  scrollViewportWidth,
                  points.length * 54.0,
                );
                final double domainSpan = lineMaxX - lineMinX;
                final double maxScrollOffset = max(
                  0.0,
                  chartWidth - scrollViewportWidth,
                );
                final double effectiveScrollOffset =
                    _lineScrollController.hasClients
                    ? _lineScrollController.offset.clamp(0.0, maxScrollOffset)
                    : _scrollOffset.clamp(0.0, maxScrollOffset);
                if (_lineScrollController.hasClients &&
                    _lineScrollController.offset > maxScrollOffset + 0.5) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || !_lineScrollController.hasClients) {
                      return;
                    }
                    _lineScrollController.jumpTo(maxScrollOffset);
                  });
                }
                final double visibleMinX =
                    lineMinX +
                    (effectiveScrollOffset / chartWidth) * domainSpan;
                final double visibleMaxX =
                    lineMinX +
                    ((effectiveScrollOffset + scrollViewportWidth) /
                            chartWidth) *
                        domainSpan;
                const double dotRadiusPx = 3.7;
                final double dotRadiusX =
                    dotRadiusPx / (chartWidth / domainSpan);
                final TextStyle dateLabelStyle =
                    Theme.of(
                      context,
                    ).textTheme.bodySmall?.copyWith(fontSize: 10) ??
                    const TextStyle(fontSize: 10);
                final TextStyle valueLabelStyle =
                    Theme.of(context).textTheme.labelSmall?.copyWith(
                      fontSize: 9,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(
                        context,
                      ).colorScheme.onSurface.withValues(alpha: 0.82),
                    ) ??
                    const TextStyle(fontSize: 9, fontWeight: FontWeight.w600);
                final Color dotFillColor = Theme.of(
                  context,
                ).colorScheme.surface;

                bool isPointVisibleInDomain(double x) {
                  return (x + dotRadiusX) >= visibleMinX &&
                      (x - dotRadiusX) <= visibleMaxX;
                }

                bool isPointFullyVisibleInDomain(double x) {
                  return (x - dotRadiusX) >= visibleMinX &&
                      (x + dotRadiusX) <= visibleMaxX;
                }

                int? resolveMonthFromTouch(
                  FlTouchEvent event,
                  LineTouchResponse? response,
                ) {
                  double? domainX = response?.touchChartCoordinate.dx;
                  if (domainX == null || !domainX.isFinite) {
                    final Offset? localPosition = event.localPosition;
                    if (localPosition == null || chartWidth <= 0) {
                      return null;
                    }
                    final double chartX = localPosition.dx.clamp(
                      0.0,
                      chartWidth,
                    );
                    domainX =
                        lineMinX +
                        ((chartX / chartWidth) * (lineMaxX - lineMinX));
                  }
                  final int month = domainX.round();
                  if (month < 1 || month > 12) {
                    return null;
                  }
                  if (!isPointVisibleInDomain(month.toDouble())) {
                    return null;
                  }
                  return month;
                }

                final bool showGuide =
                    _guideMonth != null &&
                    _guideHours != null &&
                    _guideMonth! >= 1 &&
                    _guideMonth! <= 12;
                final double guideY = (_guideHours ?? 0).clamp(
                  chartMinY,
                  chartMaxY,
                );

                return SizedBox(
                  height: chartHeight,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[
                      SizedBox(
                        width: yAxisWidth,
                        child: LineChart(
                          LineChartData(
                            minX: 0,
                            maxX: 1,
                            minY: chartMinY,
                            maxY: chartMaxY,
                            gridData: const FlGridData(show: false),
                            borderData: FlBorderData(show: false),
                            lineBarsData: const <LineChartBarData>[],
                            lineTouchData: const LineTouchData(enabled: false),
                            titlesData: FlTitlesData(
                              topTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              rightTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              bottomTitles: const AxisTitles(
                                sideTitles: SideTitles(showTitles: false),
                              ),
                              leftTitles: AxisTitles(
                                sideTitles: SideTitles(
                                  showTitles: true,
                                  reservedSize: yAxisWidth - 4,
                                  interval: axisInterval,
                                  getTitlesWidget:
                                      (double value, TitleMeta meta) {
                                        if (value <= 0) {
                                          return const SizedBox.shrink();
                                        }
                                        return Text(
                                          _formatAxisHour(value, axisInterval),
                                          textAlign: TextAlign.right,
                                          style: Theme.of(
                                            context,
                                          ).textTheme.bodySmall,
                                        );
                                      },
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: axisChartGap),
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _lineScrollController,
                          scrollDirection: Axis.horizontal,
                          physics: const BouncingScrollPhysics(),
                          child: SizedBox(
                            width: chartWidth,
                            height: chartHeight,
                            child: LineChart(
                              LineChartData(
                                minX: lineMinX,
                                maxX: lineMaxX,
                                minY: chartMinY,
                                maxY: chartMaxY,
                                clipData: const FlClipData(
                                  top: false,
                                  bottom: true,
                                  left: false,
                                  right: false,
                                ),
                                gridData: const FlGridData(show: false),
                                borderData: FlBorderData(show: false),
                                extraLinesData: ExtraLinesData(
                                  extraLinesOnTop: true,
                                  verticalLines: showGuide
                                      ? <VerticalLine>[
                                          VerticalLine(
                                            x: _guideMonth!.toDouble(),
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.42),
                                            strokeWidth: 1.1,
                                            dashArray: <int>[5, 4],
                                          ),
                                        ]
                                      : const <VerticalLine>[],
                                  horizontalLines: showGuide
                                      ? <HorizontalLine>[
                                          HorizontalLine(
                                            y: guideY,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary
                                                .withValues(alpha: 0.34),
                                            strokeWidth: 1.0,
                                            dashArray: <int>[5, 4],
                                          ),
                                        ]
                                      : const <HorizontalLine>[],
                                ),
                                titlesData: FlTitlesData(
                                  topTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  rightTitles: const AxisTitles(
                                    sideTitles: SideTitles(showTitles: false),
                                  ),
                                  leftTitles: const AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: false,
                                      reservedSize: 0,
                                    ),
                                  ),
                                  bottomTitles: AxisTitles(
                                    sideTitles: SideTitles(
                                      showTitles: true,
                                      reservedSize: bottomTitlesReservedSize,
                                      interval: 1,
                                      minIncluded: false,
                                      maxIncluded: false,
                                      getTitlesWidget:
                                          (double value, TitleMeta meta) {
                                            final int month = value.round();
                                            if ((value - month).abs() > 0.001) {
                                              return const SizedBox.shrink();
                                            }
                                            if (month < 1 || month > 12) {
                                              return const SizedBox.shrink();
                                            }
                                            if (!isPointVisibleInDomain(
                                              month.toDouble(),
                                            )) {
                                              return const SizedBox.shrink();
                                            }
                                            return Padding(
                                              padding: const EdgeInsets.only(
                                                top: 4,
                                              ),
                                              child: Text(
                                                '$month月',
                                                style: dateLabelStyle,
                                              ),
                                            );
                                          },
                                    ),
                                  ),
                                ),
                                lineTouchData: LineTouchData(
                                  enabled: true,
                                  handleBuiltInTouches: false,
                                  touchSpotThreshold: 18,
                                  touchCallback:
                                      (
                                        FlTouchEvent event,
                                        LineTouchResponse? response,
                                      ) {
                                        if (event is FlLongPressStart ||
                                            event is FlLongPressMoveUpdate) {
                                          _cancelPendingHistoryOpen();
                                          final int? guideMonth =
                                              resolveMonthFromTouch(
                                                event,
                                                response,
                                              );
                                          if (guideMonth == null) {
                                            _clearGuide();
                                          } else {
                                            _setGuide(
                                              guideMonth,
                                              rawHoursByMonth[guideMonth] ?? 0,
                                            );
                                          }
                                          return;
                                        }

                                        if (event is FlLongPressEnd ||
                                            event is FlTapCancelEvent ||
                                            event is FlPanCancelEvent ||
                                            event is FlPanEndEvent ||
                                            event is FlPointerExitEvent) {
                                          _cancelPendingHistoryOpen();
                                          _clearGuide();
                                          return;
                                        }

                                        if (event is! FlTapUpEvent) {
                                          return;
                                        }
                                        final int? targetMonth =
                                            resolveMonthFromTouch(
                                              event,
                                              response,
                                            );
                                        if (targetMonth == null) {
                                          _cancelPendingHistoryOpen();
                                          _clearGuide();
                                          return;
                                        }
                                        _setGuide(
                                          targetMonth,
                                          rawHoursByMonth[targetMonth] ?? 0,
                                        );
                                        final DateTime today = DateTime.now();
                                        final DateTime todayDate = DateTime(
                                          today.year,
                                          today.month,
                                          today.day,
                                        );
                                        final DateTime targetDate = DateTime(
                                          widget.year.year,
                                          targetMonth,
                                          1,
                                        );
                                        if (targetDate.isAfter(todayDate)) {
                                          _cancelPendingHistoryOpen();
                                          return;
                                        }
                                        _openHistoryForDateWithDelay(
                                          targetDate,
                                        );
                                      },
                                ),
                                lineBarsData: <LineChartBarData>[
                                  LineChartBarData(
                                    isCurved: false,
                                    color: lineColor,
                                    barWidth: 2.8,
                                    isStrokeJoinRound: true,
                                    dotData: const FlDotData(show: false),
                                    belowBarData: BarAreaData(
                                      show: true,
                                      applyCutOffY: true,
                                      cutOffY: 0,
                                      color: lineColor.withValues(alpha: 0.12),
                                    ),
                                    spots: smoothSpots,
                                  ),
                                  LineChartBarData(
                                    isCurved: false,
                                    color: Colors.transparent,
                                    barWidth: 0,
                                    belowBarData: BarAreaData(show: false),
                                    aboveBarData: BarAreaData(show: false),
                                    dotData: FlDotData(
                                      show: true,
                                      getDotPainter:
                                          (
                                            FlSpot spot,
                                            double percent,
                                            LineChartBarData bar,
                                            int index,
                                          ) {
                                            final int month = spot.x.round();
                                            if ((spot.x - month).abs() >
                                                    0.001 ||
                                                month < 1 ||
                                                month > 12) {
                                              return FlDotCirclePainter(
                                                radius: 0,
                                                color: Colors.transparent,
                                                strokeColor: Colors.transparent,
                                                strokeWidth: 0,
                                              );
                                            }
                                            final String valueText =
                                                '${(rawHoursByMonth[month] ?? spot.y).toStringAsFixed(1)}h';
                                            if (!isPointFullyVisibleInDomain(
                                              month.toDouble(),
                                            )) {
                                              return FlDotCirclePainter(
                                                radius: 2.8,
                                                color: dotFillColor,
                                                strokeColor: lineColor,
                                                strokeWidth: 1.8,
                                              );
                                            }
                                            return _ValueDotPainter(
                                              radius: 2.8,
                                              fillColor: dotFillColor,
                                              strokeWidth: 1.8,
                                              strokeColor: lineColor,
                                              valueText: valueText,
                                              textStyle: valueLabelStyle,
                                            );
                                          },
                                    ),
                                    spots: rawSpots,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                );
              },
            ),
          ],
        ],
      ),
    );
  }

  _AxisScale _buildNiceAxisScale(double suggestedMax) {
    final double safeMax = max(0.5, suggestedMax);
    final double range = _niceNumber(safeMax, round: false);
    final double interval = _niceNumber(range / 4, round: true);
    final double maxValue = (safeMax / interval).ceilToDouble() * interval;
    return _AxisScale(maxValue: maxValue, interval: interval);
  }

  double _niceNumber(double value, {required bool round}) {
    if (!value.isFinite || value <= 0) {
      return 1;
    }
    final double exponent = pow(10, (log(value) / ln10).floor()).toDouble();
    final double fraction = value / exponent;
    double niceFraction;
    if (round) {
      if (fraction < 1.5) {
        niceFraction = 1;
      } else if (fraction < 3) {
        niceFraction = 2;
      } else if (fraction < 7) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    } else {
      if (fraction <= 1) {
        niceFraction = 1;
      } else if (fraction <= 2) {
        niceFraction = 2;
      } else if (fraction <= 5) {
        niceFraction = 5;
      } else {
        niceFraction = 10;
      }
    }
    return niceFraction * exponent;
  }

  String _formatAxisHour(double value, double interval) {
    final bool oneDecimal =
        interval < 1 || (interval - interval.roundToDouble()).abs() > 0.001;
    final String valueText = oneDecimal
        ? value.toStringAsFixed(1)
        : value.toStringAsFixed(0);
    return '${valueText}h';
  }

  List<FlSpot> _buildMonotoneSplineSpots(
    List<FlSpot> input, {
    int samplesPerSegment = 8,
  }) {
    if (input.length <= 2) {
      return input
          .map((FlSpot spot) => FlSpot(spot.x, max(0, spot.y)))
          .toList(growable: false);
    }

    final int n = input.length;
    final List<double> h = List<double>.filled(n - 1, 0);
    final List<double> delta = List<double>.filled(n - 1, 0);
    for (int i = 0; i < n - 1; i++) {
      final double dx = input[i + 1].x - input[i].x;
      if (dx <= 0) {
        return input
            .map((FlSpot spot) => FlSpot(spot.x, max(0, spot.y)))
            .toList(growable: false);
      }
      h[i] = dx;
      delta[i] = (input[i + 1].y - input[i].y) / dx;
    }

    final List<double> m = List<double>.filled(n, 0);
    m[0] = delta[0];
    for (int i = 1; i < n - 1; i++) {
      final double prev = delta[i - 1];
      final double next = delta[i];
      if (prev == 0 || next == 0 || prev.sign != next.sign) {
        m[i] = 0;
      } else {
        m[i] = (prev + next) / 2;
      }
    }
    m[n - 1] = delta[n - 2];

    for (int i = 0; i < n - 1; i++) {
      if (delta[i] == 0) {
        m[i] = 0;
        m[i + 1] = 0;
        continue;
      }
      final double a = m[i] / delta[i];
      final double b = m[i + 1] / delta[i];
      final double s = (a * a) + (b * b);
      if (s > 9) {
        final double t = 3 / sqrt(s);
        m[i] = t * a * delta[i];
        m[i + 1] = t * b * delta[i];
      }
    }

    final int samples = max(2, samplesPerSegment);
    final List<FlSpot> output = <FlSpot>[];
    for (int i = 0; i < n - 1; i++) {
      final FlSpot p0 = input[i];
      final FlSpot p1 = input[i + 1];
      final double dx = h[i];
      if (i == 0) {
        output.add(FlSpot(p0.x, max(0, p0.y)));
      }
      for (int step = 1; step <= samples; step++) {
        final bool isSegmentEnd = step == samples;
        final double t = isSegmentEnd ? 1.0 : (step / samples);
        final double t2 = t * t;
        final double t3 = t2 * t;
        final double h00 = (2 * t3) - (3 * t2) + 1;
        final double h10 = t3 - (2 * t2) + t;
        final double h01 = (-2 * t3) + (3 * t2);
        final double h11 = t3 - t2;
        final double x = isSegmentEnd ? p1.x : (p0.x + (dx * t));
        double y =
            (h00 * p0.y) +
            (h10 * dx * m[i]) +
            (h01 * p1.y) +
            (h11 * dx * m[i + 1]);
        if (!y.isFinite) {
          y = p0.y + ((p1.y - p0.y) * t);
        }
        if (isSegmentEnd) {
          y = p1.y;
        }
        if (y < 0) {
          y = 0;
        }
        output.add(FlSpot(x, y));
      }
    }
    return output;
  }

  String _formatYear(DateTime date) => '${date.year}';
}

class _AxisScale {
  const _AxisScale({required this.maxValue, required this.interval});

  final double maxValue;
  final double interval;
}

double _computeLineChartBottomPaddingHours({
  required double chartMaxY,
  required double plotHeight,
}) {
  const double desiredBottomPaddingPx = 10;
  final double safeMaxY = max(0.0, chartMaxY);
  final double safePlotHeight = max(1.0, plotHeight);
  if (safeMaxY == 0 || safePlotHeight <= desiredBottomPaddingPx + 1) {
    return 0;
  }

  // Convert a fixed visual gap near the x-axis into chart-domain units so
  // tiny values (e.g. a single 1 min record) don't get lifted too far up.
  final double paddingHours =
      safeMaxY *
      desiredBottomPaddingPx /
      (safePlotHeight - desiredBottomPaddingPx);
  return max(0.008, paddingHours);
}

class _ValueDotPainter extends FlDotPainter {
  const _ValueDotPainter({
    required this.radius,
    required this.fillColor,
    required this.strokeColor,
    required this.strokeWidth,
    required this.valueText,
    required this.textStyle,
    this.textGap = 4,
  });

  final double radius;
  final Color fillColor;
  final Color strokeColor;
  final double strokeWidth;
  final String valueText;
  final TextStyle textStyle;
  final double textGap;

  @override
  void draw(Canvas canvas, FlSpot spot, Offset offsetInCanvas) {
    final Rect clip = canvas.getLocalClipBounds();
    final Rect dotBounds = Rect.fromCircle(
      center: offsetInCanvas,
      radius: radius + (strokeWidth / 2),
    );
    final bool dotFullyHidden =
        dotBounds.right <= clip.left ||
        dotBounds.left >= clip.right ||
        dotBounds.bottom <= clip.top ||
        dotBounds.top >= clip.bottom;
    if (dotFullyHidden) {
      return;
    }

    if (strokeWidth > 0 && strokeColor.a > 0) {
      canvas.drawCircle(
        offsetInCanvas,
        radius + (strokeWidth / 2),
        Paint()
          ..color = strokeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = strokeWidth,
      );
    }
    canvas.drawCircle(
      offsetInCanvas,
      radius,
      Paint()
        ..color = fillColor
        ..style = PaintingStyle.fill,
    );

    final TextPainter painter = TextPainter(
      text: TextSpan(text: valueText, style: textStyle),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textAlign: TextAlign.center,
    )..layout();
    final Offset desiredTextOffset = Offset(
      offsetInCanvas.dx - (painter.width / 2),
      offsetInCanvas.dy - radius - textGap - painter.height,
    );
    final double minX = clip.left + 1;
    final double maxX = clip.right - painter.width - 1;
    final double clampedX = max(minX, min(maxX, desiredTextOffset.dx));
    final double clampedY = max(clip.top + 1, desiredTextOffset.dy);
    painter.paint(canvas, Offset(clampedX, clampedY));
  }

  @override
  Size getSize(FlSpot spot) => Size.fromRadius(radius + strokeWidth + 2);

  @override
  Color get mainColor => fillColor;

  @override
  FlDotPainter lerp(FlDotPainter a, FlDotPainter b, double t) {
    if (a is _ValueDotPainter && b is _ValueDotPainter) {
      return _ValueDotPainter(
        radius: ui.lerpDouble(a.radius, b.radius, t) ?? b.radius,
        fillColor: Color.lerp(a.fillColor, b.fillColor, t) ?? b.fillColor,
        strokeColor:
            Color.lerp(a.strokeColor, b.strokeColor, t) ?? b.strokeColor,
        strokeWidth:
            ui.lerpDouble(a.strokeWidth, b.strokeWidth, t) ?? b.strokeWidth,
        valueText: t < 0.5 ? a.valueText : b.valueText,
        textStyle: TextStyle.lerp(a.textStyle, b.textStyle, t) ?? b.textStyle,
        textGap: ui.lerpDouble(a.textGap, b.textGap, t) ?? b.textGap,
      );
    }
    return b;
  }

  @override
  List<Object?> get props => <Object?>[
    radius,
    fillColor,
    strokeColor,
    strokeWidth,
    valueText,
    textStyle,
    textGap,
  ];
}

class _CustomRangeLabel extends StatelessWidget {
  const _CustomRangeLabel({
    required this.animated,
    required this.selected,
    required this.compact,
    required this.ultraCompact,
  });

  final bool animated;
  final bool selected;
  final bool compact;
  final bool ultraCompact;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;

    return AnimatedScale(
      scale: animated ? 1.08 : 1.0,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOutBack,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(ultraCompact ? '自定' : '自定义'),
          if (!compact) ...<Widget>[
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: animated ? 0.05 : 0,
              duration: const Duration(milliseconds: 220),
              child: Icon(
                Icons.auto_awesome,
                size: 13,
                color: selected
                    ? scheme.primary
                    : scheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _SingleDatePickerDialog extends StatefulWidget {
  const _SingleDatePickerDialog({
    required this.title,
    required this.sectionTitle,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final String title;
  final String sectionTitle;
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_SingleDatePickerDialog> createState() =>
      _SingleDatePickerDialogState();
}

class _SingleDatePickerDialogState extends State<_SingleDatePickerDialog> {
  late DateTime _selectedDate = _clampDate(
    DateTime(
      widget.initialDate.year,
      widget.initialDate.month,
      widget.initialDate.day,
    ),
  );

  DateTime _clampDate(DateTime value) {
    if (value.isBefore(widget.firstDate)) {
      return widget.firstDate;
    }
    if (value.isAfter(widget.lastDate)) {
      return widget.lastDate;
    }
    return value;
  }

  void _onChanged(DateTime value) {
    setState(() {
      _selectedDate = _clampDate(DateTime(value.year, value.month, value.day));
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size size = MediaQuery.sizeOf(context);
    final double dialogWidth = min(460.0, size.width - 20);
    final double dialogMaxHeight = min(520.0, size.height * 0.86);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogMaxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 6, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.6),
                  const Color(0xFF6F6D89),
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(26),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '确认',
                    onPressed: () => Navigator.of(context).pop(_selectedDate),
                    icon: const Icon(Icons.check_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                child: _DateWheelSection(
                  title: widget.sectionTitle,
                  value: _selectedDate,
                  minDate: widget.firstDate,
                  maxDate: widget.lastDate,
                  onChanged: _onChanged,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MonthPickerDialog extends StatefulWidget {
  const _MonthPickerDialog({
    required this.title,
    required this.initialDate,
    required this.firstDate,
    required this.lastDate,
  });

  final String title;
  final DateTime initialDate;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_MonthPickerDialog> createState() => _MonthPickerDialogState();
}

class _MonthPickerDialogState extends State<_MonthPickerDialog> {
  late DateTime _selectedMonth = _clampMonth(widget.initialDate);

  DateTime _monthOnly(DateTime value) => DateTime(value.year, value.month, 1);

  DateTime _clampMonth(DateTime value) {
    final DateTime minMonth = _monthOnly(widget.firstDate);
    final DateTime maxMonth = _monthOnly(widget.lastDate);
    DateTime normalized = _monthOnly(value);
    if (normalized.isBefore(minMonth)) {
      normalized = minMonth;
    }
    if (normalized.isAfter(maxMonth)) {
      normalized = maxMonth;
    }
    return normalized;
  }

  void _onChanged(DateTime value) {
    setState(() {
      _selectedMonth = _clampMonth(value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size size = MediaQuery.sizeOf(context);
    final double dialogWidth = min(460.0, size.width - 20);
    final double dialogMaxHeight = min(460.0, size.height * 0.82);
    final TextStyle pickerTextStyle =
        Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500) ??
        const TextStyle(fontSize: 30, fontWeight: FontWeight.w500);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogMaxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 6, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.6),
                  const Color(0xFF6F6D89),
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(26),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '确认',
                    onPressed: () => Navigator.of(context).pop(_selectedMonth),
                    icon: const Icon(Icons.check_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '请选择月份：',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: ColoredBox(
                        color: Color.alphaBlend(
                          scheme.onSurface.withValues(alpha: 0.04),
                          scheme.surfaceContainerLow,
                        ),
                        child: SizedBox(
                          height: 210,
                          child: CupertinoTheme(
                            data: CupertinoTheme.of(context).copyWith(
                              textTheme: CupertinoTextThemeData(
                                dateTimePickerTextStyle: pickerTextStyle,
                              ),
                            ),
                            child: CupertinoDatePicker(
                              mode: CupertinoDatePickerMode.monthYear,
                              minimumDate: widget.firstDate,
                              maximumDate: widget.lastDate,
                              initialDateTime: _selectedMonth,
                              use24hFormat: true,
                              onDateTimeChanged: _onChanged,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _YearPickerDialog extends StatefulWidget {
  const _YearPickerDialog({
    required this.title,
    required this.initialYear,
    required this.minYear,
    required this.maxYear,
  });

  final String title;
  final int initialYear;
  final int minYear;
  final int maxYear;

  @override
  State<_YearPickerDialog> createState() => _YearPickerDialogState();
}

class _YearPickerDialogState extends State<_YearPickerDialog> {
  late final List<int> _years = List<int>.generate(
    widget.maxYear - widget.minYear + 1,
    (int index) => widget.minYear + index,
    growable: false,
  );
  late int _selectedYear = widget.initialYear.clamp(
    widget.minYear,
    widget.maxYear,
  );
  late final FixedExtentScrollController _yearController =
      FixedExtentScrollController(
        initialItem: _years.indexOf(_selectedYear).clamp(0, _years.length - 1),
      );

  @override
  void dispose() {
    _yearController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size size = MediaQuery.sizeOf(context);
    final double dialogWidth = min(460.0, size.width - 20);
    final double dialogMaxHeight = min(420.0, size.height * 0.78);
    final TextStyle pickerTextStyle =
        Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500) ??
        const TextStyle(fontSize: 30, fontWeight: FontWeight.w500);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogMaxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 6, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.6),
                  const Color(0xFF6F6D89),
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(26),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      widget.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '确认',
                    onPressed: () => Navigator.of(context).pop(_selectedYear),
                    icon: const Icon(Icons.check_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      '请选择年份：',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 8),
                    ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: ColoredBox(
                        color: Color.alphaBlend(
                          scheme.onSurface.withValues(alpha: 0.04),
                          scheme.surfaceContainerLow,
                        ),
                        child: SizedBox(
                          height: 210,
                          child: CupertinoTheme(
                            data: CupertinoTheme.of(context).copyWith(
                              textTheme: CupertinoTextThemeData(
                                pickerTextStyle: pickerTextStyle,
                              ),
                            ),
                            child: CupertinoPicker(
                              scrollController: _yearController,
                              itemExtent: 40,
                              useMagnifier: true,
                              magnification: 1.06,
                              onSelectedItemChanged: (int index) {
                                setState(() {
                                  _selectedYear = _years[index];
                                });
                              },
                              children: _years
                                  .map(
                                    (int year) => Center(child: Text('$year')),
                                  )
                                  .toList(growable: false),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CustomRangePickerDialog extends StatefulWidget {
  const _CustomRangePickerDialog({
    required this.initialRange,
    required this.firstDate,
    required this.lastDate,
  });

  final DateTimeRange initialRange;
  final DateTime firstDate;
  final DateTime lastDate;

  @override
  State<_CustomRangePickerDialog> createState() =>
      _CustomRangePickerDialogState();
}

class _CustomRangePickerDialogState extends State<_CustomRangePickerDialog> {
  late DateTime _startDate = _dateOnly(widget.initialRange.start);
  late DateTime _endDate = _dateOnly(widget.initialRange.end);

  static DateTime _dateOnly(DateTime value) {
    return DateTime(value.year, value.month, value.day);
  }

  DateTime _clampDate(DateTime value) {
    if (value.isBefore(widget.firstDate)) {
      return widget.firstDate;
    }
    if (value.isAfter(widget.lastDate)) {
      return widget.lastDate;
    }
    return value;
  }

  void _handleStartChanged(DateTime value) {
    final DateTime start = _clampDate(_dateOnly(value));
    setState(() {
      _startDate = start;
      if (_startDate.isAfter(_endDate)) {
        _endDate = _startDate;
      }
    });
  }

  void _handleEndChanged(DateTime value) {
    final DateTime end = _clampDate(_dateOnly(value));
    setState(() {
      _endDate = end;
      if (_endDate.isBefore(_startDate)) {
        _startDate = _endDate;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Size size = MediaQuery.sizeOf(context);
    final double dialogWidth = min(460.0, size.width - 20);
    final double dialogMaxHeight = min(760.0, size.height * 0.9);

    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(26)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: dialogWidth,
          maxHeight: dialogMaxHeight,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              padding: const EdgeInsets.fromLTRB(18, 10, 6, 10),
              decoration: BoxDecoration(
                color: Color.alphaBlend(
                  scheme.primary.withValues(alpha: 0.6),
                  const Color(0xFF6F6D89),
                ),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(26),
                ),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      '选择开始日期和结束日期',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: Colors.white,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '确认',
                    onPressed: () {
                      Navigator.of(
                        context,
                      ).pop(DateTimeRange(start: _startDate, end: _endDate));
                    },
                    icon: const Icon(Icons.check_rounded, color: Colors.white),
                  ),
                  IconButton(
                    tooltip: '取消',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded, color: Colors.white),
                  ),
                ],
              ),
            ),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(14, 14, 14, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    _DateWheelSection(
                      title: '请选择开始日期：',
                      value: _startDate,
                      minDate: widget.firstDate,
                      maxDate: _endDate,
                      onChanged: _handleStartChanged,
                    ),
                    const SizedBox(height: 14),
                    _DateWheelSection(
                      title: '请选择结束日期：',
                      value: _endDate,
                      minDate: _startDate,
                      maxDate: widget.lastDate,
                      onChanged: _handleEndChanged,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DateWheelSection extends StatelessWidget {
  const _DateWheelSection({
    required this.title,
    required this.value,
    required this.minDate,
    required this.maxDate,
    required this.onChanged,
  });

  final String title;
  final DateTime value;
  final DateTime minDate;
  final DateTime maxDate;
  final ValueChanged<DateTime> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle pickerTextStyle =
        Theme.of(
          context,
        ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w500) ??
        const TextStyle(fontSize: 30, fontWeight: FontWeight.w500);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: ColoredBox(
            color: Color.alphaBlend(
              scheme.onSurface.withValues(alpha: 0.04),
              scheme.surfaceContainerLow,
            ),
            child: SizedBox(
              height: 210,
              child: CupertinoTheme(
                data: CupertinoTheme.of(context).copyWith(
                  textTheme: CupertinoTextThemeData(
                    dateTimePickerTextStyle: pickerTextStyle,
                  ),
                ),
                child: CupertinoDatePicker(
                  mode: CupertinoDatePickerMode.date,
                  dateOrder: DatePickerDateOrder.ymd,
                  minimumDate: minDate,
                  maximumDate: maxDate,
                  initialDateTime: value,
                  use24hFormat: true,
                  onDateTimeChanged: onChanged,
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _PieCalloutChart extends StatefulWidget {
  const _PieCalloutChart({
    required this.items,
    required this.totalSeconds,
    required this.selectedProjectId,
    required this.onSelectProject,
    this.onInteractionChanged,
  });

  final List<ProjectDistributionItem> items;
  final int totalSeconds;
  final int? selectedProjectId;
  final ValueChanged<int?> onSelectProject;
  final ValueChanged<bool>? onInteractionChanged;

  @override
  State<_PieCalloutChart> createState() => _PieCalloutChartState();
}

class _PieCalloutChartState extends State<_PieCalloutChart> {
  static const double _initialStartDegreeOffset = -90;
  double _startDegreeOffset = _initialStartDegreeOffset;
  bool _dragging = false;
  double? _lastDragAngle;
  double _dragDistance = 0;
  bool _interactionActive = false;

  void _setInteractionActive(bool active) {
    if (_interactionActive == active) {
      return;
    }
    _interactionActive = active;
    widget.onInteractionChanged?.call(active);
  }

  @override
  void didUpdateWidget(covariant _PieCalloutChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.items.length != widget.items.length ||
        oldWidget.totalSeconds != widget.totalSeconds) {
      _startDegreeOffset = _initialStartDegreeOffset;
      _dragging = false;
      _lastDragAngle = null;
      _dragDistance = 0;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.items.isEmpty) {
      return const SizedBox.shrink();
    }

    final int? resolvedSelectedId = widget.selectedProjectId;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double calloutLabelWidth = _resolveCalloutLabelWidth(context);
    const double calloutLabelHeight = 22;
    const double calloutPieGap = 8;
    const double calloutLineTextGap = 8;
    const double minHorizontalSegment = 12;

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final double preferredDiameter = min(236.0, max(176.0, width * 0.66));
        final double maxDiameterForCallout =
            width -
            (2 *
                (calloutLabelWidth +
                    calloutLineTextGap +
                    minHorizontalSegment +
                    2));
        final double maxDiameterForHeight = max(
          96.0,
          constraints.maxHeight - 32,
        );
        final double diameter = min(
          preferredDiameter,
          min(maxDiameterForCallout, maxDiameterForHeight),
        ).clamp(96.0, 236.0).toDouble();
        final double chartRadius = (diameter / 2) - 4;
        final double canvasHeight = min(constraints.maxHeight, diameter + 72);
        final double verticalInset = max(0.0, (canvasHeight - diameter) / 2);
        final double centerYOffset = min(8.0, verticalInset * 0.5);
        final double centerY = (canvasHeight / 2) + centerYOffset;
        final Offset center = Offset(width / 2, centerY);

        final List<_PieCallout> callouts = _buildCallouts(
          width: width,
          height: canvasHeight,
          center: center,
          chartRadius: chartRadius,
          selectedProjectId: resolvedSelectedId,
          labelWidth: calloutLabelWidth,
          labelHeight: calloutLabelHeight,
          pieGap: calloutPieGap,
          lineTextGap: calloutLineTextGap,
          minHorizontalSegment: minHorizontalSegment,
          startDegreeOffset: _startDegreeOffset,
        );

        return Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (PointerDownEvent event) {
            final Offset local = event.localPosition;
            final double distance = (local - center).distance;
            final bool withinChart = distance <= (diameter / 2) + 10;
            if (!withinChart) {
              _setInteractionActive(false);
              _dragging = false;
              _lastDragAngle = null;
              _dragDistance = 0;
              return;
            }
            _setInteractionActive(true);
            _dragging = true;
            _dragDistance = 0;
            _lastDragAngle = _angleFromCenter(local, center);
          },
          onPointerMove: (PointerMoveEvent event) {
            if (!_dragging) {
              return;
            }
            final double angle = _angleFromCenter(event.localPosition, center);
            if (_lastDragAngle != null) {
              final double delta = _normalizeDeltaAngle(
                angle - _lastDragAngle!,
              );
              if (delta.abs() > 0.0001) {
                setState(() {
                  _startDegreeOffset += delta;
                });
              }
            }
            _dragDistance += event.delta.distance;
            _lastDragAngle = angle;
          },
          onPointerUp: (PointerUpEvent event) {
            _setInteractionActive(false);
            final bool wasDragging = _dragging;
            final bool movedEnough = _dragDistance > 6;
            _dragging = false;
            _lastDragAngle = null;
            _dragDistance = 0;

            if (wasDragging && movedEnough) {
              return;
            }
            if (resolvedSelectedId != null) {
              final Offset local = event.localPosition;
              final bool outsideCircle =
                  (local - center).distance > (diameter / 2) + 4;
              if (outsideCircle) {
                widget.onSelectProject(null);
              }
            }
          },
          onPointerCancel: (_) {
            _setInteractionActive(false);
            _dragging = false;
            _lastDragAngle = null;
            _dragDistance = 0;
          },
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CustomPaint(
                  painter: _PieGuideLinePainter(
                    callouts: callouts,
                    defaultColor: scheme.onSurface.withValues(alpha: 0.58),
                  ),
                ),
              ),
              Positioned(
                left: center.dx - (diameter / 2),
                top: center.dy - (diameter / 2),
                width: diameter,
                height: diameter,
                child: PieChart(
                  PieChartData(
                    sectionsSpace: 1,
                    centerSpaceRadius: 0,
                    startDegreeOffset: _startDegreeOffset,
                    pieTouchData: PieTouchData(
                      enabled: true,
                      touchCallback:
                          (
                            FlTouchEvent event,
                            PieTouchResponse? touchResponse,
                          ) {
                            if (event is! FlTapUpEvent) {
                              return;
                            }
                            final PieTouchedSection? touched =
                                touchResponse?.touchedSection;
                            if (touched == null) {
                              widget.onSelectProject(null);
                              return;
                            }
                            final int index = touched.touchedSectionIndex;
                            if (index < 0 || index >= widget.items.length) {
                              return;
                            }
                            final int projectId = widget.items[index].projectId;
                            widget.onSelectProject(projectId);
                          },
                    ),
                    sections: widget.items.map((ProjectDistributionItem item) {
                      final bool hasSelection = resolvedSelectedId != null;
                      final bool isSelected =
                          hasSelection && item.projectId == resolvedSelectedId;
                      final double radius = !hasSelection
                          ? chartRadius * 0.94
                          : (isSelected
                                ? chartRadius * 1.02
                                : chartRadius * 0.88);
                      return PieChartSectionData(
                        color: item.color,
                        value: item.totalSeconds.toDouble(),
                        radius: radius,
                        title: _shortProjectName(item.projectName),
                        titlePositionPercentageOffset: 0.62,
                        titleStyle: TextStyle(
                          fontSize: isSelected ? 14 : 12,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ),
              ...callouts.map((_PieCallout callout) {
                return Positioned(
                  left: callout.labelLeft,
                  top: callout.labelTop,
                  width: callout.labelWidth,
                  child: Text(
                    callout.durationText,
                    maxLines: 1,
                    textAlign: callout.isRight
                        ? TextAlign.left
                        : TextAlign.right,
                    overflow: TextOverflow.ellipsis,
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      fontSize: callout.isSelected ? 12 : 11,
                      fontWeight: callout.isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: callout.isSelected
                          ? scheme.onSurface
                          : scheme.onSurface.withValues(alpha: 0.78),
                    ),
                  ),
                );
              }),
            ],
          ),
        );
      },
    );
  }

  double _resolveCalloutLabelWidth(BuildContext context) {
    final TextStyle style =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ) ??
        const TextStyle(fontSize: 11, fontWeight: FontWeight.w500);
    double maxWidth = 0;
    for (final ProjectDistributionItem item in widget.items) {
      final TextPainter painter = TextPainter(
        text: TextSpan(
          text: _formatCalloutDuration(item.totalSeconds),
          style: style,
        ),
        textDirection: TextDirection.ltr,
        maxLines: 1,
      )..layout();
      maxWidth = max(maxWidth, painter.width);
    }
    return max(52, min(74, maxWidth + 6));
  }

  List<_PieCallout> _buildCallouts({
    required double width,
    required double height,
    required Offset center,
    required double chartRadius,
    required int? selectedProjectId,
    required double labelWidth,
    required double labelHeight,
    required double pieGap,
    required double lineTextGap,
    required double minHorizontalSegment,
    required double startDegreeOffset,
  }) {
    final int total = max(1, widget.totalSeconds);
    const double radialSegmentLength = 12;
    double currentAngle = startDegreeOffset;
    final List<_PieCallout> raw = <_PieCallout>[];

    for (final ProjectDistributionItem item in widget.items) {
      final double sweep = (item.totalSeconds / total) * 360;
      final double mid = currentAngle + (sweep / 2);
      final double radians = (mid * pi) / 180;
      final Offset vector = Offset(cos(radians), sin(radians));
      final bool isRight = vector.dx >= 0;

      final Offset p1 = center + (vector * chartRadius);
      final Offset radialEnd =
          center + (vector * (chartRadius + radialSegmentLength));
      final double desiredCenterY = radialEnd.dy.clamp(
        labelHeight / 2,
        height - labelHeight / 2,
      );

      final double elbowX = radialEnd.dx;

      double rawLeft;
      if (isRight) {
        final double minLeft = center.dx + chartRadius + pieGap;
        final double outwardLeft = elbowX + minHorizontalSegment + lineTextGap;
        rawLeft = max(minLeft, outwardLeft);
      } else {
        final double maxLeft = center.dx - chartRadius - pieGap - labelWidth;
        final double outwardMaxLeft =
            elbowX - minHorizontalSegment - lineTextGap - labelWidth;
        rawLeft = min(maxLeft, outwardMaxLeft);
      }
      final double left = rawLeft.clamp(0, max(0, width - labelWidth));
      final double top = (desiredCenterY - (labelHeight / 2)).clamp(
        0,
        max(0, height - labelHeight),
      );
      final double lineY = top + (labelHeight / 2);
      final double lineEndX = isRight
          ? left - lineTextGap
          : left + labelWidth + lineTextGap;

      raw.add(
        _PieCallout(
          projectId: item.projectId,
          durationText: _formatCalloutDuration(item.totalSeconds),
          lineA: p1,
          lineB: Offset(elbowX, lineY),
          lineC: Offset(lineEndX, lineY),
          labelLeft: left,
          labelTop: top,
          labelWidth: labelWidth,
          isRight: isRight,
          isSelected: selectedProjectId == item.projectId,
          color: item.color,
        ),
      );

      currentAngle += sweep;
    }

    final List<_PieCallout> right =
        raw.where((_PieCallout callout) => callout.isRight).toList()
          ..sort((a, b) => a.labelTop.compareTo(b.labelTop));
    final List<_PieCallout> left =
        raw.where((_PieCallout callout) => !callout.isRight).toList()
          ..sort((a, b) => a.labelTop.compareTo(b.labelTop));

    _spreadLabelsVertically(right, height, labelHeight: labelHeight);
    _spreadLabelsVertically(left, height, labelHeight: labelHeight);

    return _pinCalloutLinesToLabels(
      <_PieCallout>[...right, ...left],
      lineTextGap: lineTextGap,
      minHorizontalSegment: minHorizontalSegment,
      labelHeight: labelHeight,
      chartWidth: width,
      chartHeight: height,
    );
  }

  void _spreadLabelsVertically(
    List<_PieCallout> side,
    double chartHeight, {
    required double labelHeight,
  }) {
    if (side.length <= 1) {
      return;
    }

    const double minGap = 18;
    final double maxTop = max(0, chartHeight - labelHeight);

    for (int i = 1; i < side.length; i++) {
      final double minTop = side[i - 1].labelTop + minGap;
      if (side[i].labelTop < minTop) {
        side[i] = side[i].copyWith(labelTop: minTop.clamp(0, maxTop));
      }
    }

    for (int i = side.length - 2; i >= 0; i--) {
      final double maxCurrent = side[i + 1].labelTop - minGap;
      if (side[i].labelTop > maxCurrent) {
        side[i] = side[i].copyWith(labelTop: maxCurrent.clamp(0, maxTop));
      }
    }
  }

  List<_PieCallout> _pinCalloutLinesToLabels(
    List<_PieCallout> callouts, {
    required double lineTextGap,
    required double minHorizontalSegment,
    required double labelHeight,
    required double chartWidth,
    required double chartHeight,
  }) {
    const double minFirstSegmentDy = 6;
    const double maxFirstSegmentDy = 18;
    return callouts.map((_PieCallout callout) {
      double labelLeft = callout.labelLeft.clamp(
        0,
        max(0, chartWidth - callout.labelWidth),
      );
      double labelTop = callout.labelTop;
      double lineEndY = labelTop + (labelHeight / 2);
      final double deltaY = lineEndY - callout.lineA.dy;
      if (deltaY.abs() < minFirstSegmentDy) {
        lineEndY =
            callout.lineA.dy +
            (deltaY >= 0 ? minFirstSegmentDy : -minFirstSegmentDy);
        labelTop = (lineEndY - (labelHeight / 2)).clamp(
          0,
          max(0, chartHeight - labelHeight),
        );
        lineEndY = labelTop + (labelHeight / 2);
      } else if (deltaY.abs() > maxFirstSegmentDy) {
        lineEndY =
            callout.lineA.dy +
            (deltaY >= 0 ? maxFirstSegmentDy : -maxFirstSegmentDy);
        labelTop = (lineEndY - (labelHeight / 2)).clamp(
          0,
          max(0, chartHeight - labelHeight),
        );
        lineEndY = labelTop + (labelHeight / 2);
      }
      double lineEndX = callout.isRight
          ? labelLeft - lineTextGap
          : labelLeft + callout.labelWidth + lineTextGap;
      final double baseElbowX = callout.lineB.dx;
      double elbowX;
      if (callout.isRight) {
        final double minElbowX = callout.lineA.dx + 0.5;
        final double maxElbowX = lineEndX - minHorizontalSegment;
        elbowX = max(minElbowX, min(baseElbowX, maxElbowX));
        if (lineEndX <= elbowX) {
          lineEndX = elbowX + minHorizontalSegment;
          labelLeft = (lineEndX + lineTextGap).clamp(
            0,
            max(0, chartWidth - callout.labelWidth),
          );
          lineEndX = labelLeft - lineTextGap;
        }
      } else {
        final double maxElbowX = callout.lineA.dx - 0.5;
        final double minElbowX = lineEndX + minHorizontalSegment;
        elbowX = min(maxElbowX, max(baseElbowX, minElbowX));
        if (lineEndX >= elbowX) {
          lineEndX = elbowX - minHorizontalSegment;
          labelLeft = (lineEndX - lineTextGap - callout.labelWidth).clamp(
            0,
            max(0, chartWidth - callout.labelWidth),
          );
          lineEndX = labelLeft + callout.labelWidth + lineTextGap;
        }
      }
      return callout.copyWith(
        labelLeft: labelLeft,
        labelTop: labelTop,
        lineB: Offset(elbowX, lineEndY),
        lineC: Offset(lineEndX, lineEndY),
      );
    }).toList();
  }

  String _shortProjectName(String name) {
    const int maxChars = 4;
    if (name.length <= maxChars) {
      return name;
    }
    return '${name.substring(0, maxChars)}…';
  }

  String _formatCalloutDuration(int seconds) {
    if (seconds <= 0) {
      return '0分';
    }
    final int hours = seconds ~/ 3600;
    final int minutes = (seconds % 3600) ~/ 60;
    if (hours <= 0) {
      return '$minutes分';
    }
    if (minutes <= 0) {
      return '$hours小时';
    }
    return '$hours时$minutes分';
  }

  double _angleFromCenter(Offset point, Offset center) {
    return atan2(point.dy - center.dy, point.dx - center.dx) * (180 / pi);
  }

  double _normalizeDeltaAngle(double delta) {
    double normalized = delta;
    while (normalized > 180) {
      normalized -= 360;
    }
    while (normalized < -180) {
      normalized += 360;
    }
    return normalized;
  }
}

class _PieCallout {
  const _PieCallout({
    required this.projectId,
    required this.durationText,
    required this.lineA,
    required this.lineB,
    required this.lineC,
    required this.labelLeft,
    required this.labelTop,
    required this.labelWidth,
    required this.isRight,
    required this.isSelected,
    required this.color,
  });

  final int projectId;
  final String durationText;
  final Offset lineA;
  final Offset lineB;
  final Offset lineC;
  final double labelLeft;
  final double labelTop;
  final double labelWidth;
  final bool isRight;
  final bool isSelected;
  final Color color;

  _PieCallout copyWith({
    double? labelLeft,
    double? labelTop,
    Offset? lineB,
    Offset? lineC,
  }) {
    return _PieCallout(
      projectId: projectId,
      durationText: durationText,
      lineA: lineA,
      lineB: lineB ?? this.lineB,
      lineC: lineC ?? this.lineC,
      labelLeft: labelLeft ?? this.labelLeft,
      labelTop: labelTop ?? this.labelTop,
      labelWidth: labelWidth,
      isRight: isRight,
      isSelected: isSelected,
      color: color,
    );
  }
}

class _PieGuideLinePainter extends CustomPainter {
  const _PieGuideLinePainter({
    required this.callouts,
    required this.defaultColor,
  });

  final List<_PieCallout> callouts;
  final Color defaultColor;

  @override
  void paint(Canvas canvas, Size size) {
    for (final _PieCallout callout in callouts) {
      final Paint paint = Paint()
        ..color = callout.isSelected
            ? callout.color.withValues(alpha: 0.95)
            : defaultColor
        ..strokeWidth = callout.isSelected ? 2 : 1.4
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;

      final Path path = Path()
        ..moveTo(callout.lineA.dx, callout.lineA.dy)
        ..lineTo(callout.lineB.dx, callout.lineB.dy)
        ..lineTo(callout.lineC.dx, callout.lineC.dy);

      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _PieGuideLinePainter oldDelegate) {
    return true;
  }
}

class _FocusSharePoster extends StatelessWidget {
  const _FocusSharePoster({
    required this.posterSize,
    required this.day,
    required this.aggregateStats,
    required this.dayStats,
    required this.distributionStats,
  });

  final Size posterSize;
  final DateTime day;
  final AggregateStats aggregateStats;
  final DayStats dayStats;
  final DistributionStats distributionStats;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<ProjectDistributionItem> items = distributionStats.items;

    return SizedBox(
      width: posterSize.width,
      height: posterSize.height,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: <Color>[
              Color.alphaBlend(
                scheme.primary.withValues(alpha: 0.24),
                const Color(0xFFF7F8FB),
              ),
              Color.alphaBlend(
                scheme.tertiary.withValues(alpha: 0.2),
                const Color(0xFFF2F4FB),
              ),
              const Color(0xFFECEFF7),
            ],
          ),
        ),
        child: Stack(
          children: <Widget>[
            Positioned(
              right: -70,
              top: -80,
              child: Container(
                width: 280,
                height: 280,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.primary.withValues(alpha: 0.13),
                ),
              ),
            ),
            Positioned(
              left: -90,
              bottom: -110,
              child: Container(
                width: 320,
                height: 320,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: scheme.secondary.withValues(alpha: 0.12),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(34, 24, 34, 10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _formatCnDate(day),
                    style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                      fontSize: 42,
                      fontWeight: FontWeight.w700,
                      color: const Color(0xFF222530),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      _PosterTag(text: '共专注${aggregateStats.activeDays}天'),
                      _PosterTag(
                        text: '连续专注${aggregateStats.consecutiveDays}天',
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              '当日专注',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _MetricsRow(
                          columnCount: 2,
                          metrics: <_MetricData>[
                            _MetricData(
                              label: '专注次数',
                              value: '${dayStats.sessionCount}次',
                            ),
                            _MetricData(
                              label: '专注时长',
                              value: formatDurationSeconds(
                                dayStats.totalSeconds,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 10),
                  _SectionCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Row(
                          children: <Widget>[
                            Text(
                              '专注时长分布',
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        if (items.isEmpty)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 12),
                            child: Text('该时间范围内暂无有效记录'),
                          )
                        else
                          SizedBox(
                            height: 208,
                            child: _PieCalloutChart(
                              items: items,
                              totalSeconds: distributionStats.totalSeconds,
                              selectedProjectId: null,
                              onSelectProject: (int? _) {},
                            ),
                          ),
                        if (items.isNotEmpty) ...<Widget>[
                          const SizedBox(height: 1),
                          Center(
                            child: Text(
                              '总计 ${formatDurationSeconds(distributionStats.totalSeconds)}  '
                              '日均 ${formatDurationSecondsKeepMinutes(distributionStats.averagePerDaySeconds)}',
                              style: Theme.of(context).textTheme.titleMedium
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                          ),
                          const SizedBox(height: 8),
                          ...items.map((ProjectDistributionItem item) {
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 4),
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 6,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.48),
                                  borderRadius: BorderRadius.circular(10),
                                ),
                                child: Row(
                                  children: <Widget>[
                                    CircleAvatar(
                                      radius: 7,
                                      backgroundColor: item.color,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        item.projectName,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Text(
                                      formatDurationSeconds(item.totalSeconds),
                                      style: Theme.of(context)
                                          .textTheme
                                          .bodyMedium
                                          ?.copyWith(
                                            fontWeight: FontWeight.w500,
                                          ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          }),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 4),
                  Center(
                    child: Text(
                      '计流',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: const Color(0xFF4F5367),
                        fontWeight: FontWeight.w700,
                        letterSpacing: 2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatCnDate(DateTime date) {
    final String month = date.month.toString().padLeft(2, '0');
    final String dayText = date.day.toString().padLeft(2, '0');
    return '${date.year}年$month月$dayText日';
  }
}

class _PosterTag extends StatelessWidget {
  const _PosterTag({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: const Color(0xFFF8F2F1).withValues(alpha: 0.92),
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: const Color(0xFFEFDAD5).withValues(alpha: 0.95),
          width: 1,
        ),
      ),
      child: Text(
        text,
        style: Theme.of(context).textTheme.titleMedium?.copyWith(
          color: const Color(0xFFBC5E4A),
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Padding(padding: const EdgeInsets.all(14), child: child),
    );
  }
}

class _MetricsRow extends StatelessWidget {
  const _MetricsRow({
    required this.metrics,
    this.columnCount = 3,
    this.compactUnitText = false,
  });

  final List<_MetricData> metrics;
  final int columnCount;
  final bool compactUnitText;

  @override
  Widget build(BuildContext context) {
    if (metrics.isEmpty) {
      return const SizedBox.shrink();
    }

    final int count = min(max(1, columnCount), metrics.length);
    final List<_MetricData> padded = List<_MetricData>.from(metrics);
    while (padded.length < count) {
      padded.add(const _MetricData(label: '', value: ''));
    }

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        const double spacing = 8;
        final double itemWidth =
            (constraints.maxWidth - (count - 1) * spacing) / count;

        return Row(
          children: List<Widget>.generate(count, (int index) {
            final _MetricData metric = padded[index];
            return Padding(
              padding: EdgeInsets.only(right: index == count - 1 ? 0 : spacing),
              child: SizedBox(
                width: itemWidth,
                child: _MetricTile(
                  label: metric.label,
                  value: metric.value,
                  compactUnitText: compactUnitText,
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

class _MetricData {
  const _MetricData({required this.label, required this.value});

  final String label;
  final String value;
}

class _MetricTile extends StatelessWidget {
  const _MetricTile({
    required this.label,
    required this.value,
    this.compactUnitText = false,
  });

  final String label;
  final String value;
  final bool compactUnitText;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle valueStyle =
        Theme.of(
          context,
        ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700) ??
        const TextStyle(fontSize: 20, fontWeight: FontWeight.w700);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Color.alphaBlend(
          scheme.primary.withValues(alpha: 0.08),
          Colors.white,
        ),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: scheme.onSurface.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 4),
          if (compactUnitText)
            _MetricValueText(value: value, numberStyle: valueStyle)
          else
            SizedBox(
              width: double.infinity,
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, softWrap: false, style: valueStyle),
              ),
            ),
        ],
      ),
    );
  }
}

class _MetricValueText extends StatelessWidget {
  const _MetricValueText({required this.value, required this.numberStyle});

  final String value;
  final TextStyle numberStyle;

  @override
  Widget build(BuildContext context) {
    if (value.isEmpty) {
      return const SizedBox.shrink();
    }

    final double numberFontSize = numberStyle.fontSize ?? 30;
    final TextStyle unitStyle = numberStyle.copyWith(
      fontSize: max(7, numberFontSize * 0.38),
      fontWeight: FontWeight.w600,
      height: 1,
    );
    final RegExp regExp = RegExp(r'(\d+)|([^\d]+)');
    final List<InlineSpan> spans = <InlineSpan>[];
    for (final RegExpMatch match in regExp.allMatches(value)) {
      final String token = match.group(0)!;
      final bool isNumber = RegExp(r'^\d+$').hasMatch(token);
      spans.add(
        TextSpan(text: token, style: isNumber ? numberStyle : unitStyle),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: Text.rich(
        TextSpan(children: spans),
        maxLines: 1,
        overflow: TextOverflow.clip,
        softWrap: false,
      ),
    );
  }
}
