//
//  Tweak.m — 取件快码 Assit / Author: AssitDev
//
//  SpringBoard 注入端，3.0 合并版：
//   · 用 Objective-C runtime swizzle 读通知文本，本机解析取件码后落盘（1.0 功能）
//   · 挂悬浮球，点开是内置面板（含 2.0 的三身份码 / 六查件入口）
//   · 打注入标记供桌面 App 自检
//
//  刻意不使用 Logos / MSHookMessageEx：dylib 不链接 CydiaSubstrate，
//  在 ElleKit 与不同 iOS 版本上少一层加载失败的可能。
//

#import "QKMConfig.h"
#import "QKMBubble.h"
#import "QKMPanel.h"
#import "QKMParser.h"
#import "QKMStore.h"
#import <objc/runtime.h>

typedef void (*QKMPublish3)(id, SEL, id, unsigned long long, BOOL);
typedef void (*QKMPublish2)(id, SEL, id, unsigned long long);

static QKMPublish3 _orig3 = NULL;
static QKMPublish2 _orig2 = NULL;
static BOOL _swizzled = NO;

#pragma mark - 通知文本读取

static NSString *QKMBulletinString(id b, NSString *key) {
    @try {
        id v = [b valueForKey:key];
        return [v isKindOfClass:[NSString class]] ? v : nil;
    } @catch (__unused NSException *e) {
        return nil;
    }
}

static UIWindow *QKMBannerWindow(void) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
}

static void QKMShowBanner(NSString *code) {
    if (![QKMConfig bannerEnabled]) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIWindow *w = QKMBannerWindow();
        if (!w) return;
        CGFloat W = CGRectGetWidth(w.bounds);
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(12, 44, W - 24, 62)];
        v.backgroundColor = [UIColor colorWithRed:0.16 green:0.60 blue:0.54 alpha:0.97];
        v.layer.cornerRadius = 12;
        v.alpha = 0;
        UILabel *t = [[UILabel alloc] initWithFrame:CGRectMake(14, 8, W - 52, 22)];
        t.text = @"收到新的取件码"; t.textColor = [UIColor whiteColor];
        t.font = [UIFont boldSystemFontOfSize:14]; [v addSubview:t];
        UILabel *c = [[UILabel alloc] initWithFrame:CGRectMake(14, 30, W - 52, 24)];
        c.text = code; c.textColor = [UIColor whiteColor];
        c.font = [UIFont boldSystemFontOfSize:20]; [v addSubview:c];
        [w addSubview:v]; [w bringSubviewToFront:v];
        [UIView animateWithDuration:0.25 animations:^{ v.alpha = 1; } completion:^(BOOL done) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.6 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [UIView animateWithDuration:0.3 animations:^{ v.alpha = 0; }
                                 completion:^(BOOL ok) { [v removeFromSuperview]; }];
            });
        }];
    });
}

static void QKMProcessBulletin(id obj) {
    if (![QKMConfig autoCapture] || !obj) return;
    @try {
        NSMutableArray *parts = [NSMutableArray array];
        for (NSString *k in @[@"title", @"subtitle", @"message"]) {
            NSString *s = QKMBulletinString(obj, k);
            if (s.length) [parts addObject:s];
        }
        if (!parts.count) return;
        NSString *text = [parts componentsJoinedByString:@"\n"];
        if (text.length > 2000) text = [text substringToIndex:2000];
        NSString *section = QKMBulletinString(obj, @"sectionID") ?: @"";
        NSInteger added = [[QKMStore shared] ingestText:text section:section];
        if (added > 0) {
            NSArray *codes = [QKMParser codesFromText:text];
            QKMShowBanner(codes.firstObject ?: [NSString stringWithFormat:@"新增 %ld 条", (long)added]);
        }
    } @catch (__unused NSException *e) {
        // 单条通知解析失败绝不能影响系统通知流程
    }
}

#pragma mark - BBServer swizzle

static void QKMRepl3(id self, SEL _cmd, id bulletin, unsigned long long dest, BOOL alwaysOn) {
    @autoreleasepool { QKMProcessBulletin(bulletin); }
    if (_orig3) _orig3(self, _cmd, bulletin, dest, alwaysOn);
}

static void QKMRepl2(id self, SEL _cmd, id bulletin, unsigned long long dest) {
    @autoreleasepool { QKMProcessBulletin(bulletin); }
    if (_orig2) _orig2(self, _cmd, bulletin, dest);
}

static void QKMSwizzleBBServer(void) {
    if (_swizzled) return;
    Class cls = objc_getClass("BBServer");
    if (!cls) return;   // SpringBoard 早期还没加载 BulletinBoard，稍后重试

    Method m3 = class_getInstanceMethod(cls, sel_registerName("publishBulletin:destinations:alwaysOn:"));
    if (m3 && !_orig3) {
        IMP o = method_getImplementation(m3);
        method_setImplementation(m3, (IMP)QKMRepl3);
        _orig3 = (QKMPublish3)o;
    }
    Method m2 = class_getInstanceMethod(cls, sel_registerName("publishBulletin:destinations:"));
    if (m2 && !_orig2) {
        IMP o = method_getImplementation(m2);
        method_setImplementation(m2, (IMP)QKMRepl2);
        _orig2 = (QKMPublish2)o;
    }
    if (_orig3 || _orig2) _swizzled = YES;
}

#pragma mark - 生命周期

static void QKMMount(void) {
    QKMSwizzleBBServer();
    [[QKMBubble shared] mount];
}

static void QKMPrefsDidChange(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [QKMConfig reloadFromDisk];
    [[QKMBubble shared] setEnabled:[QKMConfig bubbleEnabled]];
    QKMMount();
}

static void QKMCodesDidChange(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[QKMStore shared] reload];   // 桌面 App 里改了记录，SpringBoard 侧同步
}

__attribute__((constructor)) static void QKMInit(void) {
    @autoreleasepool {
        [QKMConfig markInjected];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            QKMPrefsDidChange, (__bridge CFStringRef)QKMPrefsDarwinNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
            QKMCodesDidChange, (__bridge CFStringRef)QKMCodesDarwinNotification, NULL,
            CFNotificationSuspensionBehaviorDeliverImmediately);

        // SpringBoard 启动早期可能还没有 window / BBServer，多时间点兜底
        for (NSNumber *d in @[@0.5, @1.5, @3.0, @6.0, @12.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ QKMMount(); });
        }
        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) {
                [[QKMPanel shared] dismiss];
                QKMMount();
            }];
    }
}
