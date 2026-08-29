import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/ios_linked_library_path_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'replaces a previous resolved RetroArch path after iOS path churn',
    () async {
      SharedPreferences.setMockInitialValues({
        IosLinkedLibraryPathService.retroArchPathKey: '/old/provider/RetroArch',
      });

      final result = await IosLinkedLibraryPathService.reconcile(
        configuredFolders: const ['/roms', '/old/provider/RetroArch'],
        retroArchPath: '/new/provider/RetroArch',
        manicEmuPath: null,
      );

      expect(result, const ['/roms', '/new/provider/RetroArch']);
    },
  );

  test(
    'unreadable linked root is detected without deleting anything',
    () async {
      final missing =
          '${Directory.systemTemp.path}/neostation-missing-linked-root';
      final unavailable = await IosLinkedLibraryPathService.unreadableFolders([
        missing,
      ]);
      expect(unavailable, [missing]);
    },
  );
}
