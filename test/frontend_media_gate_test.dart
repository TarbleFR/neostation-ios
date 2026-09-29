import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:neostation/services/frontend_media_gate.dart';
import 'package:neostation/services/embedded_ios_session_status.dart';
void main(){
 TestWidgetsFlutterBinding.ensureInitialized();
 test('launch closes every media producer synchronously and awaits disposal',() async {
  final gate=FrontendMediaGate();final disposal=Completer<void>();bool invalidated=false,finished=false;
  gate.register('preview',(){invalidated=true;return disposal.future;});
  final pending=gate.hold('session').then((_){finished=true;});
  expect(gate.blocked,isTrue);expect(invalidated,isTrue);
  await Future<void>.delayed(Duration.zero);expect(finished,isFalse);
  disposal.complete();await pending;expect(finished,isTrue);
  gate.release('session');expect(gate.blocked,isFalse);
 });
 test('late media initialization is stopped while game owns foreground',() async {
  final gate=FrontendMediaGate();await gate.hold('session');int stopped=0;
  gate.register('late',() async {stopped++;});await gate.quiet;expect(stopped,1);
  await gate.hold('nested');gate.release('session');expect(gate.blocked,isTrue);
  gate.release('nested');expect(gate.blocked,isFalse);
  gate.unregister('late');await gate.hold('next');expect(stopped,1);
  gate.release('next');
 });
 for(final entry in {'ios_dolphin_internal':'neostation/dolphin_internal','ios_rpcs3_internal':'neostation/rpcs3_internal'}.entries){
  test(entry.key + ': failed probes never imply exit',() async {
   final channel=MethodChannel(entry.value);bool value=true;bool failure=false;
   TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,(call)async{
    expect(call.method,'isSessionActive');if(failure)throw PlatformException(code:'transient');return value;
   });
   expect(await EmbeddedIOSSessionStatus.isActive(entry.key),isTrue);
   failure=true;expect(await EmbeddedIOSSessionStatus.isActive(entry.key),isTrue);
   failure=false;value=false;expect(await EmbeddedIOSSessionStatus.isActive(entry.key),isFalse);
   TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel,null);
  });
 }
}
