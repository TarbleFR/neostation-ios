import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:external_folder_access/external_folder_access.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../models/game_model.dart';
import '../config_service.dart';
import '../dolphin_system_files.dart';
import '../dolphin_internal_v2_service.dart';
import '../dolphin_save_store.dart';
import '../rpcs3_library_service.dart';
import '../retroarch_config_service.dart';
import 'cloud_folder_access.dart';
import 'save_snapshot.dart';
import 'save_revision.dart';
import 'switch_save_layout.dart';

/// A registered, locally authorized native save unit. A cloud manifest NEVER
/// supplies a native destination. Multi-file saves are snapshotted as a unit.
class NativeSaveUnit {
  final String key, emulator, system, owner, title, kind, source;
  final String? authorizedRoot;
  final DolphinSaveTarget? dolphin;
  const NativeSaveUnit({required this.key, required this.emulator, required this.system,
    required this.owner, required this.title, required this.kind, required this.source, this.dolphin, this.authorizedRoot});
  String get format => dolphin == null ? 'native-v1' : 'dolphin-v2';
  SaveRevision revision(SaveSnapshot snapshot) => SaveRevision(unitKey: key, emulator: emulator,
    system: system, owner: owner, title: title, kind: kind, format: format,
    contentHash: snapshot.contentHash, payloadHash: snapshot.payloadHash, size: snapshot.size,
    modified: snapshot.modified,
    relativeDirectory: SaveRevision.directoryFor(emulator, system, owner, kind, key));

  Future<SaveSnapshot?> snapshot(CloudFolderAccess access, File destination) async {
    final target = dolphin;
    if (target != null) {
      return DolphinInternalV2Service.withSaveAccess((store) async {
        final native = await store.snapshot(target);
        if (native == null) return null;
        await destination.parent.create(recursive: true);
        await native.file.copy(destination.path);
        final hash = await SaveSnapshot.hash(destination);
        return SaveSnapshot(destination, hash, hash, await destination.length(), native.modified);
      });
    }
    final staged = await access.call('stageSource', {'source': source});
    final local = staged['path'] as String;
    try {
      return await SaveSnapshot.createOffMain(local, destination.path, key);
    } finally {
      final directory = Directory(p.dirname(local));
      if (p.basename(directory.path).startsWith('stage-') && await directory.exists()) {
        await directory.delete(recursive: true);
      }
    }
  }

  /// Refuse restoration if the native unit changed since the confirmation.
  Future<String> currentFingerprint(CloudFolderAccess access) async {
    if (dolphin != null) {
      return DolphinInternalV2Service.withSaveAccess((store) async {
        final value = await store.snapshot(dolphin!);
        return value == null ? 'missing' : SaveSnapshot.hash(value.file);
      });
    }
    final result = await access.call('inspectSource', {'source': source});
    return result['fingerprint'] as String;
  }

  Future<void> restore(CloudFolderAccess access, File payload, SaveRevision revision,
      {required String expected, required String scope}) async {
    if (revision.unitKey != key || revision.format != format ||
        await SaveSnapshot.hash(payload) != revision.payloadHash) {
      throw const FormatException('Save unit or checksum mismatch');
    }
    if (dolphin != null) {
      await DolphinInternalV2Service.withSaveAccess((store) async {
        final current = await store.snapshot(dolphin!);
        final actual = current == null ? 'missing' : await SaveSnapshot.hash(current.file);
        if (actual != expected) throw const FileSystemException('Local save changed; confirm again');
        final status = await access.call('status');
        if (status['scope'] != scope || status['enabled'] != true || status['connected'] != true) {
          throw const FileSystemException('Cloud folder changed during restore');
        }
        final bytes = await payload.readAsBytes();
        await store.restore(dolphin!, bytes, checksum: md5.convert(bytes).toString());
      });
      return;
    }
    final staging = Directory('${payload.path}.unpacked');
    try {
      final decoded = await SaveSnapshot.unpackOffMain(payload.path, staging.path,
        key, revision.payloadHash, revision.contentHash);
      await access.call('restoreSource', {'source': decoded.path, 'target': source,
        'expected': expected, 'scope': scope, 'authorizedRoot': authorizedRoot ?? p.dirname(source)});
    } finally {
      if (await staging.exists()) await staging.delete(recursive: true);
    }
  }
}

class SaveDiscovery {
  final List<NativeSaveUnit> units;
  final Map<String, String> warnings;
  const SaveDiscovery(this.units, this.warnings);
}

typedef SaveAdapter = Future<List<NativeSaveUnit>> Function();

/// Extensible registry: future integrations register an adapter, or a user
/// links an explicit Saves folder. Merely installing an app grants no access.
class SaveSourceRegistry {
  final Map<String, SaveAdapter> _adapters = {};
  final Map<String, String> _titles = {};
  final Map<String, DolphinSaveIdentity> _identities = {};
  final Map<String, String> _gameIdentities = {};
  String? nativeIdentity(GameModel game) => _gameIdentities['${game.systemFolderName}/${game.romname}'];
  SaveSourceRegistry({bool builtIns = true}) {
    if (builtIns) {
      register('DolphiniOS', _retryDolphin);
      register('ARMSX2', _armsx2);
      register('MeloNX', _melonx);
      register('RPCS3', _rpcs3);
      register('RetroArch', _retroarch);
      register('Linked folders', _custom);
    }
  }
  void register(String name, SaveAdapter adapter) {
    if (_adapters.containsKey(name)) throw StateError('Duplicate save adapter: $name');
    _adapters[name] = adapter;
  }
  Future<SaveDiscovery> discover() async {
    final units = <String, NativeSaveUnit>{};
    final warnings = <String, String>{};
    for (final entry in _adapters.entries) {
      try {
        for (final unit in await entry.value()) {
          if (units.containsKey(unit.key)) throw StateError('Ambiguous native save identity');
          units[unit.key] = unit;
        }
      } catch (error) { warnings[entry.key] = error.toString(); }
    }
    return SaveDiscovery(units.values.toList(), warnings);
  }
  static bool _junk(String path) => p.split(path).any((v) => v.startsWith('.') ||
    v == '__MACOSX' || v.toLowerCase() == 'thumbs.db');
  static Future<List<File>> _files(String root) async {
    if (!await Directory(root).exists()) return [];
    final files = <File>[];
    final pending = <Directory>[Directory(root)];
    var visited = 0;
    while (pending.isNotEmpty) {
      await for (final entry in pending.removeLast().list(followLinks: false)) {
        if (_junk(p.relative(entry.path, from: root))) continue;
        if (++visited > 30000) throw const FileSystemException('Too many save members');
        await SaveSnapshot.noLinks(root, entry.path);
        if (entry is Directory) pending.add(entry);
        if (entry is File) files.add(entry);
      }
    }
    return files;
  }
  static NativeSaveUnit _unit(String emulator, String system, String owner,
      String kind, String relative, String source, {String? title, String? authorizedRoot}) {
    SaveSnapshot.safeRelative(relative);
    return NativeSaveUnit(key: '$emulator/$system/$owner/$kind/$relative',
      emulator: emulator, system: system, owner: owner, title: title ?? owner,
      kind: kind, source: source, authorizedRoot: authorizedRoot);
  }

  Future<void> remember(GameModel game) async {
    final system = game.systemFolderName;
    final id = game.titleId?.trim();
    if (system == 'switch' && id != null && RegExp(r'^01[0-9a-fA-F]{14}$').hasMatch(id)) {
      _titles['switch/${id.toLowerCase()}'] = game.name;
    }
    if (system == 'ps3' && id != null && RegExp(r'^[A-Z]{4}[0-9]{5}$').hasMatch(id.toUpperCase())) {
      _titles['ps3/${id.toUpperCase()}'] = game.name;
    }
    if (!const {'gc', 'wii'}.contains(system)) return;
    try {
      final id = await DolphinInternalV2Service.readSaveIdentity(game.systemFolderName!, game.romPath ?? '');
      final owner = id.system == 'gc' ? id.gameId : id.titleId!;
      _titles['${id.system}/$owner'] = game.name;
      _identities['${id.system}/${id.gameId}'] = id;
      _gameIdentities['${game.systemFolderName}/${game.romname}'] = owner;
      await (await SharedPreferences.getInstance()).setString('icloud_saves.native_identities', jsonEncode({
        'games': _gameIdentities,
        'identities': [for (final i in _identities.values) {'system': i.system, 'gameId': i.gameId, 'region': i.region, 'titleId': i.titleId}]
      }));
      await (await SharedPreferences.getInstance()).setString('icloud_saves.native_titles', jsonEncode(_titles));
    } catch (_) { /* Identification must never block a local game launch. */ }
  }
  Future<List<NativeSaveUnit>> _retryDolphin() async {
    for (var attempt = 0;; attempt++) {
      try { return await _dolphin(); }
      on DolphinSystemFilesException catch (error) {
        if (error.code != 'busy' || attempt >= 3) rethrow;
        await Future<void>.delayed(Duration(milliseconds: 250 * (1 << attempt)));
      }
    }
  }
  Future<void> loadIdentities() async {
    final prefs = await SharedPreferences.getInstance();
    final text = prefs.getString('icloud_saves.native_identities');
    if (text == null) return;
    try {
      final value = jsonDecode(text) as Map;
      _gameIdentities.addAll(Map<String, String>.from(value['games'] as Map));
      for (final item in value['identities'] as List) {
        final id = DolphinSaveIdentity.fromMap(Map<String, dynamic>.from(item as Map));
        _identities['${id.system}/${id.gameId}'] = id;
      }
    } catch (_) { /* Native IDs must be re-read; never guessed from a title. */ }
  }
  Future<List<NativeSaveUnit>> _dolphin() async {
    if (!Platform.isIOS) return [];
    await loadIdentities();
    final encoded = (await SharedPreferences.getInstance()).getString('icloud_saves.native_titles');
    if (encoded != null) {
      try { _titles.addAll(Map<String, String>.from(jsonDecode(encoded) as Map)); } catch (_) {}
    }
    return DolphinInternalV2Service.withSaveAccess((store) async {
      final targets = <String, DolphinSaveTarget>{};
      final files = <File>[];
      for (final sub in ['GC', 'Wii/title', 'StateSaves']) {
        files.addAll(await _files(p.join(store.userDirectory.path, sub)));
      }
      final identities = <DolphinSaveIdentity>[..._identities.values];
      for (final file in files) {
        final relative = p.relative(file.path, from: store.userDirectory.path).replaceAll('\\', '/');
        final raw = relative.startsWith('GC/') ? DolphinSaveTarget.raw(relative.substring(3)) : null;
        if (raw != null) targets[raw.cloudPath] = raw;
        final gci = RegExp(r'^GC/(USA|EUR|JAP)/Card ([AB])/[^/]+\.gci$', caseSensitive: false).firstMatch(relative);
        if (gci != null && await file.length() >= 64) {
          final input = await file.open();
          String id;
          try { id = ascii.decode(await input.read(6), allowInvalid: true); } finally { await input.close(); }
          final identity = DolphinSaveIdentity(system: 'gc', gameId: id, region: gci[1]!.toUpperCase());
          if (identity.isValid) {
            identities.add(identity);
            for (final target in DolphinSaveTarget.forGame(identity)) {
              if (target.slot == gci[2]!.toUpperCase()) targets[target.cloudPath] = target;
            }
          }
        }
        final wii = RegExp(r'^Wii/title/(0001000[014])/([0-9a-fA-F]{8})/data/.+').firstMatch(relative);
        if (wii != null) {
          final title = '${wii[1]}${wii[2]}'.toLowerCase();
          final gameId = String.fromCharCodes([for (var i = 8; i < 16; i += 2) int.parse(title.substring(i, i + 2), radix: 16)]);
          final identity = DolphinSaveIdentity(system: 'wii', gameId: gameId, region: '', titleId: title);
          identities.add(identity);
          for (final target in DolphinSaveTarget.forGame(identity)) { targets[target.cloudPath] = target; }
        }
      }
      // Disc IDs bind states independently from whether a native save exists.
      for (final file in files) {
        final match = RegExp(r'^([A-Z0-9]{4}(?:[A-Z0-9]{2})?)\.s(0[1-9]|10)$').firstMatch(p.basename(file.path));
        if (p.basename(p.dirname(file.path)) != 'StateSaves' || match == null) continue;
        final id = match[1]!;
        final known = identities.where((e) => e.system == 'gc' ? e.gameId == id : e.gameId.substring(0, 4) == id.substring(0, 4)).toList();
        for (final base in known) {
          final identity = DolphinSaveIdentity(system: base.system, gameId: id, region: base.region, titleId: base.titleId);
          for (final target in DolphinSaveTarget.statesForGame(identity)) {
            if (target.rawName == p.basename(file.path)) targets[target.cloudPath] = target;
          }
        }
      }
      return [for (final target in targets.values) NativeSaveUnit(key: 'DolphiniOS/${target.cloudPath}',
        emulator: 'DolphiniOS', system: target.system == 'gc' ? 'GameCube' : 'Wii',
        owner: target.shared ? 'Shared-${target.region}-${target.slot}' : target.identity,
        title: target.shared ? 'Shared memory card ${target.region} ${target.slot}' :
          (_titles['${target.system}/${target.identity}'] ?? target.identity),
        kind: target.isState ? 'States' : 'Saves', source: await store.nativePath(target), dolphin: target)];
    });
  }

  Future<List<NativeSaveUnit>> _armsx2() async {
    final root = ConfigService.linkedArmsx2FolderPath;
    if (root == null) return [];
    final result = <NativeSaveUnit>[];
    for (final sub in ['memcards', 'sstates', 'savestates']) {
      for (final file in await _files(p.join(root, sub))) {
        final name = p.basename(file.path);
        final card = sub == 'memcards' && name.toLowerCase().endsWith('.ps2');
        final state = sub != 'memcards' && RegExp(r'\.(p2s|state|savestate|p2s\.backup)$', caseSensitive: false).hasMatch(name);
        if (!card && !state) continue;
        final serial = RegExp(r'(?:SL[EUJP]S|SC[EUJP]S)[-_ ]?\d{3}[. _-]?\d{2}', caseSensitive: false).firstMatch(name)?.group(0);
        result.add(_unit('ARMSX2', 'PlayStation 2', card ? 'Shared' : serial ?? 'Unidentified',
          card ? 'MemoryCards' : 'States', p.relative(file.path, from: root), file.path,
          title: card ? 'Shared memory card · $name' : name, authorizedRoot: root));
      }
    }
    return result;
  }
  Future<List<NativeSaveUnit>> _melonx() async {
    final root = ConfigService.linkedMelonxSaveFolderPath;
    if (root == null) return [];
    final saves = <String, NativeSaveUnit>{};
    for (final directory in SwitchSaveLayout.melonxSaveRoots(root)) {
      for (final file in await _files(directory)) {
        final loc = SwitchSaveLayout.melonxSaveLocation(file.path, root);
        if (loc == null) continue;
        saves[loc.saveRoot] = _unit('MeloNX', 'Switch', loc.titleId, 'Saves',
          'profiles/${loc.profileId}/${loc.saveId}', loc.saveRoot, title: _titles['switch/${loc.titleId.toLowerCase()}'] ?? loc.titleId, authorizedRoot: root);
      }
    }
    return saves.values.toList();
  }
  Future<List<NativeSaveUnit>> _rpcs3() async {
    final root = Rpcs3LibraryService.linkedDataPath;
    if (root == null) return [];
    final home = Directory(p.join(root, 'dev_hdd0', 'home'));
    if (!await home.exists()) return [];
    final result = <NativeSaveUnit>[];
    await for (final profile in home.list(followLinks: false)) {
      if (profile is! Directory || !RegExp(r'^\d{8}$').hasMatch(p.basename(profile.path))) continue;
      final saves = Directory(p.join(profile.path, 'savedata'));
      if (!await saves.exists()) continue;
      await for (final save in saves.list(followLinks: false)) {
        if (save is! Directory || _junk(p.basename(save.path))) continue;
        final native = p.basename(save.path);
        result.add(_unit('RPCS3', 'PlayStation 3', native, 'Saves',
          '${p.basename(profile.path)}/$native', save.path, title: _titles['ps3/${native.toUpperCase().substring(0, native.length < 9 ? native.length : 9)}'] ?? native, authorizedRoot: home.path));
      }
    }
    return result;
  }
  Future<List<NativeSaveUnit>> _retroarch() async {
    if (ConfigService.linkedExternalFolderPath == null) return [];
    final config = await RetroArchConfigService().getMergedConfig(forceRefresh: true);
    final result = <NativeSaveUnit>[];
    final directories = {'Saves': config.savefileDirectory, 'States': config.savestateDirectory};
    for (final entry in directories.entries) {
      final root = entry.value;
      if (root == null || root.isEmpty) continue;
      final bundled = <String>{};
      for (final file in await _files(root)) {
        final relative = p.relative(file.path, from: root).replaceAll('\\', '/');
        final psp = RegExp(r'^(.*(?:^|/)PSP/SAVEDATA/([^/]+))(?:/.*)$', caseSensitive: false).firstMatch(relative);
        if (psp != null) {
          if (bundled.add(psp[1]!)) result.add(_unit('RetroArch', 'PSP', psp[2]!, 'Saves', psp[1]!, p.join(root, psp[1]!), authorizedRoot: root));
          continue;
        }
        final name = p.basename(relative);
        final allowed = entry.key == 'States'
          ? RegExp(r'\.(state(?:\d+|\.auto)?|savestate|st\d+)$', caseSensitive: false).hasMatch(name)
          : RegExp(r'\.(srm|sav|eep|fla|rtc|mcr|mcd|vmu|dsv|dat|nv|nvm|brm|sra|gci|ps2)$', caseSensitive: false).hasMatch(name);
        if (!allowed) continue;
        final shared = RegExp(r'\.(mcr|mcd|vmu|ps2)$', caseSensitive: false).hasMatch(name);
        final components = relative.split('/');
        final system = components.length > 1 ? components.first : 'Shared library';
        result.add(_unit('RetroArch', system, shared ? 'Shared' : p.basenameWithoutExtension(name),
          entry.key, relative, file.path, title: shared ? 'Shared memory card · $name' : p.basenameWithoutExtension(name), authorizedRoot: root));
      }
    }
    final systemRoot = config.systemDirectory;
    if (systemRoot != null) {
      for (final file in await _files(p.join(systemRoot, 'dc'))) {
        if (RegExp(r'^vmu_save_[A-D][12]\.bin$', caseSensitive: false).hasMatch(p.basename(file.path))) {
          result.add(_unit('RetroArch', 'Dreamcast', 'Shared', 'MemoryCards',
            p.basename(file.path), file.path, title: 'Shared VMU · ${p.basename(file.path)}', authorizedRoot: p.join(systemRoot, 'dc')));
        }
      }
    }
    return result;
  }

  Future<NativeSaveUnit?> resolveRevision(SaveRevision revision, List<NativeSaveUnit> existing) async {
    final matches = existing.where((u) => u.key == revision.unitKey).toList();
    if (matches.length > 1) throw const FormatException('Ambiguous local save destination');
    if (matches.isNotEmpty) return matches.single;
    if (revision.emulator == 'DolphiniOS' && Platform.isIOS && revision.unitKey.startsWith('DolphiniOS/')) {
      final target = DolphinSaveTarget.parse(revision.unitKey.substring('DolphiniOS/'.length));
      if (target == null || revision.format != 'dolphin-v2' ||
          revision.system != (target.system == 'gc' ? 'GameCube' : 'Wii') ||
          revision.owner != (target.shared ? 'Shared-${target.region}-${target.slot}' : target.identity)) return null;
      return DolphinInternalV2Service.withSaveAccess((store) async => NativeSaveUnit(
        key: revision.unitKey, emulator: 'DolphiniOS', system: revision.system, owner: revision.owner,
        title: revision.title, kind: target.isState ? 'States' : 'Saves', source: await store.nativePath(target), dolphin: target));
    }
    final prefix = '${revision.emulator}/${revision.system}/${revision.owner}/${revision.kind}/';
    if (!revision.unitKey.startsWith(prefix) || revision.format != 'native-v1') return null;
    final relative = revision.unitKey.substring(prefix.length);
    SaveSnapshot.safeRelative(relative);
    String? root;
    String? target;
    if (revision.emulator == 'ARMSX2' && revision.system == 'PlayStation 2') {
      root = ConfigService.linkedArmsx2FolderPath;
      final card = RegExp(r'^memcards/[^/]+\.ps2$', caseSensitive: false).hasMatch(relative);
      final state = RegExp(r'^(sstates|savestates)/[^/]+\.(p2s|state|savestate|p2s\.backup)$', caseSensitive: false).hasMatch(relative);
      if (!(card && revision.kind == 'MemoryCards' && revision.owner == 'Shared' || state && revision.kind == 'States')) return null;
      if (root != null) target = p.join(root, relative);
    } else if (revision.emulator == 'RPCS3' && revision.system == 'PlayStation 3' && revision.kind == 'Saves') {
      final match = RegExp(r'^(\d{8})/([^/]+)$').firstMatch(relative);
      root = Rpcs3LibraryService.linkedDataPath;
      if (match == null || match[2] != revision.owner || _junk(match[2]!)) return null;
      if (root != null) {
        root = p.join(root, 'dev_hdd0', 'home');
        target = p.join(root, match[1]!, 'savedata', match[2]!);
      }
    } else if (revision.emulator == 'RetroArch' && ConfigService.linkedExternalFolderPath != null) {
      final config = await RetroArchConfigService().getMergedConfig(forceRefresh: true);
      if (revision.kind == 'MemoryCards' && revision.system == 'Dreamcast' && revision.owner == 'Shared' &&
          RegExp(r'^vmu_save_[A-D][12]\.bin$', caseSensitive: false).hasMatch(relative)) {
        root = config.systemDirectory == null ? null : p.join(config.systemDirectory!, 'dc');
      } else if (revision.kind == 'Saves' || revision.kind == 'States') {
        root = revision.kind == 'Saves' ? config.savefileDirectory : config.savestateDirectory;
        final ordinary = RegExp(r'\.(srm|sav|eep|fla|rtc|mcr|mcd|vmu|dsv|dat|nv|nvm|brm|sra|gci|ps2|state(?:\d+|\.auto)?|savestate|st\d+)$', caseSensitive: false).hasMatch(relative);
        final psp = RegExp(r'^(?:.*/)?PSP/SAVEDATA/[^/]+$', caseSensitive: false).hasMatch(relative);
        if ((!ordinary && !psp) || _junk(relative)) return null;
      }
      if (root != null) target = p.join(root, relative);
    }
    if (root == null || target == null || !await Directory(root).exists()) return null;
    await SaveSnapshot.noLinks(root, target);
    return NativeSaveUnit(key: revision.unitKey, emulator: revision.emulator, system: revision.system,
      owner: revision.owner, title: revision.title, kind: revision.kind, source: target, authorizedRoot: root);
  }

  static const customKey = 'icloud_saves.linked_sources.v1';
  Future<void> addFolder(String emulator, String system) async {
    emulator = emulator.trim(); system = system.trim();
    if (emulator.isEmpty || system.isEmpty || emulator.length > 100 || system.length > 100) {
      throw const FormatException('An emulator and console name are required');
    }
    final id = sha256.convert(utf8.encode('$emulator/$system')).toString();
    final key = 'cloud-save-source-$id';
    final path = await ExternalFolderAccess.pickAndActivateFolder(key: key);
    if (path == null) return;
    final preferences = await SharedPreferences.getInstance();
    final rows = await customSources();
    rows.removeWhere((e) => e['id'] == id);
    rows.add({'id': id, 'emulator': emulator, 'system': system, 'bookmark': key});
    await preferences.setString(customKey, jsonEncode(rows));
  }
  Future<List<Map<String, String>>> customSources() async {
    final encoded = (await SharedPreferences.getInstance()).getString(customKey);
    if (encoded == null) return [];
    return (jsonDecode(encoded) as List).map((e) => Map<String, String>.from(e as Map)).toList();
  }
  Future<List<NativeSaveUnit>> _custom() async {
    final result = <NativeSaveUnit>[];
    for (final row in await customSources()) {
      final root = await ExternalFolderAccess.resolveBookmarkedFolder(key: row['bookmark']!);
      if (root == null) throw FileSystemException('Reconnect save folder: ${row['emulator']}');
      // Only the explicitly selected save folder is copied, not an app root.
      // Extensions cannot reliably identify opaque/multi-file future saves.
      result.add(_unit(row['emulator']!, row['system']!, 'Shared', 'Saves',
        'linked-${row['id']}', root, title: '${row['emulator']} · ${row['system']}', authorizedRoot: root));
    }
    return result;
  }
}
