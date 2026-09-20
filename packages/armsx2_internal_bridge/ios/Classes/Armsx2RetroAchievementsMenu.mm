#import "Armsx2RetroAchievementsMenu.h"

static void ARMSX2RAOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

static BOOL ARMSX2RAIsFrench(void) {
  NSString* language = NSLocale.preferredLanguages.firstObject.lowercaseString ?: @"";
  return [language hasPrefix:@"fr"];
}

static NSString* ARMSX2RAText(NSString* english, NSString* french) {
  return ARMSX2RAIsFrench() ? french : english;
}

static UINavigationBarAppearance* ARMSX2RAModernNavigationAppearance(void) {
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

@interface Armsx2RetroAchievementsChoiceController : UITableViewController
@property(nonatomic, copy) NSString* command;
@property(nonatomic, copy) NSArray<NSDictionary*>* choices;
@property(nonatomic, copy) Armsx2RetroAchievementsCommand performCommand;
@property(nonatomic, assign) BOOL applying;
@end

@implementation Armsx2RetroAchievementsChoiceController

- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  self.tableView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.58];
  self.tableView.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = ARMSX2RAModernNavigationAppearance();
  self.navigationController.navigationBar.scrollEdgeAppearance = self.navigationController.navigationBar.standardAppearance;
  self.navigationItem.backButtonTitle = ARMSX2RAText(@"Back", @"Retour");
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return self.choices.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  NSDictionary* choice = self.choices[indexPath.row];
  cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cell.textLabel.text = choice[@"title"];
  cell.accessoryType = [choice[@"selected"] boolValue]
      ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  if (self.applying) {
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
  }
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.applying || !self.performCommand || indexPath.row >= self.choices.count) return;
  NSDictionary* choice = self.choices[indexPath.row];
  if ([choice[@"selected"] boolValue]) {
    [self.navigationController popViewControllerAnimated:YES];
    return;
  }
  self.applying = YES;
  self.navigationController.view.userInteractionEnabled = NO;
  __weak Armsx2RetroAchievementsChoiceController* weakSelf = self;
  self.performCommand(self.command, choice[@"value"], ^(BOOL success, NSString* message) {
    ARMSX2RAOnMain(^{
      Armsx2RetroAchievementsChoiceController* screen = weakSelf;
      if (!screen) return;
      screen.applying = NO;
      screen.navigationController.view.userInteractionEnabled = YES;
      if (success) {
        [screen.navigationController popViewControllerAnimated:YES];
        return;
      }
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:
          ARMSX2RAText(@"RetroAchievements error", @"Erreur RetroAchievements")
          message:message preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
      [screen presentViewController:alert animated:YES completion:nil];
    });
  });
}

@end

@interface Armsx2RetroAchievementsAccountController : UIViewController
@property(nonatomic, copy) Armsx2RetroAchievementsReadState readState;
@property(nonatomic, copy) Armsx2RetroAchievementsCommand performCommand;
@property(nonatomic, strong) UITextField* usernameField;
@property(nonatomic, strong) UITextField* passwordField;
@property(nonatomic, strong) UILabel* statusLabel;
@property(nonatomic, strong) UIButton* linkButton;
@property(nonatomic, strong) UIButton* unlinkButton;
@property(nonatomic, assign) BOOL busy;
@end

@implementation Armsx2RetroAchievementsAccountController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = ARMSX2RAText(@"Account", @"Compte");
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = ARMSX2RAModernNavigationAppearance();
  self.navigationController.navigationBar.scrollEdgeAppearance = self.navigationController.navigationBar.standardAppearance;

  UIScrollView* scroll = [UIScrollView new];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.keyboardDismissMode = UIScrollViewKeyboardDismissModeInteractive;
  [self.view addSubview:scroll];

  UIStackView* form = [UIStackView new];
  form.axis = UILayoutConstraintAxisVertical;
  form.spacing = 16;
  form.translatesAutoresizingMaskIntoConstraints = NO;
  [scroll addSubview:form];

  [NSLayoutConstraint activateConstraints:@[
    [scroll.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor],
    [scroll.leadingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.trailingAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.view.keyboardLayoutGuide.topAnchor],
    [form.topAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.topAnchor constant:20],
    [form.bottomAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.bottomAnchor constant:-20],
    [form.leadingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.leadingAnchor constant:20],
    [form.trailingAnchor constraintEqualToAnchor:scroll.contentLayoutGuide.trailingAnchor constant:-20],
    [form.widthAnchor constraintEqualToAnchor:scroll.frameLayoutGuide.widthAnchor constant:-40],
  ]];

  UILabel* help = [UILabel new];
  help.text = ARMSX2RAText(
      @"Connect the RetroAchievements account used by ARMSX2. The password is sent to the native ARMSX2 login flow and is never stored by NeoStation.",
      @"Connectez le compte RetroAchievements utilisé par ARMSX2. Le mot de passe est transmis au flux de connexion natif ARMSX2 et n’est jamais enregistré par NeoStation.");
  help.numberOfLines = 0;
  help.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  help.adjustsFontForContentSizeCategory = YES;
  [form addArrangedSubview:help];

  self.usernameField = [UITextField new];
  self.usernameField.placeholder = ARMSX2RAText(@"Username", @"Nom d’utilisateur");
  self.usernameField.textContentType = UITextContentTypeUsername;
  self.usernameField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.usernameField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.usernameField.borderStyle = UITextBorderStyleRoundedRect;
  [form addArrangedSubview:self.usernameField];

  self.passwordField = [UITextField new];
  self.passwordField.placeholder = ARMSX2RAText(@"Password", @"Mot de passe");
  self.passwordField.textContentType = UITextContentTypePassword;
  self.passwordField.secureTextEntry = YES;
  self.passwordField.autocapitalizationType = UITextAutocapitalizationTypeNone;
  self.passwordField.autocorrectionType = UITextAutocorrectionTypeNo;
  self.passwordField.borderStyle = UITextBorderStyleRoundedRect;
  [form addArrangedSubview:self.passwordField];

  self.linkButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.linkButton setTitle:ARMSX2RAText(@"Link account", @"Lier le compte") forState:UIControlStateNormal];
  self.linkButton.configuration = UIButtonConfiguration.filledButtonConfiguration;
  [self.linkButton addTarget:self action:@selector(linkAccount) forControlEvents:UIControlEventTouchUpInside];
  [form addArrangedSubview:self.linkButton];

  self.unlinkButton = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.unlinkButton setTitle:ARMSX2RAText(@"Unlink account", @"Déconnecter le compte") forState:UIControlStateNormal];
  [self.unlinkButton addTarget:self action:@selector(unlinkAccount) forControlEvents:UIControlEventTouchUpInside];
  [form addArrangedSubview:self.unlinkButton];

  self.statusLabel = [UILabel new];
  self.statusLabel.numberOfLines = 0;
  self.statusLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
  self.statusLabel.adjustsFontForContentSizeCategory = YES;
  self.statusLabel.accessibilityIdentifier = @"armsx2.ra.status";
  [form addArrangedSubview:self.statusLabel];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadAccount];
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  self.passwordField.text = @"";
}

- (void)setBusyState:(BOOL)busy {
  self.busy = busy;
  self.usernameField.enabled = !busy;
  self.passwordField.enabled = !busy;
  self.linkButton.enabled = !busy;
  if (busy) self.unlinkButton.enabled = NO;
}

- (void)reloadAccount {
  if (!self.readState) return;
  __weak Armsx2RetroAchievementsAccountController* weakSelf = self;
  self.readState(^(NSDictionary<NSString*, id>* state) {
    ARMSX2RAOnMain(^{
      Armsx2RetroAchievementsAccountController* screen = weakSelf;
      if (!screen) return;
      NSString* username = [state[@"username"] isKindOfClass:NSString.class] ? state[@"username"] : @"";
      if (!screen.usernameField.isFirstResponder && username.length)
        screen.usernameField.text = username;
      BOOL linked = [state[@"loggedIn"] boolValue] || [state[@"savedLogin"] boolValue];
      screen.unlinkButton.enabled = !screen.busy && linked;
      if (!screen.statusLabel.text.length) {
        screen.statusLabel.text = linked
          ? ARMSX2RAText(@"Account linked.", @"Compte lié.")
          : ARMSX2RAText(@"No account linked.", @"Aucun compte lié.");
      }
    });
  });
}

- (void)finishOperation:(BOOL)success message:(NSString*)message {
  self.statusLabel.text = message.length ? message :
      (success ? ARMSX2RAText(@"Done.", @"Terminé.")
               : ARMSX2RAText(@"Operation failed.", @"L’opération a échoué."));
  UIAccessibilityPostNotification(UIAccessibilityAnnouncementNotification, self.statusLabel.text);
  [self setBusyState:NO];
  [self reloadAccount];
}

- (void)linkAccount {
  if (self.busy || !self.performCommand) return;
  NSString* username = [self.usernameField.text stringByTrimmingCharactersInSet:
      NSCharacterSet.whitespaceAndNewlineCharacterSet] ?: @"";
  NSString* password = self.passwordField.text ?: @"";
  if (!username.length || !password.length) {
    self.statusLabel.text = ARMSX2RAText(
        @"Enter your username and password.", @"Saisissez votre nom d’utilisateur et votre mot de passe.");
    return;
  }
  [self.view endEditing:YES];
  self.passwordField.text = @""; // NeoStation never retains the password.
  [self setBusyState:YES];
  self.statusLabel.text = ARMSX2RAText(@"Connecting…", @"Connexion…");
  __weak Armsx2RetroAchievementsAccountController* weakSelf = self;
  self.performCommand(@"login", @{@"username": username, @"password": password}, ^(BOOL success, NSString* message) {
    ARMSX2RAOnMain(^{ [weakSelf finishOperation:success message:message]; });
  });
}

- (void)unlinkAccount {
  if (self.busy || !self.performCommand) return;
  [self setBusyState:YES];
  self.statusLabel.text = ARMSX2RAText(@"Disconnecting…", @"Déconnexion…");
  __weak Armsx2RetroAchievementsAccountController* weakSelf = self;
  self.performCommand(@"logout", nil, ^(BOOL success, NSString* message) {
    ARMSX2RAOnMain(^{
      if (success) weakSelf.usernameField.text = @"";
      [weakSelf finishOperation:success message:message];
    });
  });
}

@end

typedef NS_ENUM(NSInteger, Armsx2RARow) {
  Armsx2RARowAccount = 0,
  Armsx2RARowEnabled,
  Armsx2RARowStatus,
  Armsx2RARowMode,
  Armsx2RARowNotifications,
  Armsx2RARowLeaderboards,
  Armsx2RARowOverlays,
  Armsx2RARowCount,
};

@interface Armsx2RetroAchievementsMenu ()
@property(nonatomic, copy) NSDictionary<NSString*, id>* state;
@property(nonatomic, assign) BOOL loading;
@end

@implementation Armsx2RetroAchievementsMenu

- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"RetroAchievements";
  self.view.backgroundColor = UIColor.systemGroupedBackgroundColor;
  self.tableView.backgroundColor = UIColor.clearColor;
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
  self.tableView.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
  self.tableView.sectionHeaderTopPadding = 12;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 56;
  self.navigationController.navigationBar.prefersLargeTitles = NO;
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = ARMSX2RAModernNavigationAppearance();
  self.navigationController.navigationBar.scrollEdgeAppearance = self.navigationController.navigationBar.standardAppearance;
  self.navigationItem.backButtonTitle = ARMSX2RAText(@"Back", @"Retour");
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:ARMSX2RAText(@"Done", @"Terminé")
      style:UIBarButtonItemStyleDone target:self action:@selector(donePressed)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadState];
}

- (void)donePressed {
  if (self.navigationController.viewControllers.firstObject != self) {
    [self.navigationController popViewControllerAnimated:YES];
  } else {
    [self dismissViewControllerAnimated:YES completion:nil];
  }
}

- (void)reloadState {
  if (self.loading || !self.readState) return;
  self.loading = YES;
  self.navigationItem.rightBarButtonItem.enabled = NO;
  __weak Armsx2RetroAchievementsMenu* weakSelf = self;
  self.readState(^(NSDictionary<NSString*, id>* state) {
    ARMSX2RAOnMain(^{
      Armsx2RetroAchievementsMenu* screen = weakSelf;
      if (!screen) return;
      screen.loading = NO;
      screen.state = [state isKindOfClass:NSDictionary.class] ? state : @{};
      screen.navigationItem.rightBarButtonItem.enabled = YES;
      [screen.tableView reloadData];
    });
  });
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return Armsx2RARowCount;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (![self.state[@"supported"] boolValue] && [self.state[@"unavailableMessage"] isKindOfClass:NSString.class])
    return self.state[@"unavailableMessage"];
  return ARMSX2RAText(
      @"ARMSX2 applies these options through its native PCSX2 RetroAchievements implementation. Hardcore can restrict cheats and save-state features.",
      @"ARMSX2 applique ces options via son implémentation RetroAchievements native PCSX2. Le mode Hardcore peut limiter les cheats et les fonctions de save state.");
}

- (NSString*)statusText {
  if ([self.state[@"loggedIn"] boolValue]) return ARMSX2RAText(@"Active", @"Actif");
  if ([self.state[@"loginPending"] boolValue]) return ARMSX2RAText(@"Connecting…", @"Connexion…");
  if ([self.state[@"savedLogin"] boolValue]) return ARMSX2RAText(@"Login saved", @"Connexion enregistrée");
  if ([self.state[@"enabled"] boolValue]) return ARMSX2RAText(@"Enabled", @"Activé");
  return ARMSX2RAText(@"Disabled", @"Désactivé");
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;

  switch ((Armsx2RARow)indexPath.row) {
    case Armsx2RARowAccount: {
      cell.textLabel.text = ARMSX2RAText(@"Account", @"Compte");
      NSString* username = [self.state[@"username"] isKindOfClass:NSString.class] ? self.state[@"username"] : @"";
      cell.detailTextLabel.text = username.length ? username : ARMSX2RAText(@"Not connected", @"Non connecté");
      break;
    }
    case Armsx2RARowEnabled:
      cell.textLabel.text = @"RetroAchievements";
      cell.detailTextLabel.text = ARMSX2RAText([self.state[@"enabled"] boolValue] ? @"On" : @"Off",
                                               [self.state[@"enabled"] boolValue] ? @"Activé" : @"Désactivé");
      break;
    case Armsx2RARowStatus:
      cell.textLabel.text = ARMSX2RAText(@"Status", @"Statut");
      cell.detailTextLabel.text = [self statusText];
      cell.accessoryType = UITableViewCellAccessoryNone;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      cell.userInteractionEnabled = NO;
      break;
    case Armsx2RARowMode:
      cell.textLabel.text = ARMSX2RAText(@"Mode", @"Mode");
      cell.detailTextLabel.text = [self.state[@"hardcorePreference"] boolValue] ? @"Hardcore" : @"Standard";
      if (![self.state[@"hardcoreSupported"] boolValue]) {
        cell.textLabel.textColor = UIColor.secondaryLabelColor;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
        cell.userInteractionEnabled = NO;
      }
      break;
    case Armsx2RARowNotifications:
      cell.textLabel.text = ARMSX2RAText(@"Notifications", @"Notifications");
      cell.detailTextLabel.text = ARMSX2RAText([self.state[@"notifications"] boolValue] ? @"On" : @"Off",
                                               [self.state[@"notifications"] boolValue] ? @"Activées" : @"Désactivées");
      break;
    case Armsx2RARowLeaderboards:
      cell.textLabel.text = ARMSX2RAText(@"Leaderboard notifications", @"Notifications des classements");
      cell.detailTextLabel.text = ARMSX2RAText([self.state[@"leaderboardNotifications"] boolValue] ? @"On" : @"Off",
                                               [self.state[@"leaderboardNotifications"] boolValue] ? @"Activées" : @"Désactivées");
      break;
    case Armsx2RARowOverlays:
      cell.textLabel.text = ARMSX2RAText(@"Overlays", @"Superpositions");
      cell.detailTextLabel.text = ARMSX2RAText([self.state[@"overlays"] boolValue] ? @"On" : @"Off",
                                               [self.state[@"overlays"] boolValue] ? @"Activées" : @"Désactivées");
      break;
    default: break;
  }

  if (self.loading || (![self.state[@"supported"] boolValue] && indexPath.row != Armsx2RARowStatus)) {
    cell.textLabel.textColor = UIColor.secondaryLabelColor;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
  }
  return cell;
}

- (void)pushBooleanChoiceWithTitle:(NSString*)title command:(NSString*)command current:(BOOL)current {
  Armsx2RetroAchievementsChoiceController* child = [Armsx2RetroAchievementsChoiceController new];
  child.title = title;
  child.command = command;
  child.performCommand = self.performCommand;
  child.choices = @[
    @{@"title": ARMSX2RAText(@"Off", @"Désactivé"), @"value": @NO, @"selected": @(!current)},
    @{@"title": ARMSX2RAText(@"On", @"Activé"), @"value": @YES, @"selected": @(current)},
  ];
  [self.navigationController pushViewController:child animated:YES];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.loading || ![self.state[@"supported"] boolValue]) return;

  switch ((Armsx2RARow)indexPath.row) {
    case Armsx2RARowAccount: {
      Armsx2RetroAchievementsAccountController* account = [Armsx2RetroAchievementsAccountController new];
      account.readState = self.readState;
      account.performCommand = self.performCommand;
      [self.navigationController pushViewController:account animated:YES];
      break;
    }
    case Armsx2RARowEnabled:
      [self pushBooleanChoiceWithTitle:@"RetroAchievements" command:@"enabled"
          current:[self.state[@"enabled"] boolValue]];
      break;
    case Armsx2RARowMode: {
      Armsx2RetroAchievementsChoiceController* child = [Armsx2RetroAchievementsChoiceController new];
      child.title = ARMSX2RAText(@"Mode", @"Mode");
      child.command = @"hardcore";
      child.performCommand = self.performCommand;
      BOOL hardcore = [self.state[@"hardcorePreference"] boolValue];
      child.choices = @[
        @{@"title": @"Standard", @"value": @NO, @"selected": @(!hardcore)},
        @{@"title": @"Hardcore", @"value": @YES, @"selected": @(hardcore)},
      ];
      [self.navigationController pushViewController:child animated:YES];
      break;
    }
    case Armsx2RARowNotifications:
      [self pushBooleanChoiceWithTitle:ARMSX2RAText(@"Notifications", @"Notifications")
          command:@"notifications" current:[self.state[@"notifications"] boolValue]];
      break;
    case Armsx2RARowLeaderboards:
      [self pushBooleanChoiceWithTitle:ARMSX2RAText(@"Leaderboard notifications", @"Notifications des classements")
          command:@"leaderboards" current:[self.state[@"leaderboardNotifications"] boolValue]];
      break;
    case Armsx2RARowOverlays:
      [self pushBooleanChoiceWithTitle:ARMSX2RAText(@"Overlays", @"Superpositions")
          command:@"overlays" current:[self.state[@"overlays"] boolValue]];
      break;
    case Armsx2RARowStatus:
    default:
      break;
  }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end
