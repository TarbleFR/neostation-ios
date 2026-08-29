# RiiSU System Art

NeoStation iOS exposes the RiiSU System Art pack as a curated external pack.
The artwork is not bundled into the application binary. NeoStation downloads the
selected system backgrounds on demand from the original RiiSU repository.

## Sources

- RiiSU for NeoStation: https://github.com/mult1v4c/RiiSU
- iiSU Interpreted for ES-DE (credited by RiiSU as the source of the system art): https://github.com/VictorUnlocked/iisu-interpreted-es-de
- iiSU project: https://iisu.network/

RiiSU's own `theme.json` identifies the pack as `RiiSU`, credits `iiSU Network`,
and marks the artwork as non-AI-generated.

## Integration

The upstream RiiSU repository already follows NeoStation's System Art layout:

```text
themes/RiiSU/
├── theme.json
└── backgrounds/
    ├── 3ds.webp
    ├── ps1.webp
    ├── ps2.webp
    ├── ps3.webp
    ├── switch.webp
    ├── wii.webp
    ├── wiiu.webp
    └── ...
```

NeoStation therefore keeps the original assets at their source and only caches
files for systems present in the user's library.

## Redistribution note

No standalone license file was visible in the RiiSU repository when this
integration was added. Keeping the artwork remotely hosted by the original
project avoids copying those binary assets into this repository or the IPA.
Attribution above must be preserved. If the upstream project publishes explicit
redistribution terms later, this note should be updated accordingly.
