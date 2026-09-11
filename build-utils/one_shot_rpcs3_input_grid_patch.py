from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]

ABI = ROOT / "packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h"
ABI.write_text(r'''#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef int32_t rpcs3_ios_status;

typedef void (*rpcs3_ios_log_callback)(void* context,
                                       int32_t level,
                                       const char* message);
typedef void (*rpcs3_ios_dispatch_function)(void* context);
typedef void (*rpcs3_ios_dispatch_callback)(
    void* context,
    rpcs3_ios_dispatch_function function,
    void* function_context);
typedef void (*rpcs3_ios_progress_callback)(void* context,
                                            uint32_t current,
                                            uint32_t total,
                                            const char* detail);

typedef struct rpcs3_ios_init_options {
  uint32_t abi_version;
  uint32_t size;
  const char* support_path;
  const char* cache_path;
  rpcs3_ios_log_callback log_callback;
  rpcs3_ios_dispatch_callback dispatch_callback;
  void* context;
  uint32_t expanded_jit_region;
  uint32_t reserved;
} rpcs3_ios_init_options;

typedef struct rpcs3_ios_display_surface {
  uint32_t size;
  uint32_t width;
  uint32_t height;
  float refresh_rate;
  void* metal_layer;
} rpcs3_ios_display_surface;

// Exact byte layout and bit assignments of the pinned XITRIX RPCS3 iOS ABI 30.
// Local names retain the existing NeoStation call sites; comments show upstream names.
typedef enum rpcs3_ios_pad_button_bits {
  rpcs3_ios_pad_up       = 1ull << 0,
  rpcs3_ios_pad_down     = 1ull << 1,
  rpcs3_ios_pad_left     = 1ull << 2,
  rpcs3_ios_pad_right    = 1ull << 3,
  rpcs3_ios_pad_cross    = 1ull << 4,
  rpcs3_ios_pad_circle   = 1ull << 5,
  rpcs3_ios_pad_square   = 1ull << 6,
  rpcs3_ios_pad_triangle = 1ull << 7,
  rpcs3_ios_pad_l1       = 1ull << 8,
  rpcs3_ios_pad_r1       = 1ull << 9,
  rpcs3_ios_pad_l2       = 1ull << 10,
  rpcs3_ios_pad_r2       = 1ull << 11,
  rpcs3_ios_pad_l3       = 1ull << 12,
  rpcs3_ios_pad_r3       = 1ull << 13,
  rpcs3_ios_pad_start    = 1ull << 14,
  rpcs3_ios_pad_select   = 1ull << 15,
  rpcs3_ios_pad_ps       = 1ull << 16,
} rpcs3_ios_pad_button_bits;

typedef struct rpcs3_ios_pad_state {
  uint32_t size;       // upstream: struct_size
  uint32_t connected;
  uint64_t buttons;
  float left_x;        // upstream: left_stick_x
  float left_y;        // upstream: left_stick_y
  float right_x;       // upstream: right_stick_x
  float right_y;       // upstream: right_stick_y
  float l2;            // upstream: left_trigger
  float r2;            // upstream: right_trigger
} rpcs3_ios_pad_state;

typedef struct rpcs3_ios_api {
  void* handle;
  uint32_t (*abi_version)(void);
  const char* (*build_info)(void);
  rpcs3_ios_status (*initialize)(const rpcs3_ios_init_options*);
  const char* (*firmware_version)(void);
  rpcs3_ios_status (*install_firmware)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_package)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_iso)(const char*, const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_zip)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*install_folder)(const char*, rpcs3_ios_progress_callback, void*);
  rpcs3_ios_status (*set_display_surface)(const rpcs3_ios_display_surface*);
  rpcs3_ios_status (*set_pad_state)(uint32_t, const rpcs3_ios_pad_state*);
  rpcs3_ios_status (*boot_game)(const char*, const char*);
  int32_t (*get_emulation_state)(void);
  rpcs3_ios_status (*stop_emulation)(void);
  rpcs3_ios_status (*shutdown)(void);
  const char* (*last_error)(void);
} rpcs3_ios_api;

#ifdef __cplusplus
}
#endif
''')

INPUT = ROOT / "packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm"
text = INPUT.read_text()
if "RPCS3 iOS pad ABI size drift" not in text:
    text = text.replace("#include <math.h>\n", "#include <math.h>\n#include <stddef.h>\n", 1)
    marker = 'static const char* const kRPCS3InputMarker = "NEOSTATION_RPCS3_INPUT_V1";\n'
    assert marker in text
    text = text.replace(marker, marker + '''\nstatic_assert(sizeof(rpcs3_ios_pad_state) == 40, "RPCS3 iOS pad ABI size drift");
static_assert(offsetof(rpcs3_ios_pad_state, size) == 0, "RPCS3 iOS pad struct_size offset drift");
static_assert(offsetof(rpcs3_ios_pad_state, connected) == 4, "RPCS3 iOS pad connected offset drift");
static_assert(offsetof(rpcs3_ios_pad_state, buttons) == 8, "RPCS3 iOS pad buttons offset drift");
static_assert(offsetof(rpcs3_ios_pad_state, left_x) == 16, "RPCS3 iOS pad left stick offset drift");
static_assert(offsetof(rpcs3_ios_pad_state, l2) == 32, "RPCS3 iOS pad trigger offset drift");
''', 1)
text = text.replace(
    "static inline void RPCS3SetBit(uint32_t* bits, uint32_t bit, BOOL pressed) {",
    "static inline void RPCS3SetBit(uint64_t* bits, uint64_t bit, BOOL pressed) {",
    1,
)
text = re.sub(
    r"(?m)^(\s*)_touchState\.size = sizeof\(_touchState\);$",
    r"\1_touchState.size = sizeof(_touchState);\n\1_touchState.connected = 1;",
    text,
)
text = re.sub(
    r"(?m)^(\s*)state\.size = sizeof\(state\);$",
    r"\1state.size = sizeof(state);\n\1state.connected = 1;",
    text,
)
text = text.replace(
'''- (void)clearCorePadState {
  rpcs3_ios_pad_state state = {};
  state.size = sizeof(state);
  state.connected = 1;
  [self sendState:&state];
}''',
'''- (void)clearCorePadState {
  rpcs3_ios_pad_state state = {};
  state.size = sizeof(state);
  state.connected = 0;
  [self sendState:&state];
}''',
1,
)
vis_old = '''  self.touchOverlay.hidden = !showTouch;
  self.touchOverlay.userInteractionEnabled = showTouch;
}'''
vis_new = '''  self.touchOverlay.hidden = !showTouch;
  self.touchOverlay.userInteractionEnabled = showTouch;
  if (showTouch) [self sendTouchState];
}'''
if "if (showTouch) [self sendTouchState];" not in text:
    assert vis_old in text
    text = text.replace(vis_old, vis_new, 1)
assert "uint64_t* bits" in text
assert "state.connected = 1;" in text
assert "_touchState.connected = 1;" in text
INPUT.write_text(text)

FOOTER = ROOT / "lib/widgets/game_view_footer.dart"
footer = FOOTER.read_text()
if "final bool showTitle;" not in footer:
    needle = "  final bool hasVideo;\n\n  const GameViewFooter({"
    assert needle in footer
    footer = footer.replace(
        needle,
        "  final bool hasVideo;\n\n  /// Hide only the scrolling title in console grid mode.\n  final bool showTitle;\n\n  const GameViewFooter({",
        1,
    )
    needle = "    this.hasVideo = false,\n  });"
    assert needle in footer
    footer = footer.replace(needle, "    this.hasVideo = false,\n    this.showTitle = true,\n  });", 1)
    needle = "                MarqueeText(\n                  text: GameUtils.formatGameName(game.name),"
    assert needle in footer
    footer = footer.replace(
        needle,
        "                if (showTitle)\n                  MarqueeText(\n                    text: GameUtils.formatGameName(game.name),",
        1,
    )
FOOTER.write_text(footer)

GRID = ROOT / "lib/screens/game_screen/my_games_grid.dart"
grid = GRID.read_text()
if "showTitle: false," not in grid:
    needle = "    _chromeFooter = GameViewFooter(\n      game: settledGame,"
    assert needle in grid
    grid = grid.replace(needle, "    _chromeFooter = GameViewFooter(\n      game: settledGame,\n      showTitle: false,", 1)
GRID.write_text(grid)

BRIDGE_TEST = ROOT / "test/rpcs3_input_bridge_test.py"
BRIDGE_TEST.write_text(r'''from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PLUGIN = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3InternalBridgePlugin.mm'
INPUT = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/RPCS3GameInputController.mm'
PODSPEC = ROOT / 'packages/rpcs3_internal_bridge/ios/rpcs3_internal_bridge.podspec'

class RPCS3InputBridgeTests(unittest.TestCase):
    def test_pinned_pad_abi(self):
        text = ABI.read_text()
        for token in (
            'uint32_t connected;', 'uint64_t buttons;',
            'rpcs3_ios_pad_cross    = 1ull << 4',
            'rpcs3_ios_pad_circle   = 1ull << 5',
            'rpcs3_ios_pad_square   = 1ull << 6',
            'rpcs3_ios_pad_r1       = 1ull << 9',
            'rpcs3_ios_pad_l2       = 1ull << 10',
            'rpcs3_ios_pad_start    = 1ull << 14',
            'rpcs3_ios_pad_select   = 1ull << 15',
            'rpcs3_ios_status (*set_pad_state)(uint32_t, const rpcs3_ios_pad_state*)',
        ):
            self.assertIn(token, text)

    def test_plugin_loads_pad_symbol(self):
        text = PLUGIN.read_text()
        self.assertIn('LOAD("rpcs3_ios_set_pad_state", set_pad_state);', text)
        self.assertIn('RPCS3GameInputController', text)
        self.assertIn('[controller.inputController start];', text)
        self.assertIn('[controller.inputController stop];', text)

    def test_physical_mapping_and_connected_state(self):
        text = INPUT.read_text()
        self.assertIn('RPCS3SetBit(uint64_t* bits, uint64_t bit', text)
        self.assertIn('rpcs3_ios_pad_cross, pad.buttonA.isPressed', text)
        self.assertIn('rpcs3_ios_pad_circle, pad.buttonB.isPressed', text)
        self.assertIn('rpcs3_ios_pad_square, pad.buttonX.isPressed', text)
        self.assertIn('rpcs3_ios_pad_triangle, pad.buttonY.isPressed', text)
        self.assertIn('state.connected = 1;', text)
        self.assertIn('_api->set_pad_state(0, state);', text)

    def test_touch_is_connected_virtual_pad(self):
        text = INPUT.read_text()
        self.assertIn('BOOL showTouch = self.started && self.physicalController == nil;', text)
        self.assertIn('if (showTouch) [self sendTouchState];', text)
        self.assertIn('_touchState.connected = 1;', text)
        self.assertIn('_touchState.l2 = 1.0f;', text)
        self.assertIn('_touchState.r2 = 1.0f;', text)

    def test_layout_guards(self):
        text = INPUT.read_text()
        self.assertIn('sizeof(rpcs3_ios_pad_state) == 40', text)
        self.assertIn('offsetof(rpcs3_ios_pad_state, connected) == 4', text)
        self.assertIn('offsetof(rpcs3_ios_pad_state, buttons) == 8', text)

    def test_gamecontroller_framework(self):
        self.assertIn("'GameController'", PODSPEC.read_text())

if __name__ == '__main__':
    unittest.main()
''')

ABI_TEST = ROOT / "test/rpcs3_input_abi_test.py"
ABI_TEST.write_text(r'''from pathlib import Path
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
ABI = ROOT / 'packages/rpcs3_internal_bridge/ios/Classes/Rpcs3CoreABI.h'
PINNED = Path(sys.argv[1]) / 'rpcs3/ios/RPCS3IOS.h' if len(sys.argv) > 1 else None

class RPCS3PadABITests(unittest.TestCase):
    def test_local_shape_and_bits(self):
        text = ABI.read_text()
        fields = ['uint32_t size;', 'uint32_t connected;', 'uint64_t buttons;',
                  'float left_x;', 'float left_y;', 'float right_x;', 'float right_y;',
                  'float l2;', 'float r2;']
        positions = [text.index(field) for field in fields]
        self.assertEqual(positions, sorted(positions))
        bits = [('rpcs3_ios_pad_cross', 4), ('rpcs3_ios_pad_circle', 5),
                ('rpcs3_ios_pad_square', 6), ('rpcs3_ios_pad_r1', 9),
                ('rpcs3_ios_pad_l2', 10), ('rpcs3_ios_pad_start', 14),
                ('rpcs3_ios_pad_select', 15)]
        for name, bit in bits:
            pos = text.index(name)
            self.assertIn(f'1ull << {bit}', text[pos:pos + 80])

    def test_pinned_upstream_shape(self):
        if PINNED is None:
            self.skipTest('pinned RPCS3 source path not supplied')
        text = PINNED.read_text()
        for token in ('uint32_t struct_size;', 'uint32_t connected;', 'uint64_t buttons;',
                      'float left_stick_x;', 'float right_stick_y;',
                      'float left_trigger;', 'float right_trigger;',
                      'RPCS3_IOS_PAD_BUTTON_CROSS     = 1ull << 4',
                      'RPCS3_IOS_PAD_BUTTON_R1        = 1ull << 9',
                      'RPCS3_IOS_PAD_BUTTON_START     = 1ull << 14',
                      'RPCS3_IOS_PAD_BUTTON_SELECT    = 1ull << 15'):
            self.assertIn(token, text)

if __name__ == '__main__':
    if len(sys.argv) > 1:
        sys.argv = [sys.argv[0]]
    unittest.main()
''')

WORKFLOW = ROOT / ".github/workflows/build-ipa-once.yml"
workflow = WORKFLOW.read_text()
if "NeoStation iOS Build 242" in workflow:
    workflow = workflow.replace("242", "243")
WORKFLOW.write_text(workflow)

print("one-shot patch applied")
