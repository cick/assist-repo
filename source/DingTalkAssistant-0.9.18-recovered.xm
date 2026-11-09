//
//  DingTalkAssistant.xm
//  钉钉助手 —— 独立项目（从「顶栏时间 Assit」v0.9.43 的钉钉模块拆分出来）
//
//  架构：单个 dylib 同时注入两个进程（filter plist 里两个 bundle）：
//    · com.apple.springboard  → 精确定时器，到点「整秒」拉起钉钉（锁屏下也生效）。
//    · com.alibaba.ios.DingTalk → 3s 轮询，在「到点窗口 / pending」内逐级导航到打卡页、
//                              按「打卡」文字找按钮并触发真实点击（含 WebView JS 兜底）。
//
//  偏好域：com.dev.dingtalkassistant。
//  日志：com.dev.dingtalkassistant.punch.log（调度侧） / com.dev.dingtalkassistant.dingtalk.log（点击侧）。
//
//  v0.9.2 改动：
//    • 调度器由「固定 30s 轮询」改为 dispatch 精确定时器，到点误差 < 1s（消除 25~26s 延迟）。
//    • 新增 pending 握手文件：调度器到点写 pending，钉钉侧点击器即使冷启动也照常行动。
//    • 点击器支持逐级导航：工作台 → 考勤打卡 → 上班/下班打卡，冷启动也能跳到打卡页自动打卡。
//    • 新增「考勤深链(可选)」偏好：填了就直接 openURL 跳到考勤页，更快更稳。
//

#import <UIKit/UIKit.h>
#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import <dispatch/dispatch.h>
#import <sys/sysctl.h>
#import <signal.h>

static NSString *const kDTA_Domain = @"com.dev.dingtalkassistant";
// 构建标记：日志里带上它，就能一眼确认「钉钉里跑的到底是哪一版 dylib」
// （手动注入的用户最容易踩的坑：装了新 deb，但 App 内还是旧的一份拷贝）
static NSString *const kDTA_BuildTag = @"0.9.18";
// 跨进程握手与调试日志一律走 CFPreferences（钉钉是被沙盒化的 App，
// 直接读写 /var/mobile/Library/Preferences 下的自定义文件会被沙盒拦截，
// 这也是旧版「冷启动后没动静 / 日志找不到」的根因）。
static NSString *const kDTA_PendingKey  = @"dingtalkPending";   // 调度器写入、点击器读取的待打卡槽位
static NSString *const kDTA_DoneKey     = @"dingtalkDoneDate";  // 今日已打卡日期 YYYY-MM-DD
// ⚠️ 两个进程的调试日志必须分开存：CFPreferences 是「整体覆盖写」，
//    若共用同一个 key，SpringBoard 与钉钉会互相抹掉对方写的日志（表现为点侧日志永远看不到）。
static NSString *const kDTA_DebugKey       = @"dingtalkDebugLog";       // SCHED 侧滚动日志
static NSString *const kDTA_DebugClickKey  = @"dingtalkDebugLogClick";  // CLICK 侧滚动日志

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// ⚠️ 跨进程读偏好前必须先同步：CFPreferences 在每个进程内都有自己的缓存，
//    若设置进程（或 SpringBoard）刚写入而本进程不同步，读到的会是陈旧值——
//    这会让「pending 握手」和「立即测试」静默失效（表现为点了没反应 / 拉起后不动手）。
//    同步是同步 IPC，因此做 3 秒节流，避免每次读都走 IPC。
static NSDate *gDTA_LastSync = nil;
static void dtaSyncIfNeeded(void) {
    @try {
        NSDate *now = [NSDate date];
        if (gDTA_LastSync && [now timeIntervalSinceDate:gDTA_LastSync] < 3.0) return;
        gDTA_LastSync = now;
        CFPreferencesAppSynchronize((__bridge CFStringRef)kDTA_Domain);
    } @catch (NSException *e) {}
}

// ── 偏好读取（独立域） ───────────────────────────────────────────────────────────
static id dtaPref(NSString *k) {
    dtaSyncIfNeeded();
    CFTypeRef v = CFPreferencesCopyValue((__bridge CFStringRef)k,
                                         (__bridge CFStringRef)kDTA_Domain,
                                         kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (v == NULL) return nil;
    return (__bridge_transfer id)v;
}
static BOOL dtaBool(NSString *k, BOOL def) {
    id v = dtaPref(k);
    if (v == nil) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v boolValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v boolValue];
    return def;
}
static NSInteger dtaInt(NSString *k, NSInteger def) {
    id v = dtaPref(k);
    if (v == nil) return def;
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v integerValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v integerValue];
    return def;
}
static NSString *dtaStr(NSString *k) {
    id v = dtaPref(k);
    return [v isKindOfClass:[NSString class]] ? v : nil;
}

// 写偏好（v 为 nil 即删除该键）。走 cfprefsd 中转，沙盒内 App 也能读。
static void dtaSetPref(NSString *k, id v) {
    CFPreferencesSetValue((__bridge CFStringRef)k,
                          v ? (__bridge CFPropertyListRef)v : NULL,
                          (__bridge CFStringRef)kDTA_Domain,
                          kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    CFPreferencesSynchronize((__bridge CFStringRef)kDTA_Domain,
                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
}
static NSString *dtaCopyPref(NSString *k) {
    dtaSyncIfNeeded();
    CFTypeRef v = CFPreferencesCopyValue((__bridge CFStringRef)k,
                                         (__bridge CFStringRef)kDTA_Domain,
                                         kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    if (!v) return nil;
    if (CFGetTypeID(v) == CFStringGetTypeID()) return (__bridge_transfer NSString *)v;
    CFRelease(v);
    return nil;
}

// ── 跨进程信标（Darwin 通知）──────────────────────────────────────────────────────
// ⚠️ 关键根因：钉钉是沙盒 App，cfprefsd 只允许它写「自己 bundleID 对应的偏好域」，
//    写外域 com.dev.dingtalkassistant 会被静默拒绝。所以点击器绝不能靠写 CFPreferences
//    向外汇报「我还活着 / 我在做什么」——那样永远看不到心跳（正是此前「从未收到心跳」的真相）。
//    改用 Darwin 通知（走 notifyd，任何进程都能发，不受沙盒限制）。
//    再由非沙盒的 SpringBoard 调度器收到后，转写 CFPreferences，供设置页读取。
static NSString *const kDTA_NoteBeatName = @"com.dev.dingtalkassistant/clicker-beat";
static NSString *const kDTA_StatePrefix  = @"com.dev.dingtalkassistant/clicker-state-";
// 点击器抓到「选择打卡企业」列表后，写进【钉钉自己的偏好域】（沙盒允许写自己域），
// 再发这个固定名通知，让非沙盒的 SpringBoard 把它转写到本插件域，供设置页展示企业名称。
static NSString *const kDTA_NoteOrgNames   = @"com.dev.dingtalkassistant/orgnames-updated";
static NSString *const kDTA_OrgNamesLocal  = @"DTAOrgNames";          // 写在钉钉域里的 key
static NSString *const kDTA_OrgNamesKey    = @"dingtalkOrgNames";     // 本插件域（设置页读这个）
static void dtaPostNote(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, FALSE);
}
// 点击器上报状态用的 code 清单（同时也是调度器要监听的通知名后缀）
static NSArray<NSString *> *kDTA_StateCodes(void) {
    static NSArray *a; static dispatch_once_t o;
    dispatch_once(&o, ^{
        a = @[@"loaded",@"alive",@"run-pending",@"run-window",@"skip-done",@"skip-off",
              @"skip-window",@"ok",@"tab-workbench",@"nav-entry",@"noweb",@"nokw",@"err"];
    });
    return a;
}
// 点击器上报状态：只发 Darwin 通知（沙盒可发），名称含 code，由调度器转写 CFPreferences
static void dtaClickState(NSString *code) {
    if (!code.length) return;
    dtaPostNote([kDTA_StatePrefix stringByAppendingString:code]);
}
// ── 企业名称缓存 ─────────────────────────────────────────────────────────────────
// 目标：设置页能直接展示「企业A / 企业B」让用户选，而不是只看到「第1个 / 第2个」。
// 关键限制：点击器在钉钉沙盒内，只能写「自己 bundleID 对应的偏好域」。
//   → 所以把企业名列表写进钉钉自己的域（沙盒允许），再发通知让 SpringBoard 转写到本插件域。
//   → 设置页两条都读：优先本插件域（调度器已转发），其次直接读钉钉域（独立注入时没有调度器）。
static NSArray<NSString *> *dtaOrgNamesArrayFromString(NSString *s) {
    NSMutableArray<NSString *> *out = [NSMutableArray array];
    if (!s.length) return out;
    for (NSString *ln in [s componentsSeparatedByString:@"\n"]) {
        NSString *t = [ln stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length) [out addObject:t];
    }
    return out;
}

// 点击器：写进自己（钉钉）的偏好域
static void dtaSaveOrgNamesToOwnDomain(NSArray<NSString *> *names) {
    @try {
        if (names.count == 0) return;
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if (!bid.length || [bid hasPrefix:@"com.apple."]) return;
        NSString *joined = [names componentsJoinedByString:@"\n"];
        CFPreferencesSetValue((__bridge CFStringRef)kDTA_OrgNamesLocal,
                              (__bridge CFStringRef)joined,
                              (__bridge CFStringRef)bid,
                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize((__bridge CFStringRef)bid,
                                 kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
    } @catch (NSException *e) {}
}

// 已知的钉钉 bundleID（真实机器上是 com.laiwang.DingTalk，其余为兼容兜底）
static NSArray<NSString *> *dtaDingTalkDomains(void) {
    return @[@"com.laiwang.DingTalk", @"com.laiwang.DingTalkHD",
             @"com.alibaba.DingTalk", @"com.alibaba.DingTalkHD"];
}

static NSArray<NSString *> *dtaOrgNamesFromDingTalkDomain(void) {
    for (NSString *dom in dtaDingTalkDomains()) {
        CFPreferencesAppSynchronize((__bridge CFStringRef)dom);
        CFTypeRef v = CFPreferencesCopyValue((__bridge CFStringRef)kDTA_OrgNamesLocal,
                                             (__bridge CFStringRef)dom,
                                             kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (!v) continue;
        NSString *s = nil;
        if (CFGetTypeID(v) == CFStringGetTypeID()) s = (__bridge_transfer NSString *)v;
        else CFRelease(v);
        NSArray *a = dtaOrgNamesArrayFromString(s);
        if (a.count) return a;
    }
    return @[];
}

// 调度器：接收点击器信标，转写为 CFPreferences（非沙盒，可写），供设置页读取。
// 这是让「心跳 / 状态」能真实显示出来的关键桥梁。
static void dtaClickerNote(CFNotificationCenterRef __unused center, void *__unused obs,
                           CFStringRef name, const void *__unused object, CFDictionaryRef __unused info) {
    @try {
        NSString *n = (__bridge NSString *)name;
        NSString *ts = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
        if ([n isEqualToString:kDTA_NoteBeatName]) {
            dtaSetPref(@"dingtalkClickBeat", ts);
            return;
        }
        if ([n isEqualToString:kDTA_NoteOrgNames]) {
            NSArray<NSString *> *names = dtaOrgNamesFromDingTalkDomain();
            if (names.count) {
                dtaSetPref(kDTA_OrgNamesKey, [names componentsJoinedByString:@"\n"]);
            }
            return;
        }
        if ([n hasPrefix:kDTA_StatePrefix]) {
            NSString *code = [n substringFromIndex:kDTA_StatePrefix.length];
            dtaSetPref(@"dingtalkClickBeat", ts);
            dtaSetPref(@"dingtalkClickState", code);
        }
    } @catch (NSException *e) {}
}

// 进程标记：SCHED / CLICK。必须在 dtaLogPath / dtaDebugKey 之前声明，
// 因为日志的文件名与偏好 key 都要按进程区分（否则两侧日志会互相覆盖）。
static NSString *gDTA_Proc = @"?";

// 日志路径：取各自进程的沙盒可写目录（SpringBoard→/var/mobile/…，钉钉→其容器），均真实可写。
// 两侧文件名也不同，便于分别排查。
static NSString *dtaLogPath(void) {
    NSString *name = [gDTA_Proc isEqualToString:@"CLICK"]
                   ? @"com.dev.dingtalkassistant.click.log"
                   : @"com.dev.dingtalkassistant.log";
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Preferences"];
    return [dir stringByAppendingPathComponent:name];
}

static NSString *dtaDebugKey(void) {
    return [gDTA_Proc isEqualToString:@"CLICK"] ? kDTA_DebugClickKey : kDTA_DebugKey;
}

static NSMutableString *gDTA_Debug = nil;          // 滚动调试缓冲（仅在日志队列内访问）
static dispatch_queue_t gDTA_LogQ = NULL;

// 日志队列：所有文件 I/O 与 cfprefsd 通信都在这里做。
// ⚠️ 绝不能在主线程同步跑——SpringBoard 启动瞬间 cfprefsd 可能还没就绪，
//    同步 IPC 会把主线程挂住，看门狗杀掉 SpringBoard → 安全模式。
static dispatch_queue_t dtaLogQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDTA_LogQ = dispatch_queue_create("com.dev.dingtalkassistant.logq", DISPATCH_QUEUE_SERIAL);
    });
    return gDTA_LogQ;
}

// 异步日志：只做格式化，落盘与偏好写入全部丢到后台队列
static void dtaLog(NSString *fmt, ...) {
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        NSString *line = [NSString stringWithFormat:@"[%@][%@] %@\n",
                          [NSDate date], gDTA_Proc, s];
        // 独立注入场景（TrollFools/自签）可由控制台/idevicesyslog 直接看到点击器日志
        if ([gDTA_Proc isEqualToString:@"CLICK"]) {
            NSLog(@"[DTA-CLICK] %@", s);
        }
        dispatch_async(dtaLogQueue(), ^{
            @try {
                NSString *path = dtaLogPath();
                NSString *old = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL] ?: @"";
                NSString *all = [old stringByAppendingString:line];
                if (all.length > 200000) all = line;   // 超过 200K 截断，避免无限增长
                [all writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL];

                if (!gDTA_Debug) gDTA_Debug = [NSMutableString string];
                [gDTA_Debug appendString:line];
                if (gDTA_Debug.length > 6000) {
                    [gDTA_Debug deleteCharactersInRange:NSMakeRange(0, gDTA_Debug.length - 6000)];
                }
                dtaSetPref(dtaDebugKey(), gDTA_Debug);
            } @catch (NSException *e) {}
        });
    } @catch (NSException *e) {}
}

// ── pending 握手（调度器 → 点击器），全部走 CFPreferences ──────────────────────────
static void dtaWritePending(NSString *slot) {
    dtaSetPref(kDTA_PendingKey, slot);
}
static void dtaClearPending(void) {
    dtaSetPref(kDTA_PendingKey, nil);
}
static NSString *dtaReadPending(void) {
    return dtaCopyPref(kDTA_PendingKey);
}

// 今日是否已成功打卡（防止 10 分钟窗口内每分钟重复点、以及深夜手动打开误打）
static BOOL dtaDoneToday(void) {
    NSString *d = dtaCopyPref(kDTA_DoneKey);
    if (!d || d.length < 10) return NO;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                   fromDate:[NSDate date]];
    NSString *today = [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
                       (long)now.year, (long)now.month, (long)now.day];
    return [d isEqualToString:today];
}
static void dtaMarkDone(void) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                   fromDate:[NSDate date]];
    NSString *today = [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
                       (long)now.year, (long)now.month, (long)now.day];
    dtaSetPref(kDTA_DoneKey, today);
    dtaLog(@"今日已打卡，写入 done 标记（当天不再重复）");
}

// 解析打卡时间 HH:mm[:ss]（兼容旧的两段格式，缺秒按 0）
static void dtaParseTime(NSString *ts, NSInteger *outH, NSInteger *outM, NSInteger *outS) {
    if (ts.length < 4) ts = @"09:00:00";
    NSArray<NSString *> *p = [ts componentsSeparatedByString:@":"];
    NSInteger h = (p.count >= 1) ? [p[0] integerValue] : 9;
    NSInteger m = (p.count >= 2) ? [p[1] integerValue] : 0;
    NSInteger s = (p.count >= 3) ? [p[2] integerValue] : 0;
    if (h < 0 || h > 23 || m < 0 || m > 59 || s < 0 || s > 59) { h = 9; m = 0; s = 0; }
    if (outH) *outH = h;
    if (outM) *outM = m;
    if (outS) *outS = s;
}

// ── 视图扫描（钉钉侧） ─────────────────────────────────────────────────────────────
static UIControl *dtaScanByTitle(UIView *view, NSString *target) {
    if (!view) return nil;
    if ([view isKindOfClass:[UIControl class]]) {
        NSString *title = nil;
        if ([view isKindOfClass:[UIButton class]]) {
            UIButton *b = (UIButton *)view;
            title = b.currentTitle ?: [b titleForState:UIControlStateNormal];
        }
        NSString *acc = [view accessibilityLabel];
        NSString *txt = title.length ? title : acc;
        if (txt && [txt rangeOfString:target].location != NSNotFound) return (UIControl *)view;
    }
    for (UIView *sub in view.subviews) {
        UIControl *r = dtaScanByTitle(sub, target);
        if (r) return r;
    }
    return nil;
}
static UILabel *dtaScanLabel(UIView *view, NSString *target) {
    if (!view) return nil;
    if ([view isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)view text];
        if (t && [t rangeOfString:target].location != NSNotFound) return (UILabel *)view;
    }
    for (UIView *sub in view.subviews) {
        UILabel *r = dtaScanLabel(sub, target);
        if (r) return r;
    }
    return nil;
}
static UIControl *dtaAncestorControl(UIView *v) {
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 32) {
        if ([cur isKindOfClass:[UIControl class]]) return (UIControl *)cur;
        cur = cur.superview;
    }
    return nil;
}

// 按 mode 选目标词：0=上班 1=下班 2=自动
static NSArray<NSString *> *dtaTargets(NSInteger mode) {
    if (mode == 0) return @[@"上班打卡", @"上班", @"打卡"];
    if (mode == 1) return @[@"下班打卡", @"下班", @"打卡"];
    return @[@"打卡"];
}

static UIControl *dtaTryButton(UIView *root, NSInteger mode) {
    NSArray<NSString *> *ts = dtaTargets(mode);
    for (NSString *t in ts) {
        UIControl *c = dtaScanByTitle(root, t);
        if (c) { dtaLog(@"找到按钮(title/acc 匹配 '%@'): %@", t, [c class]); return c; }
    }
    for (NSString *t in ts) {
        UILabel *l = dtaScanLabel(root, t);
        if (l) {
            UIControl *c = dtaAncestorControl(l);
            if (c) { dtaLog(@"找到按钮(label 匹配 '%@' → 祖先 %@)", t, [c class]); return c; }
            dtaLog(@"label 匹配 '%@' 但无祖先 UIControl", t);
        }
    }
    return nil;
}

static void dtaClick(UIControl *btn) {
    @try {
        for (id t in [[btn allTargets] allObjects]) {
            NSArray<NSString *> *acts = [btn actionsForTarget:t forControlEvent:UIControlEventTouchUpInside];
            for (NSString *a in acts) {
                SEL sel = NSSelectorFromString(a);
                if (sel && [t respondsToSelector:sel]) {
                    [t performSelector:sel withObject:btn];
                    dtaLog(@"调用 action %@ on %@", a, [t class]);
                }
            }
        }
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        dtaLog(@"sendActions TouchUpInside 已发");
    } @catch (NSException *e) {
        dtaLog(@"点击异常: %@", e);
    }
}

// WebView 兜底：找含「打卡」文字的 DOM 元素 click
static id dtaFindWebView(UIView *root) {
    if (!root) return nil;
    NSString *cls = NSStringFromClass([root class]);
    if ([cls containsString:@"WebView"]) return root;
    for (UIView *s in root.subviews) {
        id r = dtaFindWebView(s);
        if (r) return r;
    }
    return nil;
}
static void dtaWebViewFallback(UIView *root, NSInteger mode) {
    NSArray<NSString *> *ts = dtaTargets(mode);
    id web = dtaFindWebView(root);
    if (!web) return;
    NSString *js = [NSString stringWithFormat:
        @"(function(){var ts=%@;var els=document.querySelectorAll('*');"
        @"for(var i=0;i<els.length;i++){var t=(els[i].textContent||'').trim();"
        @"if(t&&els[i].offsetParent!==null){for(var j=0;j<ts.length;j++){"
        @"if(t.indexOf(ts[j])>=0){els[i].click();return 'clicked:'+t;}}}}return 'none';})()",
        [NSString stringWithFormat:@"['%@']", [ts componentsJoinedByString:@"','"]]];
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (sel && [web respondsToSelector:sel]) {
        @try {
            [web performSelector:sel withObject:js withObject:^(id res, id err){
                dtaLog(@"WebView JS 结果=%@ err=%@", res, err);
            }];
            dtaLog(@"WebView JS 已发");
        } @catch (NSException *e) {
            dtaLog(@"WebView JS 异常: %@", e);
        }
    }
}

// ── 是否处于「到点窗口」 ──────────────────────────────────────────────────────────
static BOOL dtaArmed(NSInteger *outMode) {
    if (!dtaBool(@"dingtalkPunchEnabled", NO)) return NO;
    NSInteger setH = 9, setM = 0, setS = 0;
    dtaParseTime(dtaStr(@"dingtalkPunchTime"), &setH, &setM, &setS);
    (void)setS;   // 窗口判断仍按分钟粒度，秒只影响触发时刻

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:(NSCalendarUnitWeekday|NSCalendarUnitHour|NSCalendarUnitMinute|
                                            NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                   fromDate:[NSDate date]];
    NSInteger rep = dtaInt(@"dingtalkPunchRepeat", 0);
    BOOL due = YES;
    if (rep == 0)       due = (now.weekday >= 2 && now.weekday <= 6);
    else if (rep == 1)  due = YES;
    else {
        NSInteger days = dtaInt(@"dingtalkPunchDays", 12345);
        NSInteger w = now.weekday;                 // 1=周日..7=周六
        NSInteger ours = (w == 1) ? 7 : (w - 1);    // 1=周一..7=周日
        due = (days & (1 << (ours - 1))) ? YES : NO;
    }
    if (!due) return NO;

    NSInteger nowMin = now.hour * 60 + now.minute;
    NSInteger setMin = setH * 60 + setM;
    if (nowMin < setMin || nowMin > setMin + 10) return NO;   // ±10 分钟窗口

    *outMode = dtaInt(@"dingtalkPunchMode", 2);
    return YES;
}

// pending 是否今天（调度器已在本日点过火）
static BOOL dtaPendingToday(NSInteger *outMode) {
    NSString *pend = dtaReadPending();
    if (!pend || pend.length < 10) return NO;
    NSArray<NSString *> *parts = [pend componentsSeparatedByString:@" "];
    NSString *datePart = parts.firstObject;
    if (datePart.length < 10) return NO;
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                   fromDate:[NSDate date]];
    NSString *today = [NSString stringWithFormat:@"%04ld-%02ld-%02ld",
                       (long)now.year, (long)now.month, (long)now.day];
    if (![datePart isEqualToString:today]) { dtaClearPending(); return NO; }
    // 30 分钟宽限：超过设定时间 30 分钟才手动打开钉钉，则不再自动打卡（避免深夜误打）
    if (parts.count >= 2) {
        NSArray<NSString *> *tp = [parts[1] componentsSeparatedByString:@":"];
        if (tp.count >= 2) {
            NSInteger setMin = [tp[0] integerValue] * 60 + [tp[1] integerValue];
            NSCalendar *cal = [NSCalendar currentCalendar];
            NSDateComponents *n = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute) fromDate:[NSDate date]];
            NSInteger nowMin = n.hour * 60 + n.minute;
            if (nowMin > setMin + 30) { dtaClearPending(); return NO; }
        }
    }
    *outMode = dtaInt(@"dingtalkPunchMode", 2);
    return YES;
}

static BOOL dtaClickShouldRun(NSInteger *outMode, BOOL *outFromPending) {
    if (dtaDoneToday()) return NO;   // 今日已打，当天不再重复
    if (dtaArmed(outMode)) { if (outFromPending) *outFromPending = NO;  return YES; }
    if (dtaPendingToday(outMode)) { if (outFromPending) *outFromPending = YES; return YES; }
    return NO;
}

static NSString *dtaSlotNow(NSInteger setH, NSInteger setM, NSInteger setS) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *now = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                   fromDate:[NSDate date]];
    return [NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld:%02ld:%02ld",
            (long)now.year, (long)now.month, (long)now.day, (long)setH, (long)setM, (long)setS];
}

// ── SpringBoard 调度器：精确定时器，到点整秒拉起钉钉 ─────────────────────────────────
static dispatch_source_t gDTA_Timer = NULL;
static NSString *gDTA_LastScheduled = nil;

// 探测本机上钉钉的真实 bundle ID / 可执行名。
// 这是排查「dylib 没注入钉钉」的决定性手段：SpringBoard 能枚举所有已安装 App。
static void dtaProbeDingTalkApps(void) {
    @try {
        Class wsCls = NSClassFromString(@"LSApplicationWorkspace");
        if (!wsCls) { dtaLog(@"🔍 探测失败：无 LSApplicationWorkspace"); return; }
        id ws = [wsCls performSelector:@selector(defaultWorkspace)];
        if (!ws) { dtaLog(@"🔍 探测失败：无 workspace 实例"); return; }
        NSArray *apps = nil;
        SEL allSel = @selector(allInstalledApplications);
        if ([ws respondsToSelector:allSel]) apps = [ws performSelector:allSel];
        if (!apps.count) { dtaLog(@"🔍 探测失败：应用列表为空"); return; }

        NSInteger found = 0;
        for (id app in apps) {
            NSString *bid = nil, *exe = nil, *name = nil;
            if ([app respondsToSelector:@selector(bundleIdentifier)]) bid  = [app performSelector:@selector(bundleIdentifier)];
            if ([app respondsToSelector:@selector(bundleExecutable)])  exe  = [app performSelector:@selector(bundleExecutable)];
            if ([app respondsToSelector:@selector(localizedName)])     name = [app performSelector:@selector(localizedName)];
            NSString *hay = [NSString stringWithFormat:@"%@ %@ %@", bid ?: @"", exe ?: @"", name ?: @""].lowercaseString;
            if ([hay rangeOfString:@"ding"].location == NSNotFound) continue;
            found++;
            dtaLog(@"🔍 钉钉相关应用#%ld bundleID=%@ 可执行=%@ 名称=%@", (long)found, bid, exe, name);
        }
        if (!found) dtaLog(@"🔍 未发现任何含 ding 的应用（钉钉可能未安装）");
    } @catch (NSException *e) {
        dtaLog(@"🔍 探测异常: %@", e);
    }
}

// 强制结束钉钉进程，确保下次拉起是「冷启动」。
// ⚠️ 这是「dylib 没注入钉钉」最常见的现实原因：Respring 只重启 SpringBoard，
//    不会重启早已在后台的钉钉进程，而 dylib 只在进程启动时加载 → 点击器永远不运行。
// 遍历进程表，对可执行名含 ding 的进程执行动作（doKill=YES 则 SIGKILL），返回命中数量。
static int dtaForEachDingProc(NSString *tag, BOOL doKill) {
    int mib[3] = { CTL_KERN, KERN_PROC, KERN_PROC_ALL };
    size_t len = 0;
    if (sysctl(mib, 3, NULL, &len, NULL, 0) < 0 || len == 0) return -1;
    struct kinfo_proc *procs = (struct kinfo_proc *)malloc(len);
    if (!procs) return -1;
    if (sysctl(mib, 3, procs, &len, NULL, 0) < 0) { free(procs); return -1; }

    int n = (int)(len / sizeof(struct kinfo_proc));
    int hit = 0;
    for (int i = 0; i < n; i++) {
        const char *nm = procs[i].kp_proc.p_comm;
        if (!nm || !nm[0]) continue;
        NSString *p = [NSString stringWithUTF8String:nm];
        if (!p) continue;
        if ([[p lowercaseString] rangeOfString:@"ding"].location == NSNotFound) continue;
        pid_t pid = procs[i].kp_proc.p_pid;
        if (pid <= 1) continue;
        hit++;
        if (doKill) {
            dtaLog(@"%@ %@ pid=%d", tag, p, (int)pid);
            kill(pid, SIGKILL);
        } else {
            dtaLog(@"%@ %@ pid=%d", tag, p, (int)pid);
        }
    }
    free(procs);
    return hit;
}

static void dtaKillDingTalk(void) {
    int r = dtaForEachDingProc(@"♻️ 结束钉钉进程", YES);
    if (r == 0)  dtaLog(@"♻️ 未发现运行中的钉钉进程（本就是冷启动）");
    if (r < 0)   dtaLog(@"♻️ 进程表遍历失败（sysctl 被限制），无法强制重启");
}

static NSDate *dtaNextFireDate(void) {
    if (!dtaBool(@"dingtalkPunchEnabled", NO)) return nil;
    NSInteger setH = 9, setM = 0, setS = 0;
    dtaParseTime(dtaStr(@"dingtalkPunchTime"), &setH, &setM, &setS);

    NSCalendar *cal = [NSCalendar currentCalendar];
    [cal setTimeZone:[NSTimeZone localTimeZone]];
    NSDate *now = [NSDate date];
    for (int i = 0; i < 8; i++) {
        NSDate *base = [now dateByAddingTimeInterval:(NSTimeInterval)(i * 86400)];
        NSDateComponents *bc = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay)
                                      fromDate:base];
        bc.hour = setH; bc.minute = setM; bc.second = setS; bc.nanosecond = 0;
        NSDate *cand = [cal dateFromComponents:bc];
        if (!cand) continue;
        NSDateComponents *wc = [cal components:NSCalendarUnitWeekday fromDate:cand];
        NSInteger w = wc.weekday;                 // 1=周日..7=周六
        BOOL due = NO;
        NSInteger rep = dtaInt(@"dingtalkPunchRepeat", 0);
        if (rep == 0)       due = (w >= 2 && w <= 6);
        else if (rep == 1)  due = YES;
        else {
            NSInteger days = dtaInt(@"dingtalkPunchDays", 12345);
            NSInteger ours = (w == 1) ? 7 : (w - 1);
            due = (days & (1 << (ours - 1))) ? YES : NO;
        }
        if (!due) continue;
        if ([cand timeIntervalSinceDate:now] < -5) continue;   // 已过期，看下一天
        return cand;
    }
    return nil;
}

static void dtaPunchFire(void);   // 前向声明（在 dtaReschedule 的 block 中调用）
static void dtaReschedule(void);  // 前向声明（供下面通知回调使用）
static void dtaFloatRefresh(void); // 前向声明（悬浮球按偏好显示/隐藏，定义在后面）
static void dtaManualFire(BOOL force); // 前向声明：手动触发打卡（立即测试/悬浮球双击），不受定时总开关限制

// 设置变更通知回调：立即重排定时；并处理设置页「立即测试触发一次」写下的 dingtalkTestFire 标记。
static void dtaPrefsChanged(CFNotificationCenterRef __unused center, void *__unused observer,
                            CFStringRef __unused name, const void *__unused object,
                            CFDictionaryRef __unused userInfo) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            NSString *t = dtaCopyPref(@"dingtalkTestFire");
            if (t && [t isEqualToString:@"1"]) {
                dtaSetPref(@"dingtalkTestFire", nil);
                dtaLog(@"🧪 收到【立即测试】指令，立刻执行一次触发（不受定时开关限制）");
                dtaManualFire(YES);
            }
            dtaReschedule();
            dtaFloatRefresh();   // 悬浮球开关可能刚被切换
        } @catch (NSException *e) {}
    });
}

static void dtaPunchFire(void);   // 前向声明（在 dtaReschedule 的 block 中调用）

static void dtaReschedule(void) {
    NSDate *next = dtaNextFireDate();
    NSString *nextStr = next ? [next description] : @"<none>";
    if (!next) {
        if (gDTA_Timer) { dispatch_source_cancel(gDTA_Timer); gDTA_Timer = NULL; }
        if (![nextStr isEqualToString:gDTA_LastScheduled]) {
            gDTA_LastScheduled = nextStr;
            dtaLog(@"调度器：未启用/无下次触发，进入休眠");
        }
        return;
    }
    if (gDTA_Timer && [nextStr isEqualToString:gDTA_LastScheduled]) return;  // 无需重排

    if (gDTA_Timer) { dispatch_source_cancel(gDTA_Timer); gDTA_Timer = NULL; }
    dispatch_source_t t = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0,
                        dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0));
    if (!t) { dtaLog(@"调度器：timer 创建失败"); return; }
    int64_t delta = (int64_t)([next timeIntervalSinceNow] * NSEC_PER_SEC);
    if (delta < 0) delta = 0;
    dispatch_source_set_timer(t, dispatch_time(DISPATCH_TIME_NOW, delta),
                              DISPATCH_TIME_FOREVER, (int64_t)(0.5 * NSEC_PER_SEC));
    dispatch_source_set_event_handler(t, ^{
        dtaPunchFire();
        dtaReschedule();   // 触发后立即排下一天
    });
    dispatch_resume(t);
    gDTA_Timer = t;
    gDTA_LastScheduled = nextStr;
    dtaLog(@"调度器：下次触发 %@ (约 %.0f 秒后)", next, [next timeIntervalSinceNow]);
}

// 拉起钉钉：定时触发与悬浮球点击共用。
// force=YES 时先 SIGKILL 钉钉以确保冷启动（dylib 只在进程启动时加载）。
static void dtaLaunchDingTalk(BOOL force) {
    NSString *deep = dtaStr(@"dingtalkPunchDeepLink");
    NSString *urlStr = (deep && deep.length > 0) ? deep : @"dingtalk://";
    NSURL *u = [NSURL URLWithString:urlStr];
    if (!u) { dtaLog(@"❌ URL 无效: %@", urlStr); return; }

    if (force) dtaKillDingTalk();

    // ⚠️ openURL 是 UIKit API，必须回主线程。定时器跑在全局队列上，
    //    直接在后台线程调会崩 SpringBoard。
    //    强制重启时留 2.5s 让进程完全退出，避免立刻拉起又附到旧进程上。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((force ? 2.5 : 0.0) * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            // 拉起前再报一次进程表：可确认钉钉是否已彻底退出（强制重启是否真的生效）
            if (force) {
                int still = dtaForEachDingProc(@"🔎 拉起前仍存活的钉钉进程", NO);
                if (still == 0) dtaLog(@"🔎 拉起前钉钉已完全退出 ✓ 本次将是冷启动");
            }
            [[UIApplication sharedApplication] openURL:u options:@{} completionHandler:nil];
        } @catch (NSException *e) {
            dtaLog(@"openURL 异常: %@", e);
        }
    });
    dtaLog(@"拉起钉钉 深链=%@ 强制重启=%@", (deep && deep.length) ? @"Y" : @"N", force ? @"Y" : @"N");
}

static void dtaPunchFire(void) {
    if (!dtaBool(@"dingtalkPunchEnabled", NO)) { dtaClearPending(); return; }

    NSInteger setH = 9, setM = 0, setS = 0;
    dtaParseTime(dtaStr(@"dingtalkPunchTime"), &setH, &setM, &setS);

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *wc = [cal components:NSCalendarUnitWeekday fromDate:[NSDate date]];
    NSString *slot = dtaSlotNow(setH, setM, setS);

    // 写 pending：让钉钉侧点击器（哪怕冷启动）知道该打卡
    dtaWritePending(slot);

    // 强制重启钉钉 → 保证 dylib 一定被加载（否则钉钉若在后台，进程不重启＝点击器永不运行）
    BOOL force = dtaBool(@"dingtalkForceRestart", YES);
    if (force) dtaKillDingTalk();

    dtaLaunchDingTalk(force);
    dtaLog(@"⏰ 到点触发 槽=%@ 星期=%ld", slot, (long)wc.weekday);
}

// ── 悬浮球：SpringBoard 侧桌面悬浮图标，可拖动、松手自动吸附边缘 ─────────────────────
//  实现要点（每一条都是越狱悬浮窗的实际坑）：
//   1) 用独立 UIWindow 承载，level 略高于 Alert 即可浮在普通 App 之上；
//   2) ⚠️ 关键：window 的物理尺寸只包裹「球体 + 阴影余量」(约 90×90)，球外区域根本
//      不在 window 范围内——物理上不可能拦截桌面/其他 App 的点击，彻底规避全屏透明层吞触摸；
//   3) 不用 makeKeyAndVisible，避免抢走 SpringBoard 的 keyWindow 焦点；
//   4) 所有偏好写入丢到后台队列，绝不在主线程做同步 IPC（会挂住 SpringBoard → 安全模式）；
//   5) 位置按「横向比例 + 纵向比例」存，屏幕旋转后仍能等比还原；移动改的是 window.center。
//   6) 自由拖动到桌面任意位置均可停留；仅当松手时靠近左/右边栏（阈值内）才自动吸附贴边。
static NSString *const kDTA_FloatKey  = @"dingtalkFloatEnabled";   // 悬浮球开关
static NSString *const kDTA_FloatSide = @"dingtalkFloatSide";      // 旧版吸附侧：0=左 1=右（兼容老数据）
static NSString *const kDTA_FloatX    = @"dingtalkFloatXRatio";    // 横向比例 0~1（球心），自由位置
static NSString *const kDTA_FloatY    = @"dingtalkFloatYRatio";    // 纵向比例 0~1

// 打开钉钉后自动进入考勤页（工作台 → 用户配置的入口，如「考勤打卡 / 考情助手」）
static NSString *const kDTA_AutoOpenKey = @"dingtalkAutoOpen";     // 开关，默认开
static NSString *const kDTA_EntryKey    = @"dingtalkEntryName";    // 工作台入口名称，默认「考勤打卡」
static NSString *const kDTA_OrgKey      = @"dingtalkOrgIndex";     // 多企业时选第几个（1 起，默认 1）

static CGFloat const kDTA_BallSize = 58.0;
static CGFloat const kDTA_SnapMargin = 40.0;   // 距边栏多近才吸附（pt）

// 手动触发一次打卡（立即测试 / 悬浮球双击 共用）：**不受「启用定时打卡」总开关限制**。
// 写 pending + 清 done（允许当天补打/下班卡）+ 强制冷启动钉钉 → 点击器导航到工作台考勤打卡页并自动点击。
static void dtaManualFire(BOOL force) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond)
                                 fromDate:[NSDate date]];
    NSString *slot = dtaSlotNow(c.hour, c.minute, c.second);
    dispatch_async(dtaLogQueue(), ^{
        @try {
            dtaWritePending(slot);
            dtaSetPref(kDTA_DoneKey, nil);          // 手动触发：允许当天再打一次（如下班卡）
            dtaLog(@"🧪 手动触发打卡 槽=%@ force=%@", slot, force ? @"Y" : @"N");
        } @catch (NSException *e) {}
    });
    dtaLaunchDingTalk(force);
}

// ⚠️ 关键修复：早期版本用了「全屏 UIWindow + 全屏根视图 + pointInside 穿透」的写法，
// 在部分 iOS/越狱环境下穿透会失效，整块透明层把桌面点击全吞掉（表现为「钉钉打开后点不了别的」）。
// 现改为：悬浮窗自身就只有「球体 + 少量阴影余量」那么大，球外根本不在 window 范围内，
// 物理上不可能拦截球外区域的触摸——无需任何 pointInside/hitTest 重写。
static CGFloat const kDTA_BallWinPad = 16.0;   // window 比球大的余量（容纳阴影，避免被裁切）

@interface DTAFloatBall : UIView
- (instancetype)initWithSize:(CGFloat)size;
- (void)setDone:(BOOL)done;
- (void)dockOrFree:(BOOL)animated;
- (void)applyStoredPos:(CGFloat)xRatio yRatio:(CGFloat)ratio;
- (void)flash;
@end

@implementation DTAFloatBall {
    UIPanGestureRecognizer *_pan;
    UITapGestureRecognizer *_tap;
    UITapGestureRecognizer *_tap2;
    CGPoint _startCenter;
    BOOL _moved;
    BOOL _sleeping;
    NSTimer *_sleepTimer;
    CAGradientLayer *_grad;
    UILabel *_title;
    BOOL _done;
}

- (instancetype)initWithSize:(CGFloat)size {
    self = [super initWithFrame:CGRectMake(0, 0, size, size)];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.layer.shadowColor = [UIColor blackColor].CGColor;
    self.layer.shadowOpacity = 0.35;
    self.layer.shadowRadius = 10.0;
    self.layer.shadowOffset = CGSizeMake(0, 4);

    _grad = [CAGradientLayer layer];
    _grad.frame = self.bounds;
    _grad.cornerRadius = size / 2.0;
    _grad.startPoint = CGPointMake(0, 0);
    _grad.endPoint = CGPointMake(1, 1);
    [self.layer addSublayer:_grad];

    _title = [[UILabel alloc] initWithFrame:self.bounds];
    _title.textColor = [UIColor whiteColor];
    _title.font = [UIFont boldSystemFontOfSize:15];
    _title.textAlignment = NSTextAlignmentCenter;
    _title.backgroundColor = [UIColor clearColor];
    [self addSubview:_title];

    _done = NO;
    [self setDone:NO];

    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(_onPan:)];
    [self addGestureRecognizer:_pan];
    _tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onTap:)];
    // 轻点才算点击：pan 识别成功（即发生了拖动）时 tap 不触发
    [_tap requireGestureRecognizerToFail:_pan];
    [self addGestureRecognizer:_tap];

    // 双击：跳到工作台考勤打卡页并自动打卡（与单击并存，单点需等双击失败才触发）
    _tap2 = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(_onDoubleTap:)];
    _tap2.numberOfTapsRequired = 2;
    [self addGestureRecognizer:_tap2];
    [_tap requireGestureRecognizerToFail:_tap2];

    return self;
}

- (void)setDone:(BOOL)done {
    _done = done;
    UIColor *c1, *c2;
    if (done) {
        c1 = [UIColor colorWithRed:0.13 green:0.77 blue:0.37 alpha:1.0];   // 已打卡：绿
        c2 = [UIColor colorWithRed:0.06 green:0.60 blue:0.28 alpha:1.0];
    } else {
        c1 = [UIColor colorWithRed:0.086 green:0.467 blue:1.0  alpha:1.0]; // 待打卡：钉钉蓝
        c2 = [UIColor colorWithRed:0.039 green:0.388 blue:0.902 alpha:1.0];
    }
    _grad.colors = @[(__bridge id)c1.CGColor, (__bridge id)c2.CGColor];
    _title.text = done ? @"已打" : @"打卡";
}

- (CGFloat)_topLimit {
    CGFloat ins = 20;
    if (@available(iOS 11.0, *)) {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw) ins = MAX(kw.safeAreaInsets.top, 20);
    }
    return ins + 8 + self.bounds.size.height / 2.0;
}
- (CGFloat)_bottomLimit {
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    CGFloat ins = 20;
    if (@available(iOS 11.0, *)) {
        UIWindow *kw = [UIApplication sharedApplication].keyWindow;
        if (kw) ins = MAX(kw.safeAreaInsets.bottom, 20);
    }
    return h - ins - 8 - self.bounds.size.height / 2.0;
}

- (void)_wake {
    [_sleepTimer invalidate];
    _sleepTimer = nil;
    if (!_sleeping) return;
    _sleeping = NO;
    [UIView animateWithDuration:0.2 animations:^{
        self.alpha = 1.0;
        self.transform = CGAffineTransformIdentity;
    }];
}

// 静止 4s 后半透明缩小，贴边不挡视线；一碰即恢复
- (void)_scheduleSleep {
    [_sleepTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _sleepTimer = [NSTimer scheduledTimerWithTimeInterval:4.0 repeats:NO block:^(NSTimer * __unused t){
        __strong typeof(weakSelf) s = weakSelf;
        if (!s) return;
        s->_sleeping = YES;
        [UIView animateWithDuration:0.4 animations:^{
            s.alpha = 0.45;
            s.transform = CGAffineTransformMakeScale(0.86, 0.86);
        }];
    }];
}

- (void)_onTap:(UITapGestureRecognizer *)g {
    [self flash];
    dtaLaunchDingTalk(NO);   // 单击：只打开钉钉，不打卡
}

// 双击：清 done + 写 pending + 强制冷启动钉钉 → 点击器自动导航到「工作台 → 考勤打卡」并点击
- (void)_onDoubleTap:(UITapGestureRecognizer *)g {
    [self flash];
    dtaManualFire(YES);
}

- (void)_onPan:(UIPanGestureRecognizer *)g {
    UIWindow *win = self.window;
    if (!win) return;

    if (g.state == UIGestureRecognizerStateBegan) {
        _moved = NO;
        _startCenter = win.center;
        [self _wake];
        [UIView animateWithDuration:0.15 animations:^{
            self.transform = CGAffineTransformMakeScale(1.12, 1.12);
        }];
    } else if (g.state == UIGestureRecognizerStateChanged) {
        CGPoint tr = [g translationInView:win];
        if (fabs(tr.x) > 3 || fabs(tr.y) > 3) _moved = YES;
        CGFloat r = self.bounds.size.width / 2.0;
        CGFloat sw = [UIScreen mainScreen].bounds.size.width;
        // 自由拖动：限制在屏幕内，普通位置可任意停留（不再强制贴边）
        CGFloat margin = 2.0;
        CGFloat x = MIN(MAX(_startCenter.x + tr.x, r - margin), sw - r + margin);
        CGFloat y = MIN(MAX(_startCenter.y + tr.y, [self _topLimit]), [self _bottomLimit]);
        win.center = CGPointMake(x, y);
    } else if (g.state == UIGestureRecognizerStateEnded ||
               g.state == UIGestureRecognizerStateCancelled) {
        [UIView animateWithDuration:0.18 animations:^{
            self.transform = CGAffineTransformIdentity;
        }];
        [self dockOrFree:YES];
        [self _scheduleSleep];
    }
}

// 拖动结束：仅当松手位置靠近左/右边栏（阈值内）才自动吸附贴边；
// 其余任意位置均保留为自由停留点。位置按比例写入后台队列以便重启/旋转还原。
- (void)dockOrFree:(BOOL)animated {
    UIWindow *win = self.window;
    if (!win) return;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    if (w <= 0 || h <= 0) return;

    CGFloat r = self.bounds.size.width / 2.0;
    CGFloat peek = r * 0.62;                 // 吸附后露出的半径比例（贴住边栏）
    CGFloat x = win.center.x;
    CGFloat y = MIN(MAX(win.center.y, [self _topLimit]), [self _bottomLimit]);

    // 仅横向判断是否贴近左/右边栏；纵向保持自由位置
    if (x <= (r - peek) + kDTA_SnapMargin) {
        x = r - peek;                        // 吸附左边栏
    } else if (x >= (w - r + peek) - kDTA_SnapMargin) {
        x = w - r + peek;                    // 吸附右边栏
    }

    CGPoint target = CGPointMake(x, y);   // 即 win.center 目标（window 中心 = 球中心）

    void (^save)(BOOL) = ^(BOOL __unused f){
        // 位置写入走后台队列：dtaSetPref 内含同步 IPC，不能在主线程做
        dispatch_async(dtaLogQueue(), ^{
            @try {
                dtaSetPref(kDTA_FloatX, [NSString stringWithFormat:@"%.4f", x / w]);
                dtaSetPref(kDTA_FloatY, [NSString stringWithFormat:@"%.4f", y / h]);
            } @catch (NSException *e) {}
        });
    };

    if (animated) {
        [UIView animateWithDuration:0.45 delay:0
             usingSpringWithDamping:0.72 initialSpringVelocity:0.6
                            options:UIViewAnimationOptionAllowUserInteraction
                         animations:^{ win.center = target; }
                         completion:save];
    } else {
        win.center = target;
        save(YES);
    }
}

// 按记忆的自由位置还原（横向比例 + 纵向比例），屏幕旋转后自动等比还原；
// 旧版只有「吸附侧」数据时退化为按侧还原到边栏。
- (void)applyStoredPos:(CGFloat)xRatio yRatio:(CGFloat)ratio {
    UIWindow *win = self.window;
    if (!win) return;
    CGFloat w = [UIScreen mainScreen].bounds.size.width;
    CGFloat h = [UIScreen mainScreen].bounds.size.height;
    if (w <= 0 || h <= 0) return;
    CGFloat r = self.bounds.size.width / 2.0;
    CGFloat x = w * (xRatio > 0.01 ? xRatio : 0.5);
    CGFloat y = h * (ratio > 0.01 ? ratio : 0.32);
    x = MIN(MAX(x, r - 2.0), w - r + 2.0);
    y = MIN(MAX(y, [self _topLimit]), [self _bottomLimit]);
    win.center = CGPointMake(x, y);
}

- (void)flash {
    [self _wake];
    [UIView animateWithDuration:0.12 animations:^{
        self.transform = CGAffineTransformMakeScale(1.25, 1.25);
    } completion:^(BOOL __unused f){
        [UIView animateWithDuration:0.25 delay:0
             usingSpringWithDamping:0.5 initialSpringVelocity:0.8 options:0
                         animations:^{ self.transform = CGAffineTransformIdentity; }
                         completion:nil];
        [self _scheduleSleep];
    }];
}

- (void)dealloc { [_sleepTimer invalidate]; _sleepTimer = nil; }
@end

static UIWindow *gDTA_FloatWin = nil;
static DTAFloatBall *gDTA_Ball = nil;
static BOOL gDTA_FloatOn = NO;
static BOOL gDTA_FloatDone = NO;

// 必须在主线程调用
static void dtaFloatInstall(void) {
    if (gDTA_FloatWin) return;
    @try {
        CGRect sb = [UIScreen mainScreen].bounds;
        CGFloat W = kDTA_BallSize + kDTA_BallWinPad * 2.0;   // window 仅包裹球体(+阴影余量)
        CGFloat r = kDTA_BallSize / 2.0;
        CGFloat peek = r * 0.62;
        // 初始：右侧、纵向 32%（后续 dtaFloatRefresh 的 applyStoredPos 会按记忆自由位置还原）
        CGFloat cx = sb.size.width - r + peek;
        CGFloat cy = MIN(MAX(sb.size.height * 0.32, 90), sb.size.height - 90);

        UIWindow *w = nil;
        if (@available(iOS 13.0, *)) {
            UIWindowScene *scene = nil;
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                if (((UIWindowScene *)sc).activationState != UISceneActivationStateForegroundActive) continue;
                scene = (UIWindowScene *)sc; break;
            }
            if (scene && [UIWindow instancesRespondToSelector:@selector(initWithWindowScene:)]) {
                w = [[UIWindow alloc] initWithWindowScene:scene];
            }
        }
        if (!w) w = [[UIWindow alloc] initWithFrame:CGRectMake(0, 0, W, W)];
        w.frame = CGRectMake(cx - W / 2.0, cy - W / 2.0, W, W);
        w.backgroundColor = [UIColor clearColor];
        w.windowLevel = UIWindowLevelAlert + 1.0f;   // 浮于普通 App 之上；不喧宾夺主干扰系统手势
        w.hidden = NO;   // 不用 makeKeyAndVisible，避免抢走 SpringBoard 焦点

        // 小球容器：尺寸 = W×W，球居中。容器保持 userInteractionEnabled=YES（默认），
        // 否则 UIView.hitTest 会因容器禁用手势而直接返回 nil、连球也点不动。
        // 球外区域根本不在 window 的物理范围内，故无需额外禁用容器即可保证桌面穿透。
        UIView *c = [[UIView alloc] initWithFrame:CGRectMake(0, 0, W, W)];
        c.backgroundColor = [UIColor clearColor];
        UIViewController *vc = [[UIViewController alloc] init];
        vc.view = c;
        w.rootViewController = vc;

        DTAFloatBall *ball = [[DTAFloatBall alloc] initWithSize:kDTA_BallSize];
        ball.center = CGPointMake(W / 2.0, W / 2.0);
        [c addSubview:ball];
        gDTA_Ball = ball;
        gDTA_FloatWin = w;

        __weak typeof(gDTA_FloatWin) weakWin = gDTA_FloatWin;
        [[NSNotificationCenter defaultCenter]
            addObserverForName:UIDeviceOrientationDidChangeNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *__unused n){
            @try {
                UIWindow *ww = weakWin;
                if (!ww || !gDTA_Ball) return;
                // 旋转后按记忆的自由位置等比还原（仍会自行吸附到仍在阈值内的边栏）
                CGFloat xr = 0.5, yr = 0.32;
                NSString *xs = dtaCopyPref(kDTA_FloatX); if (xs) xr = (CGFloat)[xs doubleValue];
                NSString *ys = dtaCopyPref(kDTA_FloatY); if (ys) yr = (CGFloat)[ys doubleValue];
                [gDTA_Ball applyStoredPos:xr yRatio:yr];
            } @catch (NSException *e) {}
        }];
        dtaLog(@"🎈 悬浮球窗口已创建 level=%.0f size=%.0f", w.windowLevel, W);
    } @catch (NSException *e) {
        dtaLog(@"🎈 悬浮球创建失败: %@", e);
    }
}

// 按偏好显示/隐藏悬浮球。偏好读取放后台，UI 操作回主线程。
static void dtaFloatRefresh(void) {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        @try {
            BOOL on = dtaBool(kDTA_FloatKey, YES);
            BOOL done = dtaDoneToday();
            CGFloat xRatio = 0.5, yRatio = 0.32;
            NSString *xs = dtaCopyPref(kDTA_FloatX);
            if (xs) {
                xRatio = (CGFloat)[xs doubleValue];
            } else {
                NSInteger side = dtaInt(kDTA_FloatSide, 1);   // 旧版兼容：按吸附侧还原
                xRatio = (side == 0) ? 0.0 : 1.0;
            }
            NSString *ys = dtaCopyPref(kDTA_FloatY);
            if (ys) yRatio = (CGFloat)[ys doubleValue];

            BOOL needShow = (on && !gDTA_FloatWin);
            if (!needShow && on == gDTA_FloatOn && done == gDTA_FloatDone) return;

            BOOL firstShow = needShow;
            dispatch_async(dispatch_get_main_queue(), ^{
                @try {
                    if (on) {
                        dtaFloatInstall();
                        if (firstShow && gDTA_Ball) [gDTA_Ball applyStoredPos:xRatio yRatio:yRatio];
                    }
                    if (gDTA_FloatWin) gDTA_FloatWin.hidden = !on;
                    if (gDTA_Ball) [gDTA_Ball setDone:done];
                    if (on != gDTA_FloatOn) {
                        dtaLog(@"🎈 悬浮球 %@", on ? @"已显示" : @"已隐藏");
                    }
                    gDTA_FloatOn = on;
                    gDTA_FloatDone = done;
                } @catch (NSException *e) {
                    dtaLog(@"🎈 悬浮球刷新异常: %@", e);
                }
            });
        } @catch (NSException *e) {}
    });
}

// ── 钉钉侧点击器：3s 轮询，到点窗口/pending 内逐级导航并自动点击 ───────────────────────
static NSString *gClickSlot = nil;
static NSInteger gNavCount = 0;
static NSDate *gDTA_LastBeat = nil;       // 点击器心跳节流
static NSString *gDTA_LastSkip = nil;     // 上一次「跳过原因」，变化时才写日志
static NSDate *gDTA_LastWeb = nil;        // WebView 兜底节流

// 底部 TabBar：钉钉「工作台」是 tab item，sendActions 对它通常无效，必须走 delegate/selectedItem
static UITabBar *dtaFindTabBar(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITabBar class]]) return (UITabBar *)v;
    for (UIView *s in v.subviews) { UITabBar *r = dtaFindTabBar(s); if (r) return r; }
    return nil;
}
static BOOL dtaTryTabBar(UIView *root, NSArray<NSString *> *titles) {
    UITabBar *tb = dtaFindTabBar(root);
    if (tb && tb.items.count) {
        for (UITabBarItem *it in tb.items) {
            NSString *t = it.title ?: @"";
            if (!t.length) continue;
            for (NSString *want in titles) {
                if ([t rangeOfString:want].location == NSNotFound) continue;
                if (tb.selectedItem == it) { dtaLog(@"TabBar 已在 '%@'，无需切换", t); return NO; }
                @try {
                    id del = tb.delegate;
                    SEL s = @selector(tabBar:didSelectItem:);
                    if (del && [del respondsToSelector:s]) {
                        [del performSelector:s withObject:tb withObject:it];
                    }
                    tb.selectedItem = it;
                    dtaLog(@"🔀 TabBar 已切换到 '%@'", t);
                    return YES;
                } @catch (NSException *e) { dtaLog(@"TabBar 切换异常: %@", e); }
            }
        }
    }

    // 兜底：钉钉底栏可能不是 UITabBar（自定义视图），按文字找可点击的 tab 控件
    for (NSString *want in titles) {
        UIControl *c = dtaScanByTitle(root, want);
        if (c) {
            dtaClick(c);
            dtaLog(@"🔀 自定义底栏：已点击 '%@'", want);
            return YES;
        }
    }
    return NO;
}

// ── 通用「点击一个视图」：UIControl 直接触发；表格/集合 cell 走 delegate 选中 ──────────
// 钉钉工作台的入口多半是 UICollectionViewCell / UITableViewCell（不是 UIButton），
// 只对 UIControl 调 sendActions 是点不动的，必须模拟 didSelectItem/Row。
static void dtaTapView(UIView *v) {
    if (!v) return;
    if ([v isKindOfClass:[UIControl class]]) { dtaClick((UIControl *)v); return; }

    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 24 &&
           ![cur isKindOfClass:[UITableViewCell class]] &&
           ![cur isKindOfClass:[UICollectionViewCell class]]) {
        cur = cur.superview;
    }
    if ([cur isKindOfClass:[UITableViewCell class]]) {
        UITableViewCell *cell = (UITableViewCell *)cur;
        UIView *sv = cell.superview;
        while (sv && ![sv isKindOfClass:[UITableView class]]) sv = sv.superview;
        if ([sv isKindOfClass:[UITableView class]]) {
            UITableView *tv = (UITableView *)sv;
            NSIndexPath *ip = [tv indexPathForCell:cell];
            id del = tv.delegate;
            SEL s = @selector(tableView:didSelectRowAtIndexPath:);
            if (ip && del && [del respondsToSelector:s]) {
                [del performSelector:s withObject:tv withObject:ip];
                dtaLog(@"已通过 tableView:didSelectRow 点击 cell");
                return;
            }
        }
    }
    if ([cur isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)cur;
        UIView *sv = cell.superview;
        while (sv && ![sv isKindOfClass:[UICollectionView class]]) sv = sv.superview;
        if ([sv isKindOfClass:[UICollectionView class]]) {
            UICollectionView *cv = (UICollectionView *)sv;
            NSIndexPath *ip = [cv indexPathForCell:cell];
            id del = cv.delegate;
            SEL s = @selector(collectionView:didSelectItemAtIndexPath:);
            if (ip && del && [del respondsToSelector:s]) {
                [del performSelector:s withObject:cv withObject:ip];
                dtaLog(@"已通过 collectionView:didSelectItem 点击 cell");
                return;
            }
        }
    }
    UIControl *c = dtaAncestorControl(v);
    if (c) { dtaClick(c); return; }
    dtaLog(@"无法点击视图 %@（无 UIControl / 可代理）", [v class]);
}

// ── 多企业（选择打卡企业）───────────────────────────────────────────────────────
// 一个钉钉账号可能挂在多个企业下（含测试企业）。进入考勤页时钉钉会弹「选择打卡企业」，
// 不选就停在弹层上，永远看不到「打卡」按钮。这里按设置里配置的序号点选第 N 个。
static CFAbsoluteTime gDTA_LastOrgPick = 0;   // 上次点选时间，1.5s 内不重复点
static NSInteger gDTA_OrgAttempts = 0;        // 当前弹层已尝试点击次数（换手法递进）
static NSString *gDTA_OrgSig = nil;           // 当前弹层签名（标题#行数），变化即重置

// 取当前前台 key window（iOS 13+ 多 scene，兜底老 API）
static UIWindow *dtaKeyWindowNow(void) {
    UIWindow *kw = nil;
    @try {
        if (@available(iOS 13.0, *)) {
            for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
                if (![sc isKindOfClass:[UIWindowScene class]]) continue;
                if (((UIWindowScene *)sc).activationState != UISceneActivationStateForegroundActive) continue;
                for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                    if (w.isKeyWindow) { kw = w; break; }
                }
                if (kw) break;
            }
        }
    } @catch (NSException *e) {}
    if (!kw) kw = [UIApplication sharedApplication].keyWindow;
    return kw;
}

// 当前进程所有可见 window（按 windowLevel 从高到低）。
// ⚠️ 钉钉的弹层常常挂在「独立的浮层 window」上而不是 key window 里，
//    只扫 key window 会完全看不到「选择打卡企业」——这是最容易漏的一点。
static NSArray<UIWindow *> *dtaAllWindows(void) {
    NSMutableArray<UIWindow *> *arr = [NSMutableArray array];
    @try {
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (!w || w.hidden || w.alpha <= 0.01) continue;
                if (![arr containsObject:w]) [arr addObject:w];
            }
        }
    } @catch (NSException *e) {}
    if (arr.count == 0) {
        UIWindow *kw = dtaKeyWindowNow();
        if (kw) [arr addObject:kw];
    }
    [arr sortUsingComparator:^NSComparisonResult(UIWindow *a, UIWindow *b) {
        if (a.windowLevel > b.windowLevel) return NSOrderedDescending;
        if (a.windowLevel < b.windowLevel) return NSOrderedAscending;
        return NSOrderedSame;
    }];
    return arr;
}

// 收集窗口内所有 cell（表格/集合），不深入 cell 内部避免重复收集
static void dtaCollectCells(UIView *v, NSMutableArray<UIView *> *out) {
    if (!v || v.hidden || v.alpha < 0.01 || v.window == nil) return;
    if ([v isKindOfClass:[UITableViewCell class]] || [v isKindOfClass:[UICollectionViewCell class]]) {
        [out addObject:v];
        return;
    }
    for (UIView *s in v.subviews) dtaCollectCells(s, out);
}

// 收集「行样式」的可点控件（钉钉部分弹层用自定义 UIView + UIControl 而非 cell）
static void dtaCollectRowControls(UIView *v, UIWindow *win, CGFloat minY,
                                  NSMutableArray<UIView *> *out) {
    if (!v || v.hidden || v.alpha < 0.01) return;
    if ([v isKindOfClass:[UIControl class]]) {
        CGRect f = [v convertRect:v.bounds toView:win];
        CGFloat W = win.bounds.size.width;
        if (f.origin.y >= minY - 4 && f.size.height >= 36 && f.size.height <= 180
            && f.size.width >= W * 0.5) {
            [out addObject:v];
            return;
        }
    }
    for (UIView *s in v.subviews) dtaCollectRowControls(s, win, minY, out);
}

// 收集一个行内的全部文字（UILabel + accessibilityLabel），用于识别「取消/关闭」这类非企业行
static void dtaCollectText(UIView *v, NSMutableString *out) {
    if (!v) return;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)v text];
        if (t.length) { [out appendString:t]; [out appendString:@" "]; }
    }
    NSString *acc = v.accessibilityLabel;
    if (acc.length) { [out appendString:acc]; [out appendString:@" "]; }
    for (UIView *s in v.subviews) dtaCollectText(s, out);
}

static BOOL dtaRowIsCancel(UIView *v) {
    NSMutableString *s = [NSMutableString string];
    dtaCollectText(v, s);
    if (!s.length) return NO;
    for (NSString *w in @[@"取消", @"关闭", @"完成", @"收起"]) {
        if ([s rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

static UILabel *dtaFirstLabel(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    for (UIView *s in v.subviews) {
        UILabel *r = dtaFirstLabel(s);
        if (r) return r;
    }
    return nil;
}

// 行的「主文字」：企业行的第一个 UILabel 通常就是企业名；
// 若拿不到，则退回整行文字（压缩换行/多余空格）。用于设置页展示名称、以及按名定位行。
static NSString *dtaRowPrimaryText(UIView *v) {
    if (!v) return @"";
    NSString *t = dtaFirstLabel(v).text;
    if (t.length >= 2) {
        return [t stringByTrimmingCharactersInSet:
                [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    }
    NSMutableString *s = [NSMutableString string];
    dtaCollectText(v, s);
    if (!s.length) return @"";
    NSMutableArray<NSString *> *keep = [NSMutableArray array];
    for (NSString *p in [s componentsSeparatedByCharactersInSet:
                         [NSCharacterSet whitespaceAndNewlineCharacterSet]]) {
        if (p.length) [keep addObject:p];
    }
    return [keep componentsJoinedByString:@" "];
}

// 一次遍历找「文字包含任一关键词」的 label（用于认弹层标题，避免多次全树扫描）
static UILabel *dtaFindLabelAny(UIView *v, NSArray<NSString *> *kws, NSInteger depth) {
    if (!v || depth > 80) return nil;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)v text];
        if (t.length > 0 && t.length <= 40) {
            for (NSString *k in kws) {
                if ([t rangeOfString:k].location != NSNotFound) return (UILabel *)v;
            }
        }
    }
    for (UIView *s in v.subviews) {
        UILabel *r = dtaFindLabelAny(s, kws, depth + 1);
        if (r) return r;
    }
    return nil;
}

// 有的弹层行不是 UIControl、也不是 cell，只挂了一个 UITapGestureRecognizer。
// 这种情况下 sendActions 完全无效，必须直接把手势的 target/action 调起来。
static BOOL dtaFireTapGestures(UIView *v) {
    if (!v || v.gestureRecognizers.count == 0) return NO;
    BOOL fired = NO;
    for (UIGestureRecognizer *g in v.gestureRecognizers) {
        if (![g isKindOfClass:[UITapGestureRecognizer class]]) continue;
        @try {
            NSArray *targets = [g valueForKey:@"_targets"];
            if (![targets isKindOfClass:[NSArray class]]) continue;
            for (id t in targets) {
                id tgt = nil;
                SEL act = NULL;
                unsigned int n = 0;
                Ivar *ivs = class_copyIvarList([t class], &n);
                for (unsigned int i = 0; i < n; i++) {
                    const char *nm = ivar_getName(ivs[i]);
                    const char *ty = ivar_getTypeEncoding(ivs[i]);
                    if (!nm || !ty) continue;
                    if (strcmp(ty, "@") == 0 && !tgt
                        && (strstr(nm, "target") || strstr(nm, "Target"))) {
                        tgt = object_getIvar(t, ivs[i]);
                    } else if (strcmp(ty, ":") == 0 && act == NULL) {
                        act = *(SEL *)((char *)(__bridge void *)t + ivar_getOffset(ivs[i]));
                    }
                }
                if (ivs) free(ivs);
                if (tgt && act && [tgt respondsToSelector:act]) {
                    [tgt performSelector:act withObject:g];
                    fired = YES;
                }
            }
        } @catch (NSException *e) {}
    }
    return fired;
}

static BOOL dtaFireTapGesturesDeep(UIView *v, NSInteger depth) {
    if (!v || depth > 4) return NO;
    if (dtaFireTapGestures(v)) return YES;
    for (UIView *s in v.subviews) {
        if (dtaFireTapGesturesDeep(s, depth + 1)) return YES;
    }
    return NO;
}

// 点一行：多套手法递进（不同版本钉钉的行结构差别很大，单靠一种会「找到但点不动」）
static void dtaTapRowHard(UIView *row, NSInteger attempt) {
    if (!row) return;
    NSInteger mode = attempt % 3;
    if (mode == 1) {
        if (dtaFireTapGesturesDeep(row, 0)) { dtaLog(@"🖐 手势 target/action 已触发"); return; }
    } else if (mode == 2) {
        UILabel *lab = dtaFirstLabel(row);
        if (lab) {
            if (dtaFireTapGesturesDeep(lab, 0)) { dtaLog(@"🖐 文字层手势已触发"); return; }
            UIControl *c = dtaAncestorControl(lab);
            if (c) { dtaClick(c); dtaLog(@"🖐 文字祖先控件已点"); return; }
        }
    }
    dtaTapView(row);
}

static BOOL dtaPickOrgIfNeeded(void) {
    @try {
        NSArray<UIWindow *> *wins = dtaAllWindows();
        if (wins.count == 0) return NO;

        // 1) 认弹层标题（不同版本钉钉文案略有差异）；弹层可能在任意 level 的 window 上。
        //    一次遍历匹配多个关键词，避免 7 关键字 × N 窗口的重复全树扫描。
        NSArray<NSString *> *titles = @[@"选择打卡企业", @"选择考勤企业", @"切换企业",
                                        @"选择企业", @"选择组织", @"选择团队", @"请选择企业"];
        UILabel *titleL = nil;
        UIWindow *win = nil;
        for (UIWindow *w in wins) {
            UILabel *l = dtaFindLabelAny(w, titles, 0);
            if (l) { titleL = l; win = w; break; }
        }
        if (!titleL || !win) { gDTA_OrgAttempts = 0; gDTA_OrgSig = nil; return NO; }

        // 2) 只取标题下方的元素：标题以上是底层页面（工作台图标等），不能算进企业列表
        CGFloat minY = CGRectGetMaxY([titleL convertRect:titleL.bounds toView:win]) + 2.0;
        // 配置值：0/未设置 = 「默认」= 第 1 个；1..5 = 第 N 个
        NSInteger idx = dtaInt(kDTA_OrgKey, 0);
        if (idx <= 0) idx = 1;

        NSMutableArray<UIView *> *all = [NSMutableArray array];
        dtaCollectCells(win, all);
        NSMutableArray<UIView *> *rows = [NSMutableArray array];
        NSMutableArray<UIView *> *rowsClean = [NSMutableArray array];   // 剔除「取消/关闭」等行
        for (UIView *v in all) {
            CGRect f = [v convertRect:v.bounds toView:win];
            if (f.origin.y < minY - 4) continue;
            if (f.size.height < 30) continue;
            [rows addObject:v];
            if (!dtaRowIsCancel(v)) [rowsClean addObject:v];
        }
        if (rows.count == 0) {
            dtaCollectRowControls(win, win, minY, rows);
            for (UIView *v in rows) {
                if (!dtaRowIsCancel(v)) [rowsClean addObject:v];
            }
        }
        // 优先用「干净行」：弹层底部常有「取消」按钮，按序号数进去会点错
        if (rowsClean.count > 0) rows = rowsClean;

        [rows sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
            CGFloat ya = [a convertRect:a.bounds toView:win].origin.y;
            CGFloat yb = [b convertRect:b.bounds toView:win].origin.y;
            if (ya < yb) return NSOrderedAscending;
            if (ya > yb) return NSOrderedDescending;
            return NSOrderedSame;
        }];

        if (rows.count == 0) {
            if (![gDTA_OrgSig isEqualToString:@"norow"]) {
                gDTA_OrgSig = @"norow";
                dtaLog(@"🏢 检测到「%@」弹层，但没扫到可点行（窗口=%lu）",
                       titleL.text, (unsigned long)wins.count);
                dtaClickState(@"org-norow");
            }
            return YES;
        }

        // 3) 换了一个弹层（标题/行数变了）就重置重试计数
        NSString *sig = [NSString stringWithFormat:@"%@#%lu", titleL.text, (unsigned long)rows.count];
        if (![sig isEqualToString:gDTA_OrgSig ?: @""]) {
            gDTA_OrgSig = sig;
            gDTA_OrgAttempts = 0;
            gDTA_LastOrgPick = 0;
            // 首次识别：收集每一行的文字（既用于日志核对序号，也用于设置页展示企业名称）
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSUInteger i = 0; i < rows.count; i++) {
                NSString *full = dtaRowPrimaryText(rows[i]);
                NSString *show = full.length > 20 ? [full substringToIndex:20] : full;
                dtaLog(@"🏢 行%lu: %@ <%@>", (unsigned long)(i + 1),
                       show.length ? show : @"(无文字)", [rows[i] class]);
                if (full.length >= 2 && full.length <= 40) [names addObject:full];
            }
            if (names.count == rows.count && names.count > 0) {
                // 写进钉钉自己的域（沙盒允许），再通知调度器转发到本插件域供设置页读取
                dtaSaveOrgNamesToOwnDomain(names);
                dtaPostNote(kDTA_NoteOrgNames);
                dtaLog(@"🏢 已缓存企业名称 %lu 个：%@", (unsigned long)names.count,
                       [names componentsJoinedByString:@" / "]);
            }
        }

        // 4) 刚点过 → 等它生效（弹层收起有动画），不重复点
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gDTA_LastOrgPick > 0 && now - gDTA_LastOrgPick < 1.5) return YES;

        if (gDTA_OrgAttempts >= 6) {
            if (![gDTA_OrgSig isEqualToString:@"failed"]) {
                dtaLog(@"🏢 ❌ 连试 6 次仍未关掉企业弹层（行数=%lu，配置=%ld）",
                       (unsigned long)rows.count, (long)idx);
                gDTA_OrgSig = [NSString stringWithFormat:@"%@#%lu#failed", titleL.text,
                               (unsigned long)rows.count];
                dtaClickState(@"org-fail");
            }
            return YES;
        }

        NSUInteger pick = (NSUInteger)(MIN(idx, (NSInteger)rows.count) - 1);

        // 4.5) 名字优先：若缓存过企业名且数量对得上，用「用户选的那家的名字」去当前行里定位。
        //      这样即使钉钉把企业顺序调换了，也不会点到别家（序号只作为兜底）。
        NSArray<NSString *> *cached = dtaOrgNamesFromDingTalkDomain();
        if (cached.count == rows.count && (NSInteger)cached.count >= idx) {
            NSString *want = cached[idx - 1];
            if (want.length >= 2) {
                for (NSUInteger i = 0; i < rows.count; i++) {
                    NSString *t = dtaRowPrimaryText(rows[i]);
                    if (t.length < 2) continue;
                    if ([t containsString:want] || [want containsString:t]) {
                        if (i != pick) {
                            dtaLog(@"🏢 按企业名「%@」定位到第 %lu 行（序号原为 %lu）",
                                   want, (unsigned long)(i + 1), (unsigned long)(pick + 1));
                        }
                        pick = i;
                        break;
                    }
                }
            }
        }

        UIView *row = rows[pick];
        dtaLog(@"🏢 选择打卡企业：点第 %lu 个（配置=%ld，共 %lu 个，手法=%ld，行=%@）",
               (unsigned long)(pick + 1), (long)idx, (unsigned long)rows.count,
               (long)(gDTA_OrgAttempts % 3), [row class]);
        dtaTapRowHard(row, gDTA_OrgAttempts);
        gDTA_OrgAttempts++;
        gDTA_LastOrgPick = now;
        dtaClickState(@"pick-org");
        return YES;
    } @catch (NSException *e) {
        dtaLog(@"选择企业异常: %@", e);
        return NO;
    }
}

// 独立看门狗：只要屏幕上出现「选择打卡企业」就按配置点选。
// ⚠️ 关键：它不依赖「启用定时打卡」开关，也不依赖自动导航的 8 拍窗口。
//   旧版只在「自动导航那 12 秒内」或「到点打卡流程里」处理企业弹层，
//   而弹层往往在入口点进去 10s 后才出现 / 用户手动打开钉钉时已过窗口 → 永远选不到。
static void dtaOrgWatchdogTick(void) {
    @try {
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        dtaPickOrgIfNeeded();
    } @catch (NSException *e) {}
}

// 读取「工作台入口名称」偏好（默认 考勤打卡）；用户可改成自家入口名，如「考情助手」
static NSString *dtaEntryKeyword(void) {
    NSString *s = dtaStr(kDTA_EntryKey);
    if (s && s.length) return s;
    return @"考勤打卡";
}

// 只找「考勤入口」本身（不含底部 Tab，避免把 Tab 当成入口重复点）
static UIView *dtaFindAttendanceEntry(UIView *root) {
    NSMutableArray<NSString *> *navs = [NSMutableArray array];
    NSString *kw = dtaEntryKeyword();
    if (kw.length) [navs addObject:kw];
    for (NSString *t in @[@"考勤打卡", @"考情助手", @"考勤助手", @"考勤", @"打卡"]) {
        if (![navs containsObject:t]) [navs addObject:t];
    }
    for (NSString *t in navs) {
        UIControl *c = dtaScanByTitle(root, t);
        if (c) { dtaLog(@"找到考勤入口(title/acc '%@'): %@", t, [c class]); return c; }
    }
    for (NSString *t in navs) {
        UILabel *l = dtaScanLabel(root, t);
        if (l) { dtaLog(@"找到考勤入口(label '%@' → %@)", t, [l class]); return l; }
    }
    return nil;
}

// 兼容旧调用：先找考勤入口，再退化为「工作台」按钮（用于没有 UITabBar 的布局）
static UIView *dtaFindNavEntry(UIView *root) {
    UIView *c = dtaFindAttendanceEntry(root);
    if (c) return c;
    for (NSString *t in @[@"工作台", @"工作"]) {
        UIControl *w = dtaScanByTitle(root, t);
        if (w) { dtaLog(@"找到工作台入口 '%@': %@", t, [w class]); return w; }
    }
    return nil;
}

// 打开钉钉后自动导航：切「工作台」→ 点进配置的考勤入口（只导航，不打卡）
static NSInteger gDTA_AutoStep = 0;   // 0=未完成 1=已切工作台 2=已点入口
static void dtaAutoNavigateTick(void) {
    @try {
        if (!dtaBool(kDTA_AutoOpenKey, YES)) return;
        if (gDTA_AutoStep >= 2) return;

        UIWindow *kw = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (((UIWindowScene *)sc).activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { kw = w; break; }
            }
            if (kw) break;
        }
        if (!kw) kw = [UIApplication sharedApplication].keyWindow;
        if (!kw) return;

        // 0) 若弹出「选择打卡企业」，先按配置点选第 N 个，否则会一直卡在弹层上
        if (dtaPickOrgIfNeeded()) return;

        // 1) 已经能看到考勤入口 → 直接点进去
        UIView *entry = dtaFindAttendanceEntry(kw);
        if (entry) {
            dtaTapView(entry);
            gDTA_AutoStep = 2;
            dtaLog(@"🧭 自动进入：已点击入口 '%@'", dtaEntryKeyword());
            dtaClickState(@"nav-entry");
            return;
        }
        // 2) 否则先切到工作台 Tab，下一拍再找入口
        if (dtaTryTabBar(kw, @[@"工作台", @"工作"])) {
            gDTA_AutoStep = 1;
            dtaLog(@"🧭 自动进入：已切到工作台 Tab");
            dtaClickState(@"tab-workbench");
        }
    } @catch (NSException *e) {
        dtaLog(@"自动进入异常: %@", e);
    }
}

static void dtaClickTick(void) {
    @try {
        NSInteger mode = 2;
        BOOL fromPending = NO;

        // 💓 心跳：每 60s 一条。即使一切静默，也能证明「点击器是否活着」并给出状态快照，
        //    这是排查「能拉起钉钉但从不动手」最关键的证据。
        NSDate *nowD = [NSDate date];
        if (!gDTA_LastBeat || [nowD timeIntervalSinceDate:gDTA_LastBeat] > 60.0) {
            gDTA_LastBeat = nowD;
            dtaLog(@"💓 心跳 点击器存活(v%@) enabled=%d time=%@ repeat=%ld mode=%ld pending=%@ doneToday=%d",
                   kDTA_BuildTag,
                   dtaBool(@"dingtalkPunchEnabled", NO),
                   dtaStr(@"dingtalkPunchTime") ?: @"(未设)",
                   (long)dtaInt(@"dingtalkPunchRepeat", 0),
                   (long)dtaInt(@"dingtalkPunchMode", 2),
                   dtaReadPending() ?: @"(空)",
                   dtaDoneToday());
            // ⚠️ 钉钉沙盒无法写外域 CFPreferences，所以存活/状态一律改走 Darwin 通知，
            //    由 SpringBoard 调度器转写 dingtalkClickBeat 供设置页读取。
            dtaPostNote(kDTA_NoteBeatName);
            dtaClickState(@"alive");
        }

        if (!dtaClickShouldRun(&mode, &fromPending)) {
            NSString *reason = dtaDoneToday() ? @"今日已打卡(done 标记已置位)"
                             : (!dtaBool(@"dingtalkPunchEnabled", NO) ? @"开关未启用"
                             : @"不在到点窗口且无 pending");
            if (dtaDoneToday())            dtaClickState(@"skip-done");
            else if (!dtaBool(@"dingtalkPunchEnabled", NO)) dtaClickState(@"skip-off");
            else                           dtaClickState(@"skip-window");
            if (![reason isEqualToString:gDTA_LastSkip]) {
                gDTA_LastSkip = reason;
                dtaLog(@"⏸ 跳过打卡：%@", reason);
            }
            gClickSlot = nil;
            return;
        }
        dtaClickState(fromPending ? @"run-pending" : @"run-window");
        if (![gDTA_LastSkip isEqualToString:@"(进行中)"]) {
            gDTA_LastSkip = @"(进行中)";
            dtaLog(@"▶️ 进入打卡流程 mode=%ld fromPending=%d", (long)mode, (int)fromPending);
        }

        NSCalendar *cal = [NSCalendar currentCalendar];
        NSDateComponents *now = [cal components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|
                                                NSCalendarUnitHour|NSCalendarUnitMinute)
                                       fromDate:[NSDate date]];
        NSString *slot = [NSString stringWithFormat:@"%04ld-%02ld-%02ld %02ld:%02ld",
                          (long)now.year, (long)now.month, (long)now.day,
                          (long)now.hour, (long)now.minute];
        if ([gClickSlot isEqualToString:slot]) return;

        UIWindow *kw = nil;
        for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
            if (![sc isKindOfClass:[UIWindowScene class]]) continue;
            if (((UIWindowScene *)sc).activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ((UIWindowScene *)sc).windows) {
                if (w.isKeyWindow) { kw = w; break; }
            }
            if (kw) break;
        }
        if (!kw) kw = [UIApplication sharedApplication].keyWindow;
        if (!kw) { dtaLog(@"无关键窗口（可能锁屏/后台），本次跳过"); dtaClickState(@"nokw"); return; }

        // 0) 「选择打卡企业」弹层：不点掉它，后面永远扫不到打卡按钮
        if (dtaPickOrgIfNeeded()) return;

        // 1) 直接找真实打卡按钮
        UIControl *btn = dtaTryButton(kw, mode);
        if (btn) {
            dtaClick(btn);
            gClickSlot = slot;
            gNavCount = 0;
            dtaClearPending();
            dtaMarkDone();
            dtaClickState(@"ok");
            dtaLog(@"✅ 已触发点击 slot=%@ (mode=%ld fromPending=%d) 清除 pending",
                   slot, (long)mode, fromPending);
            return;
        }

        // 2) 没找到打卡按钮 → 先切到「工作台」Tab（钉钉的考勤入口在工作台里）
        if (gNavCount < 8) {
            if (dtaTryTabBar(kw, @[@"工作台", @"工作"])) {
                gNavCount++;
                dtaClickState(@"tab-workbench");
                dtaLog(@"⬆️ 已切到工作台 Tab (第 %ld 次导航)，下一拍继续找考勤入口", (long)gNavCount);
                return;
            }
        }

        // 3) 再找「考勤打卡 / 考勤」入口并点击，进入打卡页
        if (gNavCount < 8) {
            UIView *nav = dtaFindNavEntry(kw);
            if (nav) {
                dtaTapView(nav);
                gNavCount++;
                dtaClickState(@"nav-entry");
                dtaLog(@"⬆️ 点击导航入口尝试进入打卡页 (第 %ld 次)", (long)gNavCount);
                return;   // 下一拍(3s 后)再扫描打卡按钮
            }
        }

        // 4) 仍无按钮且无可导航入口 → WebView 兜底（节流 15s，避免每 3s 重复点）
        if (!gDTA_LastWeb || [[NSDate date] timeIntervalSinceDate:gDTA_LastWeb] > 15.0) {
            gDTA_LastWeb = [NSDate date];
            dtaClickState(@"noweb");
            dtaLog(@"界面无打卡按钮/导航入口（导航 %ld 次），尝试 WebView 兜底", (long)gNavCount);
            dtaWebViewFallback(kw, mode);
        }
    } @catch (NSException *e) {
        dtaClickState(@"err");
        dtaLog(@"click tick 异常: %@", e);
    }
}

%ctor {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
        if ([bid isEqualToString:@"com.apple.springboard"]) {
            // ── 调度器：永远在 SpringBoard 跑（与「顶栏时间 Assit」总开关无关）──
            dtaLog(@"钉钉助手 调度器载入 进程=%@ pid=%d", bid, (int)getpid());
            dtaProbeDingTalkApps();   // 探测本机钉钉真实 bundleID/可执行名，便于核对 filter

            // 设置变更：改时间/开关后立即重排，不必等 60s 兜底；同时处理「立即测试」标记
            CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                dtaPrefsChanged,
                CFSTR("com.dev.dingtalkassistant/prefs"), NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);

            // 监听点击器（钉钉沙盒进程）发来的 Darwin 信标，转写 CFPreferences 供设置页读取。
            // 钉钉沙盒写不了外域 CFPreferences，所以由非沙盒的 SpringBoard 代为记录。
            CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
            CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                (__bridge CFStringRef)kDTA_NoteBeatName, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                (__bridge CFStringRef)kDTA_NoteOrgNames, NULL,
                CFNotificationSuspensionBehaviorDeliverImmediately);
            for (NSString *c in kDTA_StateCodes()) {
                NSString *nm = [kDTA_StatePrefix stringByAppendingString:c];
                CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                    (__bridge CFStringRef)nm, NULL,
                    CFNotificationSuspensionBehaviorDeliverImmediately);
            }

            dtaReschedule();   // 精确定时器，到点整秒触发

            // 60s 兜底重排 + 兜底同步企业名称（通知可能丢）
            dispatch_async(dispatch_get_main_queue(), ^{
                [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer * __unused _t){
                    @try { dtaReschedule(); } @catch (NSException *e2) {}
                    dispatch_async(dtaLogQueue(), ^{
                        @try {
                            NSArray<NSString *> *ns = dtaOrgNamesFromDingTalkDomain();
                            if (!ns.count) return;
                            NSString *joined = [ns componentsJoinedByString:@"\n"];
                            NSString *old = dtaCopyPref(kDTA_OrgNamesKey);
                            if (![joined isEqualToString:(old ?: @"")]) {
                                dtaSetPref(kDTA_OrgNamesKey, joined);
                                dtaLog(@"🏢 已同步企业名称到插件域：%@", joined);
                            }
                        } @catch (NSException *e3) {}
                    });
                }];
            });
            dtaFloatRefresh();   // 悬浮球按偏好显示/隐藏
        } else {
            // ── 点击器：注入到钉钉进程（独立注入时进程名未必含 ding，这里不拦截）──
            gDTA_Proc = @"CLICK";
            dtaLog(@"钉钉助手 点击器载入 进程=%@ pid=%d 日志=%@ pending=%@",
                   bid, (int)getpid(), dtaLogPath(), dtaReadPending() ?: @"(空)");
            gNavCount = 0;
            gDTA_AutoStep = 0;
            dtaPostNote(kDTA_NoteBeatName);   // 立即上报存活

            // 主循环：3s 一拍（到点窗口 / pending 内逐级导航到打卡页并点按钮）
            dtaClickTick();
            [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer * __unused _t){
                dtaClickTick();
            }];

            // 企业弹层看门狗：1.5s 一拍，不依赖「启用定时打卡」开关，也不依赖导航窗口
            [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * __unused _t){
                dtaOrgWatchdogTick();
            }];

            // 自动导航：只在「有 pending 任务」或用户显式开启时才跑，避免手动打开钉钉被跳页
            dispatch_async(dispatch_get_main_queue(), ^{
                if (dtaReadPending().length || dtaBool(kDTA_AutoOpenKey, NO)) {
                    __block NSInteger navTicks = 0;
                    NSTimer *navT = [NSTimer scheduledTimerWithTimeInterval:1.2 repeats:YES
                                                                      block:^(NSTimer *tt){
                        @try {
                            navTicks++;
                            dtaAutoNavigateTick();
                            if (gDTA_AutoStep >= 2 || navTicks > 50) {
                                [tt invalidate];
                                dtaLog(@"🧭 自动导航结束（step=%ld 拍了%ld 次）",
                                       (long)gDTA_AutoStep, (long)navTicks);
                            }
                        } @catch (NSException *e3) { [tt invalidate]; }
                    }];
                    (void)navT;
                }
            });
        }
    } @catch (NSException *e) {}
}

#pragma clang diagnostic pop
