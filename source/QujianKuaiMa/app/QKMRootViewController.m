//
//  QKMRootViewController.m — 取件快码 Assit / Author: AssitDev
//  按原帖截图 1:1 还原：三个身份码 · 六个查件入口 · 设置
//

#import "QKMRootViewController.h"
#import "QKMConfig.h"

static UIColor *QKMBack(void)  { return [UIColor colorWithRed:0.965 green:0.976 blue:0.973 alpha:1.0]; }
static UIColor *QKMGreen(void) { return [UIColor colorWithRed:0.30  green:0.75  blue:0.66  alpha:1.0]; }
static UIColor *QKMInk(void)   { return [UIColor colorWithRed:0.10  green:0.18  blue:0.18  alpha:1.0]; }
static UIColor *QKMGray(void)  { return [UIColor colorWithRed:0.55  green:0.60  blue:0.60  alpha:1.0]; }

#pragma mark - 设置页

@interface QKMSettingsViewController : UIViewController <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation QKMSettingsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"设置";
    self.view.backgroundColor = QKMBack();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemDone target:self action:@selector(done)];
    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    [self.view addSubview:self.table];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.table reloadData];
}

- (void)done { [self dismissViewControllerAnimated:YES completion:nil]; }

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }

- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    if (s == 0) return 2;
    if (s == 1) return [QKMConfig allEntries].count;
    return 2;
}

- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return @[@"运行状态", @"入口链接（点按可自定义）", @"关于"][s];
}

- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"悬浮球由注入 SpringBoard 的插件显示。若状态为「未注入」，说明当前没有注销 / 未开启插件注入，但桌面 App 仍可正常使用。";
    if (s == 1) return @"默认填的是各 App 的 URL Scheme（打开首页）。如果你知道对应「身份码 / 待取包裹」页面的完整深链，可以直接粘进来，点按该入口就会直达。";
    return @"取件快码 Assit v3.0.0 · Author AssitDev\n合并版：三个身份码、六个查件入口 + 通知抓码清单。";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"c"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"c"];
    c.detailTextLabel.text = nil;
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.textLabel.textColor = QKMInk();
    c.selectionStyle = UITableViewCellSelectionStyleDefault;

    if (ip.section == 0 && ip.row == 0) {
        c.textLabel.text = @"桌面悬浮球";
        c.detailTextLabel.text = @"在 SpringBoard 显示快捷入口";
        UISwitch *sw = [[UISwitch alloc] init];
        sw.on = [QKMConfig bubbleEnabled];
        [sw addTarget:self action:@selector(bubbleChanged:) forControlEvents:UIControlEventValueChanged];
        c.accessoryView = sw;
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 0 && ip.row == 1) {
        BOOL ok = [QKMConfig injectionDetected];
        c.textLabel.text = ok ? @"插件注入：正常" : @"插件注入：未检测到";
        c.detailTextLabel.text = ok ? @"悬浮球可显示" : @"请在 Dopamine 里重启 SpringBoard / 确认插件注入已开启";
        c.textLabel.textColor = ok ? QKMGreen() : [UIColor colorWithRed:0.85 green:0.42 blue:0.25 alpha:1.0];
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    } else if (ip.section == 1) {
        QKMEntry *e = [QKMConfig allEntries][ip.row];
        c.textLabel.text = e.title;
        c.detailTextLabel.text = [QKMConfig urlForEntry:e];
        c.detailTextLabel.textColor = QKMGray();
        c.detailTextLabel.adjustsFontSizeToFitWidth = YES;
        c.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    } else if (ip.row == 0) {
        c.textLabel.text = @"恢复默认链接";
        c.textLabel.textColor = QKMGreen();
    } else {
        c.textLabel.text = @"版本";
        c.detailTextLabel.text = @"3.0.0 · AssitDev";
        c.selectionStyle = UITableViewCellSelectionStyleNone;
    }
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    if (ip.section == 1) {
        QKMEntry *e = [QKMConfig allEntries][ip.row];
        UIAlertController *a = [UIAlertController alertControllerWithTitle:e.title
            message:@"填入完整 URL（URL Scheme 或 https 链接）\n留空则恢复该入口的默认值"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.text = [QKMConfig urlForEntry:e];
            tf.keyboardType = UIKeyboardTypeURL;
            tf.clearButtonMode = UITextFieldViewModeAlways;
        }];
        [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
        [a addAction:[UIAlertAction actionWithTitle:@"保存" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
            [QKMConfig setCustomURL:a.textFields.firstObject.text forEntry:e];
            [self.table reloadData];
        }]];
        [self presentViewController:a animated:YES completion:nil];
    } else if (ip.section == 2 && ip.row == 0) {
        [QKMConfig resetAllCustomURLs];
        [self.table reloadData];
    }
}

- (void)bubbleChanged:(UISwitch *)sw {
    [QKMConfig setBubbleEnabled:sw.on];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)QKMPrefsDarwinNotification, NULL, NULL, true);
}

@end

#pragma mark - 主界面

@implementation QKMRootViewController {
    UIScrollView *_scroll;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = QKMBack();
    _scroll = [[UIScrollView alloc] initWithFrame:self.view.bounds];
    _scroll.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _scroll.alwaysBounceVertical = YES;
    [self.view addSubview:_scroll];
    [self buildContent];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.navigationController setNavigationBarHidden:YES animated:animated];
}

- (UILabel *)label:(NSString *)text frame:(CGRect)f font:(UIFont *)font color:(UIColor *)color {
    UILabel *l = [[UILabel alloc] initWithFrame:f];
    l.text = text; l.font = font; l.textColor = color;
    [_scroll addSubview:l];
    return l;
}

- (void)sectionTitle:(NSString *)text y:(CGFloat)y {
    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(22, y + 2, 4, 16)];
    bar.backgroundColor = QKMGreen();
    bar.layer.cornerRadius = 2;
    [_scroll addSubview:bar];
    [self label:text frame:CGRectMake(34, y, 200, 20)
           font:[UIFont boldSystemFontOfSize:15] color:[UIColor colorWithRed:0.22 green:0.35 blue:0.34 alpha:1.0]];
}

- (UIView *)card:(CGRect)f {
    UIView *v = [[UIView alloc] initWithFrame:f];
    v.backgroundColor = [UIColor whiteColor];
    v.layer.cornerRadius = 16;
    v.layer.shadowColor = [UIColor colorWithRed:0.30 green:0.45 blue:0.43 alpha:1.0].CGColor;
    v.layer.shadowOpacity = 0.07;
    v.layer.shadowRadius = 10;
    v.layer.shadowOffset = CGSizeMake(0, 3);
    [_scroll addSubview:v];
    return v;
}

- (UIView *)badge:(NSString *)text color:(UIColor *)color size:(CGFloat)s center:(CGPoint)c {
    UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, s, s)];
    v.center = c;
    v.backgroundColor = color;
    v.layer.cornerRadius = s / 2.0;
    UILabel *l = [[UILabel alloc] initWithFrame:v.bounds];
    l.text = text;
    l.textColor = [UIColor whiteColor];
    l.textAlignment = NSTextAlignmentCenter;
    l.font = [UIFont boldSystemFontOfSize:s * 0.44];
    [v addSubview:l];
    return v;
}

- (void)attachTap:(UIView *)v tag:(NSInteger)tag {
    v.tag = tag;
    v.userInteractionEnabled = YES;
    [v addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cardTapped:)]];
}

- (void)buildContent {
    CGFloat W = CGRectGetWidth(self.view.bounds);
    CGFloat pad = 22;
    CGFloat contentW = W - pad * 2;
    CGFloat y = 26;

    UIView *bar = [[UIView alloc] initWithFrame:CGRectMake(pad, y + 4, 5, 32)];
    bar.backgroundColor = QKMGreen();
    bar.layer.cornerRadius = 2.5;
    [_scroll addSubview:bar];
    [self label:@"取件快码" frame:CGRectMake(pad + 16, y, contentW - 16, 40)
           font:[UIFont boldSystemFontOfSize:30] color:QKMInk()];
    y += 48;
    [self label:@"三个身份码 · 六个查件入口" frame:CGRectMake(pad + 2, y, contentW, 20)
           font:[UIFont systemFontOfSize:14] color:QKMGray()];
    y += 42;

    [self sectionTitle:@"身份码" y:y];
    y += 30;

    NSArray *ids = [QKMConfig identityEntries];
    for (NSUInteger i = 0; i < ids.count; i++) {
        QKMEntry *e = ids[i];
        UIView *v = [self card:CGRectMake(pad, y, contentW, 76)];
        [v addSubview:[self badge:e.badge color:e.badgeColor size:44 center:CGPointMake(16 + 22, 38)]];
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(76, 17, contentW - 190, 22)];
        t.text = e.title; t.font = [UIFont boldSystemFontOfSize:17]; t.textColor = QKMInk();
        [v addSubview:t];
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(contentW - 128, 27, 96, 22)];
        sub.text = [e.subtitle stringByAppendingString:@" ›"];
        sub.font = [UIFont systemFontOfSize:13];
        sub.textColor = QKMGray();
        sub.textAlignment = NSTextAlignmentRight;
        [v addSubview:sub];
        [self attachTap:v tag:i];
        y += 76 + 14;
    }

    y += 8;
    [self sectionTitle:@"查询快递" y:y];
    y += 30;

    CGFloat gap = 12;
    CGFloat cardW = (contentW - gap) / 2.0;
    CGFloat cardH = 100;
    NSArray *qs = [QKMConfig queryEntries];
    for (NSUInteger i = 0; i < qs.count; i++) {
        QKMEntry *e = qs[i];
        CGFloat x = pad + (i % 2) * (cardW + gap);
        CGFloat cy = y + (i / 2) * (cardH + gap);
        UIView *v = [self card:CGRectMake(x, cy, cardW, cardH)];
        [v addSubview:[self badge:e.badge color:e.badgeColor size:28 center:CGPointMake(cardW / 2.0, 28)]];
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(0, 50, cardW, 20)];
        t.text = e.title; t.font = [UIFont boldSystemFontOfSize:14];
        t.textColor = QKMInk(); t.textAlignment = NSTextAlignmentCenter;
        [v addSubview:t];
        UILabel *sub = [[UILabel alloc] initWithFrame:CGRectMake(0, 71, cardW, 16)];
        sub.text = e.subtitle; sub.font = [UIFont systemFontOfSize:11];
        sub.textColor = QKMGray(); sub.textAlignment = NSTextAlignmentCenter;
        [v addSubview:sub];
        [self attachTap:v tag:ids.count + i];
    }
    y += 3 * (cardH + gap) + 12;

    UIButton *btn = [UIButton buttonWithType:UIButtonTypeCustom];
    btn.frame = CGRectMake((W - 110) / 2.0, y, 110, 44);
    btn.backgroundColor = [UIColor colorWithRed:0.66 green:0.88 blue:0.81 alpha:1.0];
    btn.layer.cornerRadius = 22;
    [btn setTitle:@"设置" forState:UIControlStateNormal];
    [btn setTitleColor:[UIColor colorWithRed:0.13 green:0.32 blue:0.30 alpha:1.0] forState:UIControlStateNormal];
    btn.titleLabel.font = [UIFont boldSystemFontOfSize:15];
    [btn addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
    [_scroll addSubview:btn];
    y += 44 + 18;

    UILabel *foot = [[UILabel alloc] initWithFrame:CGRectMake(0, y, W, 18)];
    foot.text = @"v2.0.0 · Author AssitDev · Assist Repo";
    foot.font = [UIFont systemFontOfSize:11];
    foot.textColor = [UIColor colorWithRed:0.72 green:0.77 blue:0.76 alpha:1.0];
    foot.textAlignment = NSTextAlignmentCenter;
    [_scroll addSubview:foot];

    _scroll.contentSize = CGSizeMake(W, y + 40);
}

- (void)openSettings {
    QKMSettingsViewController *s = [[QKMSettingsViewController alloc] init];
    UINavigationController *nav = [[UINavigationController alloc] initWithRootViewController:s];
    [self presentViewController:nav animated:YES completion:nil];
}

- (void)cardTapped:(UITapGestureRecognizer *)g {
    NSInteger tag = g.view.tag;
    NSArray *all = [QKMConfig allEntries];
    if (tag < 0 || tag >= (NSInteger)all.count) return;
    QKMEntry *e = all[tag];
    NSString *s = [QKMConfig urlForEntry:e];
    NSURL *u = [NSURL URLWithString:s];
    UIApplication *app = [UIApplication sharedApplication];
    if (u && [app canOpenURL:u]) {
        [app openURL:u options:@{} completionHandler:^(BOOL ok) {
            if (!ok) dispatch_async(dispatch_get_main_queue(), ^{ [self fallback:e url:s]; });
        }];
    } else {
        [self fallback:e url:s];
    }
}

- (void)fallback:(QKMEntry *)e url:(NSString *)url {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:e.title
        message:[NSString stringWithFormat:@"无法打开：%@\n可能未安装对应 App，或该链接已失效。\n可以在「设置」里改成完整深链或网页地址。", url]
        preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"复制链接" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        [UIPasteboard generalPasteboard].string = url;
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"打开网页版" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSURL *w = [NSURL URLWithString:e.webURL];
        if (w) [[UIApplication sharedApplication] openURL:w options:@{} completionHandler:nil];
    }]];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
