import 'package:flutter/material.dart';

import '../../models/models.dart';

class ProjectFormResult {
  const ProjectFormResult({
    required this.name,
    required this.groupId,
    required this.timerMode,
    required this.countdownSeconds,
    required this.enableVibration,
    required this.enableRingtone,
  });

  final String name;
  final int groupId;
  final String timerMode;
  final int countdownSeconds;
  final bool enableVibration;
  final bool enableRingtone;
}

Future<String?> showGroupNameDialog(
  BuildContext context, {
  String title = '新增待办集',
  String submitLabel = '保存',
  String initialName = '',
}) {
  final TextEditingController controller = TextEditingController(
    text: initialName,
  );

  return showDialog<String>(
    context: context,
    builder: (BuildContext context) {
      return AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 20,
          decoration: const InputDecoration(hintText: '请输入代办集名称'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              Navigator.of(context).pop(controller.text.trim());
            },
            child: Text(submitLabel),
          ),
        ],
      );
    },
  );
}

Future<ProjectFormResult?> showProjectEditorSheet(
  BuildContext context, {
  required List<ProjectGroup> groups,
  ProjectItem? existing,
  int? initialGroupId,
}) {
  if (groups.isEmpty) {
    return Future<ProjectFormResult?>.value(null);
  }

  final GlobalKey<FormState> formKey = GlobalKey<FormState>();
  final TextEditingController nameController = TextEditingController(
    text: existing?.name ?? '',
  );

  int selectedGroupId = existing?.groupId ?? initialGroupId ?? groups.first.id;
  String selectedTimerMode = existing?.timerMode ?? 'forward';
  int selectedCountdownSeconds = _normalizeCountdownSeconds(
    existing?.timerMode == 'countdown'
        ? (existing?.countdownSeconds ?? 1800)
        : 1800,
  );
  bool selectedEnableVibration = existing?.enableVibration ?? true;
  bool selectedEnableRingtone = existing?.enableRingtone ?? true;

  return showModalBottomSheet<ProjectFormResult>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (BuildContext context) {
      return StatefulBuilder(
        builder:
            (BuildContext context, void Function(void Function()) setState) {
              return Padding(
                padding: EdgeInsets.only(
                  left: 16,
                  right: 16,
                  top: 16,
                  bottom: MediaQuery.of(context).viewInsets.bottom + 20,
                ),
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        existing == null ? '新建代办' : '编辑代办',
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 16),
                      TextFormField(
                        controller: nameController,
                        maxLength: 20,
                        decoration: const InputDecoration(
                          labelText: '代办名称',
                          hintText: '例如：数学',
                          border: OutlineInputBorder(),
                        ),
                        validator: (String? value) {
                          final String input = value?.trim() ?? '';
                          if (input.isEmpty) {
                            return '请输入代办名称';
                          }
                          if (input.length > 20) {
                            return '名称长度需在 1~20 字';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      DropdownButtonFormField<int>(
                        initialValue: selectedGroupId,
                        decoration: const InputDecoration(
                          labelText: '所属代办集',
                          border: OutlineInputBorder(),
                        ),
                        items: groups
                            .map(
                              (ProjectGroup group) => DropdownMenuItem<int>(
                                value: group.id,
                                child: Text(group.name),
                              ),
                            )
                            .toList(),
                        onChanged: (int? value) {
                          if (value == null) {
                            return;
                          }
                          setState(() {
                            selectedGroupId = value;
                          });
                        },
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '计时模式',
                        style: Theme.of(context).textTheme.titleMedium,
                      ),
                      const SizedBox(height: 8),
                      Center(
                        child: Wrap(
                          alignment: WrapAlignment.center,
                          spacing: 8,
                          runSpacing: 8,
                          children: <Widget>[
                            _CountdownPresetButton(
                              label: '正向计时',
                              selected: selectedTimerMode == 'forward',
                              onPressed: () {
                                setState(() {
                                  selectedTimerMode = 'forward';
                                });
                              },
                            ),
                            _CountdownPresetButton(
                              label: '倒计时',
                              selected: selectedTimerMode == 'countdown',
                              onPressed: () {
                                final bool switchingToCountdown =
                                    selectedTimerMode != 'countdown';
                                setState(() {
                                  selectedTimerMode = 'countdown';
                                  if (switchingToCountdown) {
                                    selectedCountdownSeconds = 1800;
                                  }
                                });
                              },
                            ),
                          ],
                        ),
                      ),
                      if (selectedTimerMode == 'countdown') ...<Widget>[
                        const SizedBox(height: 12),
                        Center(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _CountdownPresetButton(
                                label: '30min',
                                selected: selectedCountdownSeconds == 1800,
                                onPressed: () {
                                  setState(() {
                                    selectedCountdownSeconds = 1800;
                                  });
                                },
                              ),
                              _CountdownPresetButton(
                                label: '1h',
                                selected: selectedCountdownSeconds == 3600,
                                onPressed: () {
                                  setState(() {
                                    selectedCountdownSeconds = 3600;
                                  });
                                },
                              ),
                              _CountdownPresetButton(
                                label: '自定义',
                                selected:
                                    selectedCountdownSeconds != 1800 &&
                                    selectedCountdownSeconds != 3600,
                                onPressed: () async {
                                  final int? customSeconds =
                                      await _pickCustomCountdownSeconds(
                                        context,
                                        initialSeconds:
                                            selectedCountdownSeconds,
                                      );
                                  if (!context.mounted ||
                                      customSeconds == null) {
                                    return;
                                  }
                                  setState(() {
                                    selectedCountdownSeconds =
                                        _normalizeCountdownSeconds(
                                          customSeconds,
                                        );
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Center(
                          child: Text(
                            '当前：${_countdownLabel(selectedCountdownSeconds)}',
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                        const SizedBox(height: 10),
                        Center(
                          child: Wrap(
                            alignment: WrapAlignment.center,
                            spacing: 8,
                            runSpacing: 8,
                            children: <Widget>[
                              _CountdownPresetButton(
                                label: selectedEnableVibration
                                    ? '震动：开'
                                    : '震动：关',
                                selected: selectedEnableVibration,
                                onPressed: () {
                                  setState(() {
                                    selectedEnableVibration =
                                        !selectedEnableVibration;
                                  });
                                },
                              ),
                              _CountdownPresetButton(
                                label: selectedEnableRingtone ? '铃声：开' : '铃声：关',
                                selected: selectedEnableRingtone,
                                onPressed: () {
                                  setState(() {
                                    selectedEnableRingtone =
                                        !selectedEnableRingtone;
                                  });
                                },
                              ),
                            ],
                          ),
                        ),
                      ],
                      const SizedBox(height: 16),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: OutlinedButton(
                              onPressed: () => Navigator.of(context).pop(),
                              child: const Text('取消'),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: FilledButton(
                              onPressed: () {
                                if (!formKey.currentState!.validate()) {
                                  return;
                                }
                                Navigator.of(context).pop(
                                  ProjectFormResult(
                                    name: nameController.text.trim(),
                                    groupId: selectedGroupId,
                                    timerMode: selectedTimerMode,
                                    countdownSeconds: selectedCountdownSeconds,
                                    enableVibration: selectedEnableVibration,
                                    enableRingtone: selectedEnableRingtone,
                                  ),
                                );
                              },
                              child: const Text('保存'),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              );
            },
      );
    },
  );
}

int _normalizeCountdownSeconds(int value) {
  if (value < 60) {
    return 60;
  }
  if (value > 5 * 60 * 60) {
    return 5 * 60 * 60;
  }
  return value;
}

String _countdownLabel(int seconds) {
  final int mins = (seconds / 60).round();
  if (mins % 60 == 0) {
    return '${mins ~/ 60}小时';
  }
  return '$mins分钟';
}

Future<int?> _pickCustomCountdownSeconds(
  BuildContext context, {
  required int initialSeconds,
}) async {
  final int initialMinutes = ((initialSeconds / 60).round()).clamp(1, 300);
  final int? pickedMinutes = await showDialog<int>(
    context: context,
    builder: (BuildContext context) {
      return _CustomCountdownDialog(initialMinutes: initialMinutes);
    },
  );

  if (pickedMinutes == null) {
    return null;
  }
  return pickedMinutes * 60;
}

class _CountdownPresetButton extends StatelessWidget {
  const _CountdownPresetButton({
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return selected
        ? FilledButton.tonal(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}

class _CustomCountdownDialog extends StatefulWidget {
  const _CustomCountdownDialog({required this.initialMinutes});

  final int initialMinutes;

  @override
  State<_CustomCountdownDialog> createState() => _CustomCountdownDialogState();
}

class _CustomCountdownDialogState extends State<_CustomCountdownDialog> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _controller = TextEditingController(
    text: widget.initialMinutes.toString(),
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('自定义倒计时'),
      content: Form(
        key: _formKey,
        child: TextFormField(
          controller: _controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '分钟数',
            hintText: '请输入 1~300',
          ),
          validator: (String? value) {
            final String text = (value ?? '').trim();
            if (text.isEmpty) {
              return '请输入分钟数';
            }
            final int? minutes = int.tryParse(text);
            if (minutes == null) {
              return '请输入整数';
            }
            if (minutes < 1 || minutes > 300) {
              return '请输入 1~300 分钟';
            }
            return null;
          },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () {
            if (!(_formKey.currentState?.validate() ?? false)) {
              return;
            }
            final int minutes = int.parse(_controller.text.trim());
            Navigator.of(context).pop(minutes);
          },
          child: const Text('确定'),
        ),
      ],
    );
  }
}
