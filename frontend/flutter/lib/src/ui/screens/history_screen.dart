import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../../data/timeflow_repository.dart';
import '../../models/models.dart';
import '../../utils/time_format.dart';

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key, required this.initialDate});

  final DateTime initialDate;

  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}

class _HistoryScreenState extends State<HistoryScreen> {
  late DateTime _selectedDate;
  late DateTime _displayedMonth;
  int _calendarSlideDirection = 1;
  bool _loading = true;
  bool _calendarLoading = false;
  String? _error;
  List<HistoryItem> _items = <HistoryItem>[];
  Set<String> _recordedDateKeysInMonth = <String>{};
  int _requestSerial = 0;
  final ScrollController _listScrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _selectedDate = _clampToHistoryRange(
      DateTime(
        widget.initialDate.year,
        widget.initialDate.month,
        widget.initialDate.day,
      ),
    );
    _displayedMonth = DateTime(_selectedDate.year, _selectedDate.month, 1);
    _loadMarkedDatesForMonth(_displayedMonth);
    _load(forDate: _selectedDate);
  }

  @override
  void dispose() {
    _listScrollController.dispose();
    super.dispose();
  }

  Future<void> _load({
    required DateTime forDate,
    bool syncSelectedDate = false,
  }) async {
    final int requestId = ++_requestSerial;

    setState(() {
      if (syncSelectedDate) {
        _selectedDate = forDate;
      }
      _loading = true;
      _error = null;
    });

    try {
      final TimeFlowRepository repository = context.read<TimeFlowRepository>();
      final List<HistoryItem> items = await repository.fetchHistoryByDate(
        forDate,
      );
      if (!mounted || requestId != _requestSerial) {
        return;
      }
      setState(() {
        _items = items;
      });
    } catch (error) {
      if (!mounted || requestId != _requestSerial) {
        return;
      }
      setState(() {
        _error = error.toString();
      });
    } finally {
      if (mounted && requestId == _requestSerial) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  Future<void> _loadMarkedDatesForMonth(DateTime month) async {
    final DateTime monthStart = DateTime(month.year, month.month, 1);
    final DateTime monthEnd = DateTime(month.year, month.month + 1, 0);
    setState(() {
      _calendarLoading = true;
    });

    try {
      final TimeFlowRepository repository = context.read<TimeFlowRepository>();
      final Set<String> keys = await repository.fetchRecordedDateKeysInRange(
        monthStart,
        monthEnd,
      );
      if (!mounted) {
        return;
      }
      setState(() {
        _recordedDateKeysInMonth = keys;
      });
    } finally {
      if (mounted) {
        setState(() {
          _calendarLoading = false;
        });
      }
    }
  }

  Future<void> _onSelectDate(DateTime value) async {
    if (_isSameDay(_selectedDate, value)) {
      return;
    }
    if (_listScrollController.hasClients) {
      _listScrollController.jumpTo(0);
    }
    final DateTime month = DateTime(value.year, value.month, 1);
    if (!_isSameMonth(_displayedMonth, month)) {
      final int deltaMonths =
          ((month.year - _displayedMonth.year) * 12) +
          (month.month - _displayedMonth.month);
      setState(() {
        _calendarSlideDirection = deltaMonths >= 0 ? 1 : -1;
        _displayedMonth = month;
      });
      _loadMarkedDatesForMonth(month);
    }
    await _load(forDate: value, syncSelectedDate: true);
  }

  void _shiftMonth(int offset) {
    final DateTime month = DateTime(
      _displayedMonth.year,
      _displayedMonth.month + offset,
      1,
    );
    final DateTime minDate = _historyMinDate();
    final DateTime maxDate = _historyMaxDate();
    final DateTime minMonth = DateTime(minDate.year, minDate.month, 1);
    final DateTime maxMonth = DateTime(maxDate.year, maxDate.month, 1);
    if (month.isBefore(minMonth) || month.isAfter(maxMonth)) {
      return;
    }
    setState(() {
      _calendarSlideDirection = offset >= 0 ? 1 : -1;
      _displayedMonth = month;
    });
    _loadMarkedDatesForMonth(month);
  }

  Future<void> _pickYearMonth() async {
    final DateTime minDate = _historyMinDate();
    final DateTime maxDate = _historyMaxDate();
    final DateTime minMonth = DateTime(minDate.year, minDate.month, 1);
    final DateTime maxMonth = DateTime(maxDate.year, maxDate.month, 1);
    final DateTime initialMonth = DateTime(
      _displayedMonth.year,
      _displayedMonth.month,
      1,
    );

    final DateTime? pickedMonth = await showDialog<DateTime>(
      context: context,
      barrierDismissible: true,
      builder: (BuildContext dialogContext) {
        return _YearMonthPickerDialog(
          initialMonth: initialMonth,
          minMonth: minMonth,
          maxMonth: maxMonth,
        );
      },
    );

    if (!mounted || pickedMonth == null) {
      return;
    }

    final DateTime targetMonth = DateTime(
      pickedMonth.year,
      pickedMonth.month,
      1,
    );
    final int maxDayInTargetMonth = DateTime(
      targetMonth.year,
      targetMonth.month + 1,
      0,
    ).day;
    final int targetDay = _selectedDate.day > maxDayInTargetMonth
        ? maxDayInTargetMonth
        : _selectedDate.day;
    final DateTime targetDate = _clampToHistoryRange(
      DateTime(targetMonth.year, targetMonth.month, targetDay),
    );
    await _onSelectDate(targetDate);
  }

  @override
  Widget build(BuildContext context) {
    final DateTime minDate = _historyMinDate();
    final DateTime maxDate = _historyMaxDate();
    return Scaffold(
      appBar: AppBar(title: const Text('专注记录')),
      body: Column(
        children: <Widget>[
          Material(
            color: Theme.of(context).colorScheme.surfaceContainerLow,
            child: ClipRect(
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 260),
                switchInCurve: Curves.easeOutCubic,
                switchOutCurve: Curves.easeOutCubic,
                layoutBuilder:
                    (Widget? currentChild, List<Widget> previousChildren) {
                      return Stack(
                        alignment: Alignment.topCenter,
                        children: <Widget>[
                          ...previousChildren,
                          if (currentChild case final Widget child) child,
                        ],
                      );
                    },
                transitionBuilder: (Widget child, Animation<double> animation) {
                  final int direction = _calendarSlideDirection >= 0 ? 1 : -1;
                  final Key currentKey = ValueKey<String>(
                    'month-${_displayedMonth.year}-${_displayedMonth.month}',
                  );
                  final bool isIncoming = child.key == currentKey;

                  final Animation<Offset> position = isIncoming
                      ? Tween<Offset>(
                          begin: Offset(direction.toDouble(), 0),
                          end: Offset.zero,
                        ).animate(animation)
                      : Tween<Offset>(
                          begin: Offset.zero,
                          end: Offset(-direction * 0.28, 0),
                        ).animate(ReverseAnimation(animation));

                  return FadeTransition(
                    opacity: animation,
                    child: SlideTransition(position: position, child: child),
                  );
                },
                child: _HistoryMonthCalendar(
                  key: ValueKey<String>(
                    'month-${_displayedMonth.year}-${_displayedMonth.month}',
                  ),
                  displayedMonth: _displayedMonth,
                  selectedDate: _selectedDate,
                  firstDate: minDate,
                  lastDate: maxDate,
                  markedDateKeys: _recordedDateKeysInMonth,
                  loading: _calendarLoading,
                  onPreviousMonth: () => _shiftMonth(-1),
                  onNextMonth: () => _shiftMonth(1),
                  onPickMonthYear: _pickYearMonth,
                  onDateSelected: _onSelectDate,
                ),
              ),
            ),
          ),
          SizedBox(
            height: 2,
            child: AnimatedOpacity(
              opacity: _loading ? 1 : 0,
              duration: const Duration(milliseconds: 120),
              child: const LinearProgressIndicator(minHeight: 2),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text('加载失败：$_error'),
            ),
          Expanded(
            child: _HistoryList(
              items: _items,
              selectedDate: _selectedDate,
              controller: _listScrollController,
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month && a.day == b.day;
  }

  bool _isSameMonth(DateTime a, DateTime b) {
    return a.year == b.year && a.month == b.month;
  }

  DateTime _historyMinDate() {
    return DateTime(2026, 1, 1);
  }

  DateTime _historyMaxDate() {
    final DateTime now = DateTime.now();
    return DateTime(now.year, now.month + 1, 0);
  }

  DateTime _clampToHistoryRange(DateTime value) {
    final DateTime normalized = DateTime(value.year, value.month, value.day);
    final DateTime minDate = _historyMinDate();
    final DateTime maxDate = _historyMaxDate();
    if (normalized.isBefore(minDate)) {
      return minDate;
    }
    if (normalized.isAfter(maxDate)) {
      return maxDate;
    }
    return normalized;
  }
}

class _HistoryMonthCalendar extends StatelessWidget {
  const _HistoryMonthCalendar({
    super.key,
    required this.displayedMonth,
    required this.selectedDate,
    required this.firstDate,
    required this.lastDate,
    required this.markedDateKeys,
    required this.loading,
    required this.onPreviousMonth,
    required this.onNextMonth,
    required this.onPickMonthYear,
    required this.onDateSelected,
  });

  final DateTime displayedMonth;
  final DateTime selectedDate;
  final DateTime firstDate;
  final DateTime lastDate;
  final Set<String> markedDateKeys;
  final bool loading;
  final VoidCallback onPreviousMonth;
  final VoidCallback onNextMonth;
  final VoidCallback onPickMonthYear;
  final ValueChanged<DateTime> onDateSelected;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final DateTime monthStart = DateTime(
      displayedMonth.year,
      displayedMonth.month,
      1,
    );
    final DateTime monthEnd = DateTime(
      displayedMonth.year,
      displayedMonth.month + 1,
      0,
    );
    final DateTime firstMonth = DateTime(firstDate.year, firstDate.month, 1);
    final DateTime lastMonth = DateTime(lastDate.year, lastDate.month, 1);
    final DateTime prevMonth = DateTime(
      displayedMonth.year,
      displayedMonth.month - 1,
      1,
    );
    final DateTime nextMonth = DateTime(
      displayedMonth.year,
      displayedMonth.month + 1,
      1,
    );
    final bool canPrev = !prevMonth.isBefore(firstMonth);
    final bool canNext = !nextMonth.isAfter(lastMonth);

    final int leading = (monthStart.weekday + 6) % 7;
    final int daysInMonth = monthEnd.day;
    final int cells = ((leading + daysInMonth + 6) ~/ 7) * 7;
    final DateFormat monthFormat = DateFormat('yyyy年MM月');
    final List<String> weekTitles = const <String>[
      '一',
      '二',
      '三',
      '四',
      '五',
      '六',
      '日',
    ];

    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onHorizontalDragEnd: (DragEndDetails details) {
        final double velocity = details.primaryVelocity ?? 0;
        if (velocity.abs() < 220) {
          return;
        }
        if (velocity < 0) {
          if (canNext) {
            onNextMonth();
          }
          return;
        }
        if (canPrev) {
          onPreviousMonth();
        }
      },
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 10),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: canPrev ? onPreviousMonth : null,
                  icon: const Icon(Icons.chevron_left),
                ),
                Expanded(
                  child: Center(
                    child: TextButton.icon(
                      onPressed: onPickMonthYear,
                      icon: const Icon(Icons.unfold_more_rounded, size: 18),
                      label: Text(
                        monthFormat.format(displayedMonth),
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                    ),
                  ),
                ),
                IconButton(
                  visualDensity: VisualDensity.compact,
                  onPressed: canNext ? onNextMonth : null,
                  icon: const Icon(Icons.chevron_right),
                ),
              ],
            ),
            if (loading)
              const SizedBox(
                height: 2,
                child: LinearProgressIndicator(minHeight: 2),
              )
            else
              const SizedBox(height: 2),
            const SizedBox(height: 6),
            Row(
              children: weekTitles
                  .map(
                    (String text) => Expanded(
                      child: Center(
                        child: Text(
                          text,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: scheme.onSurface.withValues(alpha: 0.72),
                              ),
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
            const SizedBox(height: 6),
            GridView.builder(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: cells,
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 7,
                childAspectRatio: 1.26,
              ),
              itemBuilder: (BuildContext context, int index) {
                final int day = index - leading + 1;
                if (day < 1 || day > daysInMonth) {
                  return const SizedBox.shrink();
                }
                final DateTime date = DateTime(
                  displayedMonth.year,
                  displayedMonth.month,
                  day,
                );
                final bool disabled =
                    date.isBefore(firstDate) || date.isAfter(lastDate);
                final bool selected =
                    selectedDate.year == date.year &&
                    selectedDate.month == date.month &&
                    selectedDate.day == date.day;
                final bool marked = markedDateKeys.contains(formatDate(date));

                final Color textColor;
                if (disabled) {
                  textColor = scheme.onSurface.withValues(alpha: 0.32);
                } else if (selected) {
                  textColor = scheme.onPrimary;
                } else {
                  textColor = scheme.onSurface;
                }

                final BoxDecoration? decoration;
                if (selected) {
                  decoration = BoxDecoration(
                    shape: BoxShape.circle,
                    color: scheme.primary,
                    border: marked
                        ? Border.all(
                            color: scheme.onPrimary.withValues(alpha: 0.85),
                            width: 1.4,
                          )
                        : null,
                  );
                } else if (marked) {
                  decoration = BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(
                      color: scheme.primary.withValues(alpha: 0.9),
                      width: 1.4,
                    ),
                  );
                } else {
                  decoration = null;
                }

                return InkWell(
                  onTap: disabled ? null : () => onDateSelected(date),
                  customBorder: const CircleBorder(),
                  child: Center(
                    child: Container(
                      width: 34,
                      height: 34,
                      decoration: decoration,
                      alignment: Alignment.center,
                      child: Text(
                        '$day',
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          color: textColor,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _YearMonthPickerDialog extends StatefulWidget {
  const _YearMonthPickerDialog({
    required this.initialMonth,
    required this.minMonth,
    required this.maxMonth,
  });

  final DateTime initialMonth;
  final DateTime minMonth;
  final DateTime maxMonth;

  @override
  State<_YearMonthPickerDialog> createState() => _YearMonthPickerDialogState();
}

class _YearMonthPickerDialogState extends State<_YearMonthPickerDialog> {
  late final List<int> _years;
  late int _selectedYear;
  late int _selectedMonth;
  late final FixedExtentScrollController _yearController;
  late final FixedExtentScrollController _monthController;

  @override
  void initState() {
    super.initState();
    _years = <int>[
      for (int y = widget.minMonth.year; y <= widget.maxMonth.year; y++) y,
    ];

    final DateTime clamped = _clampMonth(widget.initialMonth);
    _selectedYear = clamped.year;
    _selectedMonth = clamped.month;

    _yearController = FixedExtentScrollController(
      initialItem: _years.indexOf(_selectedYear),
    );
    _monthController = FixedExtentScrollController(
      initialItem: _monthsForYear(_selectedYear).indexOf(_selectedMonth),
    );
  }

  @override
  void dispose() {
    _yearController.dispose();
    _monthController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final List<int> months = _monthsForYear(_selectedYear);

    return AlertDialog(
      title: const Text('快速定位年月'),
      contentPadding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      content: SizedBox(
        height: 210,
        width: 320,
        child: Row(
          children: <Widget>[
            Expanded(
              child: _buildWheel(
                controller: _yearController,
                itemCount: _years.length,
                builder: (int index) =>
                    Center(child: Text('${_years[index]}年')),
                onSelectedItemChanged: (int index) {
                  final int nextYear = _years[index];
                  if (nextYear == _selectedYear) {
                    return;
                  }
                  setState(() {
                    _selectedYear = nextYear;
                    final List<int> nextMonths = _monthsForYear(_selectedYear);
                    if (_selectedMonth < nextMonths.first) {
                      _selectedMonth = nextMonths.first;
                    }
                    if (_selectedMonth > nextMonths.last) {
                      _selectedMonth = nextMonths.last;
                    }
                  });
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (!mounted || !_monthController.hasClients) {
                      return;
                    }
                    final List<int> refreshedMonths = _monthsForYear(
                      _selectedYear,
                    );
                    final int monthIndex = refreshedMonths.indexOf(
                      _selectedMonth,
                    );
                    _monthController.jumpToItem(
                      monthIndex < 0 ? 0 : monthIndex,
                    );
                  });
                },
              ),
            ),
            Expanded(
              child: _buildWheel(
                controller: _monthController,
                itemCount: months.length,
                builder: (int index) =>
                    Center(child: Text('${months[index]}月')),
                onSelectedItemChanged: (int index) {
                  if (index < 0 || index >= months.length) {
                    return;
                  }
                  setState(() {
                    _selectedMonth = months[index];
                  });
                },
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            Navigator.of(
              context,
            ).pop(DateTime(_selectedYear, _selectedMonth, 1));
          },
          child: const Text('确定'),
        ),
      ],
    );
  }

  Widget _buildWheel({
    required FixedExtentScrollController controller,
    required int itemCount,
    required Widget Function(int index) builder,
    required ValueChanged<int> onSelectedItemChanged,
  }) {
    return CupertinoPicker.builder(
      scrollController: controller,
      itemExtent: 42,
      diameterRatio: 1.15,
      useMagnifier: true,
      magnification: 1.08,
      onSelectedItemChanged: onSelectedItemChanged,
      childCount: itemCount,
      itemBuilder: (BuildContext context, int index) {
        if (index < 0 || index >= itemCount) {
          return null;
        }
        return builder(index);
      },
    );
  }

  List<int> _monthsForYear(int year) {
    final int startMonth = year == widget.minMonth.year
        ? widget.minMonth.month
        : 1;
    final int endMonth = year == widget.maxMonth.year
        ? widget.maxMonth.month
        : 12;
    return <int>[for (int m = startMonth; m <= endMonth; m++) m];
  }

  DateTime _clampMonth(DateTime value) {
    final DateTime month = DateTime(value.year, value.month, 1);
    if (month.isBefore(widget.minMonth)) {
      return widget.minMonth;
    }
    if (month.isAfter(widget.maxMonth)) {
      return widget.maxMonth;
    }
    return month;
  }
}

class _HistoryList extends StatelessWidget {
  const _HistoryList({
    required this.items,
    required this.selectedDate,
    required this.controller,
  });

  final List<HistoryItem> items;
  final DateTime selectedDate;
  final ScrollController controller;

  @override
  Widget build(BuildContext context) {
    final bool empty = items.isEmpty;
    return ListView.separated(
      key: ValueKey<String>('history-${formatDate(selectedDate)}'),
      controller: controller,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
      itemCount: empty ? 1 : items.length,
      itemBuilder: (BuildContext context, int index) {
        if (empty) {
          return const Padding(
            padding: EdgeInsets.only(top: 48),
            child: Center(child: Text('当天暂无专注记录')),
          );
        }

        final HistoryItem item = items[index];
        return Card(
          child: ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 8,
            ),
            leading: CircleAvatar(radius: 8, backgroundColor: item.color),
            title: Text(item.projectName),
            subtitle: Text(
              '${formatTime(item.session.startTime)} - '
              '${formatTime(item.session.endTime)}',
            ),
            trailing: Text(
              formatDurationSeconds(item.session.durationSeconds),
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
        );
      },
      separatorBuilder: (BuildContext context, int index) =>
          empty ? const SizedBox.shrink() : const SizedBox(height: 4),
    );
  }
}
