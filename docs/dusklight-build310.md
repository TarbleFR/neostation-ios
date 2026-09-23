# Build 310 — Ports library

Ports opens the normal playlist even when empty. The old recursive-scan empty
screen is bypassed for this iOS library. The top-right import action is labelled
Dusklight, including inside the shared game-details tab bar.

Import uses the existing embedded Dolphin DiscIO identity reader without
starting emulation or JIT. Only Twilight Princess disc IDs already supported by
the Dusklight host are accepted, including compressed images. The scanner stores
the disc ID and the Twilight Princess — Dusklight display title. Rescans preserve
favorites and play time; imported files retain the atomic copy/rename path.

Individual scraping, manuals and batch scraping resolve the source console per
disc: GameCube 13, Wii 16. Metadata/media stay associated with the Ports row and
directory. The normal configured ScreenScraper media types include artwork and
video. Newly imported games are displayed before optional authenticated scraping
runs asynchronously. Without credentials or network access, the local game
remains available; the ordinary scrape action can be used later.

Native engines retain Build 309's pinned identities. DusklightCore is still not
included: this build does not claim to execute the native port. See the embedding
review for the native lifecycle work still required.

## Category artwork

Bundled asset: `assets/images/ports-gaming.webp`. Generated with the built-in
image-generation tool, then encoded as WebP for the application bundle. Original
prompt: square premium gaming-library category illustration; a recognizable
modern controller emerging from a luminous portal; pixel fragments becoming
smooth 3D geometry; dark indigo, teal and warm golden lighting; readable as a
thumbnail, full bleed, no lettering/logos/UI/watermark, dark lower fifth for the
app's own label. This is category artwork, not a substitute Twilight Princess
cover. User/theme artwork keeps priority.

## Validation

New tests cover all supported regional disc IDs, wrong titles, inconsistent
platforms, unreadable discs, Ports scraper configuration, a real SQLite scan
and rescan preserving preferences, twelve-language empty-state text, and narrow
tab-bar layouts. The import-width source contract now tests the configurable
width while retaining the original default for other engines.
