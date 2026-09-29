// SPDX-License-Identifier: GPL-3.0-or-later
// Generated with a distinct Objective-C class name for each embedded bridge.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "NeoCheatLabels.h"
#include "NeoCheatStore.h"

@interface DOLManualCheatEditor : UIViewController <UIDocumentPickerDelegate, UITextViewDelegate>
@property(nonatomic,copy) NSString* localeIdentifier;
@property(nonatomic,copy) NSDictionary* identity;
@property(nonatomic,assign) BOOL ps2;
@property(nonatomic,copy) void (^saveCheat)(NSDictionary*,void (^)(NSDictionary*));
@property(nonatomic,copy) dispatch_block_t saved;
@property(nonatomic,strong) UITextField* nameField;
@property(nonatomic,strong) UITextField* creatorField;
@property(nonatomic,strong) UITextView* codeField;
@property(nonatomic,strong) UILabel* errorLabel;
@property(nonatomic,strong) UISegmentedControl* formatControl;
@property(nonatomic,copy) NSString* importedType;
@property(nonatomic,copy) NSString* filename;
@property(nonatomic,assign) BOOL busy;
@end
@implementation DOLManualCheatEditor
- (NSString*)text:(NSString*)key {return NeoCheatText(key,self.localeIdentifier);}
- (UILabel*)label:(NSString*)text {
  UILabel* label=[UILabel new];label.text=text;label.numberOfLines=0;
  label.textColor=UIColor.labelColor;label.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  label.adjustsFontForContentSizeCategory=YES;return label;
}
- (UITextField*)field:(NSString*)placeholder {
  UITextField* field=[UITextField new];field.placeholder=placeholder;
  field.borderStyle=UITextBorderStyleRoundedRect;field.textColor=UIColor.labelColor;
  field.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
  field.font=[UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  field.adjustsFontForContentSizeCategory=YES;field.autocorrectionType=UITextAutocorrectionTypeNo;
  return field;
}
- (void)viewDidLoad {
  [super viewDidLoad];self.overrideUserInterfaceStyle=UIUserInterfaceStyleDark;
  self.view.backgroundColor=UIColor.systemGroupedBackgroundColor;
  self.title=[self text:@"manualTitle"];
  self.navigationItem.rightBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:[self text:@"save"] style:UIBarButtonItemStyleDone target:self action:@selector(savePressed)];
  self.navigationItem.leftBarButtonItem=[[UIBarButtonItem alloc] initWithTitle:[self text:@"cancel"] style:UIBarButtonItemStylePlain target:self action:@selector(cancelPressed)];
  UIScrollView* scroll=[UIScrollView new];scroll.translatesAutoresizingMaskIntoConstraints=NO;
  scroll.keyboardDismissMode=UIScrollViewKeyboardDismissModeInteractive;
  [self.view addSubview:scroll];
  UIStackView* stack=[[UIStackView alloc] initWithFrame:CGRectZero];stack.axis=UILayoutConstraintAxisVertical;
  stack.spacing=12;stack.translatesAutoresizingMaskIntoConstraints=NO;
  stack.layoutMargins=UIEdgeInsetsMake(16,20,20,20);stack.layoutMarginsRelativeArrangement=YES;
  [scroll addSubview:stack];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    [stack.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor],
    [stack.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor],
    [stack.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor],
    [stack.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor],
    [stack.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor],
  ]];
  NSString* identifier=self.ps2?[NSString stringWithFormat:@"%@ · CRC %@",self.identity[@"serial"]?:@"",self.identity[@"crc"]?:@""]:
      [NSString stringWithFormat:@"%@ · r%@",self.identity[@"gameId"]?:@"",self.identity[@"revision"]?:@0];
  [stack addArrangedSubview:[self label:identifier]];
  [stack addArrangedSubview:[self label:[self text:@"helpExact"]]];
  self.nameField=[self field:[self text:@"name"]];self.nameField.accessibilityIdentifier=@"manualCheatName";
  self.creatorField=[self field:[self text:@"creator"]];
  [stack addArrangedSubview:self.nameField];[stack addArrangedSubview:self.creatorField];
  if(!self.ps2) {
    self.formatControl=[[UISegmentedControl alloc] initWithItems:@[@"Gecko",@"Action Replay",@"Dolphin INI"]];
    self.formatControl.selectedSegmentIndex=0;
    [self.formatControl addTarget:self action:@selector(formatChanged) forControlEvents:UIControlEventValueChanged];
    [stack addArrangedSubview:self.formatControl];
  } else [stack addArrangedSubview:[self label:@"PNACH · patch=1,EE,XXXXXXXX,extended,YYYYYYYY"]];
  [stack addArrangedSubview:[self label:[self text:@"code"]]];
  self.codeField=[UITextView new];self.codeField.backgroundColor=UIColor.secondarySystemGroupedBackgroundColor;
  self.codeField.textColor=UIColor.labelColor;self.codeField.font=[UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
  self.codeField.autocorrectionType=UITextAutocorrectionTypeNo;self.codeField.autocapitalizationType=UITextAutocapitalizationTypeNone;
  self.codeField.smartQuotesType=UITextSmartQuotesTypeNo;self.codeField.smartDashesType=UITextSmartDashesTypeNo;
  self.codeField.accessibilityIdentifier=@"manualCheatCode";self.codeField.delegate=self;
  [self.codeField.heightAnchor constraintEqualToConstant:180].active=YES;
  [stack addArrangedSubview:self.codeField];
  UIButton* import=[UIButton buttonWithType:UIButtonTypeSystem];
  [import setTitle:[self text:@"importFile"] forState:UIControlStateNormal];
  [import addTarget:self action:@selector(importPressed) forControlEvents:UIControlEventTouchUpInside];
  [stack addArrangedSubview:import];
  self.errorLabel=[self label:@""];self.errorLabel.textColor=UIColor.systemOrangeColor;
  self.errorLabel.accessibilityIdentifier=@"manualCheatResult";
  [stack addArrangedSubview:self.errorLabel];
}
- (void)textViewDidChange:(UITextView*)textView {
  if(self.ps2)return;
  NSString* chosen=@[@"gecko",@"actionReplay",@"ini"][self.formatControl.selectedSegmentIndex];
  NSString* type=NeoString(NeoCheat::detectedFormat(textView.text.UTF8String,chosen.UTF8String));
  if([type isEqual:@"actionReplay"]) self.formatControl.selectedSegmentIndex=1;
  else if([type isEqual:@"ini"]) self.formatControl.selectedSegmentIndex=2;
  self.importedType=type;
  self.navigationItem.prompt=[NeoCheatText(@"detectedFormat",self.localeIdentifier) stringByReplacingOccurrencesOfString:@"{format}" withString:[type isEqual:@"actionReplay"]?@"Action Replay":[type isEqual:@"ini"]?@"Dolphin INI":@"Gecko"];
  self.errorLabel.text=@"";
}
- (void)formatChanged {self.importedType=nil;self.errorLabel.text=@"";}
- (void)showResultError:(NSDictionary*)result {
  [self fail:NeoField(result,@"errorKey").length?result[@"errorKey"]:@"writeFailed"];
  if([result[@"errorLine"] unsignedIntegerValue]) {
    NSString* suffix=[[self text:@"errorAtLine"] stringByReplacingOccurrencesOfString:@"{line}" withString:[result[@"errorLine"] stringValue]];
    self.errorLabel.text=[NSString stringWithFormat:@"%@ %@",self.errorLabel.text,suffix];
  }
}
- (void)cancelPressed {if(!self.busy)[self.navigationController popViewControllerAnimated:YES];}
- (void)fail:(NSString*)key {
  self.errorLabel.text=[self text:key];
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification,self.errorLabel.text);
}
- (void)importPressed {
  if(self.busy || self.presentedViewController)return;
  UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
  picker.allowsMultipleSelection=NO;picker.delegate=self;
  [self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url=urls.firstObject;if(!url || self.busy)return;
  self.busy=YES;self.navigationItem.rightBarButtonItem.enabled=NO;
  NSString* fallback=self.ps2?@"pnach":@[@"gecko",@"actionReplay",@"ini"][self.formatControl.selectedSegmentIndex];
  NSDictionary* identity=self.identity;BOOL ps2=self.ps2;
  __weak DOLManualCheatEditor* weakSelf=self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
    BOOL scoped=[url startAccessingSecurityScopedResource];
    __block NSData* data=nil;__block NSError* readError=nil;
    NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
    [coordinator coordinateReadingItemAtURL:url options:0 error:&readError byAccessor:^(NSURL* readable){
      NSFileHandle* handle=[NSFileHandle fileHandleForReadingFromURL:readable error:&readError];
      if(!handle)return;
      NSMutableData* collected=[NSMutableData data];
      while(collected.length<=262144) {
        NSData* chunk=[handle readDataUpToLength:MIN((NSUInteger)16384,262145-collected.length) error:&readError];
        if(!chunk.length)break;
        [collected appendData:chunk];
      }
      [handle closeAndReturnError:nil];data=collected;
    }];
    if(scoped)[url stopAccessingSecurityScopedResource];
    NSDictionary* result=readError||!data?NeoCheatFailure(@"fileRead"):NeoDecodeCheatDocument(data,url.lastPathComponent,identity,ps2,fallback);
    dispatch_async(dispatch_get_main_queue(),^{
      DOLManualCheatEditor* editor=weakSelf;if(!editor)return;
      editor.busy=NO;editor.navigationItem.rightBarButtonItem.enabled=YES;
      if(![result[@"success"] boolValue]){[editor showResultError:result];return;}
      editor.filename=result[@"filename"];editor.codeField.text=result[@"content"];
      editor.importedType=result[@"type"];
      if(!editor.nameField.text.length) {
        NSString* stem=url.lastPathComponent.stringByDeletingPathExtension;
        editor.nameField.text=NeoCheat::safeName(stem.UTF8String)?stem:@"";
      }
      if(!ps2)editor.formatControl.selectedSegmentIndex=[result[@"type"] isEqual:@"ini"]?2:[result[@"type"] isEqual:@"actionReplay"]?1:0;
      [editor textViewDidChange:editor.codeField];editor.errorLabel.text=@"";
    });
  });
}
- (void)savePressed {
  if(self.busy || !self.saveCheat)return;
  NSString* type=self.ps2?@"pnach":self.importedType?:@[@"gecko",@"actionReplay",@"ini"][self.formatControl.selectedSegmentIndex];
  NSString* name=[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString* creator=[self.creatorField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString* normalized=NeoString(NeoCheat::normalizeText(self.codeField.text.UTF8String?:""));
  type=self.ps2?@"pnach":NeoString(NeoCheat::detectedFormat(normalized.UTF8String,type.UTF8String));
  if(!name.length) name=[NSString stringWithFormat:@"%@ - %@",[type isEqual:@"actionReplay"]?@"Action Replay":self.ps2?@"PNACH":@"Gecko",NeoField(self.identity,self.ps2?@"crc":@"gameId")];
  const auto parsed=NeoCheat::parse(normalized.UTF8String,type.UTF8String,name.UTF8String,creator.UTF8String?:"");
  if(!parsed){[self showResultError:NeoParserFailure(parsed)];return;}
  NSMutableDictionary* request=[self.identity mutableCopy];
  request[@"type"]=type;request[@"name"]=name;request[@"creator"]=creator;
  request[@"content"]=normalized;request[@"filename"]=self.filename?:@"";
  self.busy=YES;self.navigationController.view.userInteractionEnabled=NO;
  self.navigationItem.rightBarButtonItem.enabled=NO;
  __weak DOLManualCheatEditor* weakSelf=self;
  self.saveCheat(request,^(NSDictionary* result){dispatch_async(dispatch_get_main_queue(),^{
    DOLManualCheatEditor* editor=weakSelf;if(!editor)return;
    editor.busy=NO;editor.navigationController.view.userInteractionEnabled=YES;
    editor.navigationItem.rightBarButtonItem.enabled=YES;
    if([result[@"success"] boolValue]) {
      if(editor.saved)editor.saved();
      [editor.navigationController popViewControllerAnimated:YES];
    } else [editor showResultError:result];
  });});
}
@end
