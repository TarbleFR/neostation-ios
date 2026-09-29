// SPDX-License-Identifier: GPL-3.0-or-later
#pragma once
#import <UIKit/UIKit.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#include "DOLTextureStore.h"
#include "DOLTextureLabels.h"

@interface DOLTextureSettings : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic,copy) NSString* userDirectory;
@property(nonatomic,copy) NSString* gameId;
@property(nonatomic,assign) NSInteger revision;
@property(nonatomic,copy) NSString* localeIdentifier;
@property(nonatomic,strong) NSDictionary* textureStatus;
@property(nonatomic,assign) BOOL busy;
@property(nonatomic,copy) NSString* resultKey;
@end
@implementation DOLTextureSettings
- (NSString*)text:(NSString*)key {return DOLTextureText(key,self.localeIdentifier);}
- (void)viewDidLoad {
  [super viewDidLoad];self.title=[self text:@"title"];
  self.tableView.backgroundColor=UIColor.systemGroupedBackgroundColor;
  self.tableView.accessibilityIdentifier=@"dolphinHDTextures";
  self.textureStatus=DOLTextureStatus(self.userDirectory,self.gameId,self.revision);
}
- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {return 3;}
- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return [NSString stringWithFormat:@"%@ · r%ld",self.gameId,(long)self.revision];
}
- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  NSString* help=[[self text:@"help"] stringByReplacingOccurrencesOfString:@"{game}" withString:self.gameId];
  return self.resultKey.length?[NSString stringWithFormat:@"%@\n\n%@",[self text:self.resultKey],help]:help;
}
- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell=[[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.textLabel.text=[self text:@[@"folder",@"zip",@"enable"][path.row]];
  cell.textLabel.numberOfLines=0;cell.detailTextLabel.numberOfLines=0;
  if(path.row==2) {
    cell.accessoryType=[self.textureStatus[@"enabled"] boolValue]?UITableViewCellAccessoryCheckmark:UITableViewCellAccessoryNone;
    cell.detailTextLabel.text=[[self text:@"count"] stringByReplacingOccurrencesOfString:@"{count}" withString:[self.textureStatus[@"count"] stringValue]?:@"0"];
  } else cell.accessoryType=UITableViewCellAccessoryDisclosureIndicator;
  if(self.busy){cell.userInteractionEnabled=NO;cell.textLabel.textColor=UIColor.secondaryLabelColor;}
  return cell;
}
- (void)setWorking:(BOOL)working {
  self.busy=working;self.navigationItem.hidesBackButton=working;
  self.navigationController.interactivePopGestureRecognizer.enabled=!working;
  self.navigationController.view.userInteractionEnabled=!working;
  self.navigationController.modalInPresentation=working;
  self.navigationItem.prompt=working?[self text:@"working"]:nil;
  [self.tableView reloadData];
}
- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];if(self.busy || self.presentedViewController)return;
  if(path.row==2){
    BOOL enabled=![self.textureStatus[@"enabled"] boolValue];
    if(enabled && ![self.textureStatus[@"count"] unsignedIntegerValue]){self.resultKey=@"invalid";[self.tableView reloadData];return;}
    [self setWorking:YES];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
      BOOL ok=DOLTextureEnable(self.userDirectory,self.gameId,self.revision,enabled);
      NSDictionary* status=DOLTextureStatus(self.userDirectory,self.gameId,self.revision);
      dispatch_async(dispatch_get_main_queue(),^{self.textureStatus=status;self.resultKey=ok?@"done":@"failed";[self setWorking:NO];});
    });return;
  }
  UIDocumentPickerViewController* picker=[[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[path.row==0?UTTypeFolder:UTTypeZIP] asCopy:NO];
  picker.delegate=self;picker.allowsMultipleSelection=NO;[self presentViewController:picker animated:YES completion:nil];
}
- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* url=urls.firstObject;if(!url || self.busy)return;[self setWorking:YES];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0),^{
    NSString* error=DOLTextureImport(url,self.userDirectory,self.gameId,self.revision);
    NSDictionary* status=DOLTextureStatus(self.userDirectory,self.gameId,self.revision);
    dispatch_async(dispatch_get_main_queue(),^{self.textureStatus=status;self.resultKey=error?:@"done";[self setWorking:NO];});
  });
}
@end
