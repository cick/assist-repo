//
//  QKMCodesViewController.m — 取件快码 Assit / Author: AssitDev
//  v1.0 的取件码清单：通知抓码落盘、按驿站归类、复制 / 已取 / 删除、手动添加、剪贴板识别。
//

#import "QKMCodesViewController.h"
#import "QKMConfig.h"
#import "QKMStore.h"
#import "QKMParser.h"

static UIColor *QKMBack(void)  { return [UIColor colorWithRed:0.965 green:0.976 blue:0.973 alpha:1.0]; }
static UIColor *QKMGreen(void) { return [UIColor colorWithRed:0.16  green:0.60  blue:0.54  alpha:1.0]; }
static UIColor *QKMInk(void)   { return [UIColor colorWithRed:0.10  green:0.18  blue:0.18  alpha:1.0]; }
static UIColor *QKMGray(void)  { return [UIColor colorWithRed:0.55  green:0.60  blue:0.60  alpha:1.0]; }

@interface QKMCodesViewController () <UITableViewDataSource, UITableViewDelegate, UISearchBarDelegate>
@property (nonatomic, strong) UITableView *table;
@property (nonatomic, strong) UISearchBar *search;
@property (nonatomic, strong) UILabel *summary;
@property (nonatomic, copy) NSArray<NSDictionary *> *pending;
@property (nonatomic, copy) NSArray<NSDictionary *> *done;
@end

@implementation QKMCodesViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"取件码";
    self.view.backgroundColor = QKMBack();

    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc]
        initWithBarButtonSystemItem:UIBarButtonSystemItemAdd target:self action:@selector(addManual)];
    self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc]
        initWithTitle:@"剪贴板" style:UIBarButtonItemStylePlain target:self action:@selector(fromPasteboard)];

    self.search = [[UISearchBar alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 44)];
    self.search.placeholder = @"搜索取件码 / 驿站";
    self.search.delegate = self;
    self.search.backgroundImage = [UIImage new];
    self.search.barTintColor = QKMBack();

    self.table = [[UITableView alloc] initWithFrame:self.view.bounds style:UITableViewStylePlain];
    self.table.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.table.dataSource = self;
    self.table.delegate = self;
    self.table.backgroundColor = QKMBack();
    self.table.tableHeaderView = self.search;
    self.table.rowHeight = 76;
    self.table.tableFooterView = [UIView new];
    [self.view addSubview:self.table];

    self.summary = [[UILabel alloc] initWithFrame:CGRectMake(0, 0, self.view.bounds.size.width, 34)];
    self.summary.textAlignment = NSTextAlignmentCenter;
    self.summary.font = [UIFont systemFontOfSize:12];
    self.summary.textColor = QKMGray();
    self.table.tableFooterView = self.summary;

    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData)
        name:@"QKMRecordsChanged" object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(reloadData)
        name:UIApplicationDidBecomeActiveNotification object:nil];
    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, QKMCodesChanged,
        (__bridge CFStringRef)QKMCodesDarwinNotification, NULL,
        CFNotificationSuspensionBehaviorDeliverImmediately);
}

- (void)dealloc {
    CFNotificationCenterRemoveObserver(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge const void *)self, (__bridge CFStringRef)QKMCodesDarwinNotification, NULL);
}

static void QKMCodesChanged(CFNotificationCenterRef center, void *observer,
                            CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [(__bridge QKMCodesViewController *)observer reloadData];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadData];
}

- (void)reloadData {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[QKMStore shared] reload];
        [[QKMStore shared] prune];
        NSString *q = self.search.text ?: @"";
        NSMutableArray *p = [NSMutableArray array], *d = [NSMutableArray array];
        for (NSDictionary *r in [[QKMStore shared] records]) {
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@",
                r[QKMKeyCode] ?: @"", r[QKMKeyStation] ?: @"", r[QKMKeyRaw] ?: @""];
            if (q.length && [hay rangeOfString:q options:NSCaseInsensitiveSearch].location == NSNotFound) continue;
            if ([r[QKMKeyDone] boolValue]) [d addObject:r]; else [p addObject:r];
        }
        self.pending = p;
        self.done = d;
        [self.table reloadData];
        self.summary.text = [NSString stringWithFormat:@"待取 %lu 条 · 已取 %lu 条 · 保留 %ld 天 · 全部数据仅存本机",
            (unsigned long)p.count, (unsigned long)d.count, (long)[QKMConfig keepDays]];
    });
}

#pragma mark - Table

- (NSInteger)numberOfSectionsInTableView:(UITableView *)t { return 2; }
- (NSInteger)tableView:(UITableView *)t numberOfRowsInSection:(NSInteger)s {
    return s == 0 ? (NSInteger)self.pending.count : (NSInteger)self.done.count;
}
- (NSString *)tableView:(UITableView *)t titleForHeaderInSection:(NSInteger)s {
    return s == 0 ? @"待取" : @"已取";
}

- (UITableViewCell *)tableView:(UITableView *)t cellForRowAtIndexPath:(NSIndexPath *)ip {
    UITableViewCell *c = [t dequeueReusableCellWithIdentifier:@"code"];
    if (!c) c = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"code"];
    NSDictionary *r = ip.section == 0 ? self.pending[ip.row] : self.done[ip.row];
    BOOL done = [r[QKMKeyDone] boolValue];

    c.textLabel.text = r[QKMKeyCode] ?: @"—";
    c.textLabel.font = [UIFont boldSystemFontOfSize:23];
    c.textLabel.textColor = done ? QKMGray() : QKMInk();

    NSDate *date = r[QKMKeyDate];
    NSString *when = @"";
    if ([date isKindOfClass:[NSDate class]]) {
        NSDateFormatter *f = [[NSDateFormatter alloc] init];
        f.dateFormat = @"MM-dd HH:mm";
        when = [f stringFromDate:date];
    }
    NSString *addr = r[QKMKeyAddress] ?: @"";
    c.detailTextLabel.text = [NSString stringWithFormat:@"%@  ·  %@%@%@",
        r[QKMKeyStation] ?: @"其它", when,
        addr.length ? @"  ·  " : @"", addr];
    c.detailTextLabel.textColor = QKMGray();
    c.detailTextLabel.numberOfLines = 2;
    c.accessoryType = done ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
    return c;
}

- (void)tableView:(UITableView *)t didSelectRowAtIndexPath:(NSIndexPath *)ip {
    [t deselectRowAtIndexPath:ip animated:YES];
    NSDictionary *r = ip.section == 0 ? self.pending[ip.row] : self.done[ip.row];
    NSString *code = r[QKMKeyCode] ?: @"";
    [UIPasteboard generalPasteboard].string = code;
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"已复制"
        message:code preferredStyle:UIAlertControllerStyleAlert];
    [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:a animated:YES completion:nil];
}

- (UISwipeActionsConfiguration *)tableView:(UITableView *)t
    trailingSwipeActionsConfigurationForRowAtIndexPath:(NSIndexPath *)ip {
    NSDictionary *r = ip.section == 0 ? self.pending[ip.row] : self.done[ip.row];
    NSString *rid = r[QKMKeyID] ?: @"";
    BOOL done = [r[QKMKeyDone] boolValue];

    UIContextualAction *toggle = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleNormal
        title:done ? @"恢复待取" : @"已取"
        handler:^(UIContextualAction *a, UIView *v, void (^ok)(BOOL)) {
            [[QKMStore shared] setDone:!done forID:rid];
            [self reloadData]; ok(YES);
        }];
    toggle.backgroundColor = QKMGreen();

    UIContextualAction *del = [UIContextualAction
        contextualActionWithStyle:UIContextualActionStyleDestructive title:@"删除"
        handler:^(UIContextualAction *a, UIView *v, void (^ok)(BOOL)) {
            [[QKMStore shared] removeID:rid];
            [self reloadData]; ok(YES);
        }];
    UISwipeActionsConfiguration *cfg = [UISwipeActionsConfiguration configurationWithActions:@[del, toggle]];
    cfg.performsFirstActionWithFullSwipe = NO;
    return cfg;
}

#pragma mark - 操作

- (void)addManual {
    UIAlertController *a = [UIAlertController alertControllerWithTitle:@"手动添加取件码"
        message:@"也可以直接粘贴一整段通知文本，会自动识别其中的取件码"
        preferredStyle:UIAlertControllerStyleAlert];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"取件码 或 通知全文"; }];
    [a addTextFieldWithConfigurationHandler:^(UITextField *tf) { tf.placeholder = @"驿站 / 备注（可留空）"; }];
    [a addAction:[UIAlertAction actionWithTitle:@"取消" style:UIAlertActionStyleCancel handler:nil]];
    [a addAction:[UIAlertAction actionWithTitle:@"添加" style:UIAlertActionStyleDefault handler:^(UIAlertAction *x) {
        NSString *text = a.textFields[0].text ?: @"";
        NSString *station = a.textFields[1].text ?: @"";
        NSArray *codes = [QKMParser codesFromText:text];
        if (codes.count) {
            for (NSString *c in codes) [[QKMStore shared] addManualCode:c station:station];
        } else {
            [[QKMStore shared] addManualCode:text station:station];
        }
        [QKMConfig postCodesChanged];
        [self reloadData];
    }]];
    [self presentViewController:a animated:YES completion:nil];
}

- (void)fromPasteboard {
    NSString *text = [UIPasteboard generalPasteboard].string ?: @"";
    NSArray *codes = [QKMParser codesFromText:text];
    if (!codes.count) {
        UIAlertController *a = [UIAlertController alertControllerWithTitle:@"剪贴板里没识别到取件码"
            message:@"可以复制含「取件码 XXXX」「3-2-1056」这类内容的通知文本再试"
            preferredStyle:UIAlertControllerStyleAlert];
        [a addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:a animated:YES completion:nil];
        return;
    }
    for (NSString *c in codes) [[QKMStore shared] addManualCode:c station:@"剪贴板"];
    [QKMConfig postCodesChanged];
    [self reloadData];
}

- (void)searchBar:(UISearchBar *)s textDidChange:(NSString *)text { [self reloadData]; }
- (void)searchBarSearchButtonClicked:(UISearchBar *)s { [s resignFirstResponder]; }

@end
