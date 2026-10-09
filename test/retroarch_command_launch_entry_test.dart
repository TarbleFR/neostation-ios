import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/retroarch_library_service.dart';

void main() {
  test('the exported playlist entry identifies a command launch', () {
    expect(
      RetroArchLibraryService.commandLaunchFor({
        'gameId': 'Nintendo - Game Boy Advance.lpl:12',
        'filename': '007.gba',
        'titleId': '007.gba',
        'coreName': 'Nintendo - Game Boy Advance (mGBA)',
        'system': 'Nintendo - Game Boy Advance',
      }),
      {
        'gameId': 'Nintendo - Game Boy Advance.lpl:12',
        'filename': '007.gba',
        'coreName': 'Nintendo - Game Boy Advance (mGBA)',
      },
    );
    expect(
      RetroArchLibraryService.commandLaunchFor({
        'gameId': 'Sony - PlayStation 2.lpl:0',
        'titleId': 'Game.chd',
        'coreName': '',
      }),
      {'gameId': 'Sony - PlayStation 2.lpl:0', 'filename': 'Game.chd'},
    );
  });

  test('entries without a usable playlist index keep the URL route', () {
    for (final entry in <Map<String, dynamic>>[
      {'filename': '007.gba'},
      {'gameId': 'no-index', 'filename': '007.gba'},
      {'gameId': 'x.lpl:first', 'filename': '007.gba'},
      {'gameId': ':3', 'filename': '007.gba'},
      {'gameId': 'x.lpl:3', 'filename': ''},
    ]) {
      expect(RetroArchLibraryService.commandLaunchFor(entry), isNull);
    }
  });
}
