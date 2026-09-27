# NeoStation iOS stable baseline — Build 350

Build 350 is the stable restoration point promoted by the maintainer on
27 September 2026. It supersedes Build 322.

- Packaging source: `5e6dc00b35b7bb7847c24198d9f4b08ade8ed9a0`
- Successful workflow run: `36323843067`
- Workflow job: `108632695296`
- Artifact ID: `10932894067`
- Artifact: `NeoStation-iOS-Build-350-KartPad-Relaunch-Candidate`
- IPA size: `143538718` bytes
- IPA SHA-256: `e1017b96842ec970be3ed0cd981083ee945d069cf76e689a4ca3c81339299b46`

The packaged IPA passed the build-number, donor-identity, language ABI,
session/UIKit gate, lazy-loading, ZIP CRC and ARM64 executable checks. Its
KartPad Core and Runtime match the native artifacts selected by numeric ID; the
other embedded cores and JIT helpers are byte-identical to Build 349.

The physical-device result accepted for this baseline removes the immediate
KartPad relaunch error and the earlier language-change crash. The observed
limitation remains documented: immediately returning from KartPad can leave the
frontend showing the game as running until iOS changes the foreground app.
Future fixes must remain on `experimental` until separately promoted.
