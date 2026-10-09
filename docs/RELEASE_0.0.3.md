# NeoStation iOS 0.0.3 — Build 427

**Libretro emulation cores**, also used by RetroArch, are now **embedded directly in NeoStation iOS**. For supported systems, your games launch inside NeoStation without opening the RetroArch app.

- **BIOS files:** open **Files → On My iPhone/iPad → NeoStation → Libretro → System** and add your BIOS files, just as you did in RetroArch’s `system` folder. Keep the filenames and subfolders required by each core. No BIOS files are included.
- **NeoPlay / AirPlay:** streaming is working. The **NeoPlay 0.8.0** Windows receiver is included with this release. Install it on your PC and connect your iPhone/iPad to the same local network.
- **NeoSwap:** the swap system is still a work in progress.
- **Credits and licenses:** notices for all 14 Libretro cores and their support libraries have been added to the license bundle.

## Coming next

More additions are planned for future updates, including **shader support** to customize how your games look, as in RetroArch, and **skins** to personalize the appearance of the on-screen controls.

Thank you to the Libretro and RetroArch teams, all emulator developers, and the NeoStation community for their work, support, and feedback!

## Downloads

- `NeoStation-0.0.3.ipa` — iOS/iPadOS app, internal build 427. Sign it using your usual sideloading tool.
- `NeoPlay-Setup-0.8.0.exe` — Windows installer.
- `NeoStation-0.0.3-Licenses-and-Notices.zip` — licenses and credits.
- `NeoStation-0.0.3-Source-Manifest.md` and the source archives — source and build provenance.
- `NeoStation-0.0.3-SHA256SUMS.txt` — file checksums.

## Release information

Based on build 427 (`6bfc9dd`). The emulator cores and compiled application code are preserved. The package has been updated to display version 0.0.3 and include the notices, then sealed again with ad hoc signatures. Successful build checks do not establish that every game and core has been tested on an iPhone.

Each component remains subject to its own license. Non-commercial conditions and limitations in tracing the exact sources of precompiled binaries are documented in the accompanying files. Adding these notices is not a certification of legal compliance.
