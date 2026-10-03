import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/models/system_model.dart';
import 'package:neostation/services/library_visibility_service.dart';

import 'database_test_helper.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  Future<LibraryVisibilityService> service() async =>
      LibraryVisibilityService(await SharedPreferences.getInstance());

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'fresh install requires one selection and enables no libraries',
    () async {
      final state = await (await service()).initialize(
        existingInstallation: false,
        previouslyVisibleFolders: LibraryVisibilityService.embeddedFolders,
      );
      expect(state.setupCompleted, isFalse);
      expect(state.existingInstallation, isFalse);
      expect(state.enabledFolders, isEmpty);
      expect(state.isVisible('ps3'), isFalse);
      expect(state.isVisible('all'), isFalse);
    },
  );

  test(
    'interrupted first run stays opt-in after scans create native rows',
    () async {
      await (await service()).initialize(
        existingInstallation: false,
        previouslyVisibleFolders: {},
      );
      final resumed = await (await service()).initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'ps2', 'ports', 'gc'},
      );
      expect(resumed.setupCompleted, isFalse);
      expect(resumed.existingInstallation, isFalse);
      expect(resumed.enabledFolders, isEmpty);
    },
  );

  test(
    'upgrade preserves visible and hidden legacy choices without new consoles',
    () async {
      final migrated = await (await service()).initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'ps3', 'nes', 'switch'},
        existingLibraryFolders: {'ps3', 'nes', 'switch', 'snes'},
      );
      expect(migrated.existingInstallation, isTrue);
      expect(migrated.setupCompleted, isTrue);
      expect(migrated.enabledFolders, {'ps3', 'nes', 'switch'});
      expect(migrated.isVisible('snes'), isFalse);
      expect(migrated.legacyFolders, contains('snes'));
      // A subsequently added curated console never becomes visible by upgrade.
      final loaded = await (await service()).initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'ps3', 'nes', 'switch', 'gba'},
      );
      expect(loaded.enabledFolders, migrated.enabledFolders);
      expect(loaded.isVisible('gba'), isFalse);
    },
  );

  test(
    'toggle and empty completed selection persist across restarts',
    () async {
      final preferences = await service();
      await preferences.save(
        LibraryVisibilitySelection(
          enabledFolders: {'nes', 'ps3'},
          setupCompleted: true,
          legacyFolders: {'switch'},
        ),
      );
      final toggled = preferences
          .read()!
          .withEnabled('nes', false)
          .withEnabled('gc', true);
      await preferences.save(toggled);
      final reloaded = (await service()).read()!;
      expect(reloaded.enabledFolders, {'ps3', 'gc'});
      expect(reloaded.setupCompleted, isTrue);
      expect(reloaded.legacyFolders, {'switch'});
      await preferences.save(
        LibraryVisibilitySelection(enabledFolders: {}, setupCompleted: true),
      );
      expect((await service()).read()!.enabledFolders, isEmpty);
      expect((await service()).read()!.setupCompleted, isTrue);
    },
  );

  test('enabled empty consoles expose Import without invented game counts', () {
    SystemModel model(String folder, [int count = 0]) => SystemModel(
      id: folder,
      folderName: folder,
      realName: folder,
      iconImage: '',
      color: '#000000',
      romCount: count,
    );
    final state = LibraryVisibilitySelection(
      enabledFolders: {'ps2', 'nes'},
      setupCompleted: true,
    );
    final displayed = state.exposeSelectedLibraries(
      detected: [model('nes', 3)],
      available: [model('ps2'), model('nes'), model('ps3'), model('wii')],
    );
    expect(displayed.map((system) => system.folderName), ['nes', 'ps2']);
    expect(displayed.first.romCount, 3);
    expect(displayed.last.romCount, 0);
  });

  test(
    'Mega Drive and Genesis have one checkbox controlling both IDs',
    () async {
      SystemModel model(String folder) => SystemModel(
        id: folder,
        folderName: folder,
        realName: folder,
        iconImage: '',
        color: '#000000',
      );
      final choices = LibraryVisibilitySelection.groupConsoleChoices([
        model('md'),
        model('genesis'),
        model('ps1'),
      ]);
      expect(choices, hasLength(2));
      expect(choices.first.realName, 'Sega Mega Drive / Genesis');
      expect(choices.first.id, 'md');
      var state = LibraryVisibilitySelection(
        enabledFolders: {'genesis', 'ps1'},
        setupCompleted: true,
        legacyFolders: {'genesis'},
      );
      expect(state.isConsoleEnabled('md'), isTrue);
      // Upgrade preserves the exact original folder choice until an explicit
      // toggle, rather than silently enabling another region's library.
      expect(state.enabledFolders, {'genesis', 'ps1'});
      state = state.withConsoleEnabled('md', false);
      expect(state.enabledFolders, {'ps1'});
      state = state.withConsoleEnabled('md', true);
      await (await service()).save(state);
      expect((await service()).read()!.enabledFolders, {
        'md',
        'genesis',
        'ps1',
      });
      expect((await service()).read()!.legacyFolders, {'genesis'});
    },
  );

  test(
    'RetroArch-only and native ports selection do not require JIT pairing',
    () {
      expect(
        LibraryVisibilityService.requiresPairingFor({'nes', 'ps1', 'ports'}),
        isFalse,
      );
      expect(LibraryVisibilityService.requiresPairingFor({}), isFalse);
      for (final folder in ['gc', 'wii', 'ps2', 'ps3']) {
        expect(
          LibraryVisibilityService.requiresPairingFor({'nes', folder}),
          isTrue,
        );
      }
    },
  );

  test(
    'hidden legacy libraries remain eligible after toggle and restart',
    () async {
      final preferences = await service();
      var state = await preferences.initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'switch'},
        existingLibraryFolders: {'switch', 'n64'},
      );
      state = state.withConsoleEnabled('switch', false);
      await preferences.save(state);
      final resumed = (await service()).read()!;
      expect(resumed.enabledFolders, isEmpty);
      expect(resumed.legacyFolders, {'switch', 'n64'});
      expect(resumed.withConsoleEnabled('n64', true).isVisible('n64'), isTrue);
    },
  );

  test(
    'detected-only upgrade marker survives toggles and completed fresh stays fresh',
    () async {
      final preferences = await service();
      final upgraded = await preferences.initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'nes'},
        existingLibraryFolders: {'nes'},
      );
      await preferences.save(upgraded.withConsoleEnabled('nes', false));
      expect((await service()).read()!.existingInstallation, isTrue);

      SharedPreferences.setMockInitialValues({});
      final freshPreferences = await service();
      await freshPreferences.initialize(
        existingInstallation: false,
        previouslyVisibleFolders: {},
      );
      await freshPreferences.save(
        LibraryVisibilitySelection(
          enabledFolders: {'nes'},
          setupCompleted: true,
        ),
      );
      final resumed = await (await service()).initialize(
        existingInstallation: true,
        previouslyVisibleFolders: {'nes', 'ps2'},
      );
      expect(resumed.setupCompleted, isTrue);
      expect(resumed.existingInstallation, isFalse);
      expect(resumed.enabledFolders, {'nes'});

      SharedPreferences.setMockInitialValues({
        LibraryVisibilityService.preferenceKey:
            '{"version":1,"completed":true,"enabled":["nes"]}',
      });
      // Older completed documents must never silently select a new runtime.
      expect((await service()).read()!.existingInstallation, isTrue);
    },
  );

  test(
    'new selection overrides physical hidden flags without changing legacy state',
    () {
      final legacyHidden = {'nes', 'favorites'};
      final state = LibraryVisibilitySelection(
        enabledFolders: {'nes'},
        setupCompleted: true,
      );
      final hidden = state.hiddenFolders(
        available: [
          for (final folder in ['nes', 'snes', 'all', 'favorites'])
            SystemModel(
              id: folder,
              folderName: folder,
              realName: folder,
              iconImage: '',
              color: '#000000',
            ),
        ],
        legacyHidden: legacyHidden,
      );
      expect(hidden, {'snes', 'favorites'});
      expect(legacyHidden, {'nes', 'favorites'});
    },
  );

  test(
    'visibility changes preserve BIOS, saves, ROM files and database records',
    () async {
      final helper = DatabaseTestHelper();
      final db = await helper.setUp();
      final root = await Directory.systemTemp.createTemp('library-visibility-');
      try {
        final files = <File>[
          File('${root.path}/game.nes'),
          File('${root.path}/system.bin'),
          File('${root.path}/save.srm'),
        ];
        for (final file in files) {
          await file.writeAsString(file.path);
        }
        await db.execute(
          'INSERT INTO app_systems (id, real_name, folder_name) '
          "VALUES ('nes', 'NES', 'nes')",
        );
        await db.execute(
          'INSERT INTO user_detected_systems '
          "(app_system_id, actual_folder_name) VALUES ('nes', 'nes')",
        );
        await db.execute(
          'INSERT INTO user_roms (filename, rom_path, app_system_id) '
          "VALUES ('game.nes', ?, 'nes')",
          [files.first.path],
        );
        final preferences = await service();
        await preferences.save(
          LibraryVisibilitySelection(
            enabledFolders: {'nes'},
            setupCompleted: true,
          ),
        );
        await preferences.save(preferences.read()!.withEnabled('nes', false));
        expect(await db.rawQuery('SELECT * FROM user_roms'), hasLength(1));
        expect(
          await db.rawQuery('SELECT * FROM user_detected_systems'),
          hasLength(1),
        );
        for (final file in files) {
          expect(await file.readAsString(), file.path);
        }
        await preferences.save(preferences.read()!.withEnabled('nes', true));
        expect((await service()).read()!.isVisible('nes'), isTrue);
        expect(await db.rawQuery('SELECT * FROM user_roms'), hasLength(1));
      } finally {
        await root.delete(recursive: true);
        await helper.tearDown();
      }
    },
  );
}
