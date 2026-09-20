#import "Armsx2SessionMenu.h"
#import "Armsx2RetroAchievementsMenu.h"
#import "ARMSX2InGameLocalization.h"
#include <cmath>

typedef NS_ENUM(NSInteger, ARMSX2MenuPage) {
  ARMSX2MenuRoot,
  ARMSX2MenuGraphics,
  ARMSX2MenuGraphicsHacks,
  ARMSX2MenuCheats,
  ARMSX2MenuControls,
  ARMSX2MenuSaveStates,
  ARMSX2MenuLoadStates,
};

#define ARMSX2MenuText(english, french) \
  ARMSX2LocalizedText((english), (french), self.localeIdentifier)

static void ARMSX2MenuOnMain(dispatch_block_t block) {
  if (NSThread.isMainThread) block();
  else dispatch_async(dispatch_get_main_queue(), block);
}

static UINavigationBarAppearance* ARMSX2MenuNavigationAppearance(void) {
  UINavigationBarAppearance* appearance = [UINavigationBarAppearance new];
  [appearance configureWithTransparentBackground];
  appearance.backgroundEffect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemChromeMaterialDark];
  appearance.shadowColor = [UIColor.separatorColor colorWithAlphaComponent:0.25];
  appearance.titleTextAttributes = @{
    NSForegroundColorAttributeName: UIColor.whiteColor,
    NSFontAttributeName: [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold],
  };
  return appearance;
}

@class Armsx2SessionMenu;

@interface Armsx2SessionChoiceMenu : UITableViewController
@property(nonatomic, copy) NSString* command;
@property(nonatomic, copy) NSArray<NSDictionary*>* choices;
@property(nonatomic, copy) Armsx2SessionCommand performCommand;
@property(nonatomic, copy) NSString* localeIdentifier;
@property(nonatomic, weak) Armsx2SessionMenu* owner;
@property(nonatomic, assign) BOOL applying;
@end

@interface Armsx2SessionMenu ()
@property(nonatomic, assign) ARMSX2MenuPage page;
@property(nonatomic, copy) NSDictionary<NSString*, id>* snapshot;
@property(nonatomic, assign) BOOL loading;
@property(nonatomic, copy) NSString* stateMessage;
@property(nonatomic, copy) NSDictionary<NSString*, id>* graphicsHacks;
@property(nonatomic, assign) BOOL graphicsHacksLoading;
- (void)reloadSnapshot;
- (void)reloadGraphicsHacks;
@end

@implementation Armsx2SessionChoiceMenu

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  self.tableView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.58];
  self.tableView.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = ARMSX2MenuNavigationAppearance();
  self.navigationController.navigationBar.scrollEdgeAppearance =
      self.navigationController.navigationBar.standardAppearance;
  self.navigationItem.backButtonTitle = ARMSX2MenuText(@"Back", @"Retour");
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return self.choices.count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  NSDictionary* choice = self.choices[indexPath.row];
  cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.textColor = UIColor.labelColor;
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
  __weak Armsx2SessionChoiceMenu* weakSelf = self;
  self.performCommand(self.command, choice[@"value"], ^(BOOL success, NSString* message) {
    ARMSX2MenuOnMain(^{
      Armsx2SessionChoiceMenu* screen = weakSelf;
      if (!screen) return;
      screen.applying = NO;
      screen.navigationController.view.userInteractionEnabled = YES;
      if (success) {
        [screen.navigationController popViewControllerAnimated:YES];
        [screen.owner reloadSnapshot];
        return;
      }
      UIAlertController* alert = [UIAlertController alertControllerWithTitle:
          ARMSX2MenuText(@"ARMSX2 setting failed", @"Échec du réglage ARMSX2")
          message:message preferredStyle:UIAlertControllerStyleAlert];
      [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
      [screen presentViewController:alert animated:YES completion:nil];
    });
  });
}

@end

@implementation Armsx2SessionMenu

- (instancetype)init {
  self = [super initWithStyle:UITableViewStyleInsetGrouped];
  if (self) _page = ARMSX2MenuRoot;
  return self;
}

- (NSArray<NSString*>*)rootKeys {
  return @[@"graphics", @"cheats", @"controls", @"retroachievements",
           @"save", @"load", @"resume", @"quit"];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.clearColor;
  self.tableView.backgroundColor = [UIColor colorWithWhite:0 alpha:0.58];
  self.tableView.separatorStyle = UITableViewCellSeparatorStyleSingleLine;
  self.tableView.separatorColor = [UIColor.separatorColor colorWithAlphaComponent:0.35];
  self.tableView.sectionHeaderTopPadding = 12;
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 56;
  self.navigationController.navigationBar.prefersLargeTitles = NO;
  self.navigationController.navigationBar.tintColor = UIColor.systemIndigoColor;
  self.navigationController.navigationBar.standardAppearance = ARMSX2MenuNavigationAppearance();
  self.navigationController.navigationBar.scrollEdgeAppearance =
      self.navigationController.navigationBar.standardAppearance;
  self.navigationItem.backButtonTitle = ARMSX2MenuText(@"Back", @"Retour");
  if (self.page == ARMSX2MenuRoot)
    self.title = self.gameTitle.length ? self.gameTitle : @"ARMSX2";
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
      initWithTitle:ARMSX2MenuText(@"Resume Game", @"Reprendre le jeu")
      style:UIBarButtonItemStyleDone target:self action:@selector(resumePressed)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self reloadSnapshot];
}

- (void)reloadSnapshot {
  if (self.loading || !self.readSnapshot) return;
  self.loading = YES;
  self.navigationItem.rightBarButtonItem.enabled = NO;
  __weak Armsx2SessionMenu* weakSelf = self;
  self.readSnapshot(^(NSDictionary<NSString*, id>* snapshot) {
    ARMSX2MenuOnMain(^{
      Armsx2SessionMenu* menu = weakSelf;
      if (!menu) return;
      menu.loading = NO;
      menu.snapshot = [snapshot isKindOfClass:NSDictionary.class] ? snapshot : @{};
      menu.navigationItem.rightBarButtonItem.enabled = YES;
      [menu.tableView reloadData];
    });
  });
}

- (void)reloadGraphicsHacks {
  if (self.graphicsHacksLoading || !self.readGraphicsHacks) return;
  self.graphicsHacksLoading=YES;
  __weak Armsx2SessionMenu* weakSelf=self;
  self.readGraphicsHacks(^(NSDictionary<NSString*, id>* state){
    ARMSX2MenuOnMain(^{
      Armsx2SessionMenu* menu=weakSelf;
      if (!menu) return;
      menu.graphicsHacksLoading=NO;
      menu.graphicsHacks=[state isKindOfClass:NSDictionary.class] ? state : @{};
      [menu.tableView reloadData];
    });
  });
}

- (Armsx2SessionMenu*)child:(ARMSX2MenuPage)page title:(NSString*)title {
  Armsx2SessionMenu* child = [Armsx2SessionMenu new];
  child.page = page;
  child.title = title;
  child.gameTitle = self.gameTitle;
  child.localeIdentifier = self.localeIdentifier;
  child.snapshot = self.snapshot;
  child.readSnapshot = self.readSnapshot;
  child.performCommand = self.performCommand;
  child.readRetroAchievements = self.readRetroAchievements;
  child.performRetroAchievementsCommand = self.performRetroAchievementsCommand;
  child.readGraphicsHacks = self.readGraphicsHacks;
  child.performGraphicsHack = self.performGraphicsHack;
  child.graphicsHacks = self.graphicsHacks;
  child.resumeGame = self.resumeGame;
  child.quitGame = self.quitGame;
  return child;
}

- (void)resumePressed {
  if (!self.loading && self.resumeGame) self.resumeGame();
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  switch (self.page) {
    case ARMSX2MenuRoot: return self.rootKeys.count;
    case ARMSX2MenuGraphics: return self.snapshot.count ? 3 : 0;
    case ARMSX2MenuGraphicsHacks:
      return [self.graphicsHacks[@"items"] isKindOfClass:NSArray.class]
          ? [self.graphicsHacks[@"items"] count] : 0;
    case ARMSX2MenuCheats: return self.snapshot.count ? 2 : 0;
    case ARMSX2MenuControls: return self.snapshot.count ? 1 : 0;
    case ARMSX2MenuSaveStates:
    case ARMSX2MenuLoadStates: return self.snapshot.count ? 5 : 0;
  }
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (self.page == ARMSX2MenuGraphics)
    return ARMSX2MenuText(@"Per-game graphics settings are applied live. Advanced hacks keep ARMSX2/GameDB automatic behavior unless explicitly overridden.",
                          @"Les réglages graphiques par jeu sont appliqués en direct. Les hacks avancés conservent le comportement automatique ARMSX2/GameDB sauf remplacement explicite.");
  if (self.page == ARMSX2MenuGraphicsHacks)
    return ARMSX2MenuText(@"Automatic removes this game's override and returns control to ARMSX2/GameDB.",
                          @"Automatique supprime le réglage propre à ce jeu et rend le contrôle à ARMSX2/GameDB.");
  if (self.page == ARMSX2MenuCheats)
    return ARMSX2MenuText(@"Hardcore RetroAchievements can disable cheats and save-state features.",
                          @"Le mode Hardcore de RetroAchievements peut désactiver les cheats et certaines fonctions de save state.");
  if (self.page == ARMSX2MenuControls)
    return ARMSX2MenuText(@"Choose whether NeoStation's PS2 touch overlay is visible.",
                          @"Choisissez si les commandes tactiles PS2 de NeoStation sont visibles.");
  if ((self.page == ARMSX2MenuSaveStates || self.page == ARMSX2MenuLoadStates) &&
      self.stateMessage.length)
    return self.stateMessage;
  return nil;
}

- (NSString*)aspectTitle:(NSInteger)value {
  NSArray* names = @[ARMSX2MenuText(@"Auto", @"Auto"), @"4:3", @"16:9", @"10:7",
                     ARMSX2MenuText(@"Stretch", @"Étendre")];
  return value >= 0 && value < (NSInteger)names.count ? names[value] : ARMSX2MenuText(@"Auto", @"Auto");
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = [UIColor.secondarySystemGroupedBackgroundColor colorWithAlphaComponent:0.82];
  cell.tintColor = UIColor.systemIndigoColor;
  cell.textLabel.textColor = UIColor.labelColor;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  cell.textLabel.font = [UIFont systemFontOfSize:16 weight:UIFontWeightSemibold];
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.numberOfLines = 0;
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  const NSInteger row = indexPath.row;

  if (self.page == ARMSX2MenuRoot) {
    NSString* key = self.rootKeys[row];
    NSDictionary* labels = @{
      @"graphics": ARMSX2MenuText(@"Graphics", @"Graphismes"),
      @"cheats": ARMSX2MenuText(@"Compatibility / Cheats", @"Hacks / Cheats"),
      @"controls": ARMSX2MenuText(@"Controls", @"Commandes"),
      @"retroachievements": @"RetroAchievements",
      @"save": ARMSX2MenuText(@"Save State", @"Sauvegarder un état"),
      @"load": ARMSX2MenuText(@"Load State", @"Charger un état"),
      @"resume": ARMSX2MenuText(@"Resume Game", @"Reprendre le jeu"),
      @"quit": ARMSX2MenuText(@"Quit Game", @"Quitter le jeu"),
    };
    NSDictionary* symbols = @{
      @"graphics": @"display",
      @"cheats": @"wrench.and.screwdriver",
      @"controls": @"gamecontroller",
      @"retroachievements": @"trophy",
      @"save": @"square.and.arrow.down",
      @"load": @"square.and.arrow.up",
      @"resume": @"play.fill",
      @"quit": @"xmark.circle",
    };
    cell.textLabel.text = labels[key];
    cell.imageView.image = [UIImage systemImageNamed:symbols[key] ?: @"circle"];
    cell.imageView.tintColor = [key isEqual:@"quit"] ? UIColor.systemRedColor : UIColor.systemIndigoColor;
    if ([key isEqual:@"quit"]) cell.textLabel.textColor = UIColor.systemRedColor;
  } else if (self.page == ARMSX2MenuGraphics) {
    if (row == 0) {
      cell.textLabel.text = ARMSX2MenuText(@"Internal Resolution", @"Résolution interne");
      cell.detailTextLabel.text = [NSString stringWithFormat:@"%.0f×", [self.snapshot[@"upscale"] floatValue]];
    } else if (row == 1) {
      cell.textLabel.text = ARMSX2MenuText(@"Screen Format", @"Format d’écran");
      cell.detailTextLabel.text = [self aspectTitle:[self.snapshot[@"aspect"] integerValue]];
    } else {
      cell.textLabel.text = ARMSX2MenuText(@"Graphics Hacks", @"Hacks graphiques");
      cell.detailTextLabel.text = ARMSX2MenuText(@"Per-game advanced GS options", @"Options GS avancées par jeu");
    }
  } else if (self.page == ARMSX2MenuGraphicsHacks) {
    NSArray* items = [self.graphicsHacks[@"items"] isKindOfClass:NSArray.class] ? self.graphicsHacks[@"items"] : @[];
    if (row < (NSInteger)items.count) {
      NSDictionary* item = items[row];
      NSString* english = [item[@"english"] isKindOfClass:NSString.class] ? item[@"english"] : @"";
      NSString* french = [item[@"french"] isKindOfClass:NSString.class] ? item[@"french"] : english;
      cell.textLabel.text = ARMSX2LocalizedText(english, french, self.localeIdentifier);
      const NSInteger value = [item[@"value"] integerValue];
      cell.detailTextLabel.text = value < 0
          ? ARMSX2MenuText(@"Automatic (ARMSX2/GameDB)", @"Automatique (ARMSX2/GameDB)")
          : (value ? ARMSX2MenuText(@"On", @"Activé") : ARMSX2MenuText(@"Off", @"Désactivé"));
    }
  } else if (self.page == ARMSX2MenuCheats) {
    if (row == 0) {
      cell.textLabel.text = ARMSX2MenuText(@"Enable Cheats", @"Activer les cheats");
      cell.detailTextLabel.text = ARMSX2MenuText([self.snapshot[@"cheats"] boolValue] ? @"On" : @"Off",
                                                [self.snapshot[@"cheats"] boolValue] ? @"Activés" : @"Désactivés");
    } else {
      cell.textLabel.text = ARMSX2MenuText(@"Reload Cheats / Patches", @"Recharger cheats / patches");
      cell.accessoryType = UITableViewCellAccessoryNone;
    }
  } else if (self.page == ARMSX2MenuControls) {
    cell.textLabel.text = ARMSX2MenuText(@"Touch Controls", @"Commandes tactiles");
    cell.detailTextLabel.text = ARMSX2MenuText([self.snapshot[@"touch"] boolValue] ? @"On" : @"Off",
                                              [self.snapshot[@"touch"] boolValue] ? @"Activées" : @"Désactivées");
  } else if (self.page == ARMSX2MenuSaveStates || self.page == ARMSX2MenuLoadStates) {
    const NSUInteger slot = row + 1;
    const NSUInteger mask = [self.snapshot[@"saveStateMask"] unsignedIntegerValue];
    const BOOL occupied = (mask & (1u << row)) != 0;
    cell.textLabel.text = [NSString stringWithFormat:@"%@ %lu",
        ARMSX2MenuText(@"Slot", @"Slot"), (unsigned long)slot];
    cell.detailTextLabel.text = occupied
        ? ARMSX2MenuText(@"Saved state available", @"État sauvegardé disponible")
        : ARMSX2MenuText(@"Empty", @"Vide");
    cell.accessoryType = UITableViewCellAccessoryNone;
    if (self.page == ARMSX2MenuLoadStates && !occupied) {
      cell.textLabel.textColor = UIColor.secondaryLabelColor;
      cell.selectionStyle = UITableViewCellSelectionStyleNone;
      cell.userInteractionEnabled = NO;
    }
  }

  if (self.loading) {
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    cell.userInteractionEnabled = NO;
  }
  return cell;
}

- (void)pushChoice:(NSString*)title
           command:(NSString*)command
            values:(NSArray*)values
            titles:(NSArray<NSString*>*)titles
     selectedIndex:(NSInteger)selected {
  Armsx2SessionChoiceMenu* child = [Armsx2SessionChoiceMenu new];
  child.title = title;
  child.command = command;
  child.performCommand = self.performCommand;
  child.localeIdentifier = self.localeIdentifier;
  child.owner = self;
  NSMutableArray* choices = [NSMutableArray arrayWithCapacity:values.count];
  for (NSUInteger i = 0; i < values.count; i++) {
    [choices addObject:@{
      @"title": titles[i],
      @"value": values[i],
      @"selected": @(i == (NSUInteger)selected),
    }];
  }
  child.choices = choices;
  [self.navigationController pushViewController:child animated:YES];
}

- (void)perform:(NSString*)command value:(id)value successText:(NSString*)successText {
  if (self.loading || !self.performCommand) return;
  self.loading = YES;
  self.navigationController.view.userInteractionEnabled = NO;
  __weak Armsx2SessionMenu* weakSelf = self;
  self.performCommand(command, value, ^(BOOL success, NSString* message) {
    ARMSX2MenuOnMain(^{
      Armsx2SessionMenu* menu = weakSelf;
      if (!menu) return;
      menu.loading = NO;
      menu.navigationController.view.userInteractionEnabled = YES;
      menu.stateMessage = success ? successText : message;
      [menu reloadSnapshot];
    });
  });
}

- (void)confirmQuit {
  if (self.loading || !self.quitGame) return;
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:
      ARMSX2MenuText(@"Quit Game", @"Quitter le jeu")
      message:ARMSX2MenuText(@"Return to NeoStation?", @"Revenir à NeoStation ?")
      preferredStyle:UIAlertControllerStyleAlert];
  [alert addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"Cancel", @"Annuler")
      style:UIAlertActionStyleCancel handler:nil]];
  __weak Armsx2SessionMenu* weakSelf = self;
  [alert addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"Quit", @"Quitter")
      style:UIAlertActionStyleDestructive handler:^(__unused UIAlertAction* action) {
        weakSelf.navigationController.view.userInteractionEnabled = NO;
        if (weakSelf.quitGame) weakSelf.quitGame();
      }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (self.loading) return;
  const NSInteger row = indexPath.row;

  if (self.page == ARMSX2MenuRoot) {
    NSString* key = self.rootKeys[row];
    if ([key isEqual:@"graphics"]) {
      [self.navigationController pushViewController:[self child:ARMSX2MenuGraphics
          title:ARMSX2MenuText(@"Graphics", @"Graphismes")] animated:YES];
    } else if ([key isEqual:@"cheats"]) {
      [self.navigationController pushViewController:[self child:ARMSX2MenuCheats
          title:ARMSX2MenuText(@"Compatibility / Cheats", @"Hacks / Cheats")] animated:YES];
    } else if ([key isEqual:@"controls"]) {
      [self.navigationController pushViewController:[self child:ARMSX2MenuControls
          title:ARMSX2MenuText(@"Controls", @"Commandes")] animated:YES];
    } else if ([key isEqual:@"retroachievements"]) {
      Armsx2RetroAchievementsMenu* ra = [Armsx2RetroAchievementsMenu new];
      ra.readState = self.readRetroAchievements;
      ra.performCommand = self.performRetroAchievementsCommand;
      ra.localeIdentifier = self.localeIdentifier;
      [self.navigationController pushViewController:ra animated:YES];
    } else if ([key isEqual:@"save"]) {
      [self.navigationController pushViewController:[self child:ARMSX2MenuSaveStates
          title:ARMSX2MenuText(@"Save State", @"Sauvegarder un état")] animated:YES];
    } else if ([key isEqual:@"load"]) {
      [self.navigationController pushViewController:[self child:ARMSX2MenuLoadStates
          title:ARMSX2MenuText(@"Load State", @"Charger un état")] animated:YES];
    } else if ([key isEqual:@"resume"]) {
      [self resumePressed];
    } else if ([key isEqual:@"quit"]) {
      [self confirmQuit];
    }
    return;
  }

  if (self.page == ARMSX2MenuGraphics) {
    if (row == 0) {
      NSArray* values = @[@1.0f, @2.0f, @3.0f, @4.0f, @6.0f, @8.0f];
      NSInteger selected = 0;
      const float current = [self.snapshot[@"upscale"] floatValue];
      for (NSUInteger i = 0; i < values.count; i++)
        if (fabsf([values[i] floatValue] - current) < 0.05f) selected = (NSInteger)i;
      [self pushChoice:ARMSX2MenuText(@"Internal Resolution", @"Résolution interne")
                command:@"upscale" values:values
                 titles:@[@"1×", @"2×", @"3×", @"4×", @"6×", @"8×"]
          selectedIndex:selected];
    } else if (row == 1) {
      NSInteger selected = [self.snapshot[@"aspect"] integerValue];
      [self pushChoice:ARMSX2MenuText(@"Screen Format", @"Format d’écran")
                command:@"aspect" values:@[@0, @1, @2, @3, @4]
                 titles:@[ARMSX2MenuText(@"Auto", @"Auto"), @"4:3", @"16:9", @"10:7",
                          ARMSX2MenuText(@"Stretch", @"Étendre")]
          selectedIndex:selected];
    } else {
      Armsx2SessionMenu* hacks=[self child:ARMSX2MenuGraphicsHacks
          title:ARMSX2MenuText(@"Graphics Hacks", @"Hacks graphiques")];
      [self.navigationController pushViewController:hacks animated:YES];
      [hacks reloadGraphicsHacks];
    }
  } else if (self.page == ARMSX2MenuGraphicsHacks) {
    NSArray* items = [self.graphicsHacks[@"items"] isKindOfClass:NSArray.class] ? self.graphicsHacks[@"items"] : @[];
    if (row >= (NSInteger)items.count || !self.performGraphicsHack) return;
    NSDictionary* item=items[row];
    NSString* key=[item[@"key"] isKindOfClass:NSString.class] ? item[@"key"] : @"";
    if (!key.length) return;
    NSString* english=[item[@"english"] isKindOfClass:NSString.class] ? item[@"english"] : @"";
    NSString* french=[item[@"french"] isKindOfClass:NSString.class] ? item[@"french"] : english;
    UIAlertController* sheet=[UIAlertController alertControllerWithTitle:
        ARMSX2LocalizedText(english, french, self.localeIdentifier)
        message:nil preferredStyle:UIAlertControllerStyleActionSheet];
    __weak Armsx2SessionMenu* weakSelf=self;
    void (^apply)(NSInteger)=^(NSInteger value) {
      weakSelf.graphicsHacksLoading=YES;
      weakSelf.navigationController.view.userInteractionEnabled=NO;
      weakSelf.performGraphicsHack(key,value,^(BOOL success,NSString* message){
        ARMSX2MenuOnMain(^{
          weakSelf.graphicsHacksLoading=NO;
          weakSelf.navigationController.view.userInteractionEnabled=YES;
          weakSelf.stateMessage=message;
          if (success) [weakSelf reloadGraphicsHacks];
        });
      });
    };
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"Automatic", @"Automatique") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){apply(-1);}]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"Off", @"Désactivé") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){apply(0);}]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"On", @"Activé") style:UIAlertActionStyleDefault handler:^(__unused UIAlertAction* a){apply(1);}]];
    [sheet addAction:[UIAlertAction actionWithTitle:ARMSX2MenuText(@"Cancel", @"Annuler") style:UIAlertActionStyleCancel handler:nil]];
    if (sheet.popoverPresentationController) {
      sheet.popoverPresentationController.sourceView=self.view;
      sheet.popoverPresentationController.sourceRect=[tableView rectForRowAtIndexPath:indexPath];
    }
    [self presentViewController:sheet animated:YES completion:nil];
  } else if (self.page == ARMSX2MenuCheats) {
    if (row == 0) {
      const BOOL enabled = [self.snapshot[@"cheats"] boolValue];
      [self pushChoice:ARMSX2MenuText(@"Enable Cheats", @"Activer les cheats")
                command:@"cheats" values:@[@NO, @YES]
                 titles:@[ARMSX2MenuText(@"Off", @"Désactivé"), ARMSX2MenuText(@"On", @"Activé")]
          selectedIndex:enabled ? 1 : 0];
    } else {
      [self perform:@"reloadCheats" value:@0
        successText:ARMSX2MenuText(@"Cheats and patches reloaded.",
                                   @"Cheats et patches rechargés.")];
    }
  } else if (self.page == ARMSX2MenuControls) {
    const BOOL enabled = [self.snapshot[@"touch"] boolValue];
    [self pushChoice:ARMSX2MenuText(@"Touch Controls", @"Commandes tactiles")
              command:@"touch" values:@[@NO, @YES]
               titles:@[ARMSX2MenuText(@"Off", @"Désactivées"), ARMSX2MenuText(@"On", @"Activées")]
        selectedIndex:enabled ? 1 : 0];
  } else if (self.page == ARMSX2MenuSaveStates || self.page == ARMSX2MenuLoadStates) {
    const NSUInteger slot = row + 1;
    [self perform:self.page == ARMSX2MenuLoadStates ? @"loadState" : @"saveState"
            value:@(slot)
      successText:self.page == ARMSX2MenuLoadStates
          ? ARMSX2MenuText(@"State loaded.", @"État chargé.")
          : ARMSX2MenuText(@"State saved.", @"État sauvegardé.")];
  }
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return UIInterfaceOrientationMaskLandscape;
}

@end
