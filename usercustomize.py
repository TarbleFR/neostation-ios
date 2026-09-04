"""One-shot patch of the materializer before source generation.

Dolphin is an in-process native overlay with its own deterministic stop monitor.
Registering it as an external application session would leave the shared
GameSessionManager waiting for an app-background/app-resume transition that
never occurs, potentially blocking the next emulator. Play history is still
recorded through FavoritesService.
"""
from pathlib import Path

root = Path(__file__).resolve().parent
materializer = root / 'build-utils/materialize_dolphin_isolated_v2.py'
if materializer.is_file():
    text = materializer.read_text(encoding='utf-8')
    old = """        GameSessionManager.registerGameLaunch(
          system,
          game,
          'ios_dolphin_internal',
        );
        await FavoritesService.recordGamePlayed(game);
"""
    new = """        // Dolphin owns an in-process session and deterministic native
        // cleanup; do not mutate the external-app lifecycle state machine.
        await FavoritesService.recordGamePlayed(game);
"""
    if old not in text and new not in text:
        raise SystemExit('Dolphin session-state materializer anchor missing')
    text = text.replace(old, new)
    materializer.write_text(text, encoding='utf-8')
Path(__file__).unlink(missing_ok=True)
