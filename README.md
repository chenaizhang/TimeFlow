# TimeFlow

[English](./README.md) | [简体中文](./README.zh-CN.md)

A personal "todo timing + time allocation analysis" app that helps you see exactly where your time goes.

![TimeFlow Logo](./source/applogo.png)

## Project Status

- Version: V0.1
- Status: Core features completed
- App name: 计流 (TimeFlow)
- Package name (Android/iOS): `com.francis.timeflow`

## Features (V0.1)

- Todo group and todo management: create, edit, delete
- Timer modes: forward timer, countdown timer (30 min / 1 h / custom)
- Countdown reminders: configurable vibration and ringtone
- Running timer screen: back navigation is blocked to avoid accidental exits
- Recording rules:
  - Only one active timer is allowed at a time
  - Sessions under 1 minute require confirmation and are excluded from stats by default
- Statistics:
  - Aggregate focus overview
  - Daily focus overview
  - Focus duration distribution (day / week / month / custom)
- Distribution chart interactions: tap to highlight, tap blank area to reset, drag to rotate
- Focus history screen:
  - Swipe left/right to switch months
  - Year/month wheel picker for fast navigation
  - Circle markers for dates with records
- Data capability: local SQLite storage, backup export/import (JSON)
- Sharing capability: stats poster preview, save to gallery, system share

## Tech Stack

- Flutter 3.38.9 (Dart 3.10.8)
- State management: `provider`
- Local database: `sqflite`
- Charting: `fl_chart`
- Sharing/export: `share_plus`, `screenshot`, `image_gallery_saver`, `file_picker`

## Project Structure

```text
TimeFlow/
├── docs/
│   ├── en/
│   └── zh-CN/
├── frontend/
│   └── flutter/
│       ├── lib/
│       │   └── src/
│       │       ├── data/        # Repository + SQLite
│       │       ├── models/      # Data models
│       │       ├── state/       # Global state
│       │       ├── ui/          # Screens and widgets
│       │       └── utils/       # Utilities
│       ├── android/
│       ├── ios/
│       └── test/
└── source/
    └── applogo.png
```

## Requirements

- Flutter SDK: `3.38.9` (stable channel recommended)
- Dart SDK: `3.10.8`
- Xcode (for iOS)
- Android Studio + Android SDK (for Android)

## Run Locally

From the project root:

```bash
cd frontend/flutter
flutter pub get
```

### Run on iOS

```bash
flutter run -d ios
```

Start iOS Simulator first if needed:

```bash
open -a Simulator
```

### Run on Android

```bash
flutter run -d android
```

### Basic checks

```bash
flutter analyze
flutter test
```

## Backup and Migration

In the "统计数据" (Stats) screen, open the top-right `...` menu:

- Export backup: export current local data as JSON
- Import backup: import JSON and overwrite local data (with confirmation)

Use cases: offline device migration and manual local transfer.

## Data Notes

- Local database file: `timeflow_v0_1.db`
- Core tables:
  - `project_groups`
  - `projects`
  - `focus_sessions`
  - `current_timer`

## Product Documents

- Chinese PRD v0.2: [`docs/zh-CN/PRD_计流_V0.2_20260312.md`](./docs/zh-CN/PRD_计流_V0.2_20260312.md)
- English PRD v0.2: [`docs/en/PRD_TimeFlow_V0.2_20260312.md`](./docs/en/PRD_TimeFlow_V0.2_20260312.md)
- Chinese PRD v0.1: [`docs/zh-CN/PRD_计流_V0.1_20260311.md`](./docs/zh-CN/PRD_计流_V0.1_20260311.md)
- English PRD v0.1: [`docs/en/PRD_TimeFlow_V0.1_20260311.md`](./docs/en/PRD_TimeFlow_V0.1_20260311.md)

## Known Limits (V0.1)

- "Pause" on the running timer screen is still a placeholder (planned for v0.2)
- Cloud sync and real-time multi-device merge are not supported yet
- Importing TomatoTodo data is not supported yet

## Roadmap

- v0.2: pause/resume, more statistical charts, record editing
- v0.3: cloud sync, multi-device login, goals and reminders

## Contributing

This project is currently developed primarily by a single maintainer.
If you want to contribute, please open an issue first to describe the problem or proposal before implementation.

## License

This project is licensed under the **GNU Affero General Public License v3.0 (AGPL-3.0)**.  
See [`LICENSE`](./LICENSE) for the full text.
