from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
origin=ROOT/'test/dolphin_account_267_test.py'
source=origin.read_text().replace("'CLANG_ENABLE_OBJC_ARC': 'YES',", "'CLANG_ENABLE_OBJC_ARC': 'YES', 'CLANG_CXX_LANGUAGE_STANDARD': 'c++20',")
source=source.replace("{'sdk': 'UIKit.framework'}", "{'sdk': 'UniformTypeIdentifiers.framework'}, {'sdk': 'UIKit.framework'}")
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
@end
'''
ns['native']()
