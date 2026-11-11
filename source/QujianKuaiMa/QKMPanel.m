//
//  QKMPanel.m — 取件快码 Assit / Author: AssitDev
//  SpringBoard 内的快捷面板：待取取件码 + 三身份码/六查件入口。
//  这样即使桌面 App 没被 uicache 注册，插件功能依然可用。
//

#import "QKMPanel.h"
#import "QKMConfig.h"
#import "QKMStore.h"
#import <objc/runtime.h>

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

static void QKMOpenURL(NSString *s, NSString *fallback) {
    NSURL *u = [NSURL URLWithString:s];
    if (!u) return;
    [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:^(BOOL ok) {
        if (!ok && fallback.length) {
            NSURL *w = [NSURL URLWithString:fallback];
            if (w) [[UIApplication sharedApplication] openURL:w options:@{} completionHandler:nil];
        }
    }];
}

@interface QKMPanelView : UIView
@end

@implementation QKMPanelView

- (instancetype)initWithFrame:(CGRect)frame {
    if ((self = [super initWithFrame:frame])) { self.backgroundColor = [UIColor clearColor]; }
    return self;
}

- (void)build {
    CGFloat W = CGRectGetWidth(self.bounds), H = CGRectGetHeight(self.bounds);
    UIView *dim = [[UIView alloc] initWithFrame:self.bounds];
    dim.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.32];
    dim.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [dim addGestureRecognizer:[[UITapGestureRecognizer alloc]
        initWithTarget:[QKMPanel shared] action:@selector(dismiss)]];
    [self addSubview:dim];

    CGFloat cw = MIN(W - 36, 350), ch = MIN(H - 100, 560);
    UIView *card = [[UIView alloc] initWithFrame:CGRectMake((W-cw)/2, (H-ch)/2, cw, ch)];
    card.backgroundColor = [UIColor colorWithRed:0.965 green:0.976 blue:0.973 alpha:1.0];
    card.layer.cornerRadius = 18;
    card.clipsToBounds = YES;
    [self addSubview:card];

    UILabel *title = [[UILabel alloc] initWithFrame:CGRectMake(18, 12, cw - 80, 26)];
    title.text = @"取件快码";
    title.font = [UIFont boldSystemFontOfSize:19];
    title.textColor = [UIColor colorWithRed:0.10 green:0.18 blue:0.18 alpha:1.0];
    [card addSubview:title];

    UIButton *close = [UIButton buttonWithType:UIButtonTypeSystem];
    close.frame = CGRectMake(cw - 48, 8, 40, 32);
    [close setTitle:@"关闭" forState:UIControlStateNormal];
    [close addTarget:[QKMPanel shared] action:@selector(dismiss) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:close];

    UIScrollView *sc = [[UIScrollView alloc] initWithFrame:CGRectMake(0, 46, cw, ch - 46 - 50)];
    [card addSubview:sc];
    CGFloat y = 6;

    // ---- 待取取件码 ----
    [[QKMStore shared] reload];
    NSArray *records = [[QKMStore shared] records];
    UILabel *h1 = [[UILabel alloc] initWithFrame:CGRectMake(18, y, cw - 36, 20)];
    h1.text = [NSString stringWithFormat:@"待取取件码 · %lu 条", (unsigned long)[[QKMStore shared] pendingCount]];
    h1.font = [UIFont boldSystemFontOfSize:13];
    h1.textColor = [UIColor colorWithRed:0.16 green:0.60 blue:0.54 alpha:1.0];
    [sc addSubview:h1]; y += 26;

    NSUInteger shown = 0;
    for (NSDictionary *r in records) {
        if ([r[QKMKeyDone] boolValue] || shown >= 4) continue;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(14, y, cw - 28, 46);
        b.backgroundColor = [UIColor whiteColor];
        b.layer.cornerRadius = 10;
        UILabel *code = [[UILabel alloc] initWithFrame:CGRectMake(12, 4, 150, 24)];
        code.text = r[QKMKeyCode] ?: @"—";
        code.font = [UIFont boldSystemFontOfSize:19];
        [b addSubview:code];
        UILabel *st = [[UILabel alloc] initWithFrame:CGRectMake(12, 27, cw - 60, 15)];
        st.text = [NSString stringWithFormat:@"%@ · 点按复制", r[QKMKeyStation] ?: @"其它"];
        st.font = [UIFont systemFontOfSize:11];
        st.textColor = [UIColor grayColor];
        [b addSubview:st];
        NSString *c = r[QKMKeyCode] ?: @"";
        [b addTarget:self action:@selector(copyCode:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(b, "qkm_code", c, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sc addSubview:b];
        y += 52; shown++;
    }
    if (shown == 0) {
        UILabel *empty = [[UILabel alloc] initWithFrame:CGRectMake(16, y, cw - 32, 30)];
        empty.text = @"暂无待取码 · 收到通知后自动收录";
        empty.font = [UIFont systemFontOfSize:12];
        empty.textColor = [UIColor grayColor];
        [sc addSubview:empty]; y += 34;
    }
    y += 8;

    // ---- 查件入口 ----
    UILabel *h2 = [[UILabel alloc] initWithFrame:CGRectMake(18, y, cw - 36, 20)];
    h2.text = @"三个身份码 · 六个查件入口";
    h2.font = [UIFont boldSystemFontOfSize:13];
    h2.textColor = [UIColor colorWithRed:0.16 green:0.60 blue:0.54 alpha:1.0];
    [sc addSubview:h2]; y += 26;

    NSArray *entries = [QKMConfig allEntries];
    CGFloat gap = 8, colW = (cw - 28 - gap*2) / 3.0, colH = 58;
    for (NSUInteger i = 0; i < entries.count; i++) {
        QKMEntry *e = entries[i];
        NSUInteger row = i / 3, col = i % 3;
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(14 + col*(colW+gap), y + row*(colH+gap), colW, colH);
        b.backgroundColor = [UIColor whiteColor];
        b.layer.cornerRadius = 10;
        UIView *dot = [[UIView alloc] initWithFrame:CGRectMake(8, 8, 22, 22)];
        dot.backgroundColor = e.badgeColor;
        dot.layer.cornerRadius = 11;
        [b addSubview:dot];
        UILabel *g = [[UILabel alloc] initWithFrame:CGRectMake(8, 8, 22, 22)];
        g.text = e.badge; g.textColor = [UIColor whiteColor];
        g.font = [UIFont boldSystemFontOfSize:12]; g.textAlignment = NSTextAlignmentCenter;
        [b addSubview:g];
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(6, 32, colW-12, 20)];
        t.text = e.title; t.font = [UIFont systemFontOfSize:11];
        t.textAlignment = NSTextAlignmentCenter; t.adjustsFontSizeToFitWidth = YES;
        [b addSubview:t];
        [b addTarget:self action:@selector(entryTapped:) forControlEvents:UIControlEventTouchUpInside];
        objc_setAssociatedObject(b, "qkm_url", [QKMConfig urlForEntry:e], OBJC_ASSOCIATION_COPY_NONATOMIC);
        objc_setAssociatedObject(b, "qkm_web", e.webURL, OBJC_ASSOCIATION_COPY_NONATOMIC);
        [sc addSubview:b];
    }
    y += ((entries.count + 2)/3) * (colH + gap);
    sc.contentSize = CGSizeMake(cw, MAX(y + 10, CGRectGetHeight(sc.bounds)));

    // ---- 底部：打开桌面 App ----
    UIButton *app = [UIButton buttonWithType:UIButtonTypeSystem];
    app.frame = CGRectMake(14, ch - 46, cw - 28, 36);
    app.backgroundColor = [UIColor colorWithRed:0.16 green:0.60 blue:0.54 alpha:1.0];
    [app setTitle:@"打开桌面「取件快码」App" forState:UIControlStateNormal];
    [app setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    app.layer.cornerRadius = 10;
    [app addTarget:self action:@selector(openApp) forControlEvents:UIControlEventTouchUpInside];
    [card addSubview:app];
}

- (void)copyCode:(UIButton *)b {
    NSString *c = objc_getAssociatedObject(b, "qkm_code") ?: @"";
    [UIPasteboard generalPasteboard].string = c;
    UILabel *toast = [[UILabel alloc] initWithFrame:CGRectMake(0, -30, CGRectGetWidth(self.bounds), 30)];
    toast.text = [NSString stringWithFormat:@"已复制 %@", c];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.font = [UIFont systemFontOfSize:12];
    toast.textColor = [UIColor whiteColor];
    toast.backgroundColor = [[UIColor blackColor] colorWithAlphaComponent:0.7];
    [self addSubview:toast];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2*NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [toast removeFromSuperview];
    });
}

- (void)entryTapped:(UIButton *)b {
    QKMOpenURL(objc_getAssociatedObject(b, "qkm_url"), objc_getAssociatedObject(b, "qkm_web"));
    [[QKMPanel shared] dismiss];
}

- (void)openApp {
    QKMOpenURL(QKMAppScheme, nil);
    [[QKMPanel shared] dismiss];
}

@end

@implementation QKMPanel {
    QKMPanelView *_view;
}

+ (instancetype)shared {
    static QKMPanel *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (void)toggle {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self->_view.superview) { [self dismiss]; return; }
        UIWindow *w = QKMHostWindow();
        if (!w) return;
        QKMPanelView *v = [[QKMPanelView alloc] initWithFrame:w.bounds];
        v.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [v build];
        [w addSubview:v];
        [w bringSubviewToFront:v];
        self->_view = v;
    });
}

- (void)dismiss {
    if (![NSThread isMainThread]) { dispatch_async(dispatch_get_main_queue(), ^{ [self dismiss]; }); return; }
    [_view removeFromSuperview];
    _view = nil;
}

@end
