import 'dart:async';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:neostation/providers/icloud_save_provider.dart';
import 'package:neostation/services/cloud_saves/cloud_folder_access.dart';
import 'package:neostation/services/cloud_saves/save_snapshot.dart';
import 'package:neostation/services/cloud_saves/save_source_registry.dart';

/// Real snapshot bytes with a fake file-provider transport. These tests do not
/// claim to exercise an authenticated Apple Account or real iCloud replication.
class TestFolder extends CloudFolderAccess {
  final Directory temp;
  bool connected = false, enabled = false, offline = false, uploaded = false, recoveryBlocked = false;
  String scope = 'folder-A';
  int uploads = 0, counter = 0;
  Completer<void>? holdPut;
  Completer<void>? enteredPut;
  final Map<String, Map<String,dynamic>> rows = {};
  final Map<String, File> bytes = {};
  final List<Map<String,String>> deleted = [];
  TestFolder(this.temp);
  @override Future<Map<String,dynamic>> call(String method,[Map<String,dynamic> arguments=const {}]) async {
    switch(method) {
      case 'status': return {'connected':connected,'enabled':enabled,'scope':connected?scope:''};
      case 'connect': connected=true;enabled=true;return {};
      case 'setEnabled': enabled=arguments['enabled']==true;return {};
      case 'disconnect': connected=false;enabled=false;return {};
      case 'recoverRestores':
        if(recoveryBlocked) throw PlatformException(code:'RECOVERY_REQUIRED');
        return {};
      case 'list':
        if(offline) throw PlatformException(code:'PENDING',message:'Offline');
        return {'pending':0,'invalid':0,'deleted':deleted,'revisions':[
          for(final row in rows.entries) {'manifest':row.value,'path':'${row.key}.json','state':uploaded?'uploaded':'pending'}
        ]};
      case 'put':
        enteredPut?.complete();
        await holdPut?.future;
        if(offline) throw PlatformException(code:'PENDING');
        if(!enabled || arguments['scope']!=scope) throw PlatformException(code:'ACCOUNT_CHANGED');
        final manifest=Map<String,dynamic>.from(arguments['manifest'] as Map);
        final id='${manifest['directory']}/${manifest['payloadHash']}';
        final copy=await File(arguments['source'] as String).copy('${temp.path}/remote-${counter++}');
        expect(await SaveSnapshot.hash(copy),manifest['payloadHash']);
        rows[id]=manifest;bytes[id]=copy;uploads++;
        return {'state':'pending'};
      case 'stageSource':
        final dir=await Directory('${temp.path}/stage-${counter++}').create();
        final original=File(arguments['source'] as String);
        final dest=await original.copy('${dir.path}/data');
        await dest.setLastModified((await original.stat()).modified);
        return {'path':dest.path};
      case 'inspectSource':
        final file=File(arguments['source'] as String);
        return {'fingerprint':await file.exists()?await SaveSnapshot.hash(file):'missing'};
      case 'get':
        final id=(arguments['path'] as String).replaceFirst(RegExp(r'\.nssave$'),'');
        return {'path':(await bytes[id]!.copy('${temp.path}/download-${counter++}.nssave')).path};
      case 'restoreSource':
        final target=File(arguments['target'] as String);
        if(await SaveSnapshot.hash(target)!=arguments['expected']) throw PlatformException(code:'CONFLICT');
        await target.copy('${temp.path}/original-${counter++}');
        await File(arguments['source'] as String).copy(target.path);
        return {'restored':true};
      case 'trash':
        final id=arguments['id'] as String;final row=rows.remove(id)!;
        deleted.add({'unit':row['unit'] as String,'contentHash':row['contentHash'] as String});
        return {};
    }
    throw StateError('Unexpected native call $method');
  }
}
void main(){
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory temp;
  late File native;
  late TestFolder access;
  late SaveSourceRegistry sources;
  late ICloudSaveProvider provider;
  bool playing=false;
  ICloudSaveProvider makeProvider()=>ICloudSaveProvider(access:access,sources:sources,
    supportDirectory:()async=>Directory('${temp.path}/support'),gameIsRunning:()=>playing,loadGames:()async=>[]);
  setUp(()async{
    SharedPreferences.setMockInitialValues({});playing=false;
    temp=await Directory.systemTemp.createTemp('icloud-provider-');
    native=await File('${temp.path}/Mcd001.ps2').writeAsString('native-A');
    await native.setLastModified(DateTime.utc(2025,4,12));
    access=TestFolder(temp);sources=SaveSourceRegistry(builtIns:false);
    sources.register('ARMSX2',()async=>[NativeSaveUnit(key:'ARMSX2/PlayStation 2/Shared/MemoryCards/Mcd001.ps2',
      emulator:'ARMSX2',system:'PlayStation 2',owner:'Shared',title:'Shared card',kind:'MemoryCards',source:native.path)]);
    provider=makeProvider();await provider.initialize();
  });
  tearDown(()async{provider.dispose();await temp.delete(recursive:true);});
  Future<List<File>> outbox() async {
    final dir=Directory('${temp.path}/support/ICloudSaves/outbox/folder-A');
    return !await dir.exists()?[]:await dir.list().where((e)=>e is File && e.path.endsWith('.nssave')).cast<File>().toList();
  }
  test('disabled until actual folder authorization; native save remains usable',()async{
    expect(provider.isAuthenticated,isFalse);
    expect((await provider.fullSync()).success,isFalse);
    expect(access.uploads,0);expect(await native.readAsString(),'native-A');
    expect((await provider.login()).success,isTrue);
    expect(provider.isAuthenticated,isTrue);
  });
  test('backup lists actual revision and native date without claiming upload completion',()async{
    await provider.login();expect((await provider.fullSync()).success,isTrue);
    expect(access.uploads,1);expect(provider.revisions.single.transferState,'pending');
    expect(provider.revisions.single.modified,DateTime.utc(2025,4,12));
    expect((await outbox()).length,1);
    await provider.fullSync();expect(access.uploads,1);
    access.uploaded=true;await provider.refresh();
    expect(provider.revisions.single.transferState,'uploaded');expect(await outbox(),isEmpty);
  });
  test('offline startup retains durable outbox for the next launch',()async{
    await provider.login();access.offline=true;
    expect((await provider.fullSync()).success,isFalse);expect((await outbox()).length,1);expect(access.uploads,0);
    provider.dispose();provider=makeProvider();await provider.initialize();
    access.offline=false;await provider.onAppStart();
    expect(access.uploads,1);expect(provider.revisions.length,1);
  });
  test('native byte changes create separate revisions; no native overwrite',()async{
    await provider.login();await provider.fullSync();
    await native.writeAsString('native-B');await provider.fullSync();
    expect(access.uploads,2);expect(provider.revisions.length,2);
    expect(await native.readAsString(),'native-B');
  });
  test('failed cloud refresh retains known inventory',()async{
    await provider.login();await provider.fullSync();
    access.offline=true;await expectLater(provider.refresh(),throwsA(isA<PlatformException>()));
    expect(provider.revisions.length,1);
  });
  test('different folder does not drain the previous private outbox',()async{
    await provider.login();access.offline=true;await provider.fullSync();
    expect((await outbox()).length,1);
    // No available native sources for the newly selected account/folder.
    access.offline=false;access.scope='folder-B';sources=SaveSourceRegistry(builtIns:false);
    provider.dispose();provider=makeProvider();await provider.initialize();await provider.fullSync();
    expect(access.uploads,0);expect((await outbox()).length,1);
  });
  test('feature disable cancels an in-flight cloud publish and preserves native bytes',()async{
    await provider.login();access.holdPut=Completer<void>();access.enteredPut=Completer<void>();
    final work=provider.fullSync();await access.enteredPut!.future;
    await provider.setEnabled(false);access.holdPut!.complete();await work;
    expect(access.uploads,0);expect(await native.readAsString(),'native-A');expect((await outbox()).length,1);
  });
  test('running game defers backup and refuses restoration',()async{
    await provider.login();await provider.fullSync();playing=true;
    await native.writeAsString('native-B');await provider.fullSync();
    expect(access.uploads,1);
    expect((await provider.restoreRevision(provider.revisions.first.id)).success,isFalse);
    expect(await native.readAsString(),'native-B');
  });
  test('explicit restore replays a complete verified native revision',()async{
    await provider.login();await provider.fullSync();final id=provider.revisions.single.id;
    await native.writeAsString('native-B');
    expect((await provider.restoreRevision(id)).success,isTrue);
    expect(await native.readAsString(),'native-A');
    expect((await temp.list().where((e)=>e.path.contains('original-')).toList()).length,1);
  });
  test('removing a revision never removes a native save or republishes unchanged bytes',()async{
    await provider.login();await provider.fullSync();
    expect((await provider.deleteRemote(provider.revisions.single.id)).success,isTrue);
    expect(await native.readAsString(),'native-A');
    await provider.fullSync();expect(access.uploads,1);expect(provider.revisions,isEmpty);
    await native.writeAsString('native-C');await provider.fullSync();expect(access.uploads,2);
  });
  test('unresolved restore recovery blocks new backups instead of uploading partial data',()async{
    await provider.login();access.recoveryBlocked=true;
    expect((await provider.fullSync()).success,isFalse);expect(access.uploads,0);
    expect(provider.sourceWarnings.containsKey('Recovery'),isTrue);
  });
}
