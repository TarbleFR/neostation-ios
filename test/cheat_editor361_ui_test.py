from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
origin=ROOT/'test/dolphin_account_267_test.py'
source=origin.read_text().replace("'CLANG_ENABLE_OBJC_ARC': 'YES',", "'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_CXX_LANGUAGE_STANDARD': 'c++20',")
source=source.replace("{'sdk': 'UIKit.framework'}", "{'sdk': 'UniformTypeIdentifiers.framework'}, {'sdk': 'UIKit.framework'}")
# Compile the real PS2 editor as its own host translation unit, not a mock.
source=source.replace("(directory / 'main.m').write_text(APP)",
    "(directory / 'main.m').write_text(APP)\n        (directory / 'PS2Editor.mm').write_text('#include \\\"'+str(ROOT/'packages/armsx2_internal_bridge/ios/Classes/ARMSX2ManualCheatEditor.h')+'\\\"\\n')")
source=source.replace("'sources': [str(directory / 'main.m'),", "'sources': [str(directory / 'main.m'), str(directory / 'PS2Editor.mm'),")
ns={'__file__':str(origin),'__name__':'cheat_editor_tests'}
exec(compile(source,str(origin),'exec'),ns)
ns['TESTS']=r'''
#import <XCTest/XCTest.h>
#import <UIKit/UIKit.h>
#include "NeoCheatStore.h"
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
  NSURL* file=[NSURL fileURLWithPath:[NSTemporaryDirectory() stringByAppendingPathComponent:ps2.boolValue?@"12345678.pnach":@"G4BP08.txt"]];
  [[self fiftyCodes:ps2.boolValue] writeToURL:file atomically:YES encoding:NSUTF16StringEncoding error:nil];
  [self readFile:file editor:editor];
  // Importing another TXT must not inherit the preceding canonical INI format.
  [self readFile:file editor:editor];
  XCTAssertEqual(editor.errorLabel.text.length,0);XCTAssertEqual(editor.previewEntries.count,50);
  XCTAssertEqual([editor.previewTable.dataSource tableView:editor.previewTable numberOfRowsInSection:0],50);
  XCTAssertTrue(editor.nameField.hidden);XCTAssertTrue(editor.codeField.hidden);XCTAssertFalse(editor.previewTable.hidden);
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
- (void)testCancelDoesNotImportAndBatchLabelsExistInTwelveLanguages {
 for(NSString* language in @[@"en",@"fr",@"de",@"es",@"it",@"pt",@"ru",@"id",@"ja",@"ko",@"zh",@"zh_Hant"]){
  DOLManualCheatEditor* editor=[DOLManualCheatEditor new];editor.identity=[self identity];editor.localeIdentifier=language;[editor loadViewIfNeeded];
  for(NSString* key in @[@"batchPreview",@"batchSave",@"batchLineCount",@"closePreview",@"gctCombined",@"emptyBlock",@"batchConflict",@"batchResult"])
    XCTAssertNotEqualObjects(NeoCheatText(key,language),key);
  NSString* message=NeoCheatBatchResult(@{@"added":@48,@"skipped":@2},language);
  XCTAssertTrue([message containsString:@"48"]);XCTAssertFalse([message containsString:@"{added}"]);
  __block BOOL called=NO;editor.saveCheat=^(NSDictionary* request,void(^completion)(NSDictionary*)){called=YES;};[editor cancelPressed];XCTAssertFalse(called);
 }
}
@end
'''
ns['native']()
