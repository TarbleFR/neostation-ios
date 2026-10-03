#import "RetroArchSessionMenu.h"
#import "NeoRetroArchCoreAPI.h"
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

typedef NS_ENUM(NSUInteger, NeoRAMenuPage) {
  NeoRAMenuRoot, NeoRAMenuSave, NeoRAMenuLoad, NeoRAMenuOptions,
  NeoRAMenuChoices, NeoRAMenuShaders, NeoRAMenuOverlays, NeoRAMenuCheats,
};

@interface NeoRACheatEditor : UIViewController
@property(nonatomic, copy) NSDictionary<NSString*, NSString*>* labels;
@property(nonatomic, copy) void (^saveCheat)(NSString* description, NSString* code);
@property(nonatomic, strong) UITextField* descriptionField;
@property(nonatomic, strong) UITextView* codeField;
@end

@implementation NeoRACheatEditor
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.labels[@"addCheat"];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.labels[@"cancel"]
      style:UIBarButtonItemStylePlain target:self action:@selector(cancel)];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:self.labels[@"apply"]
      style:UIBarButtonItemStyleDone target:self action:@selector(save)];
  self.descriptionField = [UITextField new];
  self.descriptionField.placeholder = self.labels[@"cheatDescription"];
  self.descriptionField.accessibilityLabel = self.labels[@"cheatDescription"];
  self.descriptionField.borderStyle = UITextBorderStyleRoundedRect;
  self.codeField = [UITextView new];
  self.codeField.accessibilityLabel = self.labels[@"cheatCode"];
  self.codeField.font = [UIFont monospacedSystemFontOfSize:15 weight:UIFontWeightRegular];
  self.codeField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.codeField.autocapitalizationType = UITextAutocapitalizationTypeAllCharacters;
  self.codeField.smartQuotesType = UITextSmartQuotesTypeNo;
  self.codeField.smartDashesType = UITextSmartDashesTypeNo;
  UILabel* codeLabel = [UILabel new];
  codeLabel.text = self.labels[@"cheatCode"];
  codeLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleSubheadline];
  codeLabel.textColor = UIColor.secondaryLabelColor;
  UIStackView* fields = [[UIStackView alloc] initWithArrangedSubviews:@[self.descriptionField, codeLabel, self.codeField]];
  fields.axis = UILayoutConstraintAxisVertical;
  fields.spacing = 12;
  fields.translatesAutoresizingMaskIntoConstraints = NO;
  [self.view addSubview:fields];
  [NSLayoutConstraint activateConstraints:@[
    [fields.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
    [fields.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor constant:20],
    [fields.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor constant:-20],
    [fields.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor constant:-20],
    [self.descriptionField.heightAnchor constraintEqualToConstant:44]]];
}
- (void)cancel { [self dismissViewControllerAnimated:YES completion:nil]; }
- (void)save {
  NSString* code = [self.codeField.text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!code.length) {
    self.navigationItem.prompt = self.labels[@"operationFailed"];
    return;
  }
  NSString* description = self.descriptionField.text ?: @"";
  void (^save)(NSString*, NSString*) = self.saveCheat;
  [self dismissViewControllerAnimated:YES completion:^{ if (save) save(description, code); }];
}
@end

@interface RetroArchSessionMenu () <UIDocumentPickerDelegate>
@property(nonatomic, assign) NeoRAMenuPage page;
@property(nonatomic, copy) NSArray<NSDictionary*>* items;
@property(nonatomic, copy) NSDictionary* option;
@property(nonatomic, assign) BOOL loading;
@property(nonatomic, copy) NSString* statusMessage;
@property(nonatomic, copy) NSString* pendingCommand;
@property(nonatomic, strong) NSTimer* pendingTimer;
@property(nonatomic, assign) BOOL skipAppearanceReload;
@end

@implementation RetroArchSessionMenu
- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  if (self) _items = @[];
  return self;
}

- (NSString*)text:(NSString*)key { return self.labels[key] ?: @""; }

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.clearColor;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 56;
  self.navigationItem.backButtonTitle = [self text:@"back"];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:[self text:@"resumeGame"] style:UIBarButtonItemStyleDone
      target:self action:@selector(resumePressed)];
  UINavigationBarAppearance* appearance = [UINavigationBarAppearance new];
  [appearance configureWithTransparentBackground];
  appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
  appearance.titleTextAttributes = @{
      NSForegroundColorAttributeName: UIColor.labelColor,
      NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold]};
  self.navigationController.navigationBar.standardAppearance = appearance;
  self.navigationController.navigationBar.scrollEdgeAppearance = appearance;
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  if (self.page == NeoRAMenuRoot)
    self.title = self.gameTitle.length ? self.gameTitle : [self text:@"menuTitle"];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (self.skipAppearanceReload) { self.skipAppearanceReload = NO; return; }
  if (self.page != NeoRAMenuRoot && self.page != NeoRAMenuChoices) [self reloadItems];
}

- (void)resumePressed { if (!self.loading && self.resumeGame) self.resumeGame(); }

- (void)showFailure {
  self.statusMessage = [self text:@"operationFailed"];
  self.navigationItem.prompt = self.statusMessage;
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.statusMessage);
}

- (void)invoke:(NSDictionary*)request completion:(void (^)(NSDictionary*))completion {
  if (self.loading || !self.performCommand) return;
  self.loading = YES;
  self.navigationItem.rightBarButtonItem.enabled = NO;
  __weak RetroArchSessionMenu* weakSelf = self;
  self.performCommand(request, ^(NSDictionary* response) {
    dispatch_async(dispatch_get_main_queue(), ^{
      RetroArchSessionMenu* menu = weakSelf;
      if (!menu) return;
      BOOL pending = [response[@"success"] boolValue] && [response[@"pending"] boolValue];
      menu.loading = pending;
      menu.navigationItem.rightBarButtonItem.enabled = !pending;
      if (pending) {
        menu.pendingCommand = request[@"command"];
        menu.navigationItem.prompt = [menu text:@"loading"];
        __weak RetroArchSessionMenu* owner = menu;
        menu.pendingTimer = [NSTimer scheduledTimerWithTimeInterval:18 repeats:NO block:^(__unused NSTimer* timer) {
          [owner completePendingOperation:@{@"command": request[@"command"] ?: @"", @"success": @NO}];
        }];
      } else {
        if (![response[@"success"] boolValue]) [menu showFailure];
        else {
          menu.statusMessage = @"";
          menu.navigationItem.prompt = nil;
        }
        if (completion) completion(response ?: @{});
      }
    });
  });
}

- (void)completePendingOperation:(NSDictionary*)response {
  if (!self.pendingCommand.length || ![response[@"command"] isEqual:self.pendingCommand]) return;
  [self.pendingTimer invalidate];
  self.pendingTimer = nil;
  self.pendingCommand = nil;
  self.loading = NO;
  self.navigationItem.rightBarButtonItem.enabled = YES;
  if (![response[@"success"] boolValue]) { [self showFailure]; return; }
  self.statusMessage = @"";
  self.navigationItem.prompt = nil;
  [self reloadItems];
}

- (void)dealloc { [self.pendingTimer invalidate]; }

- (void)reloadItems {
  NSString* command = nil;
  switch (self.page) {
    case NeoRAMenuSave:
    case NeoRAMenuLoad: command = @"readStates"; break;
    case NeoRAMenuOptions: command = @"readOptions"; break;
    case NeoRAMenuShaders: command = @"readShaders"; break;
    case NeoRAMenuOverlays: command = @"readOverlays"; break;
    case NeoRAMenuCheats: command = @"readCheats"; break;
    default: return;
  }
  __weak RetroArchSessionMenu* weakSelf = self;
  [self invoke:@{@"command": command} completion:^(NSDictionary* response) {
    RetroArchSessionMenu* menu = weakSelf;
    if (!menu || ![response[@"success"] boolValue]) return;
    id raw = response[(menu.page == NeoRAMenuSave || menu.page == NeoRAMenuLoad)
        ? @"slots" : @"items"];
    NSMutableArray* valid = [NSMutableArray array];
    if (menu.page == NeoRAMenuShaders || menu.page == NeoRAMenuOverlays)
      [valid addObject:@{@"title": [menu text:@"none"], @"path": @""}];
    if ([raw isKindOfClass:NSArray.class])
      for (id item in raw) if ([item isKindOfClass:NSDictionary.class]) [valid addObject:item];
    menu.items = valid;
    [menu.tableView reloadData];
  }];
}

- (RetroArchSessionMenu*)child:(NeoRAMenuPage)page title:(NSString*)title {
  RetroArchSessionMenu* child = [RetroArchSessionMenu new];
  child.page = page;
  child.title = title;
  child.labels = self.labels;
  child.gameTitle = self.gameTitle;
  child.capabilities = self.capabilities;
  child.cheatsPath = self.cheatsPath;
  child.performCommand = self.performCommand;
  child.resumeGame = self.resumeGame;
  child.quitGame = self.quitGame;
  return child;
}

- (NSArray<NSString*>*)rootKeys {
  return @[@"resumeGame", @"createState", @"loadState", @"coreOptions",
           @"shaders", @"overlays", @"cheats", @"quitGame"];
}

- (uint64_t)capabilityForKey:(NSString*)key {
  if ([key isEqual:@"createState"] || [key isEqual:@"loadState"]) return NEO_RA_CAP_SAVE_STATES;
  if ([key isEqual:@"coreOptions"]) return NEO_RA_CAP_CORE_OPTIONS;
  if ([key isEqual:@"shaders"]) return NEO_RA_CAP_SHADERS;
  if ([key isEqual:@"overlays"]) return NEO_RA_CAP_OVERLAYS;
  if ([key isEqual:@"cheats"]) return NEO_RA_CAP_CHEATS;
  return 0;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  if (self.page == NeoRAMenuRoot) return self.rootKeys.count;
  return self.items.count + (self.page == NeoRAMenuCheats ? 2 : 0);
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (self.statusMessage.length) return self.statusMessage;
  if (self.loading) return [self text:@"loading"];
  if (self.page == NeoRAMenuShaders || self.page == NeoRAMenuOverlays || self.page == NeoRAMenuCheats)
    return [self text:@"filesHelp"];
  if (self.page != NeoRAMenuRoot && self.items.count == 0) return [self text:@"noItems"];
  return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = UIColor.secondarySystemGroupedBackgroundColor;
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  NSUInteger row = indexPath.row;
  if (self.page == NeoRAMenuRoot) {
    NSString* key = self.rootKeys[row];
    cell.textLabel.text = [self text:key];
    NSDictionary* symbols = @{@"resumeGame": @"play.fill", @"createState": @"square.and.arrow.down",
      @"loadState": @"square.and.arrow.up", @"coreOptions": @"gearshape.2", @"shaders": @"sparkles",
      @"overlays": @"rectangle.on.rectangle", @"cheats": @"wand.and.stars", @"quitGame": @"xmark.circle"};
    cell.imageView.image = [UIImage systemImageNamed:symbols[key]];
    uint64_t required = [self capabilityForKey:key];
    if (required && !(self.capabilities & required)) {
      cell.detailTextLabel.text = [self text:@"unavailable"];
      cell.textLabel.textColor = UIColor.tertiaryLabelColor;
      cell.imageView.tintColor = UIColor.tertiaryLabelColor;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if ([key isEqual:@"quitGame"]) {
      cell.textLabel.textColor = UIColor.systemRedColor;
      cell.imageView.tintColor = UIColor.systemRedColor;
    } else if (![key isEqual:@"resumeGame"]) cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  if (self.page == NeoRAMenuCheats && row >= self.items.count) {
    cell.textLabel.text = [self text:row == self.items.count ? @"addCheat" : @"importCheats"];
    cell.imageView.image = [UIImage systemImageNamed:row == self.items.count ? @"plus.circle" : @"square.and.arrow.down"];
    return cell;
  }
  NSDictionary* item = self.items[row];
  if (self.page == NeoRAMenuSave || self.page == NeoRAMenuLoad) {
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %@", [self text:@"slot"], item[@"slot"] ?: @""];
    BOOL exists = [item[@"exists"] boolValue];
    cell.detailTextLabel.text = [self text:exists ? @"savedState" : @"emptyState"];
    if (exists && [item[@"modified"] doubleValue] > 0) {
      NSDate* date = [NSDate dateWithTimeIntervalSince1970:[item[@"modified"] doubleValue]];
      cell.detailTextLabel.text = [NSDateFormatter localizedStringFromDate:date dateStyle:NSDateFormatterMediumStyle timeStyle:NSDateFormatterShortStyle];
    }
    if (self.page == NeoRAMenuLoad && !exists) cell.textLabel.textColor = UIColor.tertiaryLabelColor;
  } else {
    cell.textLabel.text = [item[@"title"] isKindOfClass:NSString.class] ? item[@"title"] : @"";
    if (self.page == NeoRAMenuOptions) {
      cell.detailTextLabel.text = [item[@"value"] description];
      cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (self.page == NeoRAMenuCheats) {
      cell.detailTextLabel.text = [item[@"code"] isKindOfClass:NSString.class] ? item[@"code"] : @"";
      cell.accessoryType = [item[@"enabled"] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    } else {
      BOOL selected = self.page == NeoRAMenuChoices
          ? [item[@"value"] isEqual:self.option[@"value"]] : [item[@"active"] boolValue];
      cell.accessoryType = selected ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    }
  }
  return cell;
}

- (void)confirm:(NSString*)key destructive:(BOOL)destructive action:(dispatch_block_t)action {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self text:key] message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"confirm"] style:destructive ? UIAlertActionStyleDestructive : UIAlertActionStyleDefault handler:^(__unused UIAlertAction* selected) { if (action) action(); }]];
  self.skipAppearanceReload = YES;
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)applyRequest:(NSDictionary*)request {
  __weak RetroArchSessionMenu* weakSelf = self;
  [self invoke:request completion:^(NSDictionary* response) {
    if ([response[@"success"] boolValue]) [weakSelf reloadItems];
  }];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.loading) return;
  NSUInteger row = indexPath.row;
  if (self.page == NeoRAMenuRoot) {
    NSString* key = self.rootKeys[row];
    uint64_t required = [self capabilityForKey:key];
    if (required && !(self.capabilities & required)) return;
    if ([key isEqual:@"resumeGame"]) { [self resumePressed]; return; }
    if ([key isEqual:@"quitGame"]) {
      __weak RetroArchSessionMenu* weakSelf = self;
      [self confirm:@"quitConfirm" destructive:YES action:^{ if (weakSelf.quitGame) weakSelf.quitGame(); }];
      return;
    }
    NSDictionary* pages = @{@"createState": @(NeoRAMenuSave), @"loadState": @(NeoRAMenuLoad),
      @"coreOptions": @(NeoRAMenuOptions), @"shaders": @(NeoRAMenuShaders),
      @"overlays": @(NeoRAMenuOverlays), @"cheats": @(NeoRAMenuCheats)};
    [self.navigationController pushViewController:[self child:(NeoRAMenuPage)[pages[key] unsignedIntegerValue] title:[self text:key]] animated:YES];
    return;
  }
  if (self.page == NeoRAMenuCheats && row >= self.items.count) {
    if (row == self.items.count) [self addCheat]; else [self importCheats];
    return;
  }
  NSDictionary* item = self.items[row];
  if (self.page == NeoRAMenuOptions) {
    RetroArchSessionMenu* child = [self child:NeoRAMenuChoices title:item[@"title"] ?: @""];
    child.option = item;
    NSMutableArray* choices = [NSMutableArray array];
    if ([item[@"choices"] isKindOfClass:NSArray.class])
      for (id choice in item[@"choices"]) if ([choice isKindOfClass:NSDictionary.class]) [choices addObject:choice];
    child.items = choices;
    [self.navigationController pushViewController:child animated:YES];
  } else if (self.page == NeoRAMenuChoices) {
    __weak RetroArchSessionMenu* weakSelf = self;
    [self invoke:@{@"command": @"setOption", @"key": self.option[@"key"] ?: @"", @"value": item[@"value"] ?: @""}
      completion:^(NSDictionary* response) {
        if (![response[@"success"] boolValue]) return;
        [weakSelf.navigationController popViewControllerAnimated:YES];
      }];
  } else if (self.page == NeoRAMenuSave || self.page == NeoRAMenuLoad) {
    BOOL load = self.page == NeoRAMenuLoad;
    if (load && ![item[@"exists"] boolValue]) return;
    NSDictionary* request = @{@"command": load ? @"loadState" : @"saveState", @"slot": item[@"slot"] ?: @0};
    if (!load && [item[@"exists"] boolValue]) {
      __weak RetroArchSessionMenu* weakSelf = self;
      [self confirm:@"overwriteState" destructive:NO action:^{ [weakSelf applyRequest:request]; }];
    } else [self applyRequest:request];
  } else if (self.page == NeoRAMenuShaders || self.page == NeoRAMenuOverlays) {
    [self applyRequest:@{@"command": self.page == NeoRAMenuShaders ? @"applyShader" : @"applyOverlay", @"path": item[@"path"] ?: @""}];
  } else if (self.page == NeoRAMenuCheats) {
    [self applyRequest:@{@"command": @"setCheat", @"index": item[@"index"] ?: @(-1), @"enabled": @(![item[@"enabled"] boolValue])}];
  }
}

- (UISwipeActionsConfiguration*)tableView:(UITableView*)tableView trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath*)indexPath {
  if (self.page != NeoRAMenuCheats || indexPath.row >= (NSInteger)self.items.count || self.loading) return nil;
  NSDictionary* item = self.items[indexPath.row];
  __weak RetroArchSessionMenu* weakSelf = self;
  UIContextualAction* deleteAction = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive title:[self text:@"deleteCheat"] handler:^(__unused UIContextualAction* action, __unused UIView* view, void (^completion)(BOOL)) {
    completion(YES);
    [weakSelf confirm:@"deleteConfirm" destructive:YES action:^{
      [weakSelf applyRequest:@{@"command": @"deleteCheat", @"index": item[@"index"] ?: @(-1)}];
    }];
  }];
  return [UISwipeActionsConfiguration configurationWithActions:@[deleteAction]];
}

- (void)addCheat {
  NeoRACheatEditor* editor = [NeoRACheatEditor new];
  editor.labels = self.labels;
  __weak RetroArchSessionMenu* weakSelf = self;
  editor.saveCheat = ^(NSString* description, NSString* code) {
    [weakSelf applyRequest:@{@"command": @"addCheat", @"description": description, @"code": code, @"enabled": @YES}];
  };
  UINavigationController* navigation = [[UINavigationController alloc] initWithRootViewController:editor];
  navigation.modalPresentationStyle = UIModalPresentationFormSheet;
  self.skipAppearanceReload = YES;
  [self presentViewController:navigation animated:YES completion:nil];
}

- (void)importCheats {
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
  picker.delegate = self;
  picker.allowsMultipleSelection = NO;
  self.skipAppearanceReload = YES;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)controller didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* source = urls.firstObject;
  if (!source || ![source.pathExtension.lowercaseString isEqual:@"cht"] || !self.cheatsPath.length) { [self showFailure]; return; }
  // asCopy isolates the imported file. A UUID avoids replacing user cheat files.
  BOOL access = [source startAccessingSecurityScopedResource];
  NSString* name = [NSString stringWithFormat:@"%@-%@", NSUUID.UUID.UUIDString, source.lastPathComponent];
  NSURL* destination = [NSURL fileURLWithPath:[self.cheatsPath stringByAppendingPathComponent:name]];
  NSError* error = nil;
  BOOL copied = [NSFileManager.defaultManager copyItemAtURL:source toURL:destination error:&error];
  if (access) [source stopAccessingSecurityScopedResource];
  if (!copied) { [self showFailure]; return; }
  [self applyRequest:@{@"command": @"importCheats", @"path": destination.path}];
}
@end
