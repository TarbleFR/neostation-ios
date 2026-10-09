#import "LibretroSessionMenu.h"

@implementation LibretroMenuRow

+ (instancetype)rowWithTitle:(NSString *)title action:(void (^)(LibretroMenuPage *page))action {
  LibretroMenuRow *row = [self new];
  row.title = title ?: @"";
  row.action = action;
  row.enabled = YES;
  return row;
}

+ (instancetype)toggleWithTitle:(NSString *)title on:(BOOL)on toggle:(void (^)(LibretroMenuPage *page, BOOL on))toggle {
  LibretroMenuRow *row = [self rowWithTitle:title action:nil];
  row.isToggle = YES;
  row.toggleOn = on;
  row.toggle = toggle;
  return row;
}

@end

@implementation LibretroMenuSection

+ (instancetype)sectionWithTitle:(NSString *)title rows:(NSArray<LibretroMenuRow *> *)rows {
  LibretroMenuSection *section = [self new];
  section.title = title;
  section.rows = rows ?: @[];
  return section;
}

@end

@implementation LibretroMenuPage {
  NSArray<LibretroMenuSection *> *_sections;
}

- (instancetype)initWithTitle:(NSString *)title builder:(NSArray<LibretroMenuSection *> * (^)(void))builder {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  if (self) {
    self.title = title;
    _builder = [builder copy];
    _sections = @[];
    self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  }
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  [self.tableView registerClass:UITableViewCell.class forCellReuseIdentifier:@"row"];
  if (self.closeHandler != nil) {
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:self.closeTitle ?: @"OK"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(closePressed)];
  }
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self rebuild];
}

- (void)closePressed {
  if (self.closeHandler != nil) self.closeHandler();
}

- (void)rebuild {
  _sections = self.builder != nil ? self.builder() : @[];
  if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)push:(LibretroMenuPage *)page {
  page.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  [self.navigationController pushViewController:page animated:YES];
}

- (LibretroMenuRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section >= (NSInteger)_sections.count) return nil;
  NSArray<LibretroMenuRow *> *rows = _sections[indexPath.section].rows;
  return indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)_sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  return _sections[section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  return _sections[section].footer;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
  cell.textLabel.text = row.title;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.text = row.detail;
  cell.textLabel.textColor = row.destructive ? UIColor.systemRedColor : UIColor.labelColor;
  if (!row.enabled) cell.textLabel.textColor = UIColor.secondaryLabelColor;
  cell.accessibilityIdentifier = row.identifier;
  cell.accessoryType = row.checked ? UITableViewCellAccessoryCheckmark
                                   : (row.disclosure ? UITableViewCellAccessoryDisclosureIndicator
                                                     : UITableViewCellAccessoryNone);
  if (row.isToggle) {
    UISwitch *control = [[UISwitch alloc] init];
    control.on = row.toggleOn;
    control.enabled = row.enabled;
    control.tag = indexPath.section * 1000 + indexPath.row;
    [control addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = control;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  return cell;
}

- (void)switchChanged:(UISwitch *)control {
  NSIndexPath *indexPath = [NSIndexPath indexPathForRow:control.tag % 1000 inSection:control.tag / 1000];
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (row.toggle != nil) row.toggle(self, control.on);
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (row == nil || !row.enabled || row.isToggle || row.action == nil) return;
  row.action(self);
}

- (BOOL)tableView:(UITableView *)tableView canEditRowAtIndexPath:(NSIndexPath *)indexPath {
  return [self rowAtIndexPath:indexPath].remove != nil;
}

- (void)tableView:(UITableView *)tableView
    commitEditingStyle:(UITableViewCellEditingStyle)editingStyle
     forRowAtIndexPath:(NSIndexPath *)indexPath {
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (editingStyle == UITableViewCellEditingStyleDelete && row.remove != nil) row.remove(self);
}

- (void)confirmWithTitle:(NSString *)title
                 message:(NSString *)message
                  action:(NSString *)action
             cancelTitle:(NSString *)cancel
             destructive:(BOOL)destructive
                 handler:(dispatch_block_t)handler {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:action
                                            style:destructive ? UIAlertActionStyleDestructive
                                                              : UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *selected) {
                                            handler();
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)askWithTitle:(NSString *)title
              fields:(NSArray<NSString *> *)placeholders
              secure:(NSArray<NSNumber *> *)secure
              action:(NSString *)action
         cancelTitle:(NSString *)cancel
             handler:(void (^)(NSArray<NSString *> *values))handler {
  UIAlertController *alert = [UIAlertController alertControllerWithTitle:title
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleAlert];
  for (NSUInteger index = 0; index < placeholders.count; index++) {
    [alert addTextFieldWithConfigurationHandler:^(UITextField *field) {
      field.placeholder = placeholders[index];
      field.secureTextEntry = index < secure.count && secure[index].boolValue;
      field.autocorrectionType = UITextAutocorrectionTypeNo;
      field.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
  }
  __weak UIAlertController *weakAlert = alert;
  [alert addAction:[UIAlertAction actionWithTitle:cancel style:UIAlertActionStyleCancel handler:nil]];
  [alert addAction:[UIAlertAction actionWithTitle:action
                                            style:UIAlertActionStyleDefault
                                          handler:^(__unused UIAlertAction *selected) {
                                            NSMutableArray<NSString *> *values = [NSMutableArray array];
                                            for (UITextField *field in weakAlert.textFields) {
                                              [values addObject:field.text ?: @""];
                                            }
                                            handler(values);
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end
