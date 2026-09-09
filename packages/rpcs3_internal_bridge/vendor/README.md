# RPCS3 Core provenance

NeoStation does not vendor or redistribute the standalone RPCS3 iOS application UI.
During iOS builds, `build-utils/materialize_rpcs3_internal.py` downloads the pinned
XITRIX RPCS3 iOS 0.8.1 release asset, verifies its published SHA-256, extracts only
`Payload/RPCS3.app/Frameworks/libRPCS3Core.dylib`, verifies the core SHA-256, and
removes the original code signature before NeoStation packaging.

Pinned release: https://github.com/XITRIX/RPCS3-iOS-Releases/releases/tag/v0.8.1
IPA SHA-256: cd6910cb27e41a24cad224e04254f885aa90be176013569d05fb169c322f4522
Core SHA-256: a2053a59c1ea6ee18dd681f5e1ab9d6c991b0cebc32284a891250d0d9c2424a7

The PlayStation 3 firmware is not included. Users must import an official
`PS3UPDAT.PUP` themselves.
