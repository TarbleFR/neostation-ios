# Contributing to NeoStation iOS

Thank you for your interest in contributing to the NeoStation iOS port.

This repository is maintained primarily for **iOS / iPadOS 18+**. The upstream NeoStation project remains the canonical home for general non-iOS platform development.

## Reporting bugs

Before opening a report, search the existing issues to avoid duplicates.

For an iOS-port bug, include:

- NeoStation version/build number;
- iPhone or iPad model;
- iOS/iPadOS version;
- emulator involved, if relevant (RetroArch, MeloNX or ARMSX2);
- clear reproduction steps;
- expected and actual behavior;
- screenshots, screen recordings or logs when useful.

If the issue reproduces only in the original non-iOS NeoStation project, report it upstream instead of opening it here.

## Proposing features

Use the **Feature Request** issue template and describe the user problem first, then the proposed behavior. UI mockups and concrete workflow examples are welcome.

## Pull requests

1. Fork the repository.
2. Create a short-lived branch from `main`, for example:
   - `feature/your-feature-name`
   - `fix/bug-description`
   - `docs/topic-name`
   - `refactor/what-changed`
3. Keep the change focused and update documentation when behavior changes.
4. Run formatting, analysis and tests locally.
5. Open a pull request using the repository template.

Example:

```bash
git checkout -b fix/background-return-flash
flutter pub get
dart format .
flutter analyze --no-fatal-infos --no-fatal-warnings
flutter test
```

## iOS-specific validation

For changes that affect the iOS release path, test on iOS/iPadOS 18+ whenever practical. Pay particular attention to:

- external-folder/document access;
- deeplinks and installed-emulator detection;
- first-run linking flows;
- lifecycle transitions and audio/video playback;
- custom background and menu-music persistence;
- landscape/gamepad navigation;
- unsigned release builds and generated Xcode configuration.

The `ios/` scaffold is generated locally rather than stored in this repository. See `README.md` for the bootstrap/build sequence.

## Code conventions

- **Files and folders:** `snake_case`.
- **Variables and functions:** `camelCase`.
- **Classes and widgets:** `PascalCase`.
- Prefer `Color.withValues(alpha: …)` over deprecated `withOpacity()`.
- Check `mounted` before using `BuildContext` after an `await`.
- Follow the surrounding `flutter_screenutil` sizing convention.
- Keep source comments/documentation in **English**.
- Route user-visible text through the localization system rather than hardcoding one language.
- Never commit `.env`, developer credentials, signing data or other secrets.

## Architecture

The main layers are:

- **`lib/screens/`** — application screens and top-level UI composition.
- **`lib/widgets/`** — reusable UI.
- **`lib/providers/`** — application state with `ChangeNotifier`/Provider.
- **`lib/services/`** — business logic, APIs and platform integrations.
- **`lib/sync/`** — synchronization orchestration.
- **`lib/repositories/`** — persisted data access abstraction.
- **`lib/data/datasources/`** — direct SQLite/raw persistence.
- **`lib/models/`** — data models.
- **`lib/utils/`** — shared helpers.
- **`packages/`** — vendored/local Flutter workspace packages.

Read [`ARCHITECTURE.md`](ARCHITECTURE.md) before making cross-layer changes.

## Commit format

Use concise [Conventional Commits](https://www.conventionalcommits.org/) style where practical:

- `feat`: new behavior;
- `fix`: bug fix;
- `docs`: documentation only;
- `refactor`: behavior-preserving code restructuring;
- `perf`: performance improvement;
- `test`: test changes;
- `chore`: build/tooling/repository maintenance.

Examples:

```text
fix(ios): keep custom background mounted across tabs
feat(theme): add main-menu music selection
docs: refresh iOS build instructions
```

## Tests

- Add unit tests for business logic in `test/` when feasible.
- Use `flutter_test` for widget tests.
- Run the complete suite before submitting:

```bash
flutter test
```

## Assets and licensing

New artwork, fonts, audio, video or bundled third-party material must have redistribution terms compatible with the project. Preserve required notices and do not commit proprietary or unlicensed material.

## License

By contributing to this repository, you agree that your contributions are distributed under the **GNU General Public License v3.0 (GPL-3.0)** as applicable to this project.
