#import "DolphinSessionMenu.h"

typedef NS_ENUM(NSInteger, DOLMenuPage) {
  DOLMenuRoot, DOLMenuGraphics, DOLMenuControls, DOLMenuChoices, DOLMenuDevices, DOLMenuInputs, DOLMenuConsole
};

@interface DolphinSessionMenu ()
@property(nonatomic, assign) DOLMenuPage page;
@property(nonatomic, copy) NSDictionary* snapshot;
@property(nonatomic, copy) NSArray<NSDictionary*>* choices;
@property(nonatomic, copy) NSDictionary* binding;
@property(nonatomic, weak) DolphinSessionMenu* returnPage;
@property(nonatomic, assign) BOOL loading;
@end

@implementation DolphinSessionMenu

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSString*)text:(NSString*)key {
  return self.labels[key] ?: key;
}

- (NSString*)controlLabel:(NSString*)value {
  NSMutableArray* translated = [NSMutableArray array];
  for (NSString* component in [value componentsSeparatedByString:@"/"])
    if (component.length) [translated addObject:[self text:component]];
  return [translated componentsJoinedByString:@" / "];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.navigationItem.backButtonTitle = [self text:@"back"];
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 56;
  if (self.page == DOLMenuRoot) self.title = @"Dolphin";
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:[self text:@"resume"] style:UIBarButtonItemStyleDone
      target:self action:@selector(resumePressed)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  if (self.page == DOLMenuConsole || self.page == DOLMenuGraphics || self.page == DOLMenuControls)
    [self reloadSettings];
}

- (void)reloadSettings {
  if (self.loading || !self.readSettings) return;
  self.loading = YES;
  __weak DolphinSessionMenu* weakSelf = self;
  self.readSettings(self.wii, self.page == DOLMenuControls ? self.slot : -1, ^(NSDictionary* data) {
    DolphinSessionMenu* strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf.loading = NO;
    strongSelf.snapshot = data;
    [strongSelf.tableView reloadData];
    if (!data && strongSelf.view.window) [strongSelf showFailure];
  });
}

- (void)resumePressed { if (self.resumeGame) self.resumeGame(); }

- (void)showFailure {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self text:@"settingsFailed"]
      message:nil preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"close"] style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (DolphinSessionMenu*)child:(DOLMenuPage)page title:(NSString*)title {
  DolphinSessionMenu* child = [[DolphinSessionMenu alloc] init];
  child.labels = self.labels;
  child.page = page;
  child.title = title;
  child.wii = self.wii;
  child.slot = self.slot;
  child.snapshot = self.snapshot;
  child.readSettings = self.readSettings;
  child.applySettings = self.applySettings;
  child.resumeGame = self.resumeGame;
  child.quitGame = self.quitGame;
  child.restartGame = self.restartGame;
  child.binding = self.binding;
  child.returnPage = self.returnPage;
  return child;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return self.page == DOLMenuControls ? 2 : 1;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (self.page) {
    case DOLMenuRoot: return 5;
    case DOLMenuConsole: return self.snapshot ? 2 : 0;
    case DOLMenuGraphics: return self.snapshot ? 4 : 0;
    case DOLMenuControls:
      return section == 0 ? (self.wii ? 4 : 3) : [self.snapshot[@"controls"] count];
    case DOLMenuDevices: return [self.snapshot[@"devices"] count] + 1;
    default: return self.choices.count;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  if (self.page == DOLMenuControls && section == 1) return [self text:@"bindings"];
  return nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (self.page == DOLMenuGraphics) return [self text:@"graphicsHelp"];
  if (self.page == DOLMenuConsole) return [self text:@"languageHelp"];
  if (self.page == DOLMenuControls && section == 1) return [self text:@"bindingsHelp"];
  return nil;
}

- (NSString*)graphicsValue:(NSString*)key {
  NSNumber* raw = self.snapshot[@"graphics"][key];
  NSInteger value = raw.integerValue;
  if ([key isEqual:@"resolution"]) return value == 0 ? [self text:@"auto"] : [NSString stringWithFormat:@"%ld×", (long)value];
  if ([key isEqual:@"vsync"]) return [self text:value ? @"on" : @"off"];
  if ([key isEqual:@"anisotropy"]) return value < 0 ? [self text:@"auto"] : [NSString stringWithFormat:@"%ld×", 1L << MIN(value, 4)];
  NSArray* aspects = @[[self text:@"auto"], @"16:9", @"4:3", [self text:@"stretch"]];
  return value >= 0 && value < aspects.count ? aspects[value] : [self text:@"custom"];
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  NSInteger row = indexPath.row;
  if (self.page == DOLMenuRoot) {
    cell.textLabel.text = [self text:@[@"graphics", @"controls", @"console", @"resume", @"quit"][row]];
    if (row == 4) cell.textLabel.textColor = UIColor.systemRedColor;
  } else if (self.page == DOLMenuConsole) {
    cell.textLabel.text = [self text:row == 0 ? @"consoleLanguage" : @"restart"];
    if (row == 0) {
      for (NSDictionary* language in self.snapshot[@"console"][@"languages"])
        if ([language[@"selected"] boolValue]) cell.detailTextLabel.text = language[@"name"];
    } else if ([self.snapshot[@"console"][@"restartNeeded"] boolValue]) {
      cell.detailTextLabel.text = [self text:@"restartRequired"];
    }
  } else if (self.page == DOLMenuGraphics) {
    NSString* key = @[@"resolution", @"aspect", @"anisotropy", @"vsync"][row];
    cell.textLabel.text = [self text:key];
    cell.detailTextLabel.text = [self graphicsValue:key];
  } else if (self.page == DOLMenuControls) {
    if (indexPath.section == 0) {
      cell.textLabel.text = [self text:(self.wii ? @[@"controllerType", @"player", @"physicalController", @"extension"] : @[@"controllerType", @"player", @"physicalController"])[row]];
      if (row == 0) cell.detailTextLabel.text = self.wii ? [self text:@"wiimote"] : @"GameCube";
      if (row == 1) cell.detailTextLabel.text = [NSString stringWithFormat:@"%ld", (long)self.slot + 1];
      if (row == 2) cell.detailTextLabel.text = self.snapshot[@"device"];
      if (row == 3) {
        for (NSDictionary* item in self.snapshot[@"extensions"])
          if ([item[@"selected"] boolValue]) cell.detailTextLabel.text = [self controlLabel:item[@"name"]];
      }
    } else {
      NSDictionary* binding = self.snapshot[@"controls"][row];
      cell.textLabel.text = [NSString stringWithFormat:@"%@ — %@", [self controlLabel:binding[@"group"]], [self controlLabel:binding[@"name"]]];
      NSString* expression = binding[@"expression"];
      cell.detailTextLabel.text = expression.length ? expression : [self text:@"unassigned"];
    }
  } else if (self.page == DOLMenuDevices) {
    cell.textLabel.text = row == 0 ? [self text:@"clearBinding"] : self.snapshot[@"devices"][row - 1][@"name"];
  } else {
    cell.textLabel.text = self.choices[row][@"title"] ?: self.choices[row][@"name"];
    if ([self.choices[row][@"selected"] boolValue]) cell.accessoryType = UITableViewCellAccessoryCheckmark;
  }
  return cell;
}

- (void)apply:(NSDictionary*)request thenReturn:(BOOL)returnToBindings {
  if (self.loading || !self.applySettings) return;
  self.loading = YES;
  self.view.userInteractionEnabled = NO;
  self.navigationItem.rightBarButtonItem.enabled = NO;
  __weak DolphinSessionMenu* weakSelf = self;
  self.applySettings(request, ^(BOOL success) {
    DolphinSessionMenu* strongSelf = weakSelf;
    if (!strongSelf) return;
    strongSelf.loading = NO;
    strongSelf.view.userInteractionEnabled = YES;
    strongSelf.navigationItem.rightBarButtonItem.enabled = YES;
    if (!success) { [strongSelf showFailure]; return; }
    if (returnToBindings && strongSelf.returnPage)
      [strongSelf.navigationController popToViewController:strongSelf.returnPage animated:YES];
    else
      [strongSelf.navigationController popViewControllerAnimated:YES];
  });
}

- (NSDictionary*)bindingRequest:(NSString*)expression {
  return @{@"kind": @"binding", @"id": self.binding[@"id"], @"expression": expression,
           @"wii": @(self.wii), @"slot": @(self.slot)};
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.loading) return;
  NSInteger row = indexPath.row;
  if (self.page == DOLMenuRoot) {
    if (row == 3) { [self resumePressed]; return; }
    if (row == 4) {
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self text:@"quit"]
          message:[self text:@"quitHelp"] preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
      __weak DolphinSessionMenu* weakSelf = self;
      [alert addAction:[UIAlertAction actionWithTitle:[self text:@"quit"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
        if (weakSelf.quitGame) weakSelf.quitGame();
      }]];
      [self presentViewController:alert animated:YES completion:nil];
      return;
    }
    [self.navigationController pushViewController:[self child:row == 0 ? DOLMenuGraphics : row == 1 ? DOLMenuControls : DOLMenuConsole
        title:[self text:@[@"graphics", @"controls", @"console"][row]]] animated:YES];
  } else if (self.page == DOLMenuConsole) {
    if (row == 1) { [self confirmRestart]; return; }
    DolphinSessionMenu* child = [self child:DOLMenuChoices title:[self text:@"consoleLanguage"]];
    NSMutableArray* choices = [NSMutableArray array];
    for (NSDictionary* language in self.snapshot[@"console"][@"languages"])
      [choices addObject:@{@"title": language[@"name"], @"selected": language[@"selected"],
        @"request": @{@"kind": @"language", @"wii": @(self.wii), @"value": language[@"value"]}}];
    child.choices = choices;
    [self.navigationController pushViewController:child animated:YES];
  } else if (self.page == DOLMenuGraphics) {
    NSString* key = @[@"resolution", @"aspect", @"anisotropy", @"vsync"][row];
    NSArray* values;
    NSArray* titles;
    if (row == 0) { values = @[@1, @2, @3, @4]; titles = @[@"1×", @"2×", @"3×", @"4×"]; }
    else if (row == 1) { values = @[@0, @1, @2, @3]; titles = @[[self text:@"auto"], @"16:9", @"4:3", [self text:@"stretch"]]; }
    else if (row == 2) { values = @[@(-1), @0, @1, @2, @3, @4]; titles = @[[self text:@"auto"], @"1×", @"2×", @"4×", @"8×", @"16×"]; }
    else { values = @[@0, @1]; titles = @[[self text:@"off"], [self text:@"on"]]; }
    NSMutableArray* choices = [NSMutableArray array];
    for (NSUInteger index = 0; index < values.count; index++)
      [choices addObject:@{@"title": titles[index], @"selected": @([self.snapshot[@"graphics"][key] isEqual:values[index]]),
        @"request": @{@"kind": @"graphics", @"key": key, @"value": values[index]}}];
    DolphinSessionMenu* child = [self child:DOLMenuChoices title:[self text:key]];
    child.choices = choices;
    [self.navigationController pushViewController:child animated:YES];
  } else if (self.page == DOLMenuControls) {
    if (indexPath.section == 1) {
      DolphinSessionMenu* child = [self child:DOLMenuDevices title:[self text:@"chooseInput"]];
      child.binding = self.snapshot[@"controls"][row];
      child.returnPage = self;
      [self.navigationController pushViewController:child animated:YES];
      return;
    }
    DolphinSessionMenu* child = [self child:DOLMenuChoices title:[self text:(self.wii ? @[@"controllerType", @"player", @"physicalController", @"extension"] : @[@"controllerType", @"player", @"physicalController"])[row]]];
    NSMutableArray* choices = [NSMutableArray array];
    if (row == 0) {
      [choices addObject:@{@"title": @"GameCube", @"wii": @NO}];
      [choices addObject:@{@"title": [self text:@"wiimote"], @"wii": @YES}];
    } else if (row == 1) {
      for (NSInteger index = 0; index < 4; index++)
        [choices addObject:@{@"title": [NSString stringWithFormat:@"%ld", (long)index + 1], @"slot": @(index)}];
    } else if (row == 2) {
      for (NSDictionary* device in self.snapshot[@"devices"]) {
        NSString* name = device[@"name"];
        if (![name hasPrefix:@"MFi/"] && ![name isEqual:self.wii ? @"iOS/4/Touchscreen" : @"iOS/0/Touchscreen"]) continue;
        [choices addObject:@{@"title": name, @"selected": @([name isEqual:self.snapshot[@"device"]]),
          @"request": @{@"kind": @"device", @"device": name, @"wii": @(self.wii), @"slot": @(self.slot)}}];
      }
    } else {
      for (NSDictionary* extension in self.snapshot[@"extensions"])
        [choices addObject:@{@"title": [self controlLabel:extension[@"name"]], @"selected": extension[@"selected"],
          @"request": @{@"kind": @"extension", @"group": extension[@"group"], @"index": extension[@"index"],
            @"wii": @(self.wii), @"slot": @(self.slot)}}];
    }
    child.choices = choices;
    child.returnPage = self;
    [self.navigationController pushViewController:child animated:YES];
  } else if (self.page == DOLMenuDevices) {
    if (row == 0) { [self apply:[self bindingRequest:@""] thenReturn:YES]; return; }
    DolphinSessionMenu* child = [self child:DOLMenuInputs title:[self text:@"chooseInput"]];
    child.choices = self.snapshot[@"devices"][row - 1][@"inputs"];
    [self.navigationController pushViewController:child animated:YES];
  } else if (self.page == DOLMenuInputs) {
    [self apply:[self bindingRequest:self.choices[row][@"expression"]] thenReturn:YES];
  } else {
    NSDictionary* choice = self.choices[row];
    if (choice[@"wii"] || choice[@"slot"]) {
      if (choice[@"wii"]) self.returnPage.wii = [choice[@"wii"] boolValue];
      if (choice[@"slot"]) self.returnPage.slot = [choice[@"slot"] integerValue];
      [self.navigationController popViewControllerAnimated:YES];
    } else {
      [self apply:choice[@"request"] thenReturn:NO];
    }
  }
}

- (void)confirmRestart {
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:[self text:@"restart"]
      message:[self text:@"restartHelp"] preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"cancel"] style:UIAlertActionStyleCancel handler:nil]];
  __weak DolphinSessionMenu* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:[self text:@"restart"] style:UIAlertActionStyleDestructive handler:^(UIAlertAction* action) {
    if (weakSelf.restartGame) weakSelf.restartGame();
  }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }
@end
