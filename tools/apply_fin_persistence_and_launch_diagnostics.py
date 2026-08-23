from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
DB = ROOT / "lib/data/datasources/sqlite_database_service.dart"
FIN = ROOT / "lib/services/fin_library_service.dart"
TEST = ROOT / "test/fin_persistence_regression_test.dart"

# 1) Physical ROM scans must never prune Fin virtual rows.
text = DB.read_text(encoding="utf-8")
old = """    return lowerPath.startsWith('armsx2://') ||\n        lowerPath.startsWith('melonx://') ||\n        lowerPath.startsWith('rpcs3-library://');\n"""
new = """    return lowerPath.startsWith('armsx2://') ||\n        lowerPath.startsWith('melonx://') ||\n        lowerPath.startsWith('rpcs3-library://') ||\n        lowerPath.startsWith('fin://');\n"""
if old in text:
    text = text.replace(old, new, 1)
elif "lowerPath.startsWith('fin://')" not in text:
    raise RuntimeError('Could not patch persistent external-library paths')
DB.write_text(text, encoding="utf-8")

# 2) On iOS, don't gate Fin startup restore on Dart Directory.exists().
# Security-scoped/provider-backed folders can be readable by the native plugin
# while reporting false to Dart after a cold launch.
text = FIN.read_text(encoding="utf-8")
old = """    final root = await _resolveLinkedGamesRoot();\n    if (root != null && await Directory(root).exists()) {\n      try {\n        final discovery =\n            await _discoverLibraryNatively(root, allowTitleLookup: false) ??\n            await discoverLibrary(root);\n        await _importIntoNeoStation(discovery.games);\n        await _replaceCache(discovery.games, skipped: discovery.skipped);\n        await configProvider.refreshDetectedSystems();\n        await databaseProvider.loadDatabase();\n        _log.i(\n          'FinLibraryService: reconciled ${discovery.games.length} live game(s) '\n          'after database initialization.',\n        );\n        return;\n      } catch (error) {\n        _log.w('FinLibraryService: live startup reconcile failed: $error');\n      }\n    }\n"""
new = """    final root = await _resolveLinkedGamesRoot();\n    if (root != null) {\n      try {\n        final nativeDiscovery = await _discoverLibraryNatively(\n          root,\n          allowTitleLookup: false,\n        );\n        final discovery = nativeDiscovery ??\n            (await Directory(root).exists() ? await discoverLibrary(root) : null);\n        if (discovery != null) {\n          await _importIntoNeoStation(discovery.games);\n          await _replaceCache(discovery.games, skipped: discovery.skipped);\n          await configProvider.refreshDetectedSystems();\n          await databaseProvider.loadDatabase();\n          _log.i(\n            'FinLibraryService: reconciled ${discovery.games.length} live game(s) '\n            'after database initialization.',\n          );\n          return;\n        }\n      } catch (error) {\n        _log.w('FinLibraryService: live startup reconcile failed: $error');\n      }\n    }\n"""
if old in text:
    text = text.replace(old, new, 1)
elif "final nativeDiscovery = await _discoverLibraryNatively(" not in text:
    raise RuntimeError('Could not patch Fin cold-start restore')

# 3) Record exactly what NeoStation hands to the Shortcut. This distinguishes
# a NeoStation payload problem from Fin's App Intent entity/query behaviour.
old_launch = """    try {\n      return await IosShortcutJitLaunchService.run(\n        shortcutName: IosShortcutJitLaunchService.finShortcutName,\n        input: input,\n      );\n    } catch (error) {\n      _log.e('FinLibraryService: Shortcut launch failed: $error');\n      return false;\n    }\n"""
new_launch = """    await _writeLaunchDebugFile(\n      'ROM path: $romPath\\n'\n      'Relative path: ${relativePath ?? '-'}\\n'\n      'Shortcut input (Nintendo Game ID): $input',\n    );\n\n    try {\n      final launched = await IosShortcutJitLaunchService.run(\n        shortcutName: IosShortcutJitLaunchService.finShortcutName,\n        input: input,\n      );\n      await _writeLaunchDebugFile(\n        'ROM path: $romPath\\n'\n        'Relative path: ${relativePath ?? '-'}\\n'\n        'Shortcut input (Nintendo Game ID): $input\\n'\n        'Shortcuts handoff opened: $launched',\n      );\n      return launched;\n    } catch (error) {\n      await _writeLaunchDebugFile(\n        'ROM path: $romPath\\n'\n        'Relative path: ${relativePath ?? '-'}\\n'\n        'Shortcut input (Nintendo Game ID): $input\\n'\n        'Shortcut launch error: $error',\n      );\n      _log.e('FinLibraryService: Shortcut launch failed: $error');\n      return false;\n    }\n"""
if old_launch in text:
    text = text.replace(old_launch, new_launch, 1)
elif "Shortcut input (Nintendo Game ID)" not in text:
    raise RuntimeError('Could not patch Fin launch diagnostics')

anchor = """  static Future<void> _writeDebugFile(String content) async {\n"""
helper = """  static Future<void> _writeLaunchDebugFile(String content) async {\n    try {\n      final docs = await getApplicationDocumentsDirectory();\n      final file = File(path.join(docs.path, 'fin_launch_debug.txt'));\n      await file.writeAsString(\n        '--- ${DateTime.now().toIso8601String()} ---\\n$content',\n      );\n    } catch (error) {\n      _log.w('FinLibraryService: could not write launch diagnostics: $error');\n    }\n  }\n\n"""
if helper.strip() not in text:
    if anchor not in text:
        raise RuntimeError('Could not add Fin launch debug helper')
    text = text.replace(anchor, helper + anchor, 1)
FIN.write_text(text, encoding="utf-8")

TEST.write_text("""import 'dart:io';\n\nimport 'package:flutter_test/flutter_test.dart';\nimport 'package:neostation/data/datasources/sqlite_database_service.dart';\n\nvoid main() {\n  group('Fin cold-start persistence', () {\n    test('Fin virtual rows survive normal physical ROM scans', () {\n      expect(\n        SqliteDatabaseService.isPersistentExternalLibraryPath(\n          'fin://launch?system=wii&id=RMCP01&game=Mario%20Kart%20Wii.rvz',\n        ),\n        isTrue,\n      );\n      expect(\n        SqliteDatabaseService.isPersistentExternalLibraryPath('/roms/wii/game.rvz'),\n        isFalse,\n      );\n    });\n\n    test('Fin startup restore is native-first on iOS', () {\n      final source = File('lib/services/fin_library_service.dart').readAsStringSync();\n      expect(source, contains('final nativeDiscovery = await _discoverLibraryNatively('));\n      expect(\n        source,\n        isNot(contains('if (root != null && await Directory(root).exists())')),\n      );\n    });\n\n    test('Fin writes the exact Shortcut payload to a diagnostic file', () {\n      final source = File('lib/services/fin_library_service.dart').readAsStringSync();\n      expect(source, contains('fin_launch_debug.txt'));\n      expect(source, contains('Shortcut input (Nintendo Game ID)'));\n    });\n  });\n}\n""", encoding="utf-8")

print('Applied Fin cold-start persistence fix and Shortcut launch diagnostics.')
