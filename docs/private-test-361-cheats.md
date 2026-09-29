# Private candidate 361 — follow-up to the reported RE4 cheats failures

No GitHub Release is created. Release 0.0.1 and its IPA asset remain unchanged.

## Reproductions and fixes

- The user-provided five-line Auto Aim code is an encrypted Action Replay block.
  The prior parser accepted the ASCII block in AR mode, but rejected it in the
  default Gecko mode and rejected typographic dashes/Unicode spaces. Automatic
  unambiguous AR detection and formatting normalization now preserve all lines
  as one code. Raw hexadecimal AR and Gecko still require the appropriate choice.
- The actual native editor and document-picker path are tested on the simulator,
  including the provided five lines, UTF-16 file input, an empty name and an
  invalid fourth line. File I/O, encoding, size and format errors are distinct.
- UTF-8/BOM, UTF-16 BOM, CRLF/CR/Unicode newlines, INI, TXT/AR, and bounded binary
  GCT imports are supported for Dolphin. GCT is imported as one named code block.
- Long-press or swipe a personal cheat to Delete, with confirmation. Removal
  clears the code and activation entries, keeps other codes/preferences, saves a
  backup and reloads the native cheat list. Bundled patches are not deletable.
  PS2 removal deletes only the selected named PNACH section, not adjacent cheats.
- The user-provided block is also passed to the exact pinned upstream Dolphin
  Action Replay decryptor, including its parity and whole-block verification.
- The prior two queried catalogues did not contain RE4 G4BP08. A new exact-GameID
  adapter fetches the primary PAL WIIRD topic by Ralf at gc-forever on demand.
  No source code bytes from that catalogue are packaged in the repository/IPA.
  Incomplete variable codes are skipped, author and source links preserved.
  The source does not identify a disc revision: this uncertainty is shown and
  all imported codes remain disabled until the user enables them.

Primary source: https://www.gc-forever.com/forums/viewtopic.php?t=2145
User code attribution: Nikra / GameHacking.org, game 54624 (European RE4 disc 1).

## Limits

A screenshot alone cannot identify the exact file the tester failed to import.
The supported-format reproductions are automated; arbitrary PDFs, webpages and
unrecognized binary exports are rejected with an explicit format message.
Passing build/simulator/parser tests does not establish device play compatibility
or the in-game effect of a cheat. Already-applied memory changes may require a
restart even after a code is removed. No emulator core or JIT changes are made.
