from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
origin=ROOT/'test/dolphin_account_267_test.py'
source=origin.read_text().replace("'CLANG_ENABLE_OBJC_ARC': 'YES',", "'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_CXX_LANGUAGE_STANDARD': 'c++20',")
source=source.replace("{'sdk': 'UIKit.framework'}", "{'sdk': 'libz.tbd'}, {'sdk': 'UniformTypeIdentifiers.framework'}, {'sdk': 'UIKit.framework'}")
# Compile the real PS2 editor as its own host translation unit, not a mock.
source=source.replace("(directory / 'main.m').write_text(APP)",
    "(directory / 'main.m').write_text(APP)\n        (directory / 'PS2Editor.mm').write_text('#include \\\"'+str(ROOT/'packages/armsx2_internal_bridge/ios/Classes/ARMSX2ManualCheatEditor.h')+'\\\"\\n#include \\\"'+str(ROOT/'packages/dolphin_internal_bridge/ios/Classes/DOLTextureSettings.h')+'\\\"\\n')")
source=source.replace("'sources': [str(directory / 'main.m'),", "'sources': [str(directory / 'main.m'), str(directory / 'PS2Editor.mm'),")
ns={'__file__':str(origin),'__name__':'cheat_editor_tests'}
exec(compile(source,str(origin),'exec'),ns)
ns['TESTS']=r'''
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#include "NeoCheatStore.h"
#include "NeoCheatLabels.h"
#include "DOLTextureStore.h"
#include "DolphinSessionMenu.h"
@interface DOLManualCheatEditor : UIViewController
@property(nonatomic,copy) NSString* localeIdentifier;
@property(nonatomic,copy) NSDictionary* identity;
@property(nonatomic,copy) void (^saveCheat)(NSDictionary*,void (^)(NSDictionary*));
@property(nonatomic,strong) UITextView* codeField;
@property(nonatomic,strong) UITextField* nameField;
@property(nonatomic,strong) UISegmentedControl* formatControl;
@property(nonatomic,strong) UILabel* errorLabel;
@property(nonatomic,assign) BOOL busy;
@property(nonatomic,assign) BOOL ps2;
@property(nonatomic,assign) BOOL documentImported;
@property(nonatomic,assign) BOOL importMode;
@property(nonatomic,copy) NSArray<NSDictionary*>* previewEntries;
@property(nonatomic,strong) UITableView* previewTable;
@property(nonatomic,strong) UILabel* previewSummary;
@property(nonatomic,copy) void (^savedResult)(NSDictionary*);
- (void)cancelPressed;
- (void)textViewDidChange:(UITextView*)view;
- (void)savePressed;
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls;
@end
@interface CheatEditor361Tests:XCTestCase @end
@implementation CheatEditor361Tests
- (NSDictionary*)identity{return @{@"available":@YES,@"gameId":@"G4BP08",@"revision":@0,@"gecko":@[],@"actionReplay":@[],@"hardcore":@NO};}
- (NSString*)block{return @"6HUF–YY22–P0Y4N\nYP3X–W34H–8N8PU\n7663–4G9D–1BPQZ\n0WGZ–DYX8–MXNED\nGPPV–ZN8B–UVPUX";}
- (void)testActualEditorPastesFiveLinesAutoSelectsARAndSavesWholeBlock {
 DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=@"fr";
 UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:editor];[navigation loadViewIfNeeded];[editor loadViewIfNeeded];
 XCTAssertEqual(editor.formatControl.selectedSegmentIndex,0);
 editor.codeField.text=[self block];[editor textViewDidChange:editor.codeField];
 XCTAssertEqual(editor.formatControl.selectedSegmentIndex,1);XCTAssertTrue([editor.navigationItem.prompt containsString:@"Action Replay"]);
 __block NSDictionary* captured=nil;
 editor.saveCheat=^(NSDictionary* request,void (^completion)(NSDictionary*)){captured=request;completion(@{@"success":@YES});};
 [editor savePressed];XCTAssertNotNil(captured);XCTAssertEqualObjects(captured[@"type"],@"actionReplay");
 auto parsed=NeoCheat::parse([captured[@"content"] UTF8String],[captured[@"type"] UTF8String],[captured[@"name"] UTF8String]);
 XCTAssertTrue(bool(parsed));XCTAssertEqual(parsed.entries.size(),1);XCTAssertEqual(parsed.entries[0].lines.size(),5);
 XCTAssertFalse([captured[@"content"] containsString:@"–"]);
}
- (void)testActualPickerReadsUTF16AndDisplaysAllFiveLines {
 DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=@"fr";
 [editor loadViewIfNeeded];
 NSURL* url=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"G4BP08.txt"]];
 [[self block] writeToURL:url atomically:YES encoding:NSUTF16StringEncoding error:nil];
 [editor documentPicker:nil didPickDocumentsAtURLs:@[url]];
 XCTestExpectation* finished=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings){return !editor.busy;}] object:editor];
 [self waitForExpectations:@[finished] timeout:10];
 XCTAssertEqual(editor.errorLabel.text.length,0);XCTAssertEqual(editor.formatControl.selectedSegmentIndex,1);
 XCTAssertTrue([editor.codeField.text containsString:@"GPPV-ZN8B-UVPUX"]);
 [NSFileManager.defaultManager removeItemAtURL:url error:nil];
}
- (void)testInvalidFourthLineShowsItsNumberWithoutSavingPrefix {
 DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=@"fr";[editor loadViewIfNeeded];
 editor.codeField.text=[[self block] stringByReplacingOccurrencesOfString:@"MXNED" withString:@"MXNE!"];[editor textViewDidChange:editor.codeField];
 __block BOOL called=NO;editor.saveCheat=^(NSDictionary* request,void (^completion)(NSDictionary*)){called=YES;};
 [editor savePressed];XCTAssertFalse(called);XCTAssertTrue([editor.errorLabel.text containsString:@"ligne 4"]);
}

- (NSString*)fiftyCodes:(BOOL)ps2 {
 NSMutableString* file=[NSMutableString string];
 for(int i=0;i<50;++i) {
  if(ps2)[file appendFormat:@"[Cheat %d]\npatch=1,EE,%08X,word,00000001\npatch=1,EE,%08X,word,00000002\n\n",i,i*8,i*8+4];
  else [file appendFormat:@"Cheat %d [Author]\n%08X 00000001\n\n%08X 00000002\n\n",i,0x04000000+i*8,0x04000004+i*8];
 }
 return file;
}
- (void)readFile:(NSURL*)file editor:(DOLManualCheatEditor*)editor {
 [editor documentPicker:nil didPickDocumentsAtURLs:@[file]];
 XCTestExpectation* read=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings){return !editor.busy;}] object:editor];
 [self waitForExpectations:@[read] timeout:10];
}
- (void)testFiftyNamedEntriesFromActualPickerForBothNativeEditors {
 for(NSNumber* ps2 in @[@NO,@YES]) {
  DOLManualCheatEditor* editor=(id)[NSClassFromString(ps2.boolValue?@"ARMSX2ManualCheatEditor":@"DOLManualCheatEditor") new];
  XCTAssertNotNil(editor);editor.ps2=ps2.boolValue;editor.localeIdentifier=@"fr";
  editor.identity=ps2.boolValue?@{@"available":@YES,@"crc":@"12345678",@"serial":@"SLES-00000",@"items":@[],@"hardcore":@NO}:[self identity];
  UIViewController* parent=[UIViewController new];UINavigationController* navigation=[[UINavigationController alloc] initWithRootViewController:parent];
  [navigation pushViewController:editor animated:NO];[navigation loadViewIfNeeded];[editor loadViewIfNeeded];
  NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:ps2.boolValue?@"12345678.pnach":@"cheats.txt"]];
  [[self fiftyCodes:ps2.boolValue] writeToURL:file atomically:YES encoding:NSUTF16StringEncoding error:nil];
  [self readFile:file editor:editor];
  // Importing another TXT must not inherit the preceding canonical INI format.
  [self readFile:file editor:editor];
  XCTAssertEqual(editor.errorLabel.text.length,0);XCTAssertEqual(editor.previewEntries.count,50);
  XCTAssertEqual([editor.previewTable.dataSource tableView:editor.previewTable numberOfRowsInSection:0],50);
  XCTAssertTrue(editor.nameField.hidden);XCTAssertTrue(editor.codeField.hidden);XCTAssertFalse(editor.previewTable.hidden);
  for(UIView* view in @[editor.codeField,editor.previewTable])for(NSLayoutConstraint* c in view.constraints)
    if([c.identifier isEqual:@"cheatManualHeight"] || [c.identifier isEqual:@"cheatBulkPreviewHeight"])
      XCTAssertLessThan(c.priority,UILayoutPriorityRequired);
  XCTAssertTrue([editor.navigationItem.rightBarButtonItem.title containsString:@"50"]);
  for(int i=0;i<50;++i){XCTAssertEqualObjects(editor.previewEntries[i][@"name"],([NSString stringWithFormat:@"Cheat %d",i]));XCTAssertEqual([editor.previewEntries[i][@"lineCount"] intValue],2);}
  __block NSUInteger calls=0;__block void (^finish)(NSDictionary*)=nil;__block NSDictionary* captured=nil;__block NSDictionary* saved=nil;
  editor.savedResult=^(NSDictionary* result){saved=result;};
  editor.saveCheat=^(NSDictionary* request,void (^completion)(NSDictionary*)){++calls;captured=request;finish=[completion copy];};
  [editor savePressed];[editor savePressed];XCTAssertEqual(calls,1);XCTAssertTrue([captured[@"batchImport"] boolValue]);
  auto parsed=NeoCheat::parse(NeoUTF8(captured[@"content"]),NeoUTF8(captured[@"type"]),NeoUTF8(captured[@"name"]));
  XCTAssertTrue(bool(parsed));XCTAssertEqual(parsed.entries.size(),50);
  for(const auto& entry:parsed.entries)XCTAssertEqual(entry.lines.size(),2);
  XCTAssertNotNil(finish);finish(@{@"success":@YES,@"added":@50,@"skipped":@0});
  XCTestExpectation* completed=[[XCTNSPredicateExpectation alloc] initWithPredicate:[NSPredicate predicateWithBlock:^BOOL(id object,NSDictionary* bindings){return !editor.busy;}] object:editor];
  [self waitForExpectations:@[completed] timeout:5];XCTAssertEqual([saved[@"added"] intValue],50);
  [NSFileManager.defaultManager removeItemAtURL:file error:nil];
 }
}
- (void)testInvalidMiddleEntryClearsPreviewAndNeverSavesPrefix {
 DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=@"fr";[editor loadViewIfNeeded];
 NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"broken.txt"]];
 [[self fiftyCodes:NO] writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];[self readFile:file editor:editor];XCTAssertEqual(editor.previewEntries.count,50);
 NSString* broken=[[self fiftyCodes:NO] stringByReplacingOccurrencesOfString:@"040000C8 00000001" withString:@"040000C8 XXXXXXXX"];
 [broken writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];[self readFile:file editor:editor];
 XCTAssertTrue([editor.errorLabel.text containsString:@"ligne"]);XCTAssertEqual(editor.previewEntries.count,0);
 __block BOOL saved=NO;editor.saveCheat=^(NSDictionary* request,void(^completion)(NSDictionary*)){saved=YES;};
 [editor savePressed];XCTAssertFalse(saved);[NSFileManager.defaultManager removeItemAtURL:file error:nil];
}
- (void)testOrdinaryTitlesAndPnachCommentsSurviveActualPickerAndSave {
 for(NSNumber* ps2 in @[@NO,@YES]) {
  DOLManualCheatEditor* editor=(id)[NSClassFromString(ps2.boolValue?@"ARMSX2ManualCheatEditor":@"DOLManualCheatEditor") new];
  editor.ps2=ps2.boolValue;editor.localeIdentifier=@"fr";editor.importMode=YES;
  editor.identity=ps2.boolValue?@{@"available":@YES,@"crc":@"12345678",@"serial":@"SLES-00000",@"items":@[],@"hardcore":@NO}:[self identity];
  [editor loadViewIfNeeded];
  NSString* content=ps2.boolValue?@"[Health]\n\n// writes health\npatch=1,EE,00000000,word,00000001\n\n// continuation\npatch=1,EE,00000004,word,00000002\n[Ammo]\npatch=1,EE,00000008,word,00000003":@"Infinite Grenades\n04000000 00000001\n\n04000004 00000002\nUltimate Strength\n04000008 00000003";
  NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:ps2.boolValue?@"12345678.pnach":@"cheats.txt"]];
  [content writeToURL:file atomically:YES encoding:NSUTF8StringEncoding error:nil];[self readFile:file editor:editor];
  XCTAssertEqual(editor.errorLabel.text.length,0);XCTAssertEqual(editor.previewEntries.count,2);
  XCTAssertEqualObjects(editor.previewEntries[0][@"name"],ps2.boolValue?@"Health":@"Infinite Grenades");
  XCTAssertEqualObjects(editor.previewEntries[1][@"name"],ps2.boolValue?@"Ammo":@"Ultimate Strength");
  XCTAssertEqual([editor.previewEntries[0][@"lineCount"] intValue],2);
  __block NSDictionary* captured=nil;
  editor.saveCheat=^(NSDictionary* request,void(^completion)(NSDictionary*)){captured=request;completion(@{@"success":@YES,@"added":@2});};
  [editor savePressed];XCTAssertNotNil(captured);XCTAssertTrue([captured[@"batchImport"] boolValue]);
  auto parsed=NeoCheat::parse(NeoUTF8(captured[@"content"]),NeoUTF8(captured[@"type"]),NeoUTF8(captured[@"name"]));
  XCTAssertTrue(bool(parsed));XCTAssertEqual(parsed.entries.size(),2);XCTAssertEqual(parsed.entries[0].lines.size(),2);
  [NSFileManager.defaultManager removeItemAtURL:file error:nil];
 }
}
- (void)testCancelDoesNotImportAndBatchLabelsExistInTwelveLanguages {
 for(NSString* language in @[@"en",@"fr",@"de",@"es",@"it",@"pt",@"ru",@"id",@"ja",@"ko",@"zh",@"zh_Hant"]){
  DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=language;[editor loadViewIfNeeded];
  for(NSString* key in @[@"batchPreview",@"batchSave",@"batchLineCount",@"closePreview",@"gctCombined",@"gctSave",@"addCheat",@"emptyBlock",@"batchConflict",@"batchResult"])
    XCTAssertNotEqualObjects(NeoCheatText(key,language),key);
  NSString* message=NeoCheatBatchResult(@{@"added":@48,@"skipped":@2},language);
  XCTAssertTrue([message containsString:@"48"]);XCTAssertFalse([message containsString:@"{added}"]);
  __block BOOL called=NO;editor.saveCheat=^(NSDictionary* request,void(^completion)(NSDictionary*)){called=YES;};[editor cancelPressed];XCTAssertFalse(called);
 }
}
- (void)testReportedGCTHasFourCommandsButNeverInventsFourNames {
 DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.localeIdentifier=@"fr";editor.importMode=YES;
 editor.identity=@{@"gameId":@"GR8P69",@"revision":@0};[editor loadViewIfNeeded];
 XCTAssertTrue(editor.nameField.hidden);XCTAssertTrue(editor.codeField.hidden);XCTAssertFalse(editor.navigationItem.rightBarButtonItem.enabled);
 const unsigned char bytes[]={0x00,0xd0,0xc0,0xde,0x00,0xd0,0xc0,0xde,0x04,0x29,0xf0,0x40,0x3e,0x80,0x01,0xce,0x02,0x00,0xf0,0x6e,0x00,0x00,0xff,0xff,0x04,0x14,0xc9,0x74,0x39,0x20,0x03,0xe7,0x02,0x00,0xf0,0x5e,0x00,0x00,0xff,0xff,0xf0,0,0,0,0,0,0,0};
 NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:@"GR8P69.gct"]];
 [[NSData dataWithBytes:bytes length:sizeof(bytes)] writeToURL:file atomically:YES];[self readFile:file editor:editor];
 XCTAssertEqual(editor.previewEntries.count,1);XCTAssertEqual([editor.previewEntries[0][@"lineCount"] intValue],4);
 XCTAssertEqualObjects(editor.navigationItem.rightBarButtonItem.title,NeoCheatText(@"gctSave",@"fr"));
 XCTAssertFalse([editor.previewSummary.text containsString:@"1 cheats"]);XCTAssertFalse(editor.previewTable.hidden);XCTAssertTrue(editor.codeField.hidden);
 // Named source preserves its actual grouping, including multiple lines in one entry.
 [@"GR8P69\nMedal of Honor\n\nBouncy Ball Mode [Codejunkies]\n0429F040 3E8001CE\n\nTest B\n0200F06E 0000FFFF\n\nTest C\n0414C974 392003E7\n\nTest D\n0200F05E 0000FFFF\n" writeToURL:[file URLByDeletingPathExtension] atomically:YES encoding:NSUTF8StringEncoding error:nil];
 NSURL* txt=[[file URLByDeletingPathExtension] URLByAppendingPathExtension:@"txt"];
 [NSFileManager.defaultManager moveItemAtURL:[file URLByDeletingPathExtension] toURL:txt error:nil];[self readFile:txt editor:editor];
 XCTAssertEqual(editor.previewEntries.count,4);XCTAssertEqualObjects(editor.previewEntries[0][@"name"],@"Bouncy Ball Mode");
 [NSFileManager.defaultManager removeItemAtURL:file error:nil];[NSFileManager.defaultManager removeItemAtURL:txt error:nil];
}
- (void)testDirectMenuImportHasOwnRowAndPreservesFirstToggleIndex {
 DolphinSessionMenu* menu=[DolphinSessionMenu new];menu.labels=@{@"__locale":@"fr"};[menu setValue:@3 forKey:@"page"];
 NSDictionary* identity=@{@"gameId":@"GR8P69",@"revision":@0,@"hardcore":@NO,@"gecko":@[@{@"name":@"Bouncy Ball Mode",@"type":@"gecko",@"index":@0,@"enabled":@NO}],@"actionReplay":@[]};
 [menu setValue:identity forKey:@"cheatsSnapshot"];
 __block NSDictionary* captured=nil;menu.performCheatCommand=^(NSDictionary* r,void(^done)(BOOL,NSDictionary*)){captured=r;done(YES,@{});};
 [menu loadViewIfNeeded];UITableViewCell* import=[menu tableView:menu.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:4 inSection:0]];
 XCTAssertEqualObjects(import.accessibilityIdentifier,@"cheatImportRow");
 [menu tableView:menu.tableView didSelectRowAtIndexPath:[NSIndexPath indexPathForRow:5 inSection:0]];
 XCTAssertEqualObjects(captured[@"kind"],@"toggle");XCTAssertEqualObjects(captured[@"index"],@0);
}
@end
'''
ns['native']()
