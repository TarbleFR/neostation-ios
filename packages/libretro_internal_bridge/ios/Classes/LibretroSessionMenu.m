#import "LibretroSessionMenu.h"

#import "LibretroOrientation.h"

#include <math.h>

/// Orientations of the in-game menu: the game's (portrait and landscape)
/// instead of a landscape lock.
static UIInterfaceOrientationMask LibretroMenuOrientations(void) {
  UIInterfaceOrientationMask mask = LibretroOrientationGameMask();
  return mask != 0 ? mask : UIInterfaceOrientationMaskAllButUpsideDown;
}

/// `value` clamped to [minimum, maximum] and snapped to `step` from `minimum`.
static float LibretroMenuSnap(float value, float minimum, float maximum, float step) {
  if (!isfinite(minimum)) minimum = 0;
  if (!isfinite(maximum) || maximum < minimum) maximum = minimum;
  if (!isfinite(value)) value = minimum;
  if (step > 0 && isfinite(step)) {
    float steps = roundf((value - minimum) / step);
    value = minimum + steps * step;
  }
  return fminf(fmaxf(value, minimum), maximum);
}

/// Cells of pages that preview the game: 85 % of the dark grouped cell colour.
static UIColor *LibretroMenuPreviewCellColor(void) {
  return [UIColor colorWithRed:0.11 green:0.11 blue:0.118 alpha:0.85];
}

#pragma mark - Rows

@interface LibretroMenuRow ()
/// The image loader was started for this row object.
@property(nonatomic, assign) BOOL imageRequested;
@end

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

+ (instancetype)sliderWithTitle:(NSString *)title
                          value:(float)value
                        minimum:(float)minimum
                        maximum:(float)maximum
                           step:(float)step
                      formatter:(NSString * (^)(float value))formatter
                        changed:(void (^)(LibretroMenuPage *page, float value, BOOL finished))changed {
  LibretroMenuRow *row = [self rowWithTitle:title action:nil];
  row.isSlider = YES;
  row.sliderMinimum = isfinite(minimum) ? minimum : 0;
  row.sliderMaximum = isfinite(maximum) && maximum >= row.sliderMinimum ? maximum : row.sliderMinimum;
  row.sliderStep = isfinite(step) && step > 0 ? step : 0;
  row.sliderValue = LibretroMenuSnap(value, row.sliderMinimum, row.sliderMaximum, row.sliderStep);
  row.valueFormatter = formatter;
  row.sliderChanged = changed;
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

#pragma mark - Navigation

@implementation LibretroMenuNavigationController

- (void)viewDidLoad {
  [super viewDidLoad];
  // Pages that preview the game leave it visible behind them.
  self.view.backgroundColor = UIColor.clearColor;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations {
  return LibretroMenuOrientations();
}

- (BOOL)shouldAutorotate {
  return YES;
}

@end

#pragma mark - Slider

/// UISlider whose VoiceOver value is the row's formatted value and whose
/// increments follow the row's step.
@interface LibretroMenuSlider : UISlider
@property(nonatomic, assign) float step;
@property(nonatomic, copy, nullable) NSString * (^formatter)(float value);
/// VoiceOver changed the value (already snapped and applied).
@property(nonatomic, copy, nullable) void (^stepped)(float value);
@end

@implementation LibretroMenuSlider

- (NSString *)accessibilityValue {
  if (self.formatter != nil) return self.formatter(self.value);
  return [super accessibilityValue];
}

- (void)accessibilityIncrement {
  [self moveBySteps:1];
}

- (void)accessibilityDecrement {
  [self moveBySteps:-1];
}

- (void)moveBySteps:(int)direction {
  if (!self.enabled) return;
  float range = self.maximumValue - self.minimumValue;
  float step = self.step > 0 ? self.step : range / 10.0f;
  if (!(step > 0)) return;
  float value = LibretroMenuSnap(self.value + (float)direction * step, self.minimumValue, self.maximumValue, self.step);
  if (fabsf(value - self.value) < 1e-6f) return;
  self.value = value;
  if (self.stepped != nil) self.stepped(value);
}

@end

/// Slider row: the title and the formatted value on one line, the slider
/// below at full width.
@interface LibretroMenuSliderCell : UITableViewCell
@property(nonatomic, strong, readonly) UILabel *nameLabel;
@property(nonatomic, strong, readonly) UILabel *amountLabel;
@property(nonatomic, strong, readonly) LibretroMenuSlider *slider;
@property(nonatomic, weak, nullable) LibretroMenuRow *row;
@property(nonatomic, weak, nullable) LibretroMenuPage *page;
/// Tracking state of the current drag.
@property(nonatomic, readonly) BOOL dragging;
/// Called once a drag (or a VoiceOver step) has finished.
@property(nonatomic, copy, nullable) void (^dragEnded)(void);
- (void)configureWithRow:(LibretroMenuRow *)row page:(LibretroMenuPage *)page;
@end

@implementation LibretroMenuSliderCell {
  float _lastValue;
  BOOL _sentDuringDrag;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier {
  self = [super initWithStyle:style reuseIdentifier:reuseIdentifier];
  if (self) {
    self.selectionStyle = UITableViewCellSelectionStyleNone;
    _nameLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _nameLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _nameLabel.numberOfLines = 0;
    _nameLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _nameLabel.adjustsFontForContentSizeCategory = YES;
    _nameLabel.isAccessibilityElement = NO;
    [_nameLabel setContentCompressionResistancePriority:UILayoutPriorityDefaultLow
                                                forAxis:UILayoutConstraintAxisHorizontal];

    _amountLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _amountLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _amountLabel.font = [UIFont monospacedDigitSystemFontOfSize:[UIFont preferredFontForTextStyle:UIFontTextStyleBody]
                                                                    .pointSize
                                                         weight:UIFontWeightRegular];
    _amountLabel.textColor = UIColor.secondaryLabelColor;
    _amountLabel.textAlignment = NSTextAlignmentRight;
    _amountLabel.isAccessibilityElement = NO;
    [_amountLabel setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                  forAxis:UILayoutConstraintAxisHorizontal];
    [_amountLabel setContentHuggingPriority:UILayoutPriorityRequired forAxis:UILayoutConstraintAxisHorizontal];

    _slider = [[LibretroMenuSlider alloc] initWithFrame:CGRectZero];
    _slider.translatesAutoresizingMaskIntoConstraints = NO;
    _slider.continuous = YES;
    [_slider addTarget:self action:@selector(sliderTouchedDown:) forControlEvents:UIControlEventTouchDown];
    [_slider addTarget:self action:@selector(sliderMoved:) forControlEvents:UIControlEventValueChanged];
    [_slider addTarget:self
                action:@selector(sliderReleased:)
      forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
    __weak LibretroMenuSliderCell *weakSelf = self;
    _slider.stepped = ^(float value) {
      [weakSelf report:value finished:YES];
    };

    UIView *content = self.contentView;
    [content addSubview:_nameLabel];
    [content addSubview:_amountLabel];
    [content addSubview:_slider];
    UILayoutGuide *margins = content.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
      [_nameLabel.topAnchor constraintEqualToAnchor:margins.topAnchor],
      [_nameLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
      [_amountLabel.leadingAnchor constraintGreaterThanOrEqualToAnchor:_nameLabel.trailingAnchor constant:8],
      [_amountLabel.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
      [_amountLabel.firstBaselineAnchor constraintEqualToAnchor:_nameLabel.firstBaselineAnchor],
      [_slider.topAnchor constraintEqualToAnchor:_nameLabel.bottomAnchor constant:8],
      [_slider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
      [_slider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
      [_slider.bottomAnchor constraintEqualToAnchor:margins.bottomAnchor],
    ]];
  }
  return self;
}

- (void)configureWithRow:(LibretroMenuRow *)row page:(LibretroMenuPage *)page {
  self.row = row;
  self.page = page;
  _nameLabel.text = row.title;
  _nameLabel.textColor = row.enabled ? UIColor.labelColor : UIColor.secondaryLabelColor;
  _slider.minimumValue = row.sliderMinimum;
  _slider.maximumValue = MAX(row.sliderMaximum, row.sliderMinimum);
  _slider.step = row.sliderStep;
  _slider.formatter = row.valueFormatter;
  _slider.enabled = row.enabled;
  float value = LibretroMenuSnap(row.sliderValue, row.sliderMinimum, row.sliderMaximum, row.sliderStep);
  _slider.value = value;
  _slider.accessibilityLabel = row.spokenLabel ?: row.title;
  _slider.accessibilityIdentifier = row.identifier;
  _lastValue = value;
  [self showValue:value];
}

- (void)showValue:(float)value {
  LibretroMenuRow *row = self.row;
  NSString *text = row.valueFormatter != nil ? row.valueFormatter(value) : nil;
  _amountLabel.text = text ?: [NSString stringWithFormat:@"%.2f", value];
}

- (float)snappedSliderValue {
  LibretroMenuRow *row = self.row;
  float step = row != nil ? row.sliderStep : _slider.step;
  return LibretroMenuSnap(_slider.value, _slider.minimumValue, _slider.maximumValue, step);
}

- (void)sliderTouchedDown:(UISlider *)slider {
  _dragging = YES;
  _sentDuringDrag = NO;
}

- (void)sliderMoved:(UISlider *)slider {
  float value = [self snappedSliderValue];
  if (fabsf(slider.value - value) > 1e-6f) slider.value = value;
  if (fabsf(value - _lastValue) < 1e-6f) return;
  if (!slider.isTracking) {
    // Value changed without a drag (keyboard, focus): final at once.
    [self report:value finished:YES];
    return;
  }
  _sentDuringDrag = YES;
  [self report:value finished:NO];
}

- (void)sliderReleased:(UISlider *)slider {
  float value = [self snappedSliderValue];
  if (fabsf(slider.value - value) > 1e-6f) slider.value = value;
  BOOL changed = _sentDuringDrag || fabsf(value - _lastValue) >= 1e-6f;
  _dragging = NO;
  _sentDuringDrag = NO;
  if (changed) {
    [self report:value finished:YES];
  } else if (self.dragEnded != nil) {
    self.dragEnded();
  }
}

/// Updates the row and the value label in place (no table reload), then
/// tells the page's owner.
- (void)report:(float)value finished:(BOOL)finished {
  LibretroMenuRow *row = self.row;
  _lastValue = value;
  row.sliderValue = value;
  [self showValue:value];
  LibretroMenuPage *page = self.page;
  if (row.sliderChanged != nil && page != nil) row.sliderChanged(page, value, finished);
  if (finished && self.dragEnded != nil) self.dragEnded();
}

@end

#pragma mark - Image rows

@interface LibretroMenuImageCell : UITableViewCell
@property(nonatomic, weak, nullable) LibretroMenuRow *row;
@end

@implementation LibretroMenuImageCell
@end

static UIImage *LibretroMenuPlaceholder(CGSize size) {
  if (!(size.width > 0) || !(size.height > 0)) return nil;
  UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:size];
  return [renderer imageWithActions:^(UIGraphicsImageRendererContext *context) {
    [[UIColor colorWithWhite:0.22 alpha:1.0] setFill];
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, size.width, size.height) cornerRadius:6] fill];
  }];
}

#pragma mark - Page

@implementation LibretroMenuPage {
  NSArray<LibretroMenuSection *> *_sections;
  /// Layout applied for previewsGame: avoids re-applying the same values
  /// from viewDidLayoutSubviews.
  CGSize _previewLayoutSize;
  CGFloat _previewSafeTop;
  BOOL _previewStyled;
  BOOL _rebuildPending;
  NSInteger _activeSliders;
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
  self.tableView.rowHeight = UITableViewAutomaticDimension;
  self.tableView.estimatedRowHeight = 52;
  if (self.closeHandler != nil) {
    self.navigationItem.rightBarButtonItem =
        [[UIBarButtonItem alloc] initWithTitle:self.closeTitle ?: @"OK"
                                         style:UIBarButtonItemStyleDone
                                        target:self
                                        action:@selector(closePressed)];
  }
  [self applyPreviewStyle];
}

- (void)setPreviewsGame:(BOOL)previewsGame {
  if (_previewsGame == previewsGame) return;
  _previewsGame = previewsGame;
  if (self.isViewLoaded) {
    [self applyPreviewStyle];
    [self.view setNeedsLayout];
    [self.tableView reloadData];
  }
}

/// Transparent table and navigation bar for pages whose changes are seen
/// on the game; the opaque dark style otherwise.
- (void)applyPreviewStyle {
  UITableView *table = self.tableView;
  if (self.previewsGame) {
    table.backgroundColor = UIColor.clearColor;
    table.backgroundView = nil;
    table.cellLayoutMarginsFollowReadableWidth = NO;
    UINavigationBarAppearance *appearance = [[UINavigationBarAppearance alloc] init];
    [appearance configureWithTransparentBackground];
    self.navigationItem.standardAppearance = appearance;
    self.navigationItem.compactAppearance = appearance;
    self.navigationItem.scrollEdgeAppearance = appearance;
    self.navigationItem.compactScrollEdgeAppearance = appearance;
    _previewStyled = YES;
  } else if (_previewStyled) {
    table.backgroundColor = UIColor.systemGroupedBackgroundColor;
    self.navigationItem.standardAppearance = nil;
    self.navigationItem.compactAppearance = nil;
    self.navigationItem.scrollEdgeAppearance = nil;
    self.navigationItem.compactScrollEdgeAppearance = nil;
    UIEdgeInsets inset = table.contentInset;
    inset.top = 0;
    table.contentInset = inset;
    table.directionalLayoutMargins = NSDirectionalEdgeInsetsZero;
    _previewLayoutSize = CGSizeZero;
    _previewStyled = NO;
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!self.previewsGame) return;
  UITableView *table = self.tableView;
  CGSize size = table.bounds.size;
  if (size.width < 1 || size.height < 1) return;
  CGFloat safeTop = table.safeAreaInsets.top;
  if (CGSizeEqualToSize(size, _previewLayoutSize) && fabs(safeTop - _previewSafeTop) < 0.5) return;
  _previewLayoutSize = size;
  _previewSafeTop = safeTop;
  BOOL landscape = size.width > size.height;
  UIEdgeInsets inset = table.contentInset;
  NSDirectionalEdgeInsets margins = NSDirectionalEdgeInsetsZero;
  if (landscape) {
    // Trailing half: the game stays visible on the leading half.
    inset.top = 0;
    margins.leading = floor(size.width * 0.5);
  } else {
    // Bottom half: the content starts in the middle of the screen.
    inset.top = MAX(0, floor(size.height * 0.5) - safeTop);
  }
  CGFloat previousTop = table.adjustedContentInset.top;
  BOOL atTop = table.contentOffset.y <= -previousTop + 1;
  table.directionalLayoutMargins = margins;
  if (fabs(inset.top - table.contentInset.top) > 0.5) {
    table.contentInset = inset;
    if (atTop) table.contentOffset = CGPointMake(table.contentOffset.x, -table.adjustedContentInset.top);
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
  if (_activeSliders > 0) {
    // Never reload while a slider is dragged: the drag would be cancelled.
    _rebuildPending = YES;
    return;
  }
  _rebuildPending = NO;
  _sections = self.builder != nil ? self.builder() : @[];
  if (self.isViewLoaded) [self.tableView reloadData];
}

- (void)push:(LibretroMenuPage *)page {
  page.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  [self.navigationController pushViewController:page animated:YES];
}

- (LibretroMenuRow *)rowAtIndexPath:(NSIndexPath *)indexPath {
  if (indexPath.section < 0 || indexPath.section >= (NSInteger)_sections.count) return nil;
  NSArray<LibretroMenuRow *> *rows = _sections[indexPath.section].rows;
  return indexPath.row >= 0 && indexPath.row < (NSInteger)rows.count ? rows[indexPath.row] : nil;
}

- (NSIndexPath *)indexPathForMenuRow:(LibretroMenuRow *)row {
  for (NSUInteger section = 0; section < _sections.count; section++) {
    NSUInteger index = [_sections[section].rows indexOfObjectIdenticalTo:row];
    if (index != NSNotFound) return [NSIndexPath indexPathForRow:(NSInteger)index inSection:(NSInteger)section];
  }
  return nil;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)tableView {
  return (NSInteger)_sections.count;
}

- (NSInteger)tableView:(UITableView *)tableView numberOfRowsInSection:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)_sections.count) return 0;
  return (NSInteger)_sections[section].rows.count;
}

- (NSString *)tableView:(UITableView *)tableView titleForHeaderInSection:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)_sections.count) return nil;
  return _sections[section].title;
}

- (NSString *)tableView:(UITableView *)tableView titleForFooterInSection:(NSInteger)section {
  if (section < 0 || section >= (NSInteger)_sections.count) return nil;
  return _sections[section].footer;
}

- (void)configureAccessoryOfCell:(UITableViewCell *)cell row:(LibretroMenuRow *)row indexPath:(NSIndexPath *)indexPath {
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
}

- (UITableViewCell *)sliderCellForRow:(LibretroMenuRow *)row {
  LibretroMenuSliderCell *cell = [[LibretroMenuSliderCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                               reuseIdentifier:nil];
  [cell configureWithRow:row page:self];
  __weak LibretroMenuPage *weakSelf = self;
  __weak LibretroMenuSliderCell *weakCell = cell;
  [cell.slider addTarget:self action:@selector(sliderDragBegan:) forControlEvents:UIControlEventTouchDown];
  cell.dragEnded = ^{
    LibretroMenuPage *page = weakSelf;
    LibretroMenuSliderCell *strongCell = weakCell;
    if (page == nil || strongCell == nil) return;
    [page sliderDragEnded];
  };
  return cell;
}

- (void)sliderDragBegan:(UISlider *)slider {
  _activeSliders++;
}

- (void)sliderDragEnded {
  if (_activeSliders > 0) _activeSliders--;
  if (_activeSliders == 0 && _rebuildPending) {
    // Let the release finish before the cells are replaced.
    __weak LibretroMenuPage *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      LibretroMenuPage *page = weakSelf;
      if (page != nil && page->_rebuildPending) [page rebuild];
    });
  }
}

- (void)applyImage:(UIImage *)image toCell:(LibretroMenuImageCell *)cell row:(LibretroMenuRow *)row {
  if (![cell.contentConfiguration isKindOfClass:[UIListContentConfiguration class]]) return;
  UIListContentConfiguration *content = [(UIListContentConfiguration *)cell.contentConfiguration copy];
  content.image = image ?: LibretroMenuPlaceholder(row.imageSize);
  cell.contentConfiguration = content;
}

- (UITableViewCell *)imageCellForRow:(LibretroMenuRow *)row indexPath:(NSIndexPath *)indexPath {
  LibretroMenuImageCell *cell = [[LibretroMenuImageCell alloc] initWithStyle:UITableViewCellStyleDefault
                                                             reuseIdentifier:nil];
  cell.row = row;
  UIListContentConfiguration *content = [UIListContentConfiguration subtitleCellConfiguration];
  content.text = row.title;
  content.secondaryText = row.detail;
  content.textProperties.numberOfLines = 0;
  content.secondaryTextProperties.numberOfLines = 0;
  content.secondaryTextProperties.color = UIColor.secondaryLabelColor;
  UIColor *color = row.destructive ? UIColor.systemRedColor : UIColor.labelColor;
  content.textProperties.color = row.enabled ? color : UIColor.secondaryLabelColor;
  CGSize size = row.imageSize;
  if (size.width > 0 && size.height > 0) {
    content.imageProperties.maximumSize = size;
    content.imageProperties.reservedLayoutSize = size;
  }
  content.imageProperties.cornerRadius = 6;
  content.imageToTextPadding = 12;
  content.image = row.image ?: LibretroMenuPlaceholder(size);
  cell.contentConfiguration = content;

  if (row.image == nil && row.imageLoader != nil && !row.imageRequested) {
    row.imageRequested = YES;
    __weak LibretroMenuPage *weakSelf = self;
    __weak LibretroMenuRow *weakRow = row;
    void (^deliver)(UIImage *image) = ^(UIImage *image) {
      void (^apply)(void) = ^{
        LibretroMenuRow *strongRow = weakRow;
        if (strongRow == nil || image == nil) return;
        strongRow.image = image;
        LibretroMenuPage *page = weakSelf;
        if (page == nil || !page.isViewLoaded) return;
        NSIndexPath *path = [page indexPathForMenuRow:strongRow];
        if (path == nil) return;
        // Only the visible cell still showing this row receives it.
        UITableViewCell *visible = [page.tableView cellForRowAtIndexPath:path];
        if (![visible isKindOfClass:[LibretroMenuImageCell class]]) return;
        LibretroMenuImageCell *imageCell = (LibretroMenuImageCell *)visible;
        if (imageCell.row != strongRow) return;
        [page applyImage:image toCell:imageCell row:strongRow];
      };
      if (NSThread.isMainThread) {
        apply();
      } else {
        dispatch_async(dispatch_get_main_queue(), apply);
      }
    };
    row.imageLoader(deliver);
    // A loader answering at once fills this cell before it is shown.
    if (row.image != nil) [self applyImage:row.image toCell:cell row:row];
  }

  cell.accessibilityIdentifier = row.identifier;
  if (row.spokenLabel != nil) cell.accessibilityLabel = row.spokenLabel;
  [self configureAccessoryOfCell:cell row:row indexPath:indexPath];
  return cell;
}

- (UITableViewCell *)tableView:(UITableView *)tableView cellForRowAtIndexPath:(NSIndexPath *)indexPath {
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (row == nil) return [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  if (row.isSlider) return [self sliderCellForRow:row];
  if (row.image != nil || row.imageLoader != nil) return [self imageCellForRow:row indexPath:indexPath];
  UITableViewCell *cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
  cell.textLabel.text = row.title;
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.text = row.detail;
  cell.detailTextLabel.numberOfLines = 0;
  cell.textLabel.textColor = row.destructive ? UIColor.systemRedColor : UIColor.labelColor;
  if (!row.enabled) cell.textLabel.textColor = UIColor.secondaryLabelColor;
  cell.accessibilityIdentifier = row.identifier;
  if (row.spokenLabel != nil) cell.accessibilityLabel = row.spokenLabel;
  [self configureAccessoryOfCell:cell row:row indexPath:indexPath];
  return cell;
}

- (void)tableView:(UITableView *)tableView
      willDisplayCell:(UITableViewCell *)cell
    forRowAtIndexPath:(NSIndexPath *)indexPath {
  if (self.previewsGame) cell.backgroundColor = LibretroMenuPreviewCellColor();
}

- (void)switchChanged:(UISwitch *)control {
  NSIndexPath *indexPath = [NSIndexPath indexPathForRow:control.tag % 1000 inSection:control.tag / 1000];
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (row.toggle != nil) row.toggle(self, control.on);
}

- (BOOL)tableView:(UITableView *)tableView shouldHighlightRowAtIndexPath:(NSIndexPath *)indexPath {
  return ![self rowAtIndexPath:indexPath].isSlider;
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  LibretroMenuRow *row = [self rowAtIndexPath:indexPath];
  if (row == nil || !row.enabled || row.isToggle || row.isSlider || row.action == nil) return;
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
  // Follows LibretroMenuNavigationController (portrait and landscape while
  // a game is shown) instead of the former landscape lock.
  return LibretroMenuOrientations();
}

@end
