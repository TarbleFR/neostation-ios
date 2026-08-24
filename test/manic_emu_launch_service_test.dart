import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/manic_emu_launch_service.dart';

void main() {
  test('persistent hash matches Manic EMU game identifier', () {
    const sha256OfAbc =
        'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad';

    expect(
      ManicEmuLaunchService.persistentHash(sha256OfAbc),
      '8957039215404510875',
    );
  });
}
