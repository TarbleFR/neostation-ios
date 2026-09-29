// SPDX-License-Identifier: GPL-3.0-or-later
// Generated with a distinct Objective-C class name for each embedded bridge.
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "NeoCheatLabels.h"
#include "NeoCheatStore.h"

@interface ARMSX2ManualCheatEditor : UIViewController <UIDocumentPickerDelegate>
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
@implementation ARMSX2ManualCheatEditor
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
  self.codeField.accessibilityIdentifier=@"manualCheatCode";
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
- (void)formatChanged {self.importedType=nil;}
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
  NSString* ext=url.pathExtension.lowercaseString;
  if(self.ps2 ? ![ext isEqual:@"pnach"] : ![@[@"ini",@"txt"] containsObject:ext]) {[self fail:@"invalidCode"];return;}
  if(!NeoFilenameMatches(url.lastPathComponent,self.identity,self.ps2)) {[self fail:@"wrongGame"];return;}
  BOOL scoped=[url startAccessingSecurityScopedResource];
  __block NSData* data=nil;__block NSError* readError=nil;
  NSFileCoordinator* coordinator=[[NSFileCoordinator alloc] initWithFilePresenter:nil];
  [coordinator coordinateReadingItemAtURL:url options:0 error:&readError byAccessor:^(NSURL* readable){
    NSNumber* bytes=nil;
    if(![readable getResourceValue:&bytes forKey:NSURLFileSizeKey error:&readError] || bytes.unsignedLongLongValue>262144)return;
    data=[NSData dataWithContentsOfURL:readable options:NSDataReadingMappedIfSafe error:&readError];
  }];
  if(scoped)[url stopAccessingSecurityScopedResource];
  NSString* text=data.length && data.length<=262144?[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]:nil;
  if(!text){[self fail:@"invalidCode"];return;}
  self.filename=url.lastPathComponent;
  self.codeField.text=text;self.errorLabel.text=@"";
  if(!self.nameField.text.length)self.nameField.text=url.lastPathComponent.stringByDeletingPathExtension;
  if([ext isEqual:@"ini"]){self.importedType=@"ini";self.formatControl.selectedSegmentIndex=2;}
}
- (void)savePressed {
  if(self.busy || !self.saveCheat)return;
  NSString* type=self.ps2?@"pnach":self.importedType?:@[@"gecko",@"actionReplay",@"ini"][self.formatControl.selectedSegmentIndex];
  NSString* name=[self.nameField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  NSString* creator=[self.creatorField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  const auto parsed=NeoCheat::parse(self.codeField.text.UTF8String?:"",type.UTF8String,name.UTF8String?:"",creator.UTF8String?:"");
  if(!parsed){[self fail:@"invalidCode"];return;}
  NSMutableDictionary* request=[self.identity mutableCopy];
  request[@"type"]=type;request[@"name"]=name;request[@"creator"]=creator;
  request[@"content"]=self.codeField.text;request[@"filename"]=self.filename?:@"";
  self.busy=YES;self.navigationController.view.userInteractionEnabled=NO;
  self.navigationItem.rightBarButtonItem.enabled=NO;
  __weak ARMSX2ManualCheatEditor* weakSelf=self;
  self.saveCheat(request,^(NSDictionary* result){dispatch_async(dispatch_get_main_queue(),^{
    ARMSX2ManualCheatEditor* editor=weakSelf;if(!editor)return;
    editor.busy=NO;editor.navigationController.view.userInteractionEnabled=YES;
    editor.navigationItem.rightBarButtonItem.enabled=YES;
    if([result[@"success"] boolValue]) {
      if(editor.saved)editor.saved();
      [editor.navigationController popViewControllerAnimated:YES];
    } else [editor fail:NeoField(result,@"errorKey").length?result[@"errorKey"]:@"writeFailed"];
  });});
}
@end
