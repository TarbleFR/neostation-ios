# NeoStation iOS Architecture

This document describes the architecture of the NeoStation Flutter application as maintained in this iOS-focused fork.

## Overview

NeoStation is a landscape-oriented Flutter emulation frontend. This repository is maintained primarily for **iOS / iPadOS 18+**, while retaining substantial upstream Android and desktop code plus vendored platform packages so shared Flutter logic remains close to the original project.

The iOS port adds Apple-specific external-folder access, emulator discovery/launch integration, library synchronization, custom menu media, sideloading-oriented build support and iOS-specific first-run flows.

## Layered architecture

```text
┌─────────────────────────────────────────────┐
│ Presentation Layer (UI)                    │
│ lib/screens/  lib/widgets/                 │
├─────────────────────────────────────────────┤
│ State Layer                                │
│ lib/providers/                             │
├─────────────────────────────────────────────┤
│ Business Logic Layer                       │
│ lib/services/  lib/sync/                   │
├─────────────────────────────────────────────┤
│ Data Layer                                 │
│ lib/repositories/  lib/data/datasources/   │
├─────────────────────────────────────────────┤
│ External APIs / Native Integrations        │
│ RetroAchievements  ScreenScraper  NeoSync  │
│ RetroArch  MeloNX  ARMSX2                  │
└─────────────────────────────────────────────┘
```

**Dependency rule:** presentation/state code should use services or repositories rather than reaching directly into raw data sources.

- **Providers** may use **Services** or **Repositories** directly.
- **Services** should use **Repositories** for persisted application data.
- **Repositories** are the layer authorized to talk directly to `DataSources` (SQLite, files and raw persistence APIs).

## UI layer

- **`lib/screens/`**: Full application screens. `AppScreen` owns the top-level tabs and `SystemContent` owns the primary Systems experience.
- **`lib/widgets/`**: Reusable UI blocks and shared widgets.

Navigation uses standard Flutter navigation plus an indexed top-level tab model. Gamepad navigation is coordinated separately through `lib/utils/gamepad_nav.dart`.

The user-selected main-menu background is intentionally owned high enough in the main app tree to remain decoded while switching tabs, preventing a blank/theme-colored frame when returning to Systems. `SystemContent` itself stays focused on the Systems content phases (splash, setup and library).

## State layer

- **`lib/providers/`**: `ChangeNotifier` classes consumed through Provider.

Key providers include:

- `SqliteConfigProvider` — main application state, system detection and scanning.
- `SqliteDatabaseProvider` — game-library data.
- `NeoSyncProvider` — cloud-save synchronization state.
- `ThemeProvider` — built-in/custom UI themes plus custom main-menu background persistence.
- `RetroAchievementsProvider` — RetroAchievements user data and achievements.

## Business logic layer

- **`lib/services/`**: External API clients, platform-specific operations and business logic.
- **`lib/sync/`**: provider-agnostic save-sync orchestration and backends.

Key services include:

- `NeoSyncService` — NeoSync backend integration.
- `SyncManager` — save-sync orchestration.
- `RetroAchievementsService` — RetroAchievements API integration.
- `ScreenScraperService` — metadata scraping with bounded concurrency.
- `GameService` — game launching and session tracking.
- `LauncherService` — platform/emulator launch orchestration.
- `HomeMusicService` — user-selected main-menu music, lifecycle handling and playback arbitration.
- `MusicPlayerService` — normal user music playback.
- `LoggerService` — structured logging.

## Data sources

- **`lib/data/datasources/`**: Direct SQLite access, raw database operations and migrations.

Core data sources include:

- `SqliteService` — low-level SQLite access.
- `SqliteDatabaseService` — ROM scanning and game CRUD operations.
- `SqliteConfigService` — configuration persistence and system detection.
- `sqlite_migrations.dart` — versioned database migrations.

Database schema changes require coordinated updates to the initial schema/column guards and to the versioned migration path so fresh installs and upgraded databases converge to the same structure.

## Repositories

- **`lib/repositories/`**: Abstract persisted data access.

Key repositories include:

- `ConfigRepository` — user preferences, themes and view modes.
- `EmulatorRepository` — emulator paths, cores and standalone-emulator configuration.
- `GameRepository` — game CRUD, favorites and play time.
- `RetroAchievementsRepository` — hashes, IDs and cached user/game state.
- `ScraperRepository` — ScreenScraper configuration and metadata persistence.
- `SystemRepository` — system detection/settings/extensions.
- `SyncRepository` — cloud-save synchronization state.

## External services

| Service | Purpose | Authentication |
|---|---|---|
| RetroAchievements | Achievements, leaderboards, game hashes | Per-user runtime credentials |
| ScreenScraper | Game metadata, media and descriptions | Developer ID/password at build time + per-user runtime account credentials |
| NeoSync | Authentication and cloud-save features | Runtime tokens |

## iOS / iPadOS integration

The maintained release target of this fork is iOS/iPadOS 18+.

Important iOS-specific behavior includes:

- external-folder/document access used to link emulator libraries;
- RetroArch, MeloNX and ARMSX2 detection and deeplink/launch integration;
- first-run setup adapted around iOS linking rather than desktop/Android directory flows;
- custom Systems-menu backgrounds using static images, GIFs or local video containers;
- optional main-menu music copied into NeoStation user data;
- landscape UI and gamepad-focused navigation;
- unsigned IPA-friendly release builds for sideloading/signing outside the repository.

The generated `ios/` Xcode scaffold is intentionally not stored in this repository. Local/release builders create it with Flutter and then set the deployment target to iOS 18.0 before compiling.

## Other inherited platform code

The repository keeps upstream platform implementations used by shared code and workspace packages:

- **Android**: immersive mode, Android TV/directory handling and secondary-display support.
- **Windows/Linux/macOS**: inherited desktop platform code and fullscreen helpers.
- **Dual-screen Android devices**: a second Flutter engine can render `lib/screens/secondary_screen/` through the `sub_screen` package.

These directories are retained for source continuity and shared-package compatibility, but this fork's public release focus is iOS/iPadOS.

## Local packages

The Flutter workspace in `pubspec.yaml` vendors/localizes packages under `packages/`:

- `external_folder_access` — external-folder access abstraction used by the port.
- `flutter_7zip` — FFI bindings for archive extraction.
- `gamepads` — shared gamepad API.
- `gamepads_android` — Android gamepad implementation.
- `gamepads_darwin` — Darwin/iOS/macOS gamepad implementation.
- `gamepads_linux` — Linux gamepad implementation.
- `gamepads_platform_interface` — platform contract.
- `gamepads_windows` — Windows gamepad implementation.

## Assets

- `assets/data/` contains bootstrap/application data used by the app.
- `assets/systems/` contains bundled system definitions/resources.
- `assets/images/`, `assets/sounds/` and `assets/shaders/` provide presentation assets.
- User-selected background/music files are copied into the user-data area at runtime and are not repository assets.

## Build configuration

Sensitive ScreenScraper developer values are supplied to Dart as **compile-time defines**. `.env.example` is only a local template; a real `.env` file is ignored by Git and can be passed with `--dart-define-from-file=.env`.

The installed app does **not** load a runtime `.env` file.

## Code conventions

- Use `Color.withValues(alpha: …)` rather than deprecated `withOpacity()`.
- Guard `BuildContext` use after `await` with a mounted check.
- Use `flutter_screenutil` for responsive sizing/spacing where the surrounding UI follows that convention.
- Keep source comments and repository documentation in **English**.
- Route user-visible text through the localization system.
