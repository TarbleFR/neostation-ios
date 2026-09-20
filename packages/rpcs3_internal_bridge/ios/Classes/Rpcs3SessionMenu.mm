#import "Rpcs3SessionMenu.h"
#import "RPCS3InGameLocalization.h"

typedef NS_ENUM(NSInteger, RPCS3MenuPage) {
  RPCS3MenuRoot,
  RPCS3MenuGraphics,
  RPCS3MenuSystem,
  RPCS3MenuControls,
  RPCS3MenuChoices,
  RPCS3MenuSaveStates,
  RPCS3MenuLoadStates,
};

static void RPCS3MenuOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

@interface Rpcs3SessionMenu ()
@property(nonatomic, assign) RPCS3MenuPage page;
@property(nonatomic, copy) NSArray<NSDictionary*>* choices;
@property(nonatomic, copy) NSString* choiceCommand;
@property(nonatomic, copy) NSDictionary<NSString*, id>* stateSnapshot;
@property(nonatomic, assign) BOOL loading;
@property(nonatomic, weak) Rpcs3SessionMenu* returnPage;
@property(nonatomic, copy) NSString* statusMessage;
@end

@implementation Rpcs3SessionMenu

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)text:(NSString*)key {
  return RPCS3LocalizedString(key, self.localeIdentifier ?: @"en");
}

- (UINavigationBarAppearance*)modernNavigationAppearance {
  UINavigationBarAppearance* appearance = [UINavigationBarAppearance new];
  [appearance configureWithTransparentBackground];
  appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterial];
  appearance.shadowColor = [UIColor.separatorColor colorWithAlphaComponent:0.25];
  appearance.titleTextAttributes = @{
    NSForegroundColorAttributeName: UIColor.labelColor,
    NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
  };
  return appearance;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.clearColor;
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
  self.tableView.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
  self.tableView.sectionHeaderTopPadding = 12;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 56;
  self.navigationController.navigationBar.prefersLargeTitles = NO;
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = [self modernNavigationAppearance];
  self.navigationController.navigationBar.scrollEdgeAppearance =
      self.navigationController.navigationBar.standardAppearance;
  self.navigationItem.backButtonTitle = [self text:@"back"];
  if (self.page == RPCS3MenuRoot)
    self.title = self.gameTitle.length ? self.gameTitle : @"RPCS3";
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:[self text:@"resumeGame"]
              style:UIBarButtonItemStyleDone
             target:self
             action:@selector(resumePressed)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (self.page == RPCS3MenuSaveStates || self.page == RPCS3MenuLoadStates)
    [self reloadStates];
}

- (NSArray<NSString*>*)rootKeys {
  return @[@"graphicsMenu", @"systemMenu", @"controlsMenu",
           @"createState", @"loadState", @"resumeGame", @"quitGame"];
}

- (Rpcs3SessionMenu*)child:(RPCS3MenuPage)page title:(NSString*)title {
  Rpcs3SessionMenu* child = [Rpcs3SessionMenu new];
  child.page = page;
  child.title = title;
  child.localeIdentifier = self.localeIdentifier;
  child.gameTitle = self.gameTitle;
  child.performanceVisible = self.performanceVisible;
  child.touchControlsVisible = self.touchControlsVisible;
  child.languageChoices = self.languageChoices;
  child.performCommand = self.performCommand;
  child.readStates = self.readStates;
  child.performStateOperation = self.performStateOperation;
  child.resumeGame = self.resumeGame;
  child.quitGame = self.quitGame;
  child.returnPage = self;
  return child;
}

- (void)resumePressed {
  if (self.loading || !self.resumeGame) return;
  self.resumeGame();
}

- (void)showMessage:(NSString*)message {
  if (!message.length) return;
  self.statusMessage = message;
  self.navigationItem.prompt = message;
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, message);
}

- (void)reloadStates {
  if (self.loading || !self.readStates) return;
  self.loading = YES;
  __weak Rpcs3SessionMenu* weakSelf = self;
  self.readStates(^(NSDictionary<NSString*, id>* state) {
    RPCS3MenuOnMain(^{
      Rpcs3SessionMenu* menu = weakSelf;
      if (!menu) return;
      menu.loading = NO;
      menu.stateSnapshot = state ?: @{};
      [menu.tableView reloadData];
      if (!state) [menu showMessage:[menu text:@"stateFailed"]];
    });
  });
}

- (void)pushChoiceWithTitle:(NSString*)title
                    command:(NSString*)command
                     values:(NSArray*)values
                     titles:(NSArray<NSString*>*)titles {
  Rpcs3SessionMenu* child = [self child:RPCS3MenuChoices title:title];
  child.choiceCommand = command;
  NSMutableArray* items = [NSMutableArray arrayWithCapacity:MIN(values.count, titles.count)];
  for (NSUInteger i = 0; i < values.count && i < titles.count; ++i)
    [items addObject:@{@"value": values[i], @"title": titles[i]}];
  child.choices = items;
  [self.navigationController pushViewController:child animated:YES];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (self.page) {
    case RPCS3MenuRoot: return self.rootKeys.count;
    case RPCS3MenuGraphics: return 3;
    case RPCS3MenuSystem: return 1;
    case RPCS3MenuControls: return 1;
    case RPCS3MenuChoices: return self.choices.count;
    case RPCS3MenuSaveStates:
    case RPCS3MenuLoadStates:
      return [self.stateSnapshot[@"slots"] isKindOfClass:NSArray.class]
          ? [self.stateSnapshot[@"slots"] count] : 0;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (self.page == RPCS3MenuGraphics) return [self text:@"graphicsHelp"];
  if (self.page == RPCS3MenuSystem) return [self text:@"systemHelp"];
  if (self.page == RPCS3MenuControls) return [self text:@"controlsHelp"];
  if (self.page == RPCS3MenuSaveStates || self.page == RPCS3MenuLoadStates)
    return self.statusMessage;
  return nil;
}

- (UITableViewCell*)baseCell {
  UITableViewCell* cell = [[UITableViewCell alloc]
      initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  return cell;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [self baseCell];
  NSInteger row = indexPath.row;

  if (self.page == RPCS3MenuRoot) {
    NSString* key = self.rootKeys[row];
    cell.textLabel.text = [self text:key];
    NSDictionary* symbols = @{
      @"graphicsMenu": @"display",
      @"systemMenu": @"gearshape.2",
      @"controlsMenu": @"gamecontroller",
      @"createState": @"square.and.arrow.down",
      @"loadState": @"square.and.arrow.up",
      @"resumeGame": @"play.fill",
      @"quitGame": @"xmark.circle",
    };
    cell.imageView.image = [UIImage systemImageNamed:symbols[key] ?: @"circle"];
    if ([key isEqual:@"resumeGame"]) cell.accessoryType = UITableViewCellAccessoryNone;
    if ([key isEqual:@"quitGame"]) {
      cell.accessoryType = UITableViewCellAccessoryNone;
      cell.textLabel.textColor = UIColor.systemRedColor;
      cell.imageView.tintColor = UIColor.systemRedColor;
    }
    return cell;
  }

  if (self.page == RPCS3MenuGraphics) {
    if (row == 0) {
      cell.textLabel.text = [self text:@"upscaleTitle"];
      cell.detailTextLabel.text = [self text:@"perGameRestart"];
    } else if (row == 1) {
      cell.textLabel.text = [self text:@"stretchTitle"];
      cell.detailTextLabel.text = [self text:@"perGameRestart"];
    } else {
      cell.textLabel.text = [self text:@"performanceOverlay"];
      cell.detailTextLabel.text = [self text:(self.performanceVisible ? @"enabled" : @"disabled")];
      cell.accessoryType = UITableViewCellAccessoryNone;
    }
    return cell;
  }

  if (self.page == RPCS3MenuSystem) {
    cell.textLabel.text = [self text:@"languageTitle"];
    cell.detailTextLabel.text = [self text:@"languageRestart"];
    return cell;
  }

  if (self.page == RPCS3MenuControls) {
    cell.textLabel.text = [self text:@"touchControls"];
    cell.detailTextLabel.text = [self text:(self.touchControlsVisible ? @"enabled" : @"disabled")];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
  }

  if (self.page == RPCS3MenuChoices) {
    NSDictionary* choice = self.choices[row];
    cell.textLabel.text = choice[@"title"];
    cell.accessoryType = UITableViewCellAccessoryNone;
    return cell;
  }

  NSArray* slots = [self.stateSnapshot[@"slots"] isKindOfClass:NSArray.class]
      ? self.stateSnapshot[@"slots"] : @[];
  if (row < (NSInteger)slots.count) {
    NSDictionary* slot = slots[row];
    NSInteger number = [slot[@"slot"] integerValue];
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %ld", [self text:@"slot"], (long)number];
    if ([slot[@"exists"] boolValue]) {
      int64_t modified = [slot[@"modified"] longLongValue];
      NSDate* date = modified > 0 ? [NSDate dateWithTimeIntervalSince1970:(NSTimeInterval)modified] : nil;
      cell.detailTextLabel.text = date
          ? [NSDateFormatter localizedStringFromDate:date
                                           dateStyle:NSDateFormatterShortStyle
                                           timeStyle:NSDateFormatterShortStyle]
          : [self text:@"unknownDate"];
    } else {
      cell.detailTextLabel.text = [self text:@"emptySlot"];
    }
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (self.page == RPCS3MenuLoadStates &&
        (![slot[@"exists"] boolValue] || ![slot[@"compatible"] boolValue])) {
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      cell.textLabel.textColor = UIColor.secondaryLabelColor;
      if ([slot[@"exists"] boolValue] && ![slot[@"compatible"] boolValue])
        cell.detailTextLabel.text = [self text:@"incompatible"];
    }
  }
  return cell;
}

- (void)performCommand:(NSString*)command value:(id)value {
  if (self.loading || !self.performCommand) return;
  self.loading = YES;
  self.navigationController.view.userInteractionEnabled = NO;
  __weak Rpcs3SessionMenu* weakSelf = self;
  self.performCommand(command, value, ^(BOOL success, NSString* message) {
    RPCS3MenuOnMain(^{
      Rpcs3SessionMenu* menu = weakSelf;
      if (!menu) return;
      menu.loading = NO;
      menu.navigationController.view.userInteractionEnabled = YES;
      if (success) {
        if ([command isEqual:@"performance"]) {
          menu.performanceVisible = [value boolValue];
          menu.returnPage.performanceVisible = menu.performanceVisible;
        } else if ([command isEqual:@"touchControls"]) {
          menu.touchControlsVisible = [value boolValue];
          menu.returnPage.touchControlsVisible = menu.touchControlsVisible;
        }
        [menu.tableView reloadData];
        if (menu.page == RPCS3MenuChoices) [menu.navigationController popViewControllerAnimated:YES];
      } else {
        [menu showMessage:message.length ? message : [menu text:@"settingsFailed"]];
      }
    });
  });
}

- (void)confirmQuit {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:[self text:@"quitGame"]
                       message:[self text:@"quitConfirm"]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"]
                                           style:UIAlertActionStyleCancel handler:nil]];
  __weak Rpcs3SessionMenu* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"quitGame"]
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction* action) {
    if (weakSelf.quitGame) weakSelf.quitGame();
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)operateState:(NSDictionary*)slot load:(BOOL)load {
  if (self.loading || !self.performStateOperation) return;
  NSInteger number = [slot[@"slot"] integerValue];
  NSString* identifier = [slot[@"id"] isKindOfClass:NSString.class] ? slot[@"id"] : nil;
  if (number < 1 || number > 10 || (load && !identifier.length)) return;
  self.loading = YES;
  self.navigationController.view.userInteractionEnabled = NO;
  __weak Rpcs3SessionMenu* weakSelf = self;
  self.performStateOperation(number, load, identifier, ^(BOOL success, NSString* message) {
    RPCS3MenuOnMain(^{
      Rpcs3SessionMenu* menu = weakSelf;
      if (!menu) return;
      menu.loading = NO;
      menu.navigationController.view.userInteractionEnabled = YES;
      [menu showMessage:success ? [menu text:(load ? @"stateLoaded" : @"stateDone")]
                                : (message.length ? message : [menu text:@"stateFailed"])];
      [menu reloadStates];
    });
  });
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.loading) return;
  NSInteger row = indexPath.row;

  if (self.page == RPCS3MenuRoot) {
    NSString* key = self.rootKeys[row];
    if ([key isEqual:@"graphicsMenu"]) {
      [self.navigationController pushViewController:[self child:RPCS3MenuGraphics title:[self text:key]] animated:YES];
    } else if ([key isEqual:@"systemMenu"]) {
      [self.navigationController pushViewController:[self child:RPCS3MenuSystem title:[self text:key]] animated:YES];
    } else if ([key isEqual:@"controlsMenu"]) {
      [self.navigationController pushViewController:[self child:RPCS3MenuControls title:[self text:key]] animated:YES];
    } else if ([key isEqual:@"createState"]) {
      Rpcs3SessionMenu* child = [self child:RPCS3MenuSaveStates title:[self text:key]];
      [self.navigationController pushViewController:child animated:YES];
    } else if ([key isEqual:@"loadState"]) {
      Rpcs3SessionMenu* child = [self child:RPCS3MenuLoadStates title:[self text:key]];
      [self.navigationController pushViewController:child animated:YES];
    } else if ([key isEqual:@"resumeGame"]) {
      [self resumePressed];
    } else if ([key isEqual:@"quitGame"]) {
      [self confirmQuit];
    }
    return;
  }

  if (self.page == RPCS3MenuGraphics) {
    if (row == 0) {
      [self pushChoiceWithTitle:[self text:@"upscaleTitle"]
                        command:@"resolution"
                         values:@[@"50", @"75", @"100", @"125", @"150", @"200"]
                         titles:@[@"50%", @"75%", @"100%", @"125%", @"150%", @"200%"]];
    } else if (row == 1) {
      [self pushChoiceWithTitle:[self text:@"stretchTitle"]
                        command:@"stretch"
                         values:@[@NO, @YES]
                         titles:@[[self text:@"normal"], [self text:@"stretched"]]];
    } else {
      [self performCommand:@"performance" value:@(!self.performanceVisible)];
    }
    return;
  }

  if (self.page == RPCS3MenuSystem) {
    NSMutableArray* values = [NSMutableArray array];
    NSMutableArray* titles = [NSMutableArray array];
    for (NSDictionary* item in self.languageChoices ?: @[]) {
      if (item[@"value"] && item[@"label"]) {
        [values addObject:item[@"value"]];
        [titles addObject:item[@"label"]];
      }
    }
    [self pushChoiceWithTitle:[self text:@"languageTitle"]
                      command:@"language" values:values titles:titles];
    return;
  }

  if (self.page == RPCS3MenuControls) {
    [self performCommand:@"touchControls" value:@(!self.touchControlsVisible)];
    return;
  }

  if (self.page == RPCS3MenuChoices) {
    if (row < (NSInteger)self.choices.count) {
      NSDictionary* choice = self.choices[row];
      [self performCommand:self.choiceCommand value:choice[@"value"]];
    }
    return;
  }

  NSArray* slots = [self.stateSnapshot[@"slots"] isKindOfClass:NSArray.class]
      ? self.stateSnapshot[@"slots"] : @[];
  if (row >= (NSInteger)slots.count) return;
  NSDictionary* slot = slots[row];

  if (self.page == RPCS3MenuLoadStates) {
    if (![slot[@"exists"] boolValue] || ![slot[@"compatible"] boolValue]) return;
    [self operateState:slot load:YES];
    return;
  }

  if (![slot[@"exists"] boolValue]) {
    [self operateState:slot load:NO];
    return;
  }

  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:[self text:@"overwriteTitle"]
                       message:[NSString stringWithFormat:[self text:@"overwriteMessage"],
                                                     (long)[slot[@"slot"] integerValue]]
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"]
                                           style:UIAlertActionStyleCancel handler:nil]];
  __weak Rpcs3SessionMenu* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"overwrite"]
                                           style:UIAlertActionStyleDestructive
                                         handler:^(__unused UIAlertAction* action) {
    [weakSelf operateState:slot load:NO];
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

@end
