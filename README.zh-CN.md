# 计流 TimeFlow

[English](./README.md) | [简体中文](./README.zh-CN.md)

一款面向个人用户的「待办计时 + 时间分配分析」App，帮助你清楚看到时间花在了哪里。

![计流 Logo](./source/applogo.png)

## 项目现状

- 版本：V0.2.0
- 状态：当前发布基线
- App 名称：计流
- 包名（Android/iOS）：`com.francis.timeflow`

## 功能特性（V0.2.0）

- 待办集与待办管理：新增、编辑、删除
- 计时模式：正向计时、倒计时（30min / 1h / 自定义）
- 暂停/恢复：单次计时支持暂停，当前版本暂停总额度为 3 分钟
- 计时结束心得：支持立即填写或稍后再填，并可在历史记录详情中补填
- 倒计时提醒：可配置震动和铃声
- Android 提醒链路：前台进度通知、后台结束提醒，以及应用内提醒权限/通道设置入口
- 运行中计时页：禁止返回退出，防止误操作
- 记录规则：
  - 同一时刻仅允许一个计时
  - 小于 1 分钟结束会弹窗确认，默认不纳入统计
- 统计分析：
  - 累计专注概览
  - 当日专注
  - 本月专注时段分布
  - 月度专注统计
  - 年度专注统计
  - 专注时长分布（日 / 周 / 月 / 自定义）
- 分布图交互：点击高亮、点击空白恢复、拖动旋转
- 专注记录页：
  - 日历左右滑动切月
  - 年月滚轮快速定位
  - 记录详情、心得补填、删除记录
  - 有记录日期圈标
- 数据能力：本地 SQLite 存储、导出备份 / 导入备份（JSON）
- 分享能力：统计海报预览、保存到相册、系统分享

## 技术栈

- Flutter 3.38.9（Dart 3.10.8）
- 状态管理：`provider`
- 本地数据库：`sqflite`
- 图表：`fl_chart`
- 分享/导出：`share_plus`、`screenshot`、`image_gallery_saver`、`file_picker`

## 项目结构

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
│       │       ├── models/      # 数据模型
│       │       ├── state/       # 全局状态
│       │       ├── ui/          # 页面与组件
│       │       └── utils/       # 工具函数
│       ├── android/
│       ├── ios/
│       └── test/
└── source/
    └── applogo.png
```

## 环境要求

- Flutter SDK：`3.38.9`（建议 stable 渠道）
- Dart SDK：`3.10.8`
- Xcode（iOS 调试）
- Android Studio + Android SDK（Android 调试）

## 本地运行

在项目根目录执行：

```bash
cd frontend/flutter
flutter pub get
```

### 运行 iOS

```bash
flutter run -d ios
```

如果需要先启动模拟器：

```bash
open -a Simulator
```

### 运行 Android

```bash
flutter run -d android
```

### 基础检查

```bash
flutter analyze
flutter test
```

## 备份与迁移

在「统计数据」页右上角 `...` 菜单中：

- 导出备份：导出当前本地数据为 JSON
- 导入备份：导入 JSON 并覆盖本地数据（会二次确认）

适用场景：离线换机、手动迁移数据。

## 数据说明

- 本地数据库文件名：`timeflow_v0_1.db`（为兼容迁移保留）
- 核心表：
  - `project_groups`
  - `projects`
  - `focus_sessions`
  - `current_timer`

## 产品文档

- 中文 PRD v0.2.0：[`docs/zh-CN/PRD_计流_V0.2_20260312.md`](./docs/zh-CN/PRD_计流_V0.2_20260312.md)
- English PRD v0.2.0：[`docs/en/PRD_TimeFlow_V0.2_20260312.md`](./docs/en/PRD_TimeFlow_V0.2_20260312.md)
- 中文 PRD v0.1：[`docs/zh-CN/PRD_计流_V0.1_20260311.md`](./docs/zh-CN/PRD_计流_V0.1_20260311.md)
- English PRD v0.1：[`docs/en/PRD_TimeFlow_V0.1_20260311.md`](./docs/en/PRD_TimeFlow_V0.1_20260311.md)

## 已知边界（V0.2.0）

- 暂不支持云同步与多端实时合并
- 暂不支持导入番茄 Todo 数据
- 部分 Android 厂商系统仍要求用户在系统通知设置中手动打开悬浮通知/振动等通道开关

## 路线图

- v0.3：云同步、多设备登录、目标与提醒
- v0.4：更丰富的提醒控制与外部数据导入

## 贡献

当前以个人开发为主。如需协作，请先提交 issue 描述需求或问题，再讨论实现方案。

## 许可证

本项目采用 **GNU Affero General Public License v3.0（AGPL-3.0）**。  
完整条款见 [`LICENSE`](./LICENSE)。
