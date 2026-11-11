//
//  QKMDiagnosticsViewController.m — 取件快码 Assit / Author: AssitDev
//  桌面图标没出现时，用这一页自证：安装脚本有没有跑、uicache 报了什么。
//

#import "QKMDiagnosticsViewController.h"
#import "QKMConfig.h"

static UIColor *QKMBack(void)  { return [UIColor colorWithRed:0.965 green:0.976 blue:0.973 alpha:1.0]; }
static UIColor *QKMGreen(void) { return [UIColor colorWithRed:0.16  green:0.60  blue:0.54  alpha:1.0]; }
static UIColor *QKMInk(void)   { return [UIColor colorWithRed:0.10  green:0.18  blue:0.18  alpha:1.0]; }
static UIColor *QKMGray(void)  { return [UIColor colorWithRed:0.55  green:0.60  blue:0.60  alpha:1.0]; }

@interface QKMDiagnosticsViewController () <UITableViewDataSource, UITableViewDelegate>
@property (nonatomic, strong) UITableView *table;
@end

@implementation QKMDiagnosticsViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"安装自检";
    self.view.backgroundColor = QKMBack();
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"复制命令" style:UIBarButtonItemStylePlain target:self action:@selector(copyCommand)];

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStyleGrouped];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = QKMBack();
    [self.view addSubview:self.table];

    UITextView *log = [[UITextView alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 210)];
    log.editable = NO;
    log.font = [UIFont fontWithName:@"Menlo" size:11] ?: [UIFont systemFontOfSize:11];
    log.textColor = QKMInk();
    log.backgroundColor = [UIColor whiteColor];
    log.text = [self installLog];
    log.autoresizingMask = UIViewAutoresizingFlexibleWidth;
    self.table.tableFooterView = log;
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self.table reloadData];
    ((UITextView *)self.table.tableFooterView).text = [self installLog];
}

- (NSString *)installLog {
    NSString *s = [NSString stringWithContentsOfFile:[QKMConfig installLogPath]
                                           encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return @"（还没有安装日志）\n\n升级到 3.0.0 后会自动生成。\n若这里一直为空，说明 deb 的 postinst 没有执行，请检查 Sileo 安装时是否报错。";
    return s;
}

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 3; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? 2 : (s == 1 ? 2 : 2);
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return @[@"运行状态", @"桌面图标没出现时", @"关于"][s];
}
- (NSString *)tableView:(UITableView *)t titleForFooterInSection:(NSInteger)s {
    if (s == 0) return @"「插件注入」只影响悬浮球和通知抓码；桌面 App 与取件码清单不依赖注入。";
    if (s == 1) return @"最稳妥的是 Dopamine → 设置 → 操作 →「刷新越狱应用」，它执行的就是 uicache -a。也可以在终端（root）执行下面复制到的命令。";
    return @"取件快码 Assit v3.0.0 · Author AssitDev\n1.0 抓码清单 + 2.0 查件面板，合并版。";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"d"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"d"];
    c.accessoryView = nil;
    c.accessoryType = UITableViewCellAccessoryNone;
    c.textLabel.textColor = QKMInk();
    c.detailTextLabel.textColor = QKMGray();
    c.detailTextLabel.numberOfLines = 3;
    c.selectionStyle = UITableViewCellSelectionStyleNone;

    if (ip.section == 0 && ip.row == 0) {
        BOOL ok = [QKMConfig injectionDetected];
        c.textLabel.text = ok ? @"插件注入：正常" : @"插件注入：未检测到";
        c.detailTextLabel.text = ok ? @"悬浮球 / 通知抓码可用" : @"悬浮球与自动抓码不可用，但本 App 全部功能仍可用";
        c.textLabel.textColor = ok ? QKMGreen() : [UIColor colorWithRed:0.85 green:0.42 blue:0.25 alpha:1.0];
    } else if (ip.section == 0 && ip.row == 1) {
        c.textLabel.text = @"自动抓码";
        c.detailTextLabel.text = [QKMConfig autoCapture]
            ? @"已开启：收到含取件码的通知时自动收进「取件码」列表"
            : @"已关闭：可在 iOS「设置」里打开，或手动添加 / 剪贴板识别";
        c.accessoryView = [[UISwitch alloc] init];
        ((UISwitch *)c.accessoryView).on = [QKMConfig autoCapture];
        [((UISwitch *)c.accessoryView) addTarget:self action:@selector(captureChanged:)
                                forControlEvents:UIControlEventValueChanged];
    } else if (ip.section == 1 && ip.row == 0) {
        c.textLabel.text = @"① Dopamine 刷新越狱应用";
        c.detailTextLabel.text = @"设置 → 操作 → Refresh Jailbreak Apps（刷新越狱应用），然后重启 SpringBoard";
    } else if (ip.section == 1 && ip.row == 1) {
        c.textLabel.text = @"② 终端手动注册";
        c.detailTextLabel.text = @"su root 后执行：uicache -a && killall -9 SpringBoard\n点右上「复制命令」";
    } else if (ip.row == 0) {
        c.textLabel.text = @"版本";
        c.detailTextLabel.text = @"3.0.0 · 合并版（1.0 抓码 + 2.0 查件）";
    } else {
        c.textLabel.text = @"数据位置";
        c.detailTextLabel.text = [QKMConfig codesFilePath];
    }
    return c;
}

- (void)captureChanged:(UISwitch *)sw {
    [QKMConfig setAutoCapture:sw.on];
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)QKMPrefsDarwinNotification, NULL, NULL, true);
    [self.table reloadData];
}

- (void)copyCommand {
    [UIPasteboard generalPasteboard].string = @"uicache -a && killall -9 SpringBoard";
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已复制"
        message:@"uicache -a && killall -9 SpringBoard" preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

@end
