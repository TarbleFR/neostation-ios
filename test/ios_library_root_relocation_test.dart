import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/ios_library_root_relocation.dart';

/// Saved library folders found again after iOS moved an app container: the
/// files did not move, only the container's UUID changed.
void main() {
  const oldOwn = '/private/var/mobile/Containers/Data/Application/247E7CB5-3272-44D3-B641-9D41F3CBCB69';
  const olderOwn = '/var/mobile/Containers/Data/Application/0F1E2D3C-4B5A-6978-8A9B-ACBDCEDFE0F1';
  const newOwn = '/var/mobile/Containers/Data/Application/9A8B7C6D-5E4F-4031-8293-A4B5C6D7E8F9';
  const oldRetroArch = '/private/var/mobile/Containers/Data/Application/11111111-2222-4333-8444-555555555555';
  const newRetroArch = '/private/var/mobile/Containers/Data/Application/66666666-7777-4888-9999-AAAAAAAAAAAA';

  Future<bool> Function(String) existing(Set<String> folders) => (folder) async => folders.contains(folder);

  test('NeoStation\'s own roms folder is found in its new container', () async {
    final folders = await IosLibraryRootRelocation.relocate(
      ['$oldOwn/Documents/roms'],
      containers: [newOwn, newRetroArch],
      exists: existing({'$newOwn/Documents/roms'}),
    );
    expect(folders, ['$newOwn/Documents/roms']);
  });

  test('the linked folder is found in the container its bookmark resolved to', () async {
    final folders = await IosLibraryRootRelocation.relocate(
      ['$oldRetroArch/Documents/RetroArch/Bibliothèques /roms'],
      containers: [newOwn, newRetroArch],
      exists: existing({'$newRetroArch/Documents/RetroArch/Bibliothèques /roms'}),
    );
    expect(folders, ['$newRetroArch/Documents/RetroArch/Bibliothèques /roms']);
  });

  test('NeoStation\'s container is tried before the linked one', () async {
    final folders = await IosLibraryRootRelocation.relocate(
      ['$oldOwn/Documents/roms'],
      containers: [newOwn, newRetroArch],
      exists: existing({'$newOwn/Documents/roms', '$newRetroArch/Documents/roms'}),
    );
    expect(folders, ['$newOwn/Documents/roms']);
  });

  test('dead copies left by picking the folder again collapse into one', () async {
    final folders = await IosLibraryRootRelocation.relocate(
      [
        '$olderOwn/Documents/roms',
        '$oldRetroArch/Documents/RetroArch/roms',
        '$oldOwn/Documents/roms',
        '$newOwn/Documents/roms',
      ],
      containers: [newOwn, newRetroArch],
      exists: existing({'$newOwn/Documents/roms', '$newRetroArch/Documents/RetroArch/roms'}),
    );
    expect(folders, ['$newOwn/Documents/roms', '$newRetroArch/Documents/RetroArch/roms']);
  });

  test('a folder that still opens, or is found nowhere, is kept as it is', () async {
    final registered = [
      '$newOwn/Documents/roms',
      '$oldRetroArch/Documents/Unplugged drive',
      'content://com.android.externalstorage.documents/tree/primary%3AROMs',
      '/storage/emulated/0/ROMs',
    ];
    final folders = await IosLibraryRootRelocation.relocate(
      registered,
      containers: [newOwn, newRetroArch],
      exists: existing({'$newOwn/Documents/roms'}),
    );
    expect(folders, isNull, reason: 'nothing changes, nothing is saved');
  });

  test('a container itself is never taken for a library folder', () async {
    final folders = await IosLibraryRootRelocation.relocate(
      [oldOwn],
      containers: [newOwn],
      exists: existing({newOwn}),
    );
    expect(folders, isNull);
  });

  test('container paths are recognised with or without /private', () {
    expect(IosLibraryRootRelocation.split('$oldOwn/Documents/roms'),
        (container: oldOwn, relative: 'Documents/roms'));
    expect(IosLibraryRootRelocation.split('$newOwn/Documents/roms/'),
        (container: newOwn, relative: 'Documents/roms'));
    expect(IosLibraryRootRelocation.split('/Users/me/ROMs'), isNull);
  });
}
