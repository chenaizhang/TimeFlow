# TimeFlow PRD (V0.2.0)

- Version: V0.2.0
- Date: 2026-03-13
- Platform: Flutter (iOS / Android)
- Previous version: V0.1 (completed)
- Release status: shipped baseline
- One-line definition: On top of the V0.1 "record + analytics" loop, V0.2.0 completes pause control, record editing, and monthly/yearly trend analytics.

## 1. Version Goals

V0.2.0 focuses on three things:

1. Fix key UX bugs (Android reminder failure, black edge in todo-group expansion).
2. Complete the "end-of-session reflection" and "editable focus record" loop.
3. Upgrade the stats page with monthly time-slot distribution, monthly trend, and yearly trend.

## 2. Scope

### 2.1 In Scope (V0.2.0)

- Bug fixes:
  - Android ringtone and vibration not working.
  - Slight black edges on top/bottom when expanding a todo group.
- New features:
  - Focus record detail dialog (including reflection) and delete action.
  - Reflection dialog after each finished timer session (fill now / fill later).
  - Timer pause mechanism (3-minute total pause budget per session in the current release).
  - Monthly focus time-slot distribution chart (24 hourly buckets).
  - Monthly focus trend line chart (daily).
  - Yearly focus trend line chart (monthly).

### 2.2 Out of Scope (Not in V0.2.0)

- Cloud sync and multi-device conflict merge.
- Team collaboration and social features.
- Third-party data import.

## 3. Bug Fix Requirements

### 3.1 Android ringtone and vibration reliability

#### Problem

- On Android devices, ringtone/vibration after countdown completion does not trigger or is unstable.

#### Expected behavior

- When countdown ends:
  - If ringtone is enabled, play system alert sound.
  - If vibration is enabled, trigger one clear vibration feedback.
- If the app is not in foreground:
  - Send a system notification reminding that the pause/countdown has ended.
- On some OEM Android ROMs:
  - Heads-up and vibration may still depend on channel-level system switches.
  - The app should expose a direct entry to the related notification settings page.

#### Acceptance criteria

1. Android physical devices trigger ringtone reliably.
2. In background or screen-locked states, users still receive end notifications.
3. The app provides a direct notification-settings entry for user remediation on OEM ROMs.
4. If switches are off, corresponding reminders are not triggered.

### 3.2 Black edge during todo-group expansion

#### Problem

- Slight black edges appear at top and bottom of expanded todo-group cards, inconsistent with left/right edges.

#### Expected behavior

- No black edges in expanded/collapsed states.
- Shadow, clipping, and corner rendering remain visually consistent on all four sides.

#### Acceptance criteria

1. No black edge artifacts on iOS/Android.
2. Visual behavior remains stable during list scroll and expand/collapse animation.

## 4. New Feature Requirements

### 4.1 Focus record details and deletion

#### Requirement

- In the Focus History page, tapping a record opens a detail dialog.
- Dialog displays:
  - Todo name
  - Date
  - Start time
  - End time
  - Duration
  - Reflection note (optional)
- Dialog includes a "Delete record" action with secondary confirmation.

#### Interaction rules

- After deletion:
  - Record disappears from the list.
  - Stats refresh in real time.
- Reflection is read-only in this dialog view; fill/update entry is provided by the "fill later" flow (see 4.2).

#### Acceptance criteria

1. Tapping a record always opens details.
2. Record and stats update correctly after delete.
3. If reflection is empty, show `Tap to add reflection`.

### 4.2 Reflection dialog after timer completion

#### Requirement

- After each timer session ends, show a reflection dialog.
- Provide two actions:
  - `Fill and save`
  - `Fill later`

#### Field rules

- Reflection text is optional; recommended max length: 500 chars.
- If `Fill later` is selected:
  - Save session first (do not block main flow).
  - Mark record as "pending reflection".

#### Fill-later entry

- Focus record detail dialog supports filling/updating reflection later.

#### Acceptance criteria

1. Dialog always appears after each valid finished session.
2. Choosing fill later does not lose the session.
3. Updated reflection is visible in record details.

### 4.3 Timer pause mechanism (V0.2.0 key feature)

#### Requirement

- Each timer session has a total pause budget of 3 minutes (180s) in the current release.
- During pause, timer stops counting.
- Pause dialog shows remaining pause countdown and warning text:
  - "To avoid long interruptions that break focus, each session supports up to 3 minutes of pause."

#### Detailed rules

1. Multiple pauses are allowed in one session, but cumulative pause time cannot exceed 180s.
2. Current pause can end early.
3. Consumed pause time is deducted from total budget; unused budget remains available for this same session.
4. When remaining budget is 0:
  - Pause is disabled for this session.
  - Pause control must show clear disabled text/state.
5. When pause ends:
  - Vibrate once.
  - If app is backgrounded, send a system notification.
6. Pause dialog/state should not be broken by accidental close behavior.

#### Duration calculation rule

- Focus duration statistics must exclude paused time.

#### Acceptance criteria

1. Total pause budget per session is strictly capped at 180s in the current release.
2. Early-end pause deducts budget correctly and keeps remaining budget usable.
3. Pause is unavailable after budget is exhausted.
4. Foreground end triggers vibration; background end triggers notification.

### 4.4 Monthly focus time-slot distribution (hourly)

#### Requirement

- Add a "Monthly Focus Time-Slot Distribution" module.
- Statistical definition:
  - Bucket by hour (0-23, 24 buckets total).
  - Each bucket equals total focus duration in that month for that hour slot.
- Chart type: vertical bar chart (one bar per hour).

#### Interaction

- Right side of module title supports month switching (same interaction style as Daily Focus date switch).
- Display current month as `yyyy-MM`.

#### Acceptance criteria

1. Chart refreshes correctly when switching month.
2. All 24 hour slots are rendered.
3. Empty months show proper empty-state guidance text.

### 4.5 Monthly focus statistics (daily line chart)

#### Requirement

- Add a "Monthly Focus Statistics" module.
- Statistical definition:
  - X-axis: each day of current month.
  - Y-axis: focused hours for that day (1 decimal allowed).
- Chart type: line chart.

#### Interaction

- Support month switching (same style as Daily Focus switch).
- Support point tooltip for exact value.

#### Acceptance criteria

1. Daily hours match aggregated session data.
2. Month switching is smooth and correct.

### 4.6 Yearly focus statistics (monthly line chart)

#### Requirement

- Add a "Yearly Focus Statistics" module.
- Statistical definition:
  - X-axis: each month of the current year (1-12).
  - Y-axis: focused hours for that month.
- Chart type: line chart.

#### Interaction

- Support year switching (same style as Daily Focus switch).
- Support point tooltip with exact month and duration.

#### Acceptance criteria

1. Monthly values are correctly mapped across the whole year.
2. Year switching remains smooth and stable.
3. Performance remains acceptable with large data volume.

## 5. Data Design Changes (SQLite)

### 5.1 New fields in `focus_sessions`

- `note TEXT NULL`: session reflection note.
- `note_pending INTEGER NOT NULL DEFAULT 0`: whether reflection is pending (`0/1`).

### 5.2 New fields in `current_timer`

- `status TEXT`: timer state (`running` / `paused`).
- `paused_seconds_total INTEGER NOT NULL DEFAULT 0`: cumulative consumed pause time in this session.
- `pause_started_at TEXT NULL`: pause start timestamp.

### 5.3 New analytics queries

- Monthly time-slot distribution: aggregate by start-time hour (0-23).
- Monthly trend line: aggregate by `record_date` per day.
- Yearly trend line: aggregate by `record_date` per month across the year.

## 6. Interaction and Edge Cases

- If reflection dialog is interrupted (phone call/background), user should still be able to resume or re-enter fill flow.
- If app is killed while paused, remaining pause budget/state should recover based on real elapsed time.
- After deleting a record, if selected day has no records, list correctly returns to empty state.
- No page shake/jump when switching month/year in charts.
- On some OEM Android ROMs, background heads-up/vibration may still depend on notification-channel system switches.

## 7. Non-Functional Requirements

- Chart switch response target (adjacent month/year): < 300ms.
- With 2,000+ records in a month, stats page should remain smooth for scroll and interaction.
- Android reminder reliability target: >= 99% success in 100 trigger attempts.

## 8. Acceptance Checklist (V0.2.0)

1. Android ringtone and vibration work in both foreground and background scenarios.
2. No top/bottom black-edge artifacts in expanded todo groups.
3. Record detail dialog supports detail view, reflection display, and confirmed delete.
4. Reflection prompt appears after each completed timer session; supports fill now/fill later.
5. Pause mechanism satisfies the current 3-minute budget, early end, notification behavior, and budget exhaustion lock.
6. Monthly time-slot bar chart is implemented and month switch works.
7. Monthly daily line chart is implemented and month switch works.
8. Yearly monthly line chart is implemented and year switch works.
9. Schema migration keeps old data readable without crashes.

## 9. Release Criteria

- Before code freeze, complete:
  - Regression test (timer main flow, stats flow, backup import/export)
  - Android reminder special test
  - Chart performance sampling test
- Release version: `0.2.0+1`

## 10. Release Sync Notes (2026-03-13)

- This document reflects the shipped `v0.2.0` baseline rather than the earlier planning draft.
- The current release keeps a 3-minute pause budget per session.
- On some Android OEM ROMs, notification heads-up and vibration still require user-enabled channel switches in system settings.
