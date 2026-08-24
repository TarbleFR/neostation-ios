# NeoStation Theme and Menu Customization Guide

NeoStation separates three different customization systems:

1. **UI color themes** — Flutter `ThemeData` definitions under `lib/themes/`.
2. **System Art packs** — downloadable system-card artwork and logos managed by NeoAssets.
3. **Main-menu media** — a user-selected Systems-menu background and optional menu-music track.

These systems are intentionally independent. Changing a color theme does not replace a System Art pack, and a custom menu background/music selection does not become part of `ThemeData`.

## UI color themes

Built-in color themes are registered through `ThemeProvider` and `AppThemes`. A theme should provide a coherent Material color scheme, readable text/surface contrast and consistent component colors.

### File placement

Create a theme file under:

```text
lib/themes/
```

Follow the naming/style used by the existing `*_theme.dart` files rather than introducing a second theme architecture.

### Registration

A built-in theme must be exposed through the existing theme registry and added to both the theme map and display-name map used by `ThemeProvider`.

Keep identifiers stable once shipped because the selected theme name is persisted in user configuration.

### Design checklist

- Maintain readable foreground/background contrast.
- Keep primary actions visually distinct from passive surfaces.
- Test focused/selected gamepad states, not only pointer/touch states.
- Test disabled, error and success surfaces.
- Review the theme on the main Systems screen, Settings and modal/dialog surfaces.
- Prefer the established corner-radius, typography and responsive-sizing conventions.
- Do not hardcode user-visible labels inside theme widgets.

## Imported custom UI themes

NeoStation can also load user-imported custom color themes. Imported theme IDs must not collide with built-in/reserved theme names. Deleting the active imported theme must safely fall back to a built-in/system theme.

## System Art packs

System Art packs are not UI color themes. They provide downloadable artwork used by system cards and related presentation surfaces. Their manifest/cache code may still contain historical `theme` naming; do not merge those concepts with `ThemeProvider`.

## Main-menu custom background

The primary Systems menu can use a user-selected background. Supported formats are defined by `ImageUtils`:

- static/animated image: PNG, JPG/JPEG, WebP, GIF;
- local video: MP4, M4V, MOV.

The selected file is copied into NeoStation's user-data area. The background is deliberately scoped to the primary Systems menu; game playlists and other top-level screens keep their normal theme background.

The background widget is kept mounted across top-level tab changes so a decoded image can be shown immediately when returning to Systems instead of briefly exposing the underlying theme surface.

## Main-menu music

Theme settings also allow one user-selected menu-music track. Supported formats are:

- MP3;
- WAV;
- OGG;
- FLAC.

The selected track is copied into NeoStation user data and loops only while the primary Systems menu is active. Playback stops when the app leaves the menu or is backgrounded, and it yields when the normal music player is already playing.

## Contribution guidance

Before submitting a visual change:

1. run `dart format` on changed Dart files;
2. run `flutter analyze --no-fatal-infos --no-fatal-warnings`;
3. run `flutter test`;
4. verify landscape layout and gamepad focus behavior;
5. confirm new artwork/audio/video has compatible redistribution terms.

See [`ARCHITECTURE.md`](ARCHITECTURE.md) for code-layer ownership and [`CONTRIBUTING.md`](CONTRIBUTING.md) for the repository contribution workflow.

_Last updated: August 2026._
