//
//  QKMUI.m — Author: AssitDev
//  桌面悬浮球 + 取件码面板 + 设置，全部用公开 UIKit API 实现。
//

#import "QKMCommon.h"

static UIColor *QKMTint(void) { return [UIColor colorWithRed:0.10 green:0.46 blue:0.95 alpha:1.0]; }

static UIWindow *QKMHostWindow(void) {
    if (@available(iOS 13.0, *)) {
        UIApplication *app = [UIApplication sharedApplication];
        for (UIScene *scene in app.connectedScenes) {
            if (scene.activationState != UISceneActivationStateForegroundActive) continue;
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                if (!w.hidden && w.alpha > 0.01) return w;
            }
        }
    }
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

static void QKMToast(NSString *text) {
    UIWindow *w = QKMHostWindow();
    if (!w) return;
    UILabel *l = [[UILabel alloc] init];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.font = [UIFont boldSystemFontOfSize:14];
    l.textAlignment = NSTextAlignmentCenter;
    l.numberOfLines = 2;
    l.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.82];
    l.layer.cornerRadius = 12;
    l.clipsToBounds = YES;
    CGSize s = [text boundingRectWithSize:CGSizeMake(260, 80)
                                  options:NSStringDrawingUsesLineFragmentOrigin
                               attributes:@{NSFontAttributeName: l.font} context:nil].size;
    l.frame = CGRectMake(0, 0, MIN(280, s.width + 40), MAX(40, s.height + 20));
    l.center = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
    [w addSubview:l];
    [UIView animateWithDuration:0.25 delay:1.1 options:0 animations:^{ l.alpha = 0; }
                     completion:^(BOOL done) { [l removeFromSuperview]; }];
}

#pragma mark - 悬浮球

@interface QKMBubbleView : UIView
@property (nonatomic, strong) UILabel *badge;
- (void)update;
@end

@implementation QKMBubbleView {
    CGPoint _dragStart;
    CGPoint _centerStart;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [UIColor clearColor];
        self.layer.shadowColor = [UIColor blackColor].CGColor;
        self.layer.shadowOpacity = 0.28;
        self.layer.shadowRadius = 10;
        self.layer.shadowOffset = CGSizeMake(0, 3);

        UIView *bg = [[UIView alloc] initWithFrame:self.bounds];
        bg.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        CAGradientLayer *g = [CAGradientLayer layer];
        g.frame = bg.bounds;
        g.colors = @[(id)[UIColor colorWithRed:0.16 green:0.55 blue:1.0 alpha:1.0].CGColor,
                     (id)[UIColor colorWithRed:0.08 green:0.30 blue:0.82 alpha:1.0].CGColor];
        g.cornerRadius = self.bounds.size.width / 2.0;
        [bg.layer addSublayer:g];
        [self addSubview:bg];

        UILabel *glyph = [[UILabel alloc] initWithFrame:CGRectMake(0, 5, self.bounds.size.width, 26)];
        glyph.text = @"码";
        glyph.textColor = [UIColor whiteColor];
        glyph.font = [UIFont boldSystemFontOfSize:20];
        glyph.textAlignment = NSTextAlignmentCenter;
        [self addSubview:glyph];

        UILabel *cap = [[UILabel alloc] initWithFrame:CGRectMake(0, 29, self.bounds.size.width, 14)];
        cap.text = @"取件";
        cap.textColor = [[UIColor whiteColor] colorWithAlphaComponent:0.85];
        cap.font = [UIFont systemFontOfSize:10];
        cap.textAlignment = NSTextAlignmentCenter;
        [self addSubview:cap];

        _badge = [[UILabel alloc] initWithFrame:CGRectMake(self.bounds.size.width - 20, -4, 24, 24)];
        _badge.backgroundColor = [UIColor colorWithRed:1.0 green:0.35 blue:0.25 alpha:1.0];
        _badge.textColor = [UIColor whiteColor];
        _badge.font = [UIFont boldSystemFontOfSize:12];
        _badge.textAlignment = NSTextAlignmentCenter;
        _badge.layer.cornerRadius = 12;
        _badge.clipsToBounds = YES;
        [self addSubview:_badge];

        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
        [self addGestureRecognizer:[[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(panned:)]];
        UILongPressGestureRecognizer *lp = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
        lp.minimumPressDuration = 0.8;
        [self addGestureRecognizer:lp];
        [self update];
    }
    return self;
}

- (void)update {
    NSUInteger n = [[QKMStore shared] pendingCount];
    _badge.text = n > 99 ? @"99+" : [NSString stringWithFormat:@"%lu", (unsigned long)n];
    _badge.hidden = (n == 0);
    self.alpha = [QKMPrefs shared].bubbleAlpha;
    self.hidden = ![QKMPrefs shared].bubbleVisible || ![QKMPrefs shared].enabled;
}

- (void)tapped { [[QKMUI shared] togglePanel]; }

- (void)panned:(UIPanGestureRecognizer *)g {
    if (g.state == UIGestureRecognizerStateBegan) {
        _dragStart = [g locationInView:self.superview];
        _centerStart = self.center;
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint p = [g locationInView:self.superview];
        self.center = CGPointMake(_centerStart.x + p.x - _dragStart.x,
                                  _centerStart.y + p.y - _dragStart.y);
    } else if (g.state == UIGestureRecognizerStateEnded || g.state == UIGestureRecognizerStateCancelled) {
        CGRect b = self.superview.bounds;
        CGFloat pad = 8;
        CGFloat x = self.center.x < CGRectGetMidX(b) ? self.bounds.size.width / 2 + pad
                                                      : CGRectGetWidth(b) - self.bounds.size.width / 2 - pad;
        CGFloat y = MIN(MAX(self.center.y, self.bounds.size.height / 2 + 40),
                        CGRectGetHeight(b) - self.bounds.size.height / 2 - 40);
        [UIView animateWithDuration:0.25 animations:^{ self.center = CGPointMake(x, y); }];
    }
}

- (void)longPressed:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [QKMPrefs shared].bubbleVisible = NO;
    [self update];
    QKMToast(@"悬浮球已隐藏，可在面板「设置」里重新打开");
}

@end

#pragma mark - 面板

@interface QKMPanelView : UIView <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate, UITextFieldDelegate>
- (void)reload;
@end

@implementation QKMPanelView {
    UIView *_card;
    UISegmentedControl *_seg;
    UISearchBar *_search;
    UITableView *_table;
    UIScrollView *_settings;
    UIView *_addSheet;
    UITextField *_codeField;
    UITextField *_stationField;
    NSArray<NSDictionary *> *_shown;
    NSString *_query;
}

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) {
        self.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.42];
        self.alpha = 0;
        self.hidden = YES;
        _query = @"";

        UITapGestureRecognizer *tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(closeTapped:)];
        tap.delegate = (id<UIGestureRecognizerDelegate>)self;
        [self addGestureRecognizer:tap];

        CGFloat w = MIN(360, CGRectGetWidth(frame) - 32);
        CGFloat h = MIN(580, CGRectGetHeight(frame) - 150);
        _card = [[UIView alloc] initWithFrame:CGRectMake(0, 0, w, h)];
        _card.backgroundColor = [UIColor colorWithDynamicProvider:^UIColor *(UITraitCollection *t) {
            return t.userInterfaceStyle == UIUserInterfaceStyleDark
                ? [UIColor colorWithWhite:0.14 alpha:1.0]
                : [UIColor whiteColor];
        }];
        _card.layer.cornerRadius = 18;
        _card.clipsToBounds = YES;
        _card.center = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
        _card.autoresizingMask = UIViewAutoresizingFlexibleLeftMargin | UIViewAutoresizingFlexibleRightMargin |
                                 UIViewAutoresizingFlexibleTopMargin | UIViewAutoresizingFlexibleBottomMargin;
        [self addSubview:_card];

        UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(16, 12, w - 70, 24)];
        title.text = @"取件快码 Assit";
        title.font = [UIFont boldSystemFontOfSize:17];
        [_card addSubview:title];

        UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
        close.frame = CGRectMake(w - 42, 8, 34, 32);
        [close setTitle:@"✕" forState:UIControlStateNormal];
        close.titleLabel.font = [UIFont systemFontOfSize:17];
        [close addTarget:self action:@selector(hide) forControlEvents:UIControlEventTouchUpInside];
        [_card addSubview:close];

        _seg = [[UISegmentedControl alloc] initWithItems:@[@"待取", @"已取", @"设置"]];
        _seg.frame = CGRectMake(16, 44, w - 32, 30);
        _seg.selectedSegmentIndex = 0;
        [_seg addTarget:self action:@selector(segmentChanged) forControlEvents:UIControlEventValueChanged];
        [_card addSubview:_seg];

        _search = [[UISearchBar alloc] initWithFrame:CGRectMake(8, 80, w - 16, 36)];
        _search.placeholder = @"搜索取件码 / 驿站";
        _search.delegate = self;
        _search.backgroundImage = [UIImage new];
        [_card addSubview:_search];

        CGRect content = CGRectMake(0, 116, w, h - 116 - 52);
        _table = [[UITableView alloc] initWithFrame:content style:UITableViewStylePlain];
        _table.dataSource = self;
        _table.delegate = self;
        _table.rowHeight = 62;
        _table.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
        _table.backgroundColor = [UIColor clearColor];
        [_table registerClass:[UITableViewCell class] forCellReuseIdentifier:@"QKMCell"];
        [_card addSubview:_table];

        _settings = [[UIScrollView alloc] initWithFrame:content];
        _settings.hidden = YES;
        [_card addSubview:_settings];
        [self buildSettings];

        UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(0, h - 52, w, 52)];
        bar.backgroundColor = [QKMTint() colorWithAlphaComponent:0.08];
        [_card addSubview:bar];
        NSArray *btns = @[@"＋ 添加", @"粘贴识别", @"清理已取"];
        for (NSUInteger i = 0; i < btns.count; i++) {
            UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
            b.frame = CGRectMake(8 + (w - 16) / 3.0 * i, 8, (w - 16) / 3.0 - 4, 36);
            b.titleLabel.font = [UIFont systemFontOfSize:13];
            [b setTitle:btns[i] forState:UIControlStateNormal];
            b.tag = (NSInteger)i;
            [b addTarget:self action:@selector(barTapped:) forControlEvents:UIControlEventTouchUpInside];
            [bar addSubview:b];
        }

        [self buildAddSheet];
        [self reload];
    }
    return self;
}

- (void)layoutCard {
    UIWindow *w = (UIWindow *)self.superview;
    if (!w) return;
    self.frame = w.bounds;
    CGFloat width = MIN(360, CGRectGetWidth(w.bounds) - 32);
    CGFloat height = MIN(580, CGRectGetHeight(w.bounds) - 150);
    _card.bounds = CGRectMake(0, 0, width, height);
    _card.center = CGPointMake(CGRectGetMidX(w.bounds), CGRectGetMidY(w.bounds));
}

- (void)show {
    [self layoutCard];
    self.hidden = NO;
    [self reload];
    [UIView animateWithDuration:0.22 animations:^{ self.alpha = 1; }];
}
- (void)hide {
    [self endEditing:YES];
    _addSheet.hidden = YES;
    [UIView animateWithDuration:0.18 animations:^{ self.alpha = 0; }
                     completion:^(BOOL done) { self.hidden = YES; }];
}
- (void)closeTapped:(UITapGestureRecognizer *)g {
    CGPoint p = [g locationInView:self];
    if (!CGRectContainsPoint(_card.frame, p)) [self hide];
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    CGPoint p = [t locationInView:self];
    return !CGRectContainsPoint(_card.frame, p);
}

- (void)segmentChanged {
    BOOL settings = (_seg.selectedSegmentIndex == 2);
    _settings.hidden = !settings;
    _table.hidden = settings;
    _search.hidden = settings;
    [self endEditing:YES];
    [self reload];
}

- (void)reload {
    NSArray *all = [[QKMStore shared] records];
    BOOL done = (_seg.selectedSegmentIndex == 1);
    NSMutableArray *f = [NSMutableArray array];
    for (NSDictionary *r in all) {
        if ([r[QKMKeyDone] boolValue] != done) continue;
        if (_query.length) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", r[QKMKeyCode] ?: @"",
                             r[QKMKeyStation] ?: @"", r[QKMKeyAddress] ?: @""];
            if ([hay rangeOfString:_query options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
        }
        [f addObject:r];
    }
    _shown = f;
    [_table reloadData];
    if (!_settings.hidden) [self syncSettings];
}

- (void)searchBar:(UISearchBar *)searchBar textDidChange:(NSString *)searchText {
    _query = searchText ?: @"";
    [self reload];
}
- (void)searchBarSearchButtonClicked:(UISearchBar *)searchBar { [self endEditing:YES]; }

#pragma mark Table

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s { return (NSInteger)_shown.count; }

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"QKMCell" forIndexPath:ip];
    NSDictionary *r = _shown[(NSUInteger)ip.row];
    c.selectionStyle = UITableViewCellSelectionStyleDefault;
    c.textLabel.text = r[QKMKeyCode] ?: @"";
    c.textLabel.font = [UIFont boldSystemFontOfSize:20];
    c.textLabel.textColor = QKMTint();

    NSDate *d = r[QKMKeyDate];
    NSString *time = @"";
    if ([d isKindOfClass:[NSDate class]]) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm";
        time = [f stringFromDate:d];
    }
    NSString *station = r[QKMKeyStation] ?: @"";
    NSString *addr = r[QKMKeyAddress] ?: @"";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  %@  %@%@", station, time, addr,
                              [r[QKMKeyDone] boolValue] ? @"  ✓已取" : @""];
    c.detailTextLabel.textColor = [UIColor secondaryLabelColor];
    c.detailTextLabel.numberOfLines = 2;
    c.accessoryType = [r[QKMKeyDone] boolValue] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;

    // 超过 24 小时仍待取 → 橙色提示
    if (![r[QKMKeyDone] boolValue] && [d isKindOfClass:[NSDate class]] && -[d timeIntervalSinceNow] > 24 * 3600) {
        c.textLabel.textColor = [UIColor systemOrangeColor];
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *r = _shown[(NSUInteger)ip.row];
    [UIPasteboard generalPasteboard].string = r[QKMKeyCode] ?: @"";
    QKMToast([NSString stringWithFormat:@"已复制 %@", r[QKMKeyCode] ?: @""]);
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)t trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip API_AVAILABLE(ios(11.0)) {
    NSDictionary *r = _shown[(NSUInteger)ip.row];
    NSString *rid = r[QKMKeyID];
    BOOL done = [r[QKMKeyDone] boolValue];

    UIContextualAction *toggle = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleNormal
        title:done ? @"恢复待取" : @"已取"
        handler:^(UIContextualAction *a, UIView *v, void (^ok)(BOOL)) {
            [[QKMStore shared] setDone:!done forID:rid];
            [self reload]; ok(YES);
        }];
    toggle.backgroundColor = [UIColor systemGreenColor];

    UIContextualAction *del = [UIContextualAction contextualActionWithStyle:UIContextualActionStyleDestructive
        title:@"删除"
        handler:^(UIContextualAction *a, UIView *v, void (^ok)(BOOL)) {
            [[QKMStore shared] removeID:rid];
            [self reload]; ok(YES);
        }];
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[del, toggle]];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

#pragma mark 底部工具条

- (void)barTapped:(UIButton *)b {
    if (b.tag == 0) {
        _addSheet.hidden = NO;
        _codeField.text = @"";
        [_codeField becomeFirstResponder];
    } else if (b.tag == 1) {
        NSString *p = [UIPasteboard generalPasteboard].string ?: @"";
        NSArray *codes = [QKMParser codesFromText:p];
        if (!codes.count) { QKMToast(@"剪贴板里没识别到取件码"); return; }
        for (NSString *c in codes) [[QKMStore shared] addManualCode:c station:@"剪贴板"];
        [self reload];
        QKMToast([NSString stringWithFormat:@"识别到 %lu 条", (unsigned long)codes.count]);
    } else {
        [[QKMStore shared] clearDone];
        [self reload];
        QKMToast(@"已清空已取记录");
    }
}

- (void)buildAddSheet {
    CGFloat w = _card.bounds.size.width;
    _addSheet = [[UIView alloc] initWithFrame:CGRectMake(12, 120, w - 24, 160)];
    _addSheet.backgroundColor = [[UIColor systemBackgroundColor] colorWithAlphaComponent:0.98];
    _addSheet.layer.cornerRadius = 14;
    _addSheet.layer.shadowOpacity = 0.2;
    _addSheet.layer.shadowRadius = 12;
    _addSheet.hidden = YES;
    [_card addSubview:_addSheet];

    _codeField = [[UITextField alloc] initWithFrame:CGRectMake(14, 14, w - 52, 36)];
    _codeField.placeholder = @"取件码（必填）";
    _codeField.borderStyle = UITextBorderStyleRoundedRect;
    _codeField.autocapitalizationType = UITextAutocapitalizationTypeNone;
    _codeField.delegate = self;
    [_addSheet addSubview:_codeField];

    _stationField = [[UITextField alloc] initWithFrame:CGRectMake(14, 58, w - 52, 36)];
    _stationField.placeholder = @"驿站 / 备注（选填）";
    _stationField.borderStyle = UITextBorderStyleRoundedRect;
    _stationField.delegate = self;
    [_addSheet addSubview:_stationField];

    UIButton *save = [UIButton buttonWithType:UIButtonTypeSystem];
    save.frame = CGRectMake(14, 106, (w - 60) / 2, 36);
    [save setTitle:@"保存" forState:UIControlStateNormal];
    save.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [save addTarget:self action:@selector(saveManual) forControlEvents:UIControlEventTouchUpInside];
    [_addSheet addSubview:save];

    UIButton *cancel = [UIButton buttonWithType:UIButtonTypeSystem];
    cancel.frame = CGRectMake(14 + (w - 60) / 2 + 8, 106, (w - 60) / 2, 36);
    [cancel setTitle:@"取消" forState:UIControlStateNormal];
    [cancel addTarget:self action:@selector(cancelManual) forControlEvents:UIControlEventTouchUpInside];
    [_addSheet addSubview:cancel];
}

- (void)saveManual {
    NSString *code = [_codeField.text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!code.length) { QKMToast(@"请填写取件码"); return; }
    [[QKMStore shared] addManualCode:code station:_stationField.text];
    _addSheet.hidden = YES;
    [self endEditing:YES];
    [self reload];
    QKMToast(@"已添加");
}
- (void)cancelManual { _addSheet.hidden = YES; [self endEditing:YES]; }
- (BOOL)textFieldShouldReturn:(UITextField *)f { if (f == _codeField) [_stationField becomeFirstResponder]; else [self saveManual]; return YES; }

#pragma mark 设置

- (void)switchRow:(NSString *)title sub:(NSString *)sub tag:(NSInteger)tag y:(CGFloat)y {
    CGFloat w = _settings.bounds.size.width;
    UILabel *l = [[UILabel alloc] initWithFrame:CGRectMake(16, y, w - 90, 20)];
    l.text = title; l.font = [UIFont systemFontOfSize:15];
    [_settings addSubview:l];
    UILabel *s = [[UILabel alloc] initWithFrame:CGRectMake(16, y + 21, w - 90, 16)];
    s.text = sub; s.font = [UIFont systemFontOfSize:11.5]; s.textColor = [UIColor secondaryLabelColor];
    [_settings addSubview:s];
    UISwitch *sw = [[UISwitch alloc] initWithFrame:CGRectMake(w - 66, y + 6, 50, 30)];
    sw.tag = tag;
    [sw addTarget:self action:@selector(switchChanged:) forControlEvents:UIControlEventValueChanged];
    [_settings addSubview:sw];
}

- (void)buildSettings {
    CGFloat w = _card.bounds.size.width;
    _settings.contentSize = CGSizeMake(w, 520);
    [self switchRow:@"启用插件" sub:@"关闭后停止抓码并隐藏悬浮球" tag:1 y:8];
    [self switchRow:@"桌面悬浮球" sub:@"长按悬浮球可临时隐藏" tag:2 y:62];
    [self switchRow:@"自动抓取通知" sub:@"从短信 / 微信 / 菜鸟等通知里解析取件码" tag:3 y:116];
    [self switchRow:@"新码横幅提醒" sub:@"抓到新码时在屏幕顶部弹一条提示" tag:4 y:170];

    UILabel *l1 = [[UILabel alloc] initWithFrame:CGRectMake(16, 230, w - 32, 20)];
    l1.text = @"记录保留天数"; l1.font = [UIFont systemFontOfSize:15];
    [_settings addSubview:l1];
    UIStepper *step = [[UIStepper alloc] initWithFrame:CGRectMake(16, 258, 100, 30)];
    step.minimumValue = 1; step.maximumValue = 90; step.stepValue = 1; step.tag = 11;
    [step addTarget:self action:@selector(stepChanged:) forControlEvents:UIControlEventValueChanged];
    [_settings addSubview:step];
    UILabel *daysL = [[UILabel alloc] initWithFrame:CGRectMake(124, 258, 120, 30)];
    daysL.tag = 12; daysL.font = [UIFont systemFontOfSize:14]; daysL.textColor = [UIColor secondaryLabelColor];
    [_settings addSubview:daysL];

    UILabel *l2 = [[UILabel alloc] initWithFrame:CGRectMake(16, 305, w - 32, 20)];
    l2.text = @"悬浮球透明度"; l2.font = [UIFont systemFontOfSize:15];
    [_settings addSubview:l2];
    UISlider *slider = [[UISlider alloc] initWithFrame:CGRectMake(16, 335, w - 32, 30)];
    slider.minimumValue = 0.35; slider.maximumValue = 1.0; slider.tag = 21;
    [slider addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];
    [_settings addSubview:slider];

    UILabel *l3 = [[UILabel alloc] initWithFrame:CGRectMake(16, 382, w - 32, 20)];
    l3.text = @"自定义匹配关键词"; l3.font = [UIFont systemFontOfSize:15];
    [_settings addSubview:l3];
    UITextField *tf = [[UITextField alloc] initWithFrame:CGRectMake(16, 410, w - 32, 34)];
    tf.placeholder = @"逗号分隔，例如：包裹码,柜号";
    tf.borderStyle = UITextBorderStyleRoundedRect;
    tf.font = [UIFont systemFontOfSize:13];
    tf.tag = 31;
    tf.delegate = self;
    [tf addTarget:self action:@selector(keywordChanged:) forControlEvents:UIControlEventEditingChanged];
    [_settings addSubview:tf];

    UILabel *note = [[UILabel alloc] initWithFrame:CGRectMake(16, 456, w - 32, 56)];
    note.text = @"所有解析与存储都在本机完成，不联网、不上传。支持 rootless 无根与 roothide 隐根。\n取件快码 Assit v1.0.0 · AssitDev";
    note.font = [UIFont systemFontOfSize:11.5];
    note.textColor = [UIColor tertiaryLabelColor];
    note.numberOfLines = 0;
    [_settings addSubview:note];
}

- (void)syncSettings {
    QKMPrefs *p = [QKMPrefs shared];
    [(UISwitch *)[_settings viewWithTag:1] setOn:p.enabled];
    [(UISwitch *)[_settings viewWithTag:2] setOn:p.bubbleVisible];
    [(UISwitch *)[_settings viewWithTag:3] setOn:p.autoCapture];
    [(UISwitch *)[_settings viewWithTag:4] setOn:p.bannerEnabled];
    UIStepper *step = (UIStepper *)[_settings viewWithTag:11];
    step.value = p.keepDays;
    [(UILabel *)[_settings viewWithTag:12] setText:[NSString stringWithFormat:@"%ld 天", (long)p.keepDays]];
    [(UISlider *)[_settings viewWithTag:21] setValue:p.bubbleAlpha];
    UITextField *tf = (UITextField *)[_settings viewWithTag:31];
    if (!tf.isFirstResponder) tf.text = p.customKeywords;
    _settings.contentSize = CGSizeMake(_settings.bounds.size.width, 520);
}

- (void)switchChanged:(UISwitch *)sw {
    QKMPrefs *p = [QKMPrefs shared];
    switch (sw.tag) {
        case 1: p.enabled = sw.on; break;
        case 2: p.bubbleVisible = sw.on; break;
        case 3: p.autoCapture = sw.on; break;
        case 4: p.bannerEnabled = sw.on; break;
    }
    [[QKMUI shared] refresh];
}
- (void)stepChanged:(UIStepper *)s {
    [QKMPrefs shared].keepDays = (NSInteger)s.value;
    [(UILabel *)[_settings viewWithTag:12] setText:[NSString stringWithFormat:@"%ld 天", (NSInteger)s.value]];
}
- (void)sliderChanged:(UISlider *)s { [QKMPrefs shared].bubbleAlpha = s.value; [[QKMUI shared] refresh]; }
- (void)keywordChanged:(UITextField *)tf { [QKMPrefs shared].customKeywords = tf.text; }

@end

#pragma mark - 管理器

@implementation QKMUI {
    QKMBubbleView *_bubble;
    QKMPanelView *_panel;
    UIView *_banner;
}

+ (instancetype)shared {
    static QKMUI *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(onRecords:) name:QKMRecordsChangedNotification object:nil];
        [nc addObserver:self selector:@selector(onSettings) name:QKMSettingsChangedNotification object:nil];
        [nc addObserver:self selector:@selector(rehost) name:UIWindowDidBecomeKeyNotification object:nil];
        [nc addObserver:self selector:@selector(rehost) name:UIApplicationDidBecomeActiveNotification object:nil];
    }
    return self;
}

- (void)setup {
    dispatch_async(dispatch_get_main_queue(), ^{ [self rehost]; });
}

- (void)rehost {
    UIWindow *w = QKMHostWindow();
    if (!w) return;

    if (!_bubble) {
        _bubble = [[QKMBubbleView alloc] initWithFrame:CGRectMake(0, 0, 58, 58)];
        _bubble.center = CGPointMake(CGRectGetWidth(w.bounds) - 38, CGRectGetMidY(w.bounds) - 60);
    }
    if (_bubble.superview != w) [w addSubview:_bubble];
    [w bringSubviewToFront:_bubble];

    if (!_panel) {
        _panel = [[QKMPanelView alloc] initWithFrame:w.bounds];
    }
    if (_panel.superview != w) [w addSubview:_panel];
    if (!_panel.hidden) [w bringSubviewToFront:_panel];
    [self refresh];
}

- (void)refresh {
    dispatch_async(dispatch_get_main_queue(), ^{
        [_bubble update];
        [_panel reload];
    });
}

- (void)togglePanel {
    dispatch_async(dispatch_get_main_queue(), ^{
        [self rehost];
        if (_panel.hidden) { [self->_panel show]; [self superviewBringPanel]; }
        else [_panel hide];
    });
}

- (void)superviewBringPanel {
    [_panel.superview bringSubviewToFront:_panel];
    [_panel.superview bringSubviewToFront:_bubble];
}

- (void)onRecords:(NSNotification *)n {
    [self refresh];
    NSArray *added = n.userInfo[@"added"];
    if (![added isKindOfClass:[NSArray class]] || !added.count) return;
    if (![QKMPrefs shared].bannerEnabled || ![QKMPrefs shared].enabled) return;
    NSDictionary *first = added[0];
    [self showBannerWithCode:first[QKMKeyCode] ?: @"" station:first[QKMKeyStation] ?: @""];
}

- (void)onSettings { [self refresh]; }

- (void)showBannerWithCode:(NSString *)code station:(NSString *)station {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QKMHostWindow();
        if (!w) return;
        [_banner removeFromSuperview];

        CGFloat width = CGRectGetWidth(w.bounds) - 24;
        _banner = [[UIView alloc] initWithFrame:CGRectMake(12, -90, width, 76)];
        _banner.backgroundColor = [[UIColor whiteColor] colorWithAlphaComponent:0.96];
        _banner.layer.cornerRadius = 16;
        _banner.layer.shadowColor = [UIColor blackColor].CGColor;
        _banner.layer.shadowOpacity = 0.22;
        _banner.layer.shadowRadius = 12;
        [w addSubview:_banner];

        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(16, 10, width - 32, 20)];
        t.text = [NSString stringWithFormat:@"新取件码 · %@", station ?: @""];
        t.font = [UIFont boldSystemFontOfSize:13];
        t.textColor = [UIColor secondaryLabelColor];
        [_banner addSubview:t];

        UILabel *c = [[UILabel alloc] initWithFrame:CGRectMake(16, 32, width - 32, 32)];
        c.text = code;
        c.font = [UIFont boldSystemFontOfSize:24];
        c.textColor = QKMTint();
        [_banner addSubview:c];

        CGFloat top = 12;
        if (@available(iOS 11.0, *)) {
            UIEdgeInsets insets = w.safeAreaInsets;
            if (insets.top > 0) top = insets.top + 4;
        }
        [UIView animateWithDuration:0.35 delay:0 usingSpringWithDamping:0.8 initialSpringVelocity:0.6
                            options:0 animations:^{
            CGRect f = _banner.frame; f.origin.y = top; _banner.frame = f;
        } completion:nil];

        UIView *b = _banner;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [UIView animateWithDuration:0.25 animations:^{ b.alpha = 0; }
                             completion:^(BOOL done) { [b removeFromSuperview]; }];
        });
    });
}

@end
