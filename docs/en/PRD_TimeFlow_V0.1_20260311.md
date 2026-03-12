# TimeFlow PRD (V0.1, Condensed)

- Version: V0.1
- Date: 2026-03-11
- Platform: Flutter (iOS / Android)
- One-line definition: A personal productivity app focused on "todo timing + time allocation analysis".

## 1. Version Goals

V0.1 delivers one complete loop:

1. Users can create todo groups and todos, then start either forward timing or countdown timing.
2. When timing ends, a focus record is generated automatically (records under 1 minute may be discarded).
3. Users can view time distribution on the stats page by day/week/month/custom range.
4. Users can view focus history, export backups, import backups, and share a stats poster.

## 2. Scope

### 2.1 In Scope (V0.1)

- Todo group management: create, edit, delete.
- Todo management: create, edit, delete, and duplicate-name validation within the same group.
- Timer modes: forward timer, countdown timer (30 min / 1 h / custom, max 5 h).
- Countdown completion reminder: configurable vibration and ringtone.
- Running timer page: shows timer and todo name; back navigation is blocked.
- Record generation: stopping writes a record; <1 minute shows a confirmation dialog and is excluded from stats by default.
- Stats page: aggregate focus, daily focus, focus duration distribution.
- Distribution dimensions: day / week / month / custom.
- Pie chart interactions: tap to highlight, tap blank area to reset, drag to rotate.
- History page: view records by date; calendar supports horizontal month swipe and quick year/month wheel jump.
- Data capability: local SQLite storage; JSON backup export/import.
- Sharing capability: stats poster preview, save to gallery, system share.

### 2.2 Out of Scope (Not in V0.1)

- Cloud sync and real-time multi-device conflict resolution.
- Team collaboration and social features.
- Complex Pomodoro workflows (for example, multi-stage cycles).
- AI review/suggestion features.
- Importing TomatoTodo data.

## 3. Detailed Requirements

### 3.1 Todo Timing Module

#### 3.1.1 Todo Groups

- Group name is required, length 1-20.
- Group names must be unique.
- Deletion down to 0 groups is allowed.
- When deleting a group:
  - If its todos have history, soft-delete the todos and group, while keeping historical records.
  - If there is no history, physical deletion is allowed.

#### 3.1.2 Todos

- Fields: name, group, timer mode, countdown seconds, vibration switch, ringtone switch.
- Name is required, length 1-20.
- Duplicate names are not allowed within the same group (same name is treated as the same todo).
- Colors are auto-assigned by the app; users do not assign colors manually.
- Deletion follows the same principle as groups: preserve historical data integrity.
- If history exists and a todo with the same name is recreated after deletion, the old color must not be reused during the deleted period (to avoid historical color conflicts).

#### 3.1.3 Timing Flow

- Only one timer can run at any given time.
- Tapping "Start" should trigger a transition effect into the running timer page.
- Running timer page displays:
  - Timer (forward increasing / countdown decreasing)
  - Todo name (below the timer)
  - Status text (Forward Timing / Countdown)
  - Stop button (Pause is reserved for later versions)
- Stop logic:
  - >= 1 minute: save record and refresh stats.
  - < 1 minute: show a confirmation dialog; if ended, do not include in stats.
- After app background/restore/relaunch: resume running timer state from `current_timer`.

### 3.2 Stats Module

#### 3.2.1 Aggregate Focus Overview

- Displays: total sessions, total duration, average daily duration.
- Large-number adaptation: values must not be truncated.
- Text rule: when hours >= 1000, total duration hides minutes and shows hours only.

#### 3.2.2 Daily Focus

- Displays: session count and duration for the selected date.
- Default date is today.
- Supports previous/next day and wheel-based date picking (range: 2026-01-01 to today).

#### 3.2.3 Focus Duration Distribution

- Displays: date range, segmented control (day/week/month/custom), pie chart, total, daily average, and the todo list below.
- Date text rules:
  - Single day: show `yyyy-MM-dd` only.
  - Multi-day: show `start ~ end`.
- Pie chart rules:
  - Colors must match todo colors on the timer page.
  - No percentages; show todo and duration.
  - Leader lines must be "diagonal first, then horizontal".
  - Duration text must be at the end of the line, without overlapping line or pie.
  - Slice expands only when selected; tapping blank area resets to full circle.
  - Supports drag rotation; page scrolling is disabled while rotating.

#### 3.2.4 Focus History

- Supports per-day detail list (todo name, start-end time, duration).
- Dates with records are circled in the calendar.
- Calendar supports animated left/right month swiping.
- Supports quick year/month wheel navigation.

### 3.3 Sharing and Backup

#### 3.3.1 Share Poster

- Enter from stats page into a centered preview dialog (not a bottom sheet).
- Poster includes: date, daily focus module, focus distribution module, detail list.
- Module structure matches the stats page, only scaled down.
- Exported image ratio should be close to 1:1; avoid large bottom whitespace; pie chart must remain circular (not squashed).

#### 3.3.2 Data Backup

- Top-right "..." menu on the stats page supports:
  - Export backup (JSON)
  - Import backup (JSON)
- Import requires secondary confirmation and overwrites local data.

## 4. Data Design (SQLite)

### 4.1 `project_groups` (Todo Group)

- `id`, `name`, `sort_order`, `is_deleted`, `created_at`, `updated_at`

### 4.2 `projects` (Todo)

- `id`, `name`, `group_id`, `timer_mode`, `countdown_seconds`
- `color_value`, `enable_vibration`, `enable_ringtone`
- `is_enabled`, `is_deleted`, `sort_order`, `created_at`, `updated_at`

### 4.3 `focus_sessions` (Focus Record)

- `id`, `project_id`, `start_time`, `end_time`, `duration_seconds`
- `status`, `record_date`, `created_at`, `updated_at`

### 4.4 `current_timer` (Running Timer)

- `id=1`, `project_id`, `start_time`, `status`, `last_sync_time`
- `timer_mode`, `target_seconds`

## 5. Statistical Definitions

- Valid record: `duration_seconds >= 60` and `status = completed`.
- Date attribution: attributed to the start-time date.
- Aggregate daily average: total duration / number of active days.
- Range daily average: range total duration / number of calendar days in range.

## 6. Acceptance Checklist (V0.1)

1. Todo groups and todos can be created/edited/deleted with correct duplicate-name validation.
2. Timer can start/stop correctly, and only one timer can run at once.
3. Countdown supports 30 min / 1 h / custom (<=5 h) + vibration/ringtone toggles.
4. Ending below 1 minute triggers confirmation and does not count in stats.
5. Aggregate, daily, and distribution statistics are correct.
6. Day/week/month/custom switching works with valid date constraints.
7. Pie chart interactions (select/reset/rotate) work, and labels remain readable.
8. History page supports calendar switching, month swiping, and quick year/month navigation.
9. Backup export and import are available.
10. Share poster preview, save, and system share are available.

## 7. V0.1 Completion Status (2026-03-11)

- Conclusion: **V0.1 core functionality is complete**.
- Status: **Passed** (validated against this condensed PRD scope).

### 7.1 Completed

- Full todo/todo-group lifecycle management.
- Full forward timer + countdown flow.
- <1 minute confirmation and discard logic.
- Three main stats modules (aggregate, daily, distribution).
- Pie chart interaction and label layout optimization.
- History calendar enhancements (marked days, swipe, wheel navigation).
- Backup export/import.
- Share poster preview and export.

### 7.2 Non-mandatory for V0.1 (Deferred)

- The "Pause" button on the running timer page is still a placeholder (planned for v0.2).
