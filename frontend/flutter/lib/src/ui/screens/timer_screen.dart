import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../data/timeflow_repository.dart';
import '../../models/models.dart';
import '../../services/countdown_alert_service.dart';
import '../../state/app_model.dart';
import '../widgets/project_editor_sheet.dart';

DateTime? _lastNeedGroupHintAt;

class TimerScreen extends StatelessWidget {
  const TimerScreen({super.key});

  static bool get _showPromotedNotificationSettingsEntry =>
      !kIsWeb && defaultTargetPlatform == TargetPlatform.android;

  @override
  Widget build(BuildContext context) {
    final AppModel model = context.watch<AppModel>();
    final List<ProjectGroupBundle> bundles = model.bundles;

    return Scaffold(
      appBar: AppBar(
        title: const Text('待办集'),
        actions: <Widget>[
          if (_showPromotedNotificationSettingsEntry)
            IconButton(
              tooltip: '通知提升设置',
              onPressed: () => _openPromotedNotificationSettings(context),
              icon: const Icon(Icons.notifications_active_outlined),
            ),
          IconButton(
            tooltip: '新增待办集',
            onPressed: () => _createGroup(context, model),
            icon: const Icon(Icons.create_new_folder_outlined),
          ),
          IconButton(
            tooltip: '新建代办',
            onPressed: () => _createProject(context, model),
            icon: const Icon(Icons.add_circle_outline),
          ),
        ],
      ),
      body: Column(
        children: <Widget>[
          if (model.loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: bundles.isEmpty
                ? _EmptyProjectView(
                    onCreateGroup: () => _createGroup(context, model),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                    itemCount: bundles.length,
                    itemBuilder: (BuildContext context, int index) {
                      final ProjectGroupBundle bundle = bundles[index];
                      return _GroupSection(
                        bundle: bundle,
                        onCreateProject: () => _createProject(
                          context,
                          model,
                          initialGroupId: bundle.group.id,
                        ),
                        onEditGroup: () =>
                            _editGroup(context, model, bundle.group),
                        onDeleteGroup: () =>
                            _deleteGroup(context, model, bundle.group),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Future<void> _openPromotedNotificationSettings(BuildContext context) async {
    final bool opened = await CountdownAlertService.instance
        .openPromotedNotificationSettings();
    if (!context.mounted || opened) {
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('当前系统未提供通知提升设置入口')),
    );
  }

  Future<void> _createGroup(BuildContext context, AppModel model) async {
    final String? name = await showGroupNameDialog(context);
    if (!context.mounted || name == null || name.isEmpty) {
      return;
    }

    try {
      await model.createGroup(name);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('待办集创建成功')));
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<void> _editGroup(
    BuildContext context,
    AppModel model,
    ProjectGroup group,
  ) async {
    final String? name = await showGroupNameDialog(
      context,
      title: '编辑代办集',
      initialName: group.name,
      submitLabel: '保存',
    );

    if (!context.mounted || name == null || name.isEmpty) {
      return;
    }

    try {
      await model.updateGroup(groupId: group.id, name: name);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代办集已更新')));
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<void> _deleteGroup(
    BuildContext context,
    AppModel model,
    ProjectGroup group,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除代办集'),
          content: Text('确认删除代办集“${group.name}”及其代办？历史记录会保留。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );

    if (!context.mounted || confirmed != true) {
      return;
    }

    try {
      await model.deleteGroup(group.id);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代办集已删除')));
    } catch (error) {
      _showError(context, error);
    }
  }

  Future<void> _createProject(
    BuildContext context,
    AppModel model, {
    int? initialGroupId,
  }) async {
    final List<ProjectGroup> groups = model.bundles
        .map((ProjectGroupBundle item) => item.group)
        .toList();
    if (groups.isEmpty) {
      _showNeedGroupHint(context);
      return;
    }

    final ProjectFormResult? result = await showProjectEditorSheet(
      context,
      groups: groups,
      initialGroupId: initialGroupId,
    );

    if (!context.mounted || result == null) {
      return;
    }

    try {
      await model.createProject(
        name: result.name,
        groupId: result.groupId,
        timerMode: result.timerMode,
        countdownSeconds: result.countdownSeconds,
        enableVibration: result.enableVibration,
        enableRingtone: result.enableRingtone,
      );
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代办创建成功')));
    } catch (error) {
      _showError(context, error);
    }
  }

  static void _showError(BuildContext context, Object error) {
    String message = '操作失败';
    if (error is ValidationException || error is TimerConflictException) {
      message = error.toString();
    }

    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  static void _showNeedGroupHint(BuildContext context) {
    final DateTime now = DateTime.now();
    if (_lastNeedGroupHintAt != null &&
        now.difference(_lastNeedGroupHintAt!) <
            const Duration(milliseconds: 1200)) {
      return;
    }
    _lastNeedGroupHintAt = now;

    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger
      ..hideCurrentSnackBar()
      ..clearSnackBars()
      ..showSnackBar(const SnackBar(content: Text('请先创建代办集')));
  }
}

class _EmptyProjectView extends StatelessWidget {
  const _EmptyProjectView({required this.onCreateGroup});

  final VoidCallback onCreateGroup;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.assignment_outlined,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(height: 12),
            Text(
              '还没有代办集，先创建代办集吧',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: onCreateGroup,
              icon: const Icon(Icons.add),
              label: const Text('新建代办集'),
            ),
          ],
        ),
      ),
    );
  }
}

class _GroupSection extends StatelessWidget {
  const _GroupSection({
    required this.bundle,
    required this.onCreateProject,
    required this.onEditGroup,
    required this.onDeleteGroup,
  });

  final ProjectGroupBundle bundle;
  final VoidCallback onCreateProject;
  final VoidCallback onEditGroup;
  final VoidCallback onDeleteGroup;

  @override
  Widget build(BuildContext context) {
    final ThemeData baseTheme = Theme.of(context);
    return Theme(
      data: baseTheme.copyWith(dividerColor: Colors.transparent),
      child: Card(
        margin: const EdgeInsets.only(bottom: 12),
        clipBehavior: Clip.hardEdge,
        child: ExpansionTile(
          key: PageStorageKey<String>('group-${bundle.group.id}'),
          initiallyExpanded: true,
          backgroundColor: Colors.transparent,
          collapsedBackgroundColor: Colors.transparent,
          shape: const RoundedRectangleBorder(side: BorderSide.none),
          collapsedShape: const RoundedRectangleBorder(side: BorderSide.none),
          title: Text(bundle.group.name),
          subtitle: Text('代办 ${bundle.projects.length} 个'),
          childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: Row(
                children: <Widget>[
                  TextButton.icon(
                    onPressed: onCreateProject,
                    icon: const Icon(Icons.add),
                    label: const Text('新增代办'),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: onEditGroup,
                    child: const Text('代办集设置'),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '删除代办集',
                    onPressed: onDeleteGroup,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
            if (bundle.projects.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无代办，点击“新增代办”开始记录时间'),
              )
            else
              ...bundle.projects.map(
                (ProjectItem project) => _ProjectCard(project: project),
              ),
          ],
        ),
      ),
    );
  }
}

class _ProjectCard extends StatelessWidget {
  const _ProjectCard({required this.project});

  final ProjectItem project;

  @override
  Widget build(BuildContext context) {
    final AppModel model = context.watch<AppModel>();

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: <Widget>[
            Container(
              width: 12,
              height: 36,
              decoration: BoxDecoration(
                color: project.color,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    project.name,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    project.timerMode == 'countdown'
                        ? '倒计时 ${_formatCountdown(project.countdownSeconds)}'
                        : '正向计时',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              onSelected: (String value) {
                if (value == 'edit') {
                  _editProject(context, model, project);
                }
                if (value == 'delete') {
                  _deleteProject(context, model, project);
                }
              },
              itemBuilder: (BuildContext context) =>
                  const <PopupMenuEntry<String>>[
                    PopupMenuItem<String>(value: 'edit', child: Text('编辑代办')),
                    PopupMenuItem<String>(value: 'delete', child: Text('删除代办')),
                  ],
            ),
            const SizedBox(width: 4),
            FilledButton(
              onPressed: model.hasRunningTimer
                  ? null
                  : () => _startTimer(context, model, project.id),
              child: const Text('开始'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _startTimer(
    BuildContext context,
    AppModel model,
    int projectId,
  ) async {
    try {
      await model.startTimer(projectId);
    } catch (error) {
      if (!context.mounted) {
        return;
      }
      TimerScreen._showError(context, error);
    }
  }

  Future<void> _deleteProject(
    BuildContext context,
    AppModel model,
    ProjectItem project,
  ) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('删除代办'),
          content: Text('确认删除“${project.name}”？历史记录会保留。'),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('删除'),
            ),
          ],
        );
      },
    );

    if (!context.mounted || confirmed != true) {
      return;
    }

    try {
      await model.deleteProject(project.id);
      if (!context.mounted) {
        return;
      }
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代办已删除')));
    } catch (error) {
      TimerScreen._showError(context, error);
    }
  }

  Future<void> _editProject(
    BuildContext context,
    AppModel model,
    ProjectItem project,
  ) async {
    final List<ProjectGroup> groups = model.bundles
        .map((ProjectGroupBundle item) => item.group)
        .toList();
    final ProjectFormResult? result = await showProjectEditorSheet(
      context,
      groups: groups,
      existing: project,
    );

    if (!context.mounted || result == null) {
      return;
    }

    try {
      await model.updateProject(
        projectId: project.id,
        name: result.name,
        groupId: result.groupId,
        timerMode: result.timerMode,
        countdownSeconds: result.countdownSeconds,
        enableVibration: result.enableVibration,
        enableRingtone: result.enableRingtone,
      );

      if (!context.mounted) {
        return;
      }

      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('代办已更新')));
    } catch (error) {
      TimerScreen._showError(context, error);
    }
  }

  String _formatCountdown(int seconds) {
    final int mins = (seconds / 60).round();
    if (mins % 60 == 0) {
      return '${mins ~/ 60}h';
    }
    return '${mins}min';
  }
}
