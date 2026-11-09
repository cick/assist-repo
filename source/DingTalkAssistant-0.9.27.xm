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
static NSString *const kDTA_BuildTag = @"0.9.27";
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

// 值没变就不写（cfprefsd 同步是 IPC，SpringBoard 上要省着用）
static void dtaSetPrefIfChanged(NSString *k, NSString *v) {
    NSString *old = dtaCopyPref(k);
    if (old == nil && v == nil) return;
    if ([old isEqualToString:(v ?: @"")]) return;
    dtaSetPref(k, v);
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
              @"skip-window",@"ok",@"tab-workbench",@"nav-entry",@"noweb",@"nokw",@"err",
              @"pick-org",@"org-norow",@"org-fail",@"idle",@"cmd-armed",
              @"verify",@"punch-fail",@"webview"];
    });
    return a;
}
// 点击器上报状态：Darwin 通知（沙盒可发）+ 状态文件（沙盒必可写）。
// 两条都发：通知走不到时，SpringBoard 每 3s 读文件也能补上，状态/版本不再「看不见」。
static void dtaStatusWrite(NSString *state);   // 定义在下方（容器通道）
static BOOL dtaIsClicker(void);                // 定义在下方（容器通道）
static void dtaClickState(NSString *code) {
    if (!code.length) return;
    dtaPostNote([kDTA_StatePrefix stringByAppendingString:code]);
    if (dtaIsClicker()) dtaStatusWrite(code);
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

// ══════════════════════════════════════════════════════════════════════════════
// 容器文件通道（SpringBoard ⇄ 钉钉）
// ──────────────────────────────────────────────────────────────────────────────
// 背景（0.9.20 的根因修复）：
//   钉钉是沙盒 App，cfprefsd 只允许它访问「自己 bundleID」的偏好域：
//     · 读不到 dingtalkPending / dingtalkOrgIndex / dingtalkEntryName
//       → 表现：悬浮球触发了也不动手、永远选第 1 个企业、入口名改了没反应；
//     · 写不进 dingtalkDebugLogClick
//       → 表现：设置页「点击侧日志」永远是空的，只能靠猜。
//   唯一「SpringBoard 能写、钉钉必定能读」的通路是钉钉自己的数据容器：
//     SpringBoard → <钉钉容器>/Documents/DTA/dta_cmd.plist   （下发指令）
//     点击器      → <钉钉容器>/Documents/DTA/dta_status.plist（回报状态/版本/完成标记）
//   偏好域握手保留为兜底（老路径不删，避免极端环境失效时彻底没动作）。
// ══════════════════════════════════════════════════════════════════════════════
static NSString *const kDTA_ChanDirName    = @"DTA";
static NSString *const kDTA_ChanCmdName    = @"dta_cmd.plist";
static NSString *const kDTA_ChanStatusName = @"dta_status.plist";
static NSString *const kDTA_ClickLogName   = @"com.dev.dingtalkassistant.click.log";
static NSString *const kDTA_VerKey         = @"dingtalkClickVer";     // 钉钉内 dylib 的版本（诊断注入是否更新）
static NSString *const kDTA_DetailKey      = @"dingtalkClickDetail";  // 点击器最近一次细节（企业序号/跳过原因）

static NSArray<NSString *> *dtaDingTalkDomains(void);   // 定义在下方（Darwin 信标一节）

static BOOL dtaIsClicker(void) {
    return [gDTA_Proc isEqualToString:@"CLICK"];
}

static NSMutableString *gDTA_StatusDetail = nil;       // 点击器最近一次细节（可选）

// SpringBoard 侧：解析钉钉的数据容器路径（点击器侧不需要，直接用 NSHomeDirectory()）
static NSString *gDTA_DingBid = nil;    // 命中的钉钉 bundleID（用于备用通道写它自己的偏好域）
static NSString *dtaDingTalkContainer(void) {
    @try {
        Class proxyCls = NSClassFromString(@"LSApplicationProxy");
        SEL sel = NSSelectorFromString(@"applicationProxyForIdentifier:");
        if (proxyCls && [proxyCls respondsToSelector:sel]) {
            for (NSString *bid in dtaDingTalkDomains()) {
                @try {
                    id p = [proxyCls performSelector:sel withObject:bid];
                    if (!p) continue;
                    SEL uSel = NSSelectorFromString(@"dataContainerURL");
                    if (![p respondsToSelector:uSel]) continue;
                    NSURL *u = (NSURL *)[p performSelector:uSel];
                    if ([u isKindOfClass:[NSURL class]] && u.path.length) {
                        gDTA_DingBid = bid;
                        return u.path;
                    }
                } @catch (NSException *e) {}
            }
        }
    } @catch (NSException *e) {}

    // 兜底：直接扫容器元数据（TrollStore 等非常规安装也能命中）
    @try {
        NSString *base = @"/var/mobile/Containers/Data/Application";
        for (NSString *sub in [[NSFileManager defaultManager] contentsOfDirectoryAtPath:base error:NULL]) {
            NSString *p = [base stringByAppendingPathComponent:sub];
            NSDictionary *m = [NSDictionary dictionaryWithContentsOfFile:
                [p stringByAppendingPathComponent:@".com.apple.mobile_container_manager.metadata.plist"]];
            NSString *ident = m[@"MCMMetadataIdentifier"];
            NSString *low = [ident lowercaseString];
            if ([low isKindOfClass:[NSString class]] && [low containsString:@"laiwang"]) {
                gDTA_DingBid = ident;
                return p;
            }
        }
    } @catch (NSException *e) {}
    return nil;
}

// 通道目录：SB → 钉钉容器；点击器 → 自己的容器（两者指向同一个物理目录）
static NSString *gDTA_ChanRoot = nil;
static NSString *dtaChanRoot(void) {
    @try {
        if (dtaIsClicker()) {
            return [NSHomeDirectory() stringByAppendingPathComponent:
                    [NSString stringWithFormat:@"Documents/%@", kDTA_ChanDirName]];
        }
        if (gDTA_ChanRoot.length) return gDTA_ChanRoot;
        NSString *c = dtaDingTalkContainer();
        if (c.length) {
            gDTA_ChanRoot = [c stringByAppendingPathComponent:
                             [NSString stringWithFormat:@"Documents/%@", kDTA_ChanDirName]];
        }
        return gDTA_ChanRoot;
    } @catch (NSException *e) { return nil; }
}

static NSDictionary *dtaChanLoad(NSString *name) {
    NSString *root = dtaChanRoot();
    if (!root.length) return nil;
    @try {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:
                           [root stringByAppendingPathComponent:name]];
        return [d isKindOfClass:[NSDictionary class]] ? d : nil;
    } @catch (NSException *e) { return nil; }
}

static BOOL dtaChanSave(NSString *name, NSDictionary *d) {
    NSString *root = dtaChanRoot();
    if (!root.length || !d) return NO;
    @try {
        NSFileManager *fm = [NSFileManager defaultManager];
        if (![fm fileExistsAtPath:root]) {
            [fm createDirectoryAtPath:root withIntermediateDirectories:YES attributes:nil error:NULL];
        }
        return [d writeToFile:[root stringByAppendingPathComponent:name] atomically:YES];
    } @catch (NSException *e) { return NO; }
}

// 备用通道：直接写进钉钉自己的偏好域。
//   点击器「读自己的域」必定允许；SpringBoard 没有容器限制，通常也能写。
//   容器文件写不进去的极少数环境下，这条还能兜住。
static BOOL dtaMirrorCmdToDingDomain(NSDictionary *d) {
    if (!d || dtaIsClicker()) return NO;
    @try {
        NSString *bid = gDTA_DingBid;
        if (!bid.length) {
            NSString *c = dtaDingTalkContainer();
            bid = gDTA_DingBid;
            if (!c.length || !bid.length) return NO;
        }
        CFStringRef dom = (__bridge CFStringRef)bid;
        CFPreferencesSetValue(CFSTR("DTAPending"), (__bridge CFPropertyListRef)(d[@"pending"] ?: @""),
                              dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("DTAOrg"), (__bridge CFPropertyListRef)@([d[@"org"] integerValue]),
                              dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("DTAEntry"), (__bridge CFPropertyListRef)(d[@"entry"] ?: @""),
                              dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("DTATs"), (__bridge CFPropertyListRef)@([d[@"ts"] doubleValue]),
                              dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSetValue(CFSTR("DTASeq"), (__bridge CFPropertyListRef)@([d[@"seq"] doubleValue]),
                              dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        CFPreferencesSynchronize(dom, kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        return YES;
    } @catch (NSException *e) { return NO; }
}

// 点击器：从「自己的偏好域」读备用指令（容器文件不可用时的最后手段）
static NSDictionary *dtaCmdFromOwnDomain(void) {
    NSString *bid = [[NSBundle mainBundle] bundleIdentifier];
    if (!bid.length) return nil;
    @try {
        CFStringRef dom = (__bridge CFStringRef)bid;
        CFPreferencesAppSynchronize(dom);
        NSString *p = nil;
        CFTypeRef pv = CFPreferencesCopyValue(CFSTR("DTAPending"), dom,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (pv) {
            if (CFGetTypeID(pv) == CFStringGetTypeID()) p = (__bridge_transfer NSString *)pv;
            else CFRelease(pv);
        }
        if (!p.length) return nil;

        double ts = 0, seq = 0; NSInteger org = 0; NSString *entry = @"";
        CFTypeRef tv = CFPreferencesCopyValue(CFSTR("DTATs"), dom,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (tv) { if (CFGetTypeID(tv) == CFNumberGetTypeID()) ts = [(__bridge NSNumber *)tv doubleValue];
                  CFRelease(tv); }
        CFTypeRef sv = CFPreferencesCopyValue(CFSTR("DTASeq"), dom,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (sv) { if (CFGetTypeID(sv) == CFNumberGetTypeID()) seq = [(__bridge NSNumber *)sv doubleValue];
                  CFRelease(sv); }
        CFTypeRef ov = CFPreferencesCopyValue(CFSTR("DTAOrg"), dom,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (ov) { if (CFGetTypeID(ov) == CFNumberGetTypeID()) org = [(__bridge NSNumber *)ov integerValue];
                  CFRelease(ov); }
        CFTypeRef ev = CFPreferencesCopyValue(CFSTR("DTAEntry"), dom,
                                              kCFPreferencesCurrentUser, kCFPreferencesAnyHost);
        if (ev) { if (CFGetTypeID(ev) == CFStringGetTypeID()) entry = (__bridge_transfer NSString *)ev;
                  else CFRelease(ev); }

        return @{ @"pending": p, @"ts": @(ts), @"seq": @(seq),
                  @"org": @(org), @"entry": entry ?: @"" };
    } @catch (NSException *e) { return nil; }
}

// 点击器侧缓存的命令与「今日已打卡」标记
static NSDictionary *gDTA_Cmd = nil;
static double gDTA_CmdSeq = 0;
static NSString *gDTA_CmdDone = nil;        // 点击器自己记的 done（沙盒写不进偏好域，改记状态文件）

static BOOL dtaCmdFresh(NSDictionary *d) {
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    id p = d[@"pending"];
    if (![p isKindOfClass:[NSString class]] || [(NSString *)p length] < 10) return NO;
    double ts = [d[@"ts"] doubleValue];
    if (ts <= 0) return NO;
    double age = [[NSDate date] timeIntervalSince1970] - ts;
    if (age < -60 || age > 1800) return NO;   // 30 分钟有效期
    return YES;
}

// 点击器：重新读命令文件。返回 YES 表示「来了新指令」（seq 变化）
static BOOL dtaCmdRefresh(void) {
    NSDictionary *d = dtaChanLoad(kDTA_ChanCmdName);
    if (![d isKindOfClass:[NSDictionary class]]) d = dtaCmdFromOwnDomain();   // 备用通道
    if (![d isKindOfClass:[NSDictionary class]]) return NO;
    double seq = [d[@"seq"] doubleValue];
    double old = gDTA_CmdSeq;
    if (seq > gDTA_CmdSeq) gDTA_CmdSeq = seq;
    gDTA_Cmd = dtaCmdFresh(d) ? d : nil;
    return (seq > old + 0.0001);
}

static NSString *dtaCmdPending(void) {
    if (!dtaIsClicker()) return nil;
    if (gDTA_CmdSeq <= 0) dtaCmdRefresh();
    if (!dtaCmdFresh(gDTA_Cmd)) return nil;
    return gDTA_Cmd[@"pending"];
}

// 点击器：把状态写进状态文件（SB 每 3s 读出来转写偏好域 → 设置页可见）
static NSArray<NSString *> *gDTA_OrgNamesCache = nil;   // 抓到的企业名（随状态文件回传给 SpringBoard）
static NSString *gDTA_LastStatusState = nil;
static double gDTA_LastStatusTs = 0;
static void dtaStatusWrite(NSString *state) {
    if (!dtaIsClicker()) return;
    @try {
        // 同一状态 3s 内不重复写（每拍都会调用；避免每秒刷盘），但心跳/新状态照写
        double now = [[NSDate date] timeIntervalSince1970];
        if (state.length && [state isEqualToString:(gDTA_LastStatusState ?: @"")] &&
            now - gDTA_LastStatusTs < 3.0) {
            return;
        }
        gDTA_LastStatusState = state;
        gDTA_LastStatusTs = now;

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        NSDictionary *old = dtaChanLoad(kDTA_ChanStatusName);
        if ([old isKindOfClass:[NSDictionary class]]) [d addEntriesFromDictionary:old];
        d[@"ver"] = kDTA_BuildTag;
        if (state.length) d[@"state"] = state;
        d[@"ts"] = @(now);
        d[@"pending"] = dtaCmdPending() ?: @"";
        NSInteger org = [gDTA_Cmd[@"org"] integerValue];
        if (org > 0) d[@"org"] = @(org);
        if (gDTA_CmdDone.length) d[@"done"] = gDTA_CmdDone;
        else [d removeObjectForKey:@"done"];
        if (gDTA_StatusDetail.length) d[@"detail"] = gDTA_StatusDetail;
        else [d removeObjectForKey:@"detail"];
        if (gDTA_OrgNamesCache.count) d[@"orgnames"] = gDTA_OrgNamesCache;
        dtaChanSave(kDTA_ChanStatusName, d);
    } @catch (NSException *e) {}
}

static void dtaStatusDetail(NSString *fmt, ...) {
    if (!dtaIsClicker()) return;
    @try {
        va_list ap; va_start(ap, fmt);
        NSString *s = [[NSString alloc] initWithFormat:fmt arguments:ap];
        va_end(ap);
        if (!gDTA_StatusDetail) gDTA_StatusDetail = [NSMutableString string];
        [gDTA_StatusDetail setString:s ?: @""];
    } @catch (NSException *e) {}
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
    // 点击器写不了偏好域 → 必须把钉钉容器里的指令文件也清掉，
    // 否则「这一条 pending」会一直算有效，下一次触发前会被当成同一件事重复执行。
    if (dtaIsClicker()) {
        @try {
            NSDictionary *cmd = dtaChanLoad(kDTA_ChanCmdName);
            if ([cmd isKindOfClass:[NSDictionary class]]) {
                NSMutableDictionary *d = [cmd mutableCopy];
                d[@"pending"] = @"";
                d[@"ts"] = @(0);
                dtaChanSave(kDTA_ChanCmdName, d);
            }
            gDTA_Cmd = nil;     // 同时清掉内存缓存，否则本拍还会读到旧的 pending
        } @catch (NSException *e) {}
    }
}
static NSString *dtaReadPending(void) {
    // ⚠️ 点击器在钉钉沙盒内，读不到本插件偏好域 —— 必须以「钉钉容器里的命令文件」为准，
    //    否则会永远认为「没有 pending」→ 触发后什么都不做（0.9.19 之前的真实表现）。
    if (dtaIsClicker()) return dtaCmdPending();
    return dtaCopyPref(kDTA_PendingKey);
}

// 今日是否已成功打卡（防止 10 分钟窗口内每分钟重复点、以及深夜手动打开误打）
static BOOL dtaDoneToday(void) {
    // 点击器侧：以自己记在状态文件里的 done 为准（偏好域读不到；新触发时会清空，允许下班卡）
    if (dtaIsClicker() && gDTA_CmdDone.length) return YES;
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
    if (dtaIsClicker()) {
        gDTA_CmdDone = today;      // 状态文件里也会带上，SB 读后转写偏好域（设置页/悬浮球变绿）
    }
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
static UIControl *dtaAncestorControl(UIView *v) {
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 32) {
        if ([cur isKindOfClass:[UIControl class]]) return (UIControl *)cur;
        cur = cur.superview;
    }
    return nil;
}

// 视图是否真的「在屏幕上可见」。
// ⚠️ 这一点非常关键：钉钉的消息列表/工作台里有大量离屏复用的 cell，里面的 label 文字
//    （比如聊天摘要里的「打卡」）用普通递归扫会被当成目标 → 表现为「找到了但点不动」。
static BOOL dtaViewOnScreen(UIView *v) {
    if (!v || !v.window) return NO;
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 40) {
        if (cur.hidden || cur.alpha < 0.02) return NO;
        cur = cur.superview;
    }
    CGRect f = [v convertRect:v.bounds toView:v.window];
    if (f.size.width < 2 || f.size.height < 2) return NO;
    if (!CGRectIntersectsRect(f, v.window.bounds)) return NO;
    return YES;
}

// ⚠️⚠️ 0.9.24 的核心修复之一。
// 「在屏幕坐标内」不等于「用户能看见」：钉钉的「小程序顶栏」、被弹层/考勤页盖住的后台页面、
// 迷你程序宿主视图里的残留控件，坐标全都落在屏幕内，老逻辑于是把一个被盖住的「打卡」标题
// 当成打卡按钮点掉，然后直接宣布「已打卡」—— 这正是「点了没反应，却显示今日已打卡」的真凶。
// 这里对控件中心点做一次 hitTest：命中结果必须是它自己、它的子视图，或它的祖先，
// 否则说明该位置被别的东西盖住了，绝对不能点。
static BOOL dtaViewIsHittable(UIView *v) {
    if (!v || !v.window) return NO;
    if (!dtaViewOnScreen(v)) return NO;
    CGRect b = v.bounds;
    if (b.size.width < 2 || b.size.height < 2) return NO;
    CGPoint p = [v convertPoint:CGPointMake(CGRectGetMidX(b), CGRectGetMidY(b)) toView:v.window];
    if (!CGRectContainsPoint(v.window.bounds, p)) return NO;
    UIView *hit = nil;
    @try { hit = [v.window hitTest:p withEvent:nil]; } @catch (NSException *e) { return NO; }
    if (!hit) return NO;
    if (hit == v) return YES;
    if ([hit isDescendantOfView:v]) return YES;   // 命中点在它的子视图上（按钮内的图标/文字）
    if ([v isDescendantOfView:hit]) return YES;   // 命中点是它的祖先（label 默认不接收触摸）
    return NO;
}

// 顶栏/导航栏/底栏里的文字一律不是「打卡按钮」：那是标题。
// 本次日志里的 '打卡' 祖先链是 DTMiniSiteTopBarDefaultCell —— 小程序顶栏标题，
// 点它当然什么都不会发生。
static BOOL dtaInChromeBar(UIView *v) {
    static NSArray<NSString *> *names = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        names = @[@"TopBar", @"NavigationBar", @"TabBar", @"ToolBar", @"NavBar", @"TitleBar", @"StatusBar"];
    });
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 24) {
        NSString *cls = NSStringFromClass([cur class]);
        for (NSString *n in names) {
            if ([cls rangeOfString:n].location != NSNotFound) return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

// 树里是否存在「类名包含 needle 且屏幕上看得见」的视图（小程序宿主、自定义底栏这类特征）。
// 小程序被压在导航栈后面时也留在视图树里，不判可见性的话会把「后台的小程序」当成当前页，
// 然后一直对着一个看不见的 WebView 点。
static BOOL dtaHasVisibleViewClass(UIView *root, NSString *needle, NSInteger depth) {
    if (!root || depth > 60) return NO;
    if ([NSStringFromClass([root class]) rangeOfString:needle].location != NSNotFound
        && dtaViewOnScreen(root)) return YES;
    for (UIView *s in root.subviews) {
        if (dtaHasVisibleViewClass(s, needle, depth + 1)) return YES;
    }
    return NO;
}

// 是否已经在「考勤打卡」这类钉钉小程序里。
// 特征：小程序宿主有自己的底栏（打卡 / 设置 / 统计），页面正文全在 WKWebView 里，
// UIKit 层只扫得到底栏标题，扫不到真正的打卡按钮 —— 必须改到网页层去点。
static BOOL dtaLooksLikeMiniAppPage(UIWindow *win) {
    if (!win) return NO;
    if (dtaHasVisibleViewClass(win, @"RVPTabBar", 0)) return YES;
    if (dtaHasVisibleViewClass(win, @"Tinyapp", 0)) return YES;
    if (dtaHasVisibleViewClass(win, @"MiniApp", 0)) return YES;
    return NO;
}

// 「外勤打卡」在绝大多数公司被管理员关掉了（本次日志里就弹了「管理员已关闭外勤打卡」）：
// 点了只会弹一句提示、永远打不上，还会把「等 6 秒验证」的拍数白白耗掉。
// 「更新打卡」是已经打过卡才会出现 —— 也不是我们要点的。
// 这两个（以及记录/规则/申诉这类）一律不碰。
static BOOL dtaIsBlockedPunchText(NSString *t) {
    if (!t.length) return NO;
    for (NSString *w in @[@"外勤", @"更新打卡", @"打卡记录", @"打卡规则", @"打卡设置", @"申诉", @"申请"]) {
        if ([t rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}


// 收集屏幕上的全部文字（用于判断「当前是不是考勤页」/「有没有打卡成功标志」）
static void dtaCollectVisibleTexts(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 60 || out.count >= 80) return;
    if (v.hidden || v.alpha < 0.02) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length && l.text.length <= 40 && dtaViewOnScreen(l)) [out addObject:l.text];
        return;
    }
    for (UIView *s in v.subviews) dtaCollectVisibleTexts(s, out, depth + 1);
}

static NSString *gDTA_WebText = nil;          // 最近一次从 WebView 读到的页面文字（H5 考勤页只能靠它）
static BOOL gDTA_WebPunched = NO;             // 本条指令内是否已经通过 JS 点过 H5 打卡按钮
// 这几个状态 WebView 模块（点击/验证）也要用，提前声明
static CFAbsoluteTime gDTA_VerifyAt = 0;      // !=0 表示刚点完打卡，正在等页面给出成功标志
static NSInteger gPunchTries = 0;             // 本次触发已尝试点击打卡的次数
static NSString *gDTA_LastPunchText = nil;    // 刚才点的到底是哪个文字（日志/详情用）
static CFAbsoluteTime gDTA_LastPunchAt = 0;   // 上次点击时间
static CFAbsoluteTime gDTA_LastWebTry = 0;    // H5 点击节流
static CFAbsoluteTime gDTA_WebOkAt = 0;       // 网页层看到「打卡成功」的时刻（toast 很短，要快抓）
static CFAbsoluteTime gDTA_LastWebNav = 0;    // 网页层点考勤入口的节流

static NSString *dtaPageText(UIWindow *win) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    if (win) dtaCollectVisibleTexts(win, a, 0);
    if (gDTA_WebText.length) [a addObject:gDTA_WebText];
    return [a componentsJoinedByString:@" | "];
}

// 「打卡成功」的页面证据。命中任意一个才算真的打上了。
static BOOL dtaTextHasPunchSuccess(NSString *t) {
    if (!t.length) return NO;
    static NSArray<NSString *> *ws = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ws = @[@"打卡成功", @"已打卡", @"已签到", @"成功打卡", @"签到成功",
               @"更新打卡", @"已打上班卡", @"已打下班卡"];
    });
    for (NSString *w in ws) {
        if ([t rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

// 页面是否已经给出「打卡成功」的证据（原生文字 + H5 文字都算）
static BOOL dtaPunchConfirmed(UIWindow *win) {
    return dtaTextHasPunchSuccess(dtaPageText(win));
}

// 强特征：只会在考勤页的「真按钮」上出现。命中它就可以按成功处理
// （考勤页很可能是 H5/小程序，成功标志拿不到，不能死等）。
static BOOL dtaTextIsStrongPunch(NSString *t) {
    if (!t.length) return NO;
    if (dtaIsBlockedPunchText(t)) return NO;   // 外勤/更新打卡 不是我们要点的
    for (NSString *w in @[@"上班打卡", @"下班打卡", @"立即打卡", @"极速打卡", @"点击打卡"]) {
        if ([t rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

// 页面是不是考勤页（只有考勤页才允许把孤零零的「打卡」二字当按钮）
static BOOL dtaAttendanceContext(NSString *pageText) {
    if (!pageText.length) return NO;
    for (NSString *w in @[@"上班时间", @"下班时间", @"考勤组", @"打卡时间", @"考勤", @"外勤",
                          @"工时", @"排班", @"迟到", @"早退", @"缺卡", @"签到", @"打卡地点"]) {
        if ([pageText rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

static void dtaCollectLabelsMatching(UIView *v, NSString *t, NSMutableArray<UILabel *> *out, NSInteger depth) {
    if (!v || depth > 70 || out.count >= 24) return;
    if (v.hidden || v.alpha < 0.02) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        if (l.text.length && [l.text rangeOfString:t].location != NSNotFound && dtaViewOnScreen(l)) {
            [out addObject:l];
        }
        return;
    }
    for (UIView *s in v.subviews) dtaCollectLabelsMatching(s, t, out, depth + 1);
}

static NSArray<UILabel *> *dtaVisibleLabelsMatching(UIView *root, NSString *t) {
    NSMutableArray<UILabel *> *a = [NSMutableArray array];
    dtaCollectLabelsMatching(root, t, a, 0);
    return a;
}

// 控件子树里第一个可见 label（很多自定义按钮的标题文字放在子 label 上，
// UIControl 自身的 title/accessibilityLabel 是空的 —— 老逻辑会漏掉整类按钮）
static UILabel *dtaFirstVisibleLabelDeep(UIView *v, NSInteger depth) {
    if (!v || depth > 4 || v.hidden || v.alpha < 0.02) return nil;
    if ([v isKindOfClass:[UILabel class]]) return (UILabel *)v;
    for (UIView *s in v.subviews) {
        UILabel *l = dtaFirstVisibleLabelDeep(s, depth + 1);
        if (l) return l;
    }
    return nil;
}

// 智能找控件：自身 title/accessibilityLabel 命中，或「子 label 文字命中」也算。
// 这能命中钉钉里那种 UIControl 容器 + 内部 UILabel 的自定义按钮。
static BOOL dtaControlMatches(UIControl *c, NSString *target) {
    if (!c) return NO;
    NSString *title = nil;
    if ([c isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)c;
        title = b.currentTitle ?: [b titleForState:UIControlStateNormal];
    }
    if (title.length && [title rangeOfString:target].location != NSNotFound) return YES;
    NSString *acc = [c accessibilityLabel];
    if (acc.length && [acc rangeOfString:target].location != NSNotFound) return YES;
    UILabel *l = dtaFirstVisibleLabelDeep(c, 0);
    if (l.text.length && [l.text rangeOfString:target].location != NSNotFound) return YES;
    return NO;
}

// 收集所有命中的控件（含容器），按面积从小到大排序：
// 面积小的通常是「真正的那个按钮/图标」，面积大的往往是整页容器 —— 选错就会点不动。
static void dtaCollectControls(UIView *view, NSString *target,
                               NSMutableArray<UIControl *> *out, NSInteger depth) {
    if (!view || depth > 60 || view.hidden || view.alpha < 0.02) return;
    if ([view isKindOfClass:[UIControl class]] && dtaViewOnScreen(view)
        && dtaControlMatches((UIControl *)view, target)) {
        [out addObject:(UIControl *)view];
    }
    for (UIView *sub in view.subviews) dtaCollectControls(sub, target, out, depth + 1);
}

static NSArray<UIControl *> *dtaControlsMatching(UIView *root, NSString *target) {
    NSMutableArray<UIControl *> *out = [NSMutableArray array];
    dtaCollectControls(root, target, out, 0);
    [out sortUsingComparator:^NSComparisonResult(UIControl *a, UIControl *b) {
        CGRect fa = [a convertRect:a.bounds toView:a.window];
        CGRect fb = [b convertRect:b.bounds toView:b.window];
        CGFloat aa = fa.size.width * fa.size.height;
        CGFloat ab = fb.size.width * fb.size.height;
        if (aa < ab) return NSOrderedAscending;
        if (aa > ab) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    return out;
}

static UIControl *dtaScanControlSmart(UIView *view, NSString *target) {
    NSArray<UIControl *> *arr = dtaControlsMatching(view, target);
    if (arr.count == 0) return nil;
    // 优先 30x30 以上（避免命中角标/小图标里的同名文字），否则就取最小的那个
    for (UIControl *c in arr) {
        CGRect f = [c convertRect:c.bounds toView:c.window];
        if (f.size.width >= 30 && f.size.height >= 30) return c;
    }
    return arr.firstObject;
}

// 祖先类名链（排查「到底是个什么控件」用，日志里一行就能看清）
static NSString *dtaAncestorChain(UIView *v) {
    NSMutableArray<NSString *> *a = [NSMutableArray array];
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < 7) {
        [a addObject:NSStringFromClass([cur class])];
        cur = cur.superview;
    }
    return [a componentsJoinedByString:@" < "];
}

static BOOL dtaHasAncestorClass(UIView *v, NSString *clsName, NSInteger maxUp);   // 定义在下面

// 文字是否更像「工作台上的考勤入口」而不是「打卡按钮」。
// 入口（考勤打卡 / 考情助手 / 工作台…）点了只会进二级页，绝不能被当成打卡成功。
static BOOL dtaLooksLikeNavEntry(NSString *t) {
    if (!t.length) return NO;
    for (NSString *w in @[@"考勤", @"助手", @"工作台", @"应用", @"更多"]) {
        if ([t rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

static NSString *dtaControlText(UIControl *c) {
    if (!c) return @"";
    if ([c isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)c;
        NSString *t = b.currentTitle ?: [b titleForState:UIControlStateNormal];
        if (t.length) return t;
    }
    NSString *acc = [c accessibilityLabel];
    if (acc.length) return acc;
    UILabel *l = dtaFirstVisibleLabelDeep(c, 0);
    return l.text ?: @"";
}

// 「找到文字就点」的旧实现（0.9.23 及以前）在这里踩了两个坑，0.9.24 全部修掉：
//   ① 命中「小程序顶栏标题『打卡』」→ 点了没反应，却被当成打卡成功；
//   ② 被考勤页/弹层盖住的页面里的同名文字也会被扫到 → 点了没反应。
// 现在按「证据强度」分档：
//   强特征（上班打卡/下班打卡/立即打卡…）→ 只出现在真按钮上，点了就算成功；
//   弱特征（孤零零一个「打卡」）→ 可能只是标题/卡片，点了要等页面给出成功标志才算数。
static NSString *gDTA_PendingWeakSig = nil;   // finder 填：本次返回的弱目标签名（调用方负责记住它，避免反复点同一个）
static NSMutableSet<NSString *> *gDTA_WeakTriedSet = nil;   // 本条指令内已点过但没确认成功的弱目标（可多个）

static UIView *dtaFindPunchTarget(UIWindow *root, NSInteger mode, BOOL *outStrong, NSString **outText) {
    if (outStrong) *outStrong = NO;
    if (outText) *outText = @"";
    gDTA_PendingWeakSig = nil;

    NSString *pageText = dtaPageText(root);
    BOOL ctx = dtaAttendanceContext(pageText);

    // ① 强特征：按 mode 排优先级
    NSArray<NSString *> *strong;
    if (mode == 0)      strong = @[@"上班打卡", @"立即打卡", @"极速打卡", @"点击打卡", @"下班打卡"];
    else if (mode == 1) strong = @[@"下班打卡", @"立即打卡", @"极速打卡", @"点击打卡", @"上班打卡"];
    else                strong = @[@"上班打卡", @"下班打卡", @"立即打卡", @"极速打卡", @"点击打卡"];

    for (NSString *t in strong) {
        for (UIControl *c in dtaControlsMatching(root, t)) {
            if (dtaInChromeBar(c)) continue;
            if (!dtaViewIsHittable(c)) continue;
            NSString *txt = dtaControlText(c);
            if (!dtaTextIsStrongPunch(txt)) continue;
            if (outStrong) *outStrong = YES;
            if (outText) *outText = txt;
            dtaLog(@"🎯 找到打卡按钮（强特征 '%@'）%@ 文字='%@'", t, [c class], txt);
            return c;
        }
        for (UILabel *l in dtaVisibleLabelsMatching(root, t)) {
            if (dtaInChromeBar(l)) continue;
            if (!dtaViewIsHittable(l)) continue;
            if (!dtaTextIsStrongPunch(l.text)) continue;
            if (outStrong) *outStrong = YES;
            if (outText) *outText = l.text ?: @"";
            UIControl *anc = dtaAncestorControl(l);
            dtaLog(@"🎯 找到打卡按钮（强特征文字 '%@'）祖先=%@", l.text ?: @"", dtaAncestorChain(l));
            return anc ?: l;
        }
    }

    // ② 弱特征「打卡」：要求页面确实在考勤上下文里，且文字不在顶栏/导航栏/底栏
    if (!ctx) {
        static NSString *lastNoCtx = nil;
        if (![lastNoCtx isEqualToString:pageText ?: @""]) {
            lastNoCtx = pageText ?: @"";
            dtaLog(@"🔍 没找到强特征打卡按钮，且当前页不像考勤页 → 先导航，不瞎点「打卡」");
        }
        return nil;
    }
    for (UILabel *l in dtaVisibleLabelsMatching(root, @"打卡")) {
        if (dtaInChromeBar(l)) {
            static NSString *lastChrome = nil;
            if (![lastChrome isEqualToString:l.text ?: @""]) {
                lastChrome = l.text ?: @"";
                dtaLog(@"🚫 跳过顶栏/导航栏里的 '%@'（那是标题，不是打卡按钮）祖先=%@",
                       l.text ?: @"", dtaAncestorChain(l));
            }
            continue;
        }
        if (!dtaViewIsHittable(l)) {
            static NSString *lastCovered = nil;
            if (![lastCovered isEqualToString:l.text ?: @""]) {
                lastCovered = l.text ?: @"";
                dtaLog(@"🚫 跳过被盖住的 '%@'（当前页面上看不到它）祖先=%@",
                       l.text ?: @"", dtaAncestorChain(l));
            }
            continue;
        }
        NSString *t = l.text ?: @"";
        if (dtaLooksLikeNavEntry(t)) continue;    // 考勤打卡/考勤助手 等入口
        if (dtaTextIsStrongPunch(t)) continue;
        if (dtaIsBlockedPunchText(t)) continue;   // 「外勤打卡」等：点了也打不上
        CGRect lf = [l convertRect:l.bounds toView:l.window];
        NSString *sig = [NSString stringWithFormat:@"%@|%.0f|%.0f|%.0f", t,
                         lf.origin.x, lf.origin.y, lf.size.width];
        if ([gDTA_WeakTriedSet containsObject:sig]) continue;   // 这条指令里已经点过且没成功
        gDTA_PendingWeakSig = sig;
        if (outText) *outText = t;
        UIControl *anc = dtaAncestorControl(l);
        dtaLog(@"🎯 找到「%@」（弱特征，需页面确认）祖先=%@", t, dtaAncestorChain(l));
        return anc ?: l;
    }
    return nil;
}

static void dtaClick(UIControl *btn) {
    @try {
        // 0.9.27：不再只查 TouchUpInside。钉钉有些自定义控件把 action 挂在 TouchDown /
        // PrimaryActionTriggered 上，之前取不到就当成「没有 target」，白点一场。
        UIControlEvents mask = btn.allControlEvents;
        if (mask == 0) mask = UIControlEventTouchUpInside;
        BOOL called = NO;
        for (id t in [[btn allTargets] allObjects]) {
            for (NSUInteger e = 1; e <= (1u << 20); e <<= 1) {
                if (!(mask & e)) continue;
                NSArray<NSString *> *acts = [btn actionsForTarget:t forControlEvent:(UIControlEvents)e];
                for (NSString *a in acts) {
                    SEL sel = NSSelectorFromString(a);
                    if (sel && [t respondsToSelector:sel]) {
                        [t performSelector:sel withObject:btn];
                        called = YES;
                        dtaLog(@"调用 action %@ on %@", a, [t class]);
                    }
                }
            }
        }
        [btn sendActionsForControlEvents:UIControlEventTouchDown];
        [btn sendActionsForControlEvents:UIControlEventTouchUpInside];
        dtaLog(@"sendActions %@ 已发", called ? @"(含直接 action)" : @"TouchDown+TouchUpInside");
    } @catch (NSException *e) {
        dtaLog(@"点击异常: %@", e);
    }
}

// ── WebView 选择（0.9.25 核心修复）──────────────────────────────────────────────
// 老实现是「深度优先返回第一个 WebView」。钉钉里第一个永远是**后台**那个全屏 WebView
// （消息页/工作台），考勤小程序的 WebView 叠在它上面。后果非常隐蔽：
//   ① 探针读的是后台页面 → 读到空文字 → 判定「当前页不像考勤页」；
//   ② JS 在后台页面里当然找不到打卡按钮 → 永远返回 'none'。
// 0.9.24 日志里那串「WebView 点击结果=none」+「找不到打卡按钮」就是这么来的。
// 现在收集全部 WebView，优先「中心点 hitTest 打得到自己」的那个（= 最前面那个）。
static void dtaCollectWebViews(UIView *v, NSMutableArray<UIView *> *out, NSInteger depth) {
    if (!v || depth > 90 || out.count >= 24) return;
    // ⚠️ 0.9.27：只认**真正的** WKWebView / UIWebView（含其子类）。
    //    0.9.26 用「respondsToSelector: evaluateJavaScript:」判断，结果钉钉的 LAWebView
    //    也实现了这个方法（装样子），于是把它当成 WebView 收了进来，
    //    JS 发过去永远没有回调 —— 日志里就是「选中 WebView LAWebView … 可点=0 / 共 1 个」，
    //    后面既读不到页面文字、也点不到按钮。真正的 WKWebView 是它的子视图，被这一层挡在门外。
    Class wk = NSClassFromString(@"WKWebView");
    Class ui = NSClassFromString(@"UIWebView");
    if ((wk && [v isKindOfClass:wk]) || (ui && [v isKindOfClass:ui])) {
        [out addObject:v];
        return;                 // 真 WebView 内部全是 WKContentView 等，无需再往下
    }
    for (UIView *s in v.subviews) dtaCollectWebViews(s, out, depth + 1);
}

// 收集当前进程的全部窗口（多 scene）。小程序可能被放在另一个 window 里，
// 只看 key window 会漏掉它（0.9.26 日志里「共 1 个」就是这个原因）。
static void dtaCollectWindows(NSMutableArray<UIWindow *> *out) {
    for (UIScene *sc in [UIApplication sharedApplication].connectedScenes) {
        if (![sc isKindOfClass:[UIWindowScene class]]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            if (w && ![out containsObject:w]) [out addObject:w];
        }
    }
    UIWindow *kw = [UIApplication sharedApplication].keyWindow;
    if (kw && ![out containsObject:kw]) [out addObject:kw];
}

static id dtaFindWebView(UIView *root) {
    NSMutableArray<UIWindow *> *wins = [NSMutableArray array];
    if (root.window && ![wins containsObject:root.window]) [wins addObject:root.window];
    dtaCollectWindows(wins);

    NSMutableArray<UIView *> *all = [NSMutableArray array];
    for (UIWindow *w in wins) dtaCollectWebViews(w, all, 0);
    if (all.count == 0) return nil;

    // 打分：能 hitTest 到（在最前面）权重最高；同分取面积大的
    UIView *best = nil;
    CGFloat bestScore = -1;
    NSMutableArray<NSString *> *desc = [NSMutableArray array];
    NSInteger i = 0;
    for (UIView *w in all) {
        i++;
        CGRect f = w.window ? [w convertRect:w.bounds toView:w.window] : CGRectZero;
        BOOL visible = (w.window && !w.hidden && w.alpha > 0.02 && f.size.width > 40 && f.size.height > 40);
        BOOL hit = visible ? dtaViewIsHittable(w) : NO;
        [desc addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f,%.0f,%.0f)%@",
                         NSStringFromClass([w class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
                         hit ? @" 可点" : (visible ? @"" : @" 不可见")]];
        if (!visible) continue;
        CGFloat score = (hit ? 100000.0 : 0.0) + f.size.width * f.size.height / 1000.0 + i * 0.01;
        if (score >= bestScore) { bestScore = score; best = w; }
    }
    if (!best) best = all.lastObject;
    static __weak UIView *lastLogged = nil;
    static NSString *lastDesc = nil;
    NSString *nowDesc = [desc componentsJoinedByString:@"; "];
    if (best != lastLogged || ![nowDesc isEqualToString:lastDesc ?: @""]) {
        lastLogged = best;
        lastDesc = nowDesc;
        CGRect f = best.window ? [best convertRect:best.bounds toView:best.window] : CGRectZero;
        dtaLog(@"🌐 选中 WebView %@ (%.0f,%.0f,%.0f,%.0f) 可点=%d / 共 %lu 个",
               NSStringFromClass([best class]), f.origin.x, f.origin.y, f.size.width, f.size.height,
               (int)dtaViewIsHittable(best), (unsigned long)all.count);
        dtaLog(@"🌐 WebView 候选：%@", nowDesc);
    }
    return best;
}
static NSString *dtaEntryKeyword(void);   // 定义在下面（考勤入口名，默认「考勤打卡」）

// ── WebView / 小程序（H5）兜底 ────────────────────────────────────────────────────
// 钉钉的考勤页经常是小程序/H5：页面上的文字和按钮全在 WKWebView 里，UIKit 扫不到。
// 这里做两件事：① 读页面文字（探针，用于判断考勤页/成功标志）；② 在网页层真点按钮。
static SEL dtaWebSel(void) {
    return NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
}

static void dtaWebEval(id web, NSString *js, void (^done)(id res, NSError *err)) {
    SEL sel = dtaWebSel();
    if (!web || !sel || ![web respondsToSelector:sel]) return;
    @try {
        [web performSelector:sel withObject:js withObject:^(id res, id err) {
            if (done) done(res, err);
        }];
    } @catch (NSException *e) {
        dtaLog(@"WebView JS 异常: %@", e);
    }
}

static NSString *dtaWebEvalString(id res) {
    if (![res isKindOfClass:[NSString class]]) return nil;
    return [(NSString *)res stringByTrimmingCharactersInSet:
            [NSCharacterSet whitespaceAndNewlineCharacterSet]];
}

static NSString *gDTA_LastWebProbeText = nil;

// 只读文字：既做诊断（日志里能直接看到 H5 页面写了什么），也做成功判定。
static void dtaWebProbe(UIWindow *root) {
    static CFAbsoluteTime last = 0;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (now - last < 4.0) return;
    id web = dtaFindWebView(root);
    if (!web) return;
    last = now;

    // 顺手记下 URL：小程序页的 URL 里带 appId / 页面路径，是排查「到底停在哪一页」最硬的证据
    static __weak UIView *lastURLWeb = nil;
    static NSString *lastURL = nil;
    @try {
        id u = [web valueForKey:@"URL"];
        NSString *us = [u isKindOfClass:[NSURL class]] ? [(NSURL *)u absoluteString] : nil;
        if (us.length && (web != lastURLWeb || ![us isEqualToString:lastURL ?: @""])) {
            lastURLWeb = web;
            lastURL = us;
            dtaLog(@"🌐 WebView URL: %@", us.length > 160 ? [us substringToIndex:160] : us);
        }
    } @catch (NSException *e) {}

    // 「假 WebView」检测：LAWebView 这类容器会 respond 但永不回调。
    // 2.5 秒还没拿到任何文字，就明确写一行日志，别再让人猜。
    NSString *before = gDTA_LastWebProbeText;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (gDTA_LastWebProbeText != before) return;         // 有回字，正常
        static CFAbsoluteTime lastWarn = 0;
        CFAbsoluteTime t = CFAbsoluteTimeGetCurrent();
        if (t - lastWarn < 20.0) return;
        lastWarn = t;
        dtaLog(@"⚠️ WebView 2.5 秒没有返回任何 JS 结果（%@）→ 换下一个候选或页面还没加载完",
               NSStringFromClass([web class]));
    });

    NSString *js = @"(function(){try{var b=document.body;if(!b)return 'nobody';"
                    "var t=b.innerText||'';t=t.replace(/\\s+/g,' ');return t.slice(0,300);}"
                    "catch(e){return 'err:'+e;}})()";
    dtaWebEval(web, js, ^(id res, NSError *err) {
        NSString *s = dtaWebEvalString(res);
        if (!s.length || [s isEqualToString:@"nobody"]) return;
        if ([s hasPrefix:@"err:"]) {
            dtaLog(@"🌐 探针 JS 出错：%@", s);
            return;
        }
        gDTA_WebText = s;
        if (![gDTA_LastWebProbeText isEqualToString:s]) {
            gDTA_LastWebProbeText = s;
            NSString *show = s.length > 120 ? [s substringToIndex:120] : s;
            dtaLog(@"🌐 WebView 页面文字：%@", show);
        }
    });
}

// 在网页层找「打卡按钮」并真点。三条硬约束（全是 0.9.24 日志里踩出来的）：
//   ① 只点 上班打卡/下班打卡/立即打卡/极速打卡/点击打卡。
//      绝不点 外勤打卡 —— 管理员一关就永远打不上，只会弹「管理员已关闭外勤打卡」；
//      也不点 更新打卡（已经打过了）和 记录/规则/申请（那是别的入口）。
//   ② 点「文案最精确 + 面积最小」的那个元素，而不是第一个含「打卡」二字的整块容器。
//   ③ 必须发完整的指针/触摸/鼠标事件序列 —— 小程序只认这个，光 click() 没反应。
static NSString *dtaWebTapJS(NSArray<NSString *> *good, NSArray<NSString *> *bad);

static NSString *dtaWebPunchJS(NSInteger mode) {
    NSMutableArray<NSString *> *ts = [NSMutableArray array];
    if (mode == 0)      [ts addObjectsFromArray:@[@"上班打卡", @"立即打卡", @"极速打卡", @"点击打卡"]];
    else if (mode == 1) [ts addObjectsFromArray:@[@"下班打卡", @"立即打卡", @"极速打卡", @"点击打卡"]];
    else                [ts addObjectsFromArray:@[@"上班打卡", @"下班打卡", @"立即打卡", @"极速打卡", @"点击打卡"]];
    return dtaWebTapJS(ts, @[@"外勤", @"更新打卡", @"打卡记录", @"打卡规则", @"打卡设置", @"申诉", @"申请"]);
}

// 通用「在网页层按文字点一下」：
//   good = 目标文案（按下标优先级），bad = 排除词（子串命中就跳过）。
// 选元素规则：文案命中且最靠前、面积最小的那个 —— 容器面积大，点它没用。
static NSString *dtaWebTapJS(NSArray<NSString *> *good, NSArray<NSString *> *bad) {
    NSString *arr = [NSString stringWithFormat:@"['%@']", [good componentsJoinedByString:@"','"]];
    NSString *badStr = [NSString stringWithFormat:@"['%@']", [bad componentsJoinedByString:@"','"]];

    return [NSString stringWithFormat:
        @"(function(){try{"
        @"var TS=%@,BAD=%@;"
        @"function vis(e){try{var r=e.getBoundingClientRect();"
        @"return r.width>10&&r.height>10&&r.right>0&&r.bottom>0&&r.left<innerWidth&&r.top<innerHeight;}catch(x){return false;}}"
        @"function tx(e){var t=(e.innerText||e.textContent||'');return t.replace(/\\s+/g,'');}"
        @"function isBad(t){for(var i=0;i<BAD.length;i++){if(t.indexOf(BAD[i])>=0)return true;}return false;}"
        @"var els=document.querySelectorAll('*'),cs=[],labels=[];"
        @"for(var i=0;i<els.length;i++){var e=els[i];if(!vis(e))continue;"
        @"var t=tx(e);if(!t||t.length>30)continue;"
        @"if(labels.length<16&&t.length<=12&&labels.indexOf(t)<0)labels.push(t);"
        @"if(isBad(t))continue;"
        @"for(var j=0;j<TS.length;j++){if(t.indexOf(TS[j])<0)continue;"
        @"var r=e.getBoundingClientRect();"
        @"cs.push({i:j,t:t,a:r.width*r.height,x:r.left+r.width/2,y:r.top+r.height/2,el:e});break;}}"
        @"cs.sort(function(p,q){if(p.i!==q.i)return p.i-q.i;return p.a-q.a;});"
        @"if(!cs.length){var b=(document.body.innerText||'').replace(/\\s+/g,' ').slice(0,200);"
        // 没找到就先往下滚一屏（到底部就回到顶部）：工作台的考勤图标常在第二屏，
        // 不滚永远搜不到，日志里就会一直「网页层也没找到」。
        @"var sy=window.scrollY||0,hh=document.body.scrollHeight,nh=sy+innerHeight*0.8;"
        @"if(nh>hh-innerHeight*0.6)nh=0;try{window.scrollTo(0,nh);}catch(x){}"
        @"return JSON.stringify({hit:'',n:0,labels:labels,body:b,scroll:Math.round(nh)});}"
        @"var c=cs[0],pt={x:c.x,y:c.y},top=null;"
        @"try{top=document.elementFromPoint(pt.x,pt.y);}catch(x){}"
        @"function fire(el,ty){try{"
        @"var o={bubbles:true,cancelable:true,composed:true,clientX:pt.x,clientY:pt.y,view:window};"
        @"if(ty==='touchstart'||ty==='touchend'){"
        @"var tt=new Touch({identifier:1,target:el,clientX:pt.x,clientY:pt.y,pageX:pt.x,pageY:pt.y,screenX:pt.x,screenY:pt.y});"
        @"var live=(ty==='touchend')?[]:[tt];"
        @"el.dispatchEvent(new TouchEvent(ty,{bubbles:true,cancelable:true,composed:true,touches:live,targetTouches:live,changedTouches:[tt]}));"
        @"}else if(ty==='pointerdown'||ty==='pointerup'){el.dispatchEvent(new PointerEvent(ty,o));}"
        @"else{el.dispatchEvent(new MouseEvent(ty,o));}}catch(x){}}"
        @"var tg=[c.el];if(top&&top!==c.el)tg.push(top);"
        @"for(var k=0;k<tg.length;k++){var el=tg[k];if(!el)continue;"
        @"fire(el,'pointerdown');fire(el,'touchstart');fire(el,'pointerup');fire(el,'touchend');"
        @"fire(el,'mousedown');fire(el,'mouseup');fire(el,'click');"
        @"try{if(el.click)el.click();}catch(x){}}"
        @"return JSON.stringify({hit:c.t,n:cs.length,labels:labels,body:''});"
        @"}catch(err){return JSON.stringify({hit:'',n:-1,labels:[],body:'JS异常:'+err});}})()",
        arr, badStr];
}

// 小程序打完卡只弹 1~2 秒的 toast（「打卡成功」），而点击器是 3 秒一拍 —— 等下一拍再去看，
// toast 早没了。所以点完立刻在网页层密集轮询几次（0.6/1.2/2/3/4.5 秒），抓到就记下来。
static void dtaWebWatchSuccess(UIWindow *root) {
    CFTimeInterval base = gDTA_LastPunchAt;
    NSString *js = @"(function(){try{var t=(document.body.innerText||'').replace(/\\s+/g,' ');"
                   "return /打卡成功|已打卡|已签到|成功打卡|签到成功|更新打卡|已打上班卡|已打下班卡/.test(t)"
                   "?t.slice(0,100):'';}catch(e){return '';}})()";
    for (NSNumber *d in @[@0.6, @1.2, @2.0, @3.0, @4.5]) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (gDTA_LastPunchAt != base) return;        // 已经换了一次新的点击，别用旧结果
            UIView *web = dtaFindWebView(root);
            if (!web) return;
            dtaWebEval(web, js, ^(id res, NSError *err) {
                NSString *s = dtaWebEvalString(res);
                if (!s.length || gDTA_WebOkAt > 0) return;
                gDTA_WebOkAt = CFAbsoluteTimeGetCurrent();
                gDTA_WebText = s;
                dtaLog(@"✅ H5 页面出现打卡成功标志：%@", s);
            });
        });
    }
}

// 工作台本身也是个 H5 页面：考勤入口是网页里的一个图标，UIKit 扫不到
// （0.9.24 日志里「入口点击 0 次」就是这么来的）。
// 这里在网页层按文字点「考勤打卡 / 考勤」。
static void dtaWebNavToAttendance(UIWindow *root) {
    id web = dtaFindWebView(root);
    if (!web) { dtaLog(@"🌐 工作台没有 WebView，网页层也点不到考勤入口"); return; }
    NSString *js = dtaWebTapJS(@[@"考勤打卡", @"考勤"],
                               @[@"记录", @"统计", @"设置", @"规则", @"申诉", @"申请",
                                 @"报表", @"排班", @"管理", @"通讯录"]);
    dtaLog(@"🌐 在网页层找「考勤打卡」入口…");
    dtaWebEval(web, js, ^(id res, NSError *err) {
        NSString *s = dtaWebEvalString(res);
        NSDictionary *d = nil;
        if (s.length) {
            id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]]) d = (NSDictionary *)o;
        }
        NSString *hit = [d[@"hit"] isKindOfClass:[NSString class]] ? d[@"hit"] : @"";
        NSArray *labels = [d[@"labels"] isKindOfClass:[NSArray class]] ? d[@"labels"] : nil;
        if (labels.count) dtaLog(@"🌐 工作台 H5 可见文字：%@", [labels componentsJoinedByString:@" | "]);
        if (hit.length) {
            dtaLog(@"✅ 已在网页层点中「%@」→ 等考勤页打开", hit);
        } else {
            NSNumber *sc = [d[@"scroll"] isKindOfClass:[NSNumber class]] ? d[@"scroll"] : nil;
            dtaLog(@"⚠️ 网页层也没找到「考勤打卡」入口（已下滑到 y=%@，下一拍再找）err=%@",
                   sc ?: @"?", err ?: @"(null)");
        }
    });
}

static void dtaWebTryPunch(UIWindow *root, NSInteger mode) {
    id web = dtaFindWebView(root);
    if (!web) { dtaLog(@"🌐 本页没有 WebView（考勤页可能是原生控件）"); return; }
    gDTA_LastWebTry = CFAbsoluteTimeGetCurrent();
    NSString *js = dtaWebPunchJS(mode);
    dtaLog(@"🌐 在小程序/H5 页面里找打卡按钮（排除外勤/更新/记录）…");
    dtaWebEval(web, js, ^(id res, NSError *err) {
        NSString *s = dtaWebEvalString(res);
        NSDictionary *d = nil;
        if (s.length) {
            id o = [NSJSONSerialization JSONObjectWithData:[s dataUsingEncoding:NSUTF8StringEncoding]
                                                   options:0 error:NULL];
            if ([o isKindOfClass:[NSDictionary class]]) d = (NSDictionary *)o;
        }
        NSString *hit = [d[@"hit"] isKindOfClass:[NSString class]] ? d[@"hit"] : @"";
        NSArray *labels = [d[@"labels"] isKindOfClass:[NSArray class]] ? d[@"labels"] : nil;
        NSString *body = [d[@"body"] isKindOfClass:[NSString class]] ? d[@"body"] : @"";
        if (labels.count) dtaLog(@"🌐 H5 可见文字：%@", [labels componentsJoinedByString:@" | "]);
        if (body.length)  dtaLog(@"🌐 H5 页面文字：%@", body);

        if (hit.length) {
            gDTA_WebPunched = YES;
            gPunchTries++;
            gDTA_LastPunchText = hit;
            gDTA_LastPunchAt = CFAbsoluteTimeGetCurrent();
            gDTA_VerifyAt = gDTA_LastPunchAt;
            dtaClickState(@"webview");
            dtaLog(@"✅ 已在 H5/小程序里点中「%@」（共 %@ 个候选）→ 等页面确认",
                   hit, d[@"n"] ?: @"?");
            dtaWebWatchSuccess(root);
        } else {
            gDTA_WebPunched = NO;
            dtaLog(@"⚠️ H5 里没找到打卡按钮（本次没点任何东西）err=%@", err ?: @"(null)");
            if (!labels.count && !body.length) {
                dtaLog(@"🌐 这个 WebView 读不到内容 → 可能不是考勤页，或页面还没加载完");
            }
        }
    });
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
    // ⚠️ 必须先看「有没有新的触发指令」，再看 done：
    //    用户主动点悬浮球 = 明确要求再跑一次（补打/下班卡/重试），
    //    不能被上次成功写下的 done 标记挡住，否则表现就是「第一次成功，之后怎么点都没反应」。
    if (dtaPendingToday(outMode)) {
        if (outFromPending) *outFromPending = YES;
        return YES;
    }
    if (dtaDoneToday()) return NO;   // 定时/被动路径下，当天不重复
    if (dtaArmed(outMode)) { if (outFromPending) *outFromPending = NO;  return YES; }
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
static void dtaSyncCmdConfig(void); // 前向声明（把最新配置同步到钉钉容器里的指令文件）
static void dtaManualFire(BOOL force); // 前向声明：手动触发打卡（立即测试/悬浮球单击），不受定时总开关限制

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
            dtaSyncCmdConfig();   // 改了「第几个企业/入口名」立刻同步到钉钉容器（正在执行中的指令）
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

static void dtaPushCmd(NSString *pending, BOOL bumpSeq);   // 定义在下方（容器通道，SpringBoard 侧）

static void dtaPunchFire(void) {
    if (!dtaBool(@"dingtalkPunchEnabled", NO)) { dtaClearPending(); dtaPushCmd(nil, YES); return; }

    NSInteger setH = 9, setM = 0, setS = 0;
    dtaParseTime(dtaStr(@"dingtalkPunchTime"), &setH, &setM, &setS);

    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *wc = [cal components:NSCalendarUnitWeekday fromDate:[NSDate date]];
    NSString *slot = dtaSlotNow(setH, setM, setS);

    // 写 pending：让钉钉侧点击器（哪怕冷启动）知道该打卡
    dtaWritePending(slot);
    dtaPushCmd(slot, YES);      // 容器命令文件（钉钉沙盒读得到，唯一可靠通路）

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

// ── 指令下发 / 状态回收（SpringBoard 侧）──────────────────────────────────────────
// 每次触发（单击悬浮球 / 立即测试 / 到点）都把「要做什么」写成钉钉容器里的命令文件：
//   钉钉沙盒读不到本插件偏好域，但**必定读得到自己容器里的文件**。
static void dtaPushCmd(NSString *pending, BOOL bumpSeq) {
    if (dtaIsClicker()) return;
    @try {
        NSInteger org = dtaInt(kDTA_OrgKey, 0);
        if (org <= 0) org = 1;
        NSString *entry = dtaStr(kDTA_EntryKey) ?: @"";
        NSDictionary *old = dtaChanLoad(kDTA_ChanCmdName);
        double seq = [old[@"seq"] doubleValue];
        double now = [[NSDate date] timeIntervalSince1970];
        if (bumpSeq || seq <= 0) seq = MAX(now, seq + 0.001);

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"pending"] = pending ?: @"";
        d[@"org"]     = @(org);
        d[@"entry"]   = entry;
        d[@"mode"]    = @(dtaInt(@"dingtalkPunchMode", 2));
        d[@"autoOpen"] = @(dtaBool(kDTA_AutoOpenKey, NO));
        d[@"ts"]      = pending.length ? @(now) : @(0);
        d[@"seq"]     = @(seq);

        BOOL ok = dtaChanSave(kDTA_ChanCmdName, d);
        BOOL alt = dtaMirrorCmdToDingDomain(d);      // 备用通道（写钉钉自己的偏好域）

        // 新指令一下发，立刻把状态文件里的「上一次 ok / done」冲成 cmd-armed，
        // 否则 3s 轮询会在冷启动那十几秒里把这条刚写的 pending 当成已完成而撤掉。
        if (pending.length) {
            @try {
                NSMutableDictionary *sd = [NSMutableDictionary dictionary];
                NSDictionary *oldS = dtaChanLoad(kDTA_ChanStatusName);
                if ([oldS isKindOfClass:[NSDictionary class]]) [sd addEntriesFromDictionary:oldS];
                sd[@"state"] = @"cmd-armed";
                [sd removeObjectForKey:@"done"];   // 不动 ts：心跳时间要真实，不能装作点击器还活着
                dtaChanSave(kDTA_ChanStatusName, sd);
            } @catch (NSException *e) {}
        }
        if (ok) {
            dtaLog(@"📮 已下发指令到钉钉容器：pending=%@ org=%ld entry='%@'%@",
                   pending.length ? pending : @"(空)", (long)org,
                   entry.length ? entry : @"(默认)", alt ? @" (+偏好域备用)" : @"");
        } else if (alt) {
            dtaLog(@"📮 容器不可写，已改走偏好域备用通道：pending=%@ org=%ld entry='%@'",
                   pending.length ? pending : @"(空)", (long)org,
                   entry.length ? entry : @"(默认)");
        } else {
            dtaLog(@"⚠️ 找不到钉钉数据容器，指令下发失败（退回偏好域握手）");
        }
    } @catch (NSException *e) {}
}

// 指令还在执行中时，若用户改了「第几个企业/入口名」，原地更新命令文件（不换 seq，不打断流程）
static void dtaSyncCmdConfig(void) {
    if (dtaIsClicker()) return;
    @try {
        NSDictionary *cmd = dtaChanLoad(kDTA_ChanCmdName);
        NSString *cp = cmd[@"pending"];
        if (![cp isKindOfClass:[NSString class]] || !cp.length) return;
        NSInteger org = dtaInt(kDTA_OrgKey, 0);
        if (org <= 0) org = 1;
        NSString *entry = dtaStr(kDTA_EntryKey) ?: @"";
        NSString *curEntry = cmd[@"entry"];
        if ([cmd[@"org"] integerValue] != org ||
            ![(([curEntry isKindOfClass:[NSString class]] ? curEntry : @"")) isEqualToString:entry]) {
            dtaPushCmd(cp, NO);
        }
    } @catch (NSException *e) {}
}

// 读点击器写回的状态文件 → 转写偏好域，供设置页/悬浮球使用（含版本号，便于确认注入的是新版）
static void dtaPullClickerStatus(void) {
    if (dtaIsClicker()) return;
    @try {
        NSDictionary *st = dtaChanLoad(kDTA_ChanStatusName);
        if (![st isKindOfClass:[NSDictionary class]]) return;
        NSString *state  = st[@"state"];
        NSString *ver    = st[@"ver"];
        NSString *detail = st[@"detail"];
        NSString *done   = st[@"done"];
        double ts = [st[@"ts"] doubleValue];
        if (ts > 0)            dtaSetPrefIfChanged(@"dingtalkClickBeat", [NSString stringWithFormat:@"%.0f", ts]);
        if (ver.length)        dtaSetPrefIfChanged(kDTA_VerKey, ver);
        if (state.length)      dtaSetPrefIfChanged(@"dingtalkClickState", state);
        if (detail.length)     dtaSetPrefIfChanged(kDTA_DetailKey, detail);
        if (done.length >= 10) dtaSetPrefIfChanged(kDTA_DoneKey, done);

        // 企业名称：点击器把名字数组塞在状态文件里（必达），比跨域读偏好可靠得多
        id names = st[@"orgnames"];
        if ([names isKindOfClass:[NSArray class]] && [(NSArray *)names count]) {
            NSString *joined = [(NSArray *)names componentsJoinedByString:@"\n"];
            if (joined.length) dtaSetPrefIfChanged(kDTA_OrgNamesKey, joined);
        }

        if ([state isEqualToString:@"ok"]) {
            // ⚠️ 关键：状态文件会一直留着「上一次 ok」。3s 轮询如果无条件把它当成本次完成，
            //    就会在新指令刚下发 3 秒内把 pending 撤掉 —— 表现是「钉钉刚打开、弹出企业选择后就不动了」。
            //    所以要求：ok 的写入时间必须晚于本条指令的签发时间，并且同一次 ok 只处理一遍。
            NSDictionary *cmd = dtaChanLoad(kDTA_ChanCmdName);
            double cmdTs = [cmd[@"ts"] doubleValue];
            double stTs  = [st[@"ts"] doubleValue];
            double doneTs = [dtaCopyPref(@"dingtalkOkHandledTs") doubleValue];
            BOOL fresh = (stTs > 0 && stTs > doneTs && (cmdTs <= 0 || stTs >= cmdTs));
            if (fresh) {
                dtaSetPref(@"dingtalkOkHandledTs", [NSString stringWithFormat:@"%.0f", stTs]);
                NSString *p = dtaCopyPref(kDTA_PendingKey);
                if (p.length) {
                    dtaSetPref(kDTA_PendingKey, nil);
                    dtaLog(@"🧹 已确认打卡完成，撤销 pending");
                }
                NSString *cp = cmd[@"pending"];
                if ([cp isKindOfClass:[NSString class]] && cp.length) dtaPushCmd(nil, YES);
            }
        }
    } @catch (NSException *e) {}
}

// 把点击侧日志搬进偏好域：设置页的「── 点击侧 (钉钉) ──」终于能显示内容了
static void dtaMirrorClickLog(void) {
    if (dtaIsClicker()) return;
    @try {
        NSString *root = dtaChanRoot();          // <钉钉容器>/Documents/DTA
        if (!root.length) return;
        NSString *container = [[root stringByDeletingLastPathComponent] stringByDeletingLastPathComponent];
        NSString *p = [container stringByAppendingPathComponent:
                       [NSString stringWithFormat:@"Library/Preferences/%@", kDTA_ClickLogName]];
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:NULL];
        if (!s.length) return;
        if (s.length > 8000) s = [s substringFromIndex:s.length - 8000];
        NSString *old = dtaCopyPref(kDTA_DebugClickKey);
        if (![old isEqualToString:s]) dtaSetPref(kDTA_DebugClickKey, s);
    } @catch (NSException *e) {}
}

// 点击器实际使用的企业序号：命令文件优先（钉钉读不到偏好域），偏好域兜底
static NSInteger dtaOrgIndexEffective(void) {
    NSInteger idx = 0;
    if (dtaIsClicker() && dtaCmdFresh(gDTA_Cmd)) idx = [gDTA_Cmd[@"org"] integerValue];
    if (idx <= 0) idx = dtaInt(kDTA_OrgKey, 0);
    if (idx <= 0) idx = 1;
    return idx;
}


// 手动触发一次打卡（立即测试 / 悬浮球单击 共用）：**不受「启用定时打卡」总开关限制**，也不受 done 限制。
// 写 pending + 清 done（允许当天补打/下班卡/重试）+ 拉起钉钉 → 点击器导航到工作台考勤打卡页并自动点击。
static void dtaManualFire(BOOL force) {
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond)
                                 fromDate:[NSDate date]];
    NSString *slot = dtaSlotNow(c.hour, c.minute, c.second);

    // 点击器还活着（近 20s 内有心跳）就不杀进程重启：
    // 钉钉已在考勤页时，点一下悬浮球 3s 内就能再打一次，不用等 20~30s 冷启动。
    if (force) {
        @try {
            double beat = [dtaCopyPref(@"dingtalkClickBeat") doubleValue];
            double age = [[NSDate date] timeIntervalSince1970] - beat;
            if (beat > 0 && age >= 0 && age < 20.0) {
                dtaLog(@"♻️ 点击器存活（%.0fs 前有心跳），不重启钉钉，直接下发指令", age);
                force = NO;
            }
        } @catch (NSException *e) {}
    }

    dispatch_async(dtaLogQueue(), ^{
        @try {
            dtaWritePending(slot);
            dtaSetPref(kDTA_DoneKey, nil);          // 手动触发：允许当天重复打卡（下班卡 / 重试）
            // 关键：把指令写进钉钉容器。点击器一启动/下一拍就能读到。
            dtaPushCmd(slot, YES);
            dtaLog(@"👆 手动触发打卡 槽=%@ force=%@（每次点击都重新执行一遍）", slot, force ? @"Y" : @"N");
            dtaFloatRefresh();                      // done 已清：悬浮球立即回到「打卡」蓝色
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
    UILongPressGestureRecognizer *_long;
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

    // 长按：只打开钉钉，不做任何自动操作（给「自己动手打卡」留一个干净入口）
    _long = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(_onLongPress:)];
    _long.minimumPressDuration = 0.6;
    _long.allowableMovement = 12.0;
    [self addGestureRecognizer:_long];
    // 长按成功时不要再触发单击
    [_tap requireGestureRecognizerToFail:_long];

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

// 单击：立即执行一次「打开钉钉 → 工作台 → 考勤入口 →（多企业）选企业 → 打卡」
// 不受「启用定时打卡」总开关限制，也不受「今日已打卡」限制（每次点都重新跑一遍）。
- (void)_onTap:(UITapGestureRecognizer *)g {
    [self flash];
    dtaLog(@"👆 单击悬浮球 → 立即打卡");
    dtaManualFire(YES);
}

// 长按：只把钉钉打开，什么都不做（用户自己操作）
- (void)_onLongPress:(UILongPressGestureRecognizer *)g {
    if (g.state != UIGestureRecognizerStateBegan) return;
    [self flash];
    dtaLog(@"✋ 长按悬浮球 → 只打开钉钉，不执行任何自动操作");
    dtaLaunchDingTalk(NO);
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
static NSInteger gTabClicks = 0;          // 本次触发已切工作台次数（防止「一直点 Tab」死循环）
static NSInteger gMiniTabTries = 0;       // 小程序底栏「打卡」页切换次数（同样防死循环）
static NSInteger gEntryAttempts = 0;      // 本次触发已点考勤入口次数
static CFAbsoluteTime gLastEntryTap = 0;  // 上次点入口的时间（节流，给跳页留时间）
static CFAbsoluteTime gEnteredAt = 0;     // 成功点进考勤页的时间（宽容期内切 Tab 会把人踢走）
static BOOL gEntryGaveUp = NO;            // 入口点了多次仍无效 → 只记一次日志
static NSDate *gDTA_LastBeat = nil;       // 点击器心跳节流
static NSString *gDTA_LastSkip = nil;     // 上一次「跳过原因」，变化时才写日志
// ── 0.9.24 新增：点完必须验证，不再「点完就报已打卡」 ──────────────────────────
static NSInteger gDTA_VerifyTries = 0;        // 验证已等待的拍数

// 底部 TabBar：钉钉「工作台」是 tab item，sendActions 对它通常无效，必须走 delegate/selectedItem
static UITabBar *dtaFindTabBar(UIView *v) {
    if (!v) return nil;
    if ([v isKindOfClass:[UITabBar class]]) return (UITabBar *)v;
    for (UIView *s in v.subviews) { UITabBar *r = dtaFindTabBar(s); if (r) return r; }
    return nil;
}

static BOOL dtaSwitchTabByController(NSArray<NSString *> *titles);   // 定义在下面（直接改 selectedIndex，最可靠）
static UIWindow *dtaKeyWindowNow(void);                              // 定义在下面
static NSArray<UIWindow *> *dtaAllWindows(void);                     // 定义在下面
static BOOL dtaTapHard(UIView *v);                                   // 定义在下面（多手法硬点）
static BOOL dtaFireTapGestures(UIView *v);                           // 定义在下面（直接调手势 target/action）

// 控件（或其容器）是否处于「已选中」态：已选中就别再点了，
// 否则每 3s 重复点同一个 tab，把每一拍都耗在「切工作台」上，永远走不到点考勤入口那一步。
static BOOL dtaControlIsSelected(UIControl *c) {
    UIView *cur = c;
    NSInteger guard = 0;
    while (cur && guard++ < 6) {
        if ([cur isKindOfClass:[UIControl class]]) {
            UIControl *cc = (UIControl *)cur;
            if (cc.selected || cc.highlighted) return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

// 「已在目标 Tab」这类提示每 3s 会重复出现，只在内容变化时记一次，避免刷屏
static void dtaLogTabOnce(NSString *msg) {
    static NSString *last = nil;
    if (msg.length && ![msg isEqualToString:last ?: @""]) {
        last = [msg copy];
        dtaLog(@"%@", msg);
    }
}

static BOOL dtaTryTabBar(UIView *root, NSArray<NSString *> *titles) {
    // ① 直接改 UITabBarController.selectedIndex（钉钉多数版本仍用它托管底栏，最稳）
    if (dtaSwitchTabByController(titles)) return YES;

    UITabBar *tb = dtaFindTabBar(root);
    if (tb && tb.items.count) {
        for (UITabBarItem *it in tb.items) {
            NSString *t = it.title ?: @"";
            if (!t.length) continue;
            for (NSString *want in titles) {
                if ([t rangeOfString:want].location == NSNotFound) continue;
                if (tb.selectedItem == it) { dtaLogTabOnce([NSString stringWithFormat:@"TabBar 已在 '%@'，无需切换", t]); return NO; }
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

    // ② 兜底：钉钉底栏可能不是 UITabBar（自定义视图），按文字找可点击的 tab 控件
    //    只认屏幕下方 40% 区域里的控件 —— 页面内容区也可能出现「工作台」这几个字。
    CGFloat minY = root.bounds.size.height * 0.55;
    for (NSString *want in titles) {
        NSArray<UIControl *> *arr = dtaControlsMatching(root, want);
        UIControl *pick = nil;
        CGFloat bestY = -1;
        for (UIControl *c in arr) {
            CGRect f = [c convertRect:c.bounds toView:root];
            if (f.origin.y < minY) continue;
            if (f.origin.y > bestY) { bestY = f.origin.y; pick = c; }
        }
        if (!pick) continue;
        if (dtaControlIsSelected(pick)) {
            dtaLogTabOnce([NSString stringWithFormat:@"自定义底栏看起来已在 '%@'（selected=1），不再重复点击", want]);
            return NO;
        }
        if (dtaTapHard(pick)) {
            dtaLog(@"🔀 自定义底栏：已点击 '%@'（%@）", want, NSStringFromClass([pick class]));
            return YES;
        }
    }
    return NO;
}

// 直接切 UITabBarController：不依赖任何点击手法，最可靠的一条路
static BOOL dtaSwitchTabByController(NSArray<NSString *> *titles) {
    NSMutableArray<UIViewController *> *roots = [NSMutableArray array];
    for (UIWindow *w in dtaAllWindows()) {
        if (w.rootViewController) [roots addObject:w.rootViewController];
    }
    if (roots.count == 0) {
        UIWindow *kw = dtaKeyWindowNow();
        if (kw.rootViewController) [roots addObject:kw.rootViewController];
    }
    for (UIViewController *r in roots) {
        UITabBarController *tbc = nil;
        UIViewController *cur = r;
        NSInteger guard = 0;
        while (cur && guard++ < 12 && !tbc) {
            if ([cur isKindOfClass:[UITabBarController class]]) { tbc = (UITabBarController *)cur; break; }
            for (UIViewController *ch in cur.childViewControllers) {
                if ([ch isKindOfClass:[UITabBarController class]]) { tbc = (UITabBarController *)ch; break; }
            }
            cur = cur.presentedViewController;
        }
        if (!tbc) continue;
        NSArray<UIViewController *> *vcs = tbc.viewControllers;
        for (NSUInteger i = 0; i < vcs.count; i++) {
            UIViewController *vc = vcs[i];
            NSString *t = vc.tabBarItem.title ?: vc.title ?: @"";
            if (!t.length) continue;
            for (NSString *want in titles) {
                if ([t rangeOfString:want].location == NSNotFound) continue;
                if (tbc.selectedIndex == (NSInteger)i) {
                    dtaLogTabOnce([NSString stringWithFormat:@"TabController 已在 '%@'(index=%lu)，无需切换", t, (unsigned long)i]);
                    return NO;
                }
                @try {
                    tbc.selectedIndex = (NSInteger)i;
                    dtaLog(@"🔀 TabController 已切到 '%@' (index=%lu)", t, (unsigned long)i);
                    return YES;
                } @catch (NSException *e) {}
            }
        }
    }
    return NO;
}

// ── 通用「点击一个视图」：多套手法递进，直到真的点下去 ────────────────────────────────
// 钉钉的入口/按钮形态随版本变化很大：UIControl、cell、纯 UIView + 手势、纯文字。
// 只走 sendActions 会「找到但点不动」，所以这里按可靠性从高到低逐个尝试。
static BOOL dtaTapHard(UIView *v) {
    if (!v) return NO;
    if ([v isKindOfClass:[UIControl class]]) {
        UIControl *c = (UIControl *)v;
        BOOL hasTargets = (c.allTargets.count > 0);
        dtaClick(c);
        if (hasTargets) return YES;
        // 0.9.27：钉钉的自定义底栏（DTUIIconTitleButton）压根没有 target/action，
        // sendActions 发出去等于白点 —— 日志里就是这样「已点击 '工作台'」5 次却纹丝不动。
        // 这种情况继续用手势 / 位置点击兜底。
        dtaLog(@"⚠️ %@ 没有 target/action → 改用位置点击", NSStringFromClass([c class]));
    }

    // 1) cell：走 delegate 的 didSelect（工作台图标最常见）
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
                return YES;
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
                return YES;
            }
        }
    }

    // 1.5) 位置点击：中心点上真正接手势的往往是另一个子视图（自定义底栏就是这样）
    if (v.window && v.bounds.size.width > 2 && v.bounds.size.height > 2) {
        CGPoint p = [v convertPoint:CGPointMake(CGRectGetMidX(v.bounds), CGRectGetMidY(v.bounds))
                              toView:v.window];
        UIView *hit = nil;
        @try { hit = [v.window hitTest:p withEvent:nil]; } @catch (NSException *e) {}
        if (hit && hit != v && ([hit isDescendantOfView:v] || [v isDescendantOfView:hit])) {
            UIView *h = hit;
            NSInteger hd = 0;
            while (h && hd++ < 8) {
                if (dtaFireTapGestures(h)) {
                    dtaLog(@"🖐 位置命中的手势已触发(%@ ← %@)", NSStringFromClass([h class]), NSStringFromClass([v class]));
                    return YES;
                }
                if ([h isKindOfClass:[UIControl class]] && ((UIControl *)h).allTargets.count > 0) {
                    dtaClick((UIControl *)h);
                    return YES;
                }
                h = h.superview;
            }
        }
    }

    // 2) 手势：视图自身 + 最近 8 层祖先（自定义 tile 常把单击挂在 label 上）
    UIView *g = v;
    NSInteger gd = 0;
    while (g && gd++ < 14) {
        if (dtaFireTapGestures(g)) {
            dtaLog(@"🖐 手势 target/action 已触发(%@)", NSStringFromClass([g class]));
            return YES;
        }
        g = g.superview;
    }

    // 3) 无障碍激活：对开了 accessibilityTraits 的自定义控件有效
    UIView *a = v;
    NSInteger ad = 0;
    while (a && ad++ < 14) {
        @try {
            if ([a respondsToSelector:@selector(accessibilityActivate)] && [a accessibilityActivate]) {
                dtaLog(@"♿ accessibilityActivate 已触发(%@)", NSStringFromClass([a class]));
                return YES;
            }
        } @catch (NSException *e) {}
        a = a.superview;
    }

    // 4) 兜底：任意祖先里的 UIControl
    UIControl *c = dtaAncestorControl(v);
    if (c) { dtaClick(c); return YES; }

    dtaLog(@"❌ 点不动 %@ 祖先=%@", NSStringFromClass([v class]), dtaAncestorChain(v));
    return NO;
}

static void dtaTapView(UIView *v) {
    dtaTapHard(v);
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

// 顶层可见控制器（用于日志：到底停在哪一页）
static UIViewController *dtaTopViewController(void) {
    UIWindow *kw = dtaKeyWindowNow();
    UIViewController *vc = kw.rootViewController;
    NSInteger guard = 0;
    while (vc && guard++ < 20) {
        UIViewController *next = vc.presentedViewController;
        if (!next) {
            if ([vc isKindOfClass:[UINavigationController class]]) {
                next = ((UINavigationController *)vc).topViewController;
            } else if ([vc isKindOfClass:[UITabBarController class]]) {
                next = ((UITabBarController *)vc).selectedViewController;
            } else if (vc.childViewControllers.count) {
                next = vc.childViewControllers.lastObject;
            }
        }
        if (!next || next == vc) break;
        vc = next;
    }
    return vc;
}

static void dtaCollectShortText(UIView *v, NSMutableArray<NSString *> *out, NSInteger depth) {
    if (!v || depth > 40 || out.count >= 14 || v.hidden || v.alpha < 0.02) return;
    if ([v isKindOfClass:[UILabel class]]) {
        UILabel *l = (UILabel *)v;
        NSString *t = [l.text stringByTrimmingCharactersInSet:
                       [NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (t.length >= 2 && t.length <= 14 && dtaViewOnScreen(l)) [out addObject:t];
        return;
    }
    for (UIView *s in v.subviews) dtaCollectShortText(s, out, depth + 1);
}

// 页面快照：出问题时把「当前 VC + 屏幕上的文字」打进日志，
// 下次不用再猜「到底卡在哪一页」。
static void dtaLogPageSnapshot(NSString *why) {
    @try {
        NSMutableArray<NSString *> *texts = [NSMutableArray array];
        UIWindow *kw = dtaKeyWindowNow();
        if (kw) dtaCollectShortText(kw, texts, 0);
        dtaLog(@"📄 %@ 页面快照: VC=%@ 文字=[%@]",
               why ?: @"", NSStringFromClass([dtaTopViewController() class]),
               [texts componentsJoinedByString:@" | "]);
    } @catch (NSException *e) {}
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

// ── 行识别：把「企业列表里的一行」找出来 ─────────────────────────────────────────
// 钉钉不同版本的「选择打卡企业」结构差别极大：UITableViewCell / UICollectionViewCell /
// 自定义 UIControl / 纯 UIView 挂手势 / H5。只用一种收集方式一定会「找不到行」。
static BOOL dtaSubtreeHasText(UIView *v, NSInteger depth) {
    if (!v || depth > 12) return NO;
    if ([v isKindOfClass:[UILabel class]] && [(UILabel *)v text].length) return YES;
    if ([v isKindOfClass:[UIButton class]]) {
        UIButton *b = (UIButton *)v;
        if ((b.currentTitle ?: [b titleForState:UIControlStateNormal]).length) return YES;
    }
    if (v.accessibilityLabel.length) return YES;
    for (UIView *s in v.subviews) {
        if (dtaSubtreeHasText(s, depth + 1)) return YES;
    }
    return NO;
}

static BOOL dtaRowFrameOK(UIView *v, UIWindow *win, CGFloat minY) {
    CGRect f = [v convertRect:v.bounds toView:win];
    if (f.size.height < 36.0 || f.size.height > 220.0) return NO;
    if (f.size.width < win.bounds.size.width * 0.5) return NO;
    if (f.origin.y < minY - 4.0) return NO;
    return YES;
}

static void dtaCollectRowCandidates(UIView *v, UIWindow *win, CGFloat minY,
                                    NSMutableArray<UIView *> *out, NSInteger depth) {
    if (!v || depth > 28) return;
    if (v.hidden || v.alpha < 0.02) return;
    if (!dtaViewOnScreen(v)) return;
    BOOL isCell = [v isKindOfClass:[UITableViewCell class]] || [v isKindOfClass:[UICollectionViewCell class]];
    BOOL isCtl  = [v isKindOfClass:[UIControl class]];
    BOOL hasG   = v.gestureRecognizers.count > 0;
    if ((isCell || isCtl || hasG) && dtaRowFrameOK(v, win, minY) && dtaSubtreeHasText(v, 0)) {
        [out addObject:v];
        if (isCell) return;      // cell 内部不再深入，避免同一个 cell 被算成多行
    }
    for (UIView *s in v.subviews) dtaCollectRowCandidates(s, win, minY, out, depth + 1);
}

// 候选去重 + 去掉「容器」：一个视图里装着 2 个以上候选，说明它是列表容器而不是一行。
// ⚠️ 这一步是「按第 N 个选企业」能对准的关键：容器若混进来，行号会整体错位。
static void dtaFilterRows(NSMutableArray<UIView *> *rows, UIWindow *win) {
    if (rows.count <= 1) return;
    NSMutableArray<UIView *> *containers = [NSMutableArray array];
    for (UIView *a in rows) {
        CGRect fa = [a convertRect:a.bounds toView:win];
        NSInteger inside = 0;
        for (UIView *b in rows) {
            if (a == b) continue;
            CGRect fb = [b convertRect:b.bounds toView:win];
            if (CGRectContainsRect(CGRectInset(fa, 2.0, 2.0), fb)) inside++;
        }
        if (inside >= 2) [containers addObject:a];
    }
    NSMutableArray<UIView *> *rest = [NSMutableArray array];
    for (UIView *v in rows) {
        if (![containers containsObject:v]) [rest addObject:v];
    }
    // 同一行被「外层包一层」重复收集时，只留最外层的那一个
    NSMutableArray<UIView *> *keep = [NSMutableArray array];
    for (UIView *v in rest) {
        CGRect f = [v convertRect:v.bounds toView:win];
        BOOL dup = NO;
        for (UIView *k in keep) {
            CGRect kf = [k convertRect:k.bounds toView:win];
            if (fabs(CGRectGetMinY(f) - CGRectGetMinY(kf)) < 6.0 &&
                fabs(CGRectGetHeight(f) - CGRectGetHeight(kf)) < 8.0) { dup = YES; break; }
            if (CGRectContainsRect(CGRectInset(kf, -4.0, -4.0), f) &&
                CGRectGetHeight(f) <= CGRectGetHeight(kf) + 4.0) { dup = YES; break; }
        }
        if (!dup) [keep addObject:v];
    }
    [keep sortUsingComparator:^NSComparisonResult(UIView *a, UIView *b) {
        CGFloat ya = [a convertRect:a.bounds toView:win].origin.y;
        CGFloat yb = [b convertRect:b.bounds toView:win].origin.y;
        if (ya < yb) return NSOrderedAscending;
        if (ya > yb) return NSOrderedDescending;
        return NSOrderedSame;
    }];
    [rows setArray:keep];
}

// 只在「看得见」的 label 里找标题（页面里常留着上一页的离屏文字，否则会锚错位置）
static UILabel *dtaFindVisibleLabelAny(UIView *v, NSArray<NSString *> *kws, NSInteger depth) {
    if (!v || depth > 80) return nil;
    if ([v isKindOfClass:[UILabel class]]) {
        NSString *t = [(UILabel *)v text];
        if (t.length > 0 && t.length <= 40 && dtaViewOnScreen((UILabel *)v)) {
            for (NSString *k in kws) {
                if ([t rangeOfString:k].location != NSNotFound) return (UILabel *)v;
            }
        }
    }
    for (UIView *s in v.subviews) {
        UILabel *r = dtaFindVisibleLabelAny(s, kws, depth + 1);
        if (r) return r;
    }
    return nil;
}

// 行是否与标题在「同一个容器」里。
// ⚠️ 弹层下面还压着工作台页面，那些 cell 的 y 也可能在标题之下；不加这一层会把背景内容数进企业列表，
//    表现就是「按第2个选」却点到了背后的卡片。
static BOOL dtaSharesSubtree(UIView *row, UIView *anchor, UIWindow *win) {
    if (!row || !anchor) return NO;
    NSMutableArray<UIView *> *chain = [NSMutableArray array];
    UIView *c = anchor;
    NSInteger g = 0;
    while (c && c != win && g++ < 20) { [chain addObject:c]; c = c.superview; }
    UIView *r = row;
    g = 0;
    while (r && r != win && g++ < 24) {
        if ([chain containsObject:r]) return YES;
        r = r.superview;
    }
    return NO;
}

static NSMutableArray<UIView *> *dtaFindOrgRows(UIWindow *win, CGFloat minY, UIView *anchor) {
    NSMutableArray<UIView *> *rows = [NSMutableArray array];
    NSMutableArray<UIView *> *all = [NSMutableArray array];
    dtaCollectCells(win, all);
    for (UIView *v in all) {
        CGRect f = [v convertRect:v.bounds toView:win];
        if (f.origin.y < minY - 4.0) continue;
        if (f.size.height < 30.0) continue;
        if (![rows containsObject:v]) [rows addObject:v];
    }
    if (rows.count < 2) {
        NSMutableArray<UIView *> *cand = [NSMutableArray array];
        dtaCollectRowCandidates(win, win, minY, cand, 0);
        for (UIView *v in cand) {
            if (![rows containsObject:v]) [rows addObject:v];
        }
    }
    if (anchor && rows.count > 0) {
        NSMutableArray<UIView *> *same = [NSMutableArray array];
        for (UIView *v in rows) {
            if (dtaSharesSubtree(v, anchor, win)) [same addObject:v];
        }
        if (same.count > 0) [rows setArray:same];
    }
    dtaFilterRows(rows, win);
    NSMutableArray<UIView *> *clean = [NSMutableArray array];
    for (UIView *v in rows) {
        if (!dtaRowIsCancel(v)) [clean addObject:v];
    }
    if (clean.count > 0) [rows setArray:clean];
    return rows;
}

// 弹层是否是「模态」：有 presented 控制器，或挂在普通 window 之上（浮层 window）
static BOOL dtaWindowIsModal(UIWindow *w) {
    if (!w) return NO;
    if (w.windowLevel > UIWindowLevelNormal) return YES;
    UIViewController *vc = w.rootViewController;
    NSInteger g = 0;
    while (vc && g++ < 12) {
        if (vc.presentedViewController) return YES;
        vc = vc.childViewControllers.lastObject;
    }
    return NO;
}

// 文字像不像公司名（用于「没有标题也没有取消按钮」的企业列表识别）
static BOOL dtaLooksLikeCompanyName(NSString *t) {
    if (t.length < 4) return NO;
    for (NSString *w in @[@"有限公司", @"有限责任公司", @"集团", @"公司", @"工作室",
                          @"事务所", @"研究院", @"大学", @"分公司", @"子公司"]) {
        if ([t rangeOfString:w].location != NSNotFound) return YES;
    }
    return NO;
}

// 只找「点得到」的文字（被弹层/考勤页盖住的不算）——诊断用，避免把后台页面的公司名当弹层
static UILabel *dtaFindHittableLabelAny(UIWindow *w, NSArray<NSString *> *kws) {
    if (!w) return nil;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
    NSInteger visited = 0;
    while (stack.count > 0 && visited < 900) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        visited++;
        if ([v isKindOfClass:[UILabel class]]) {
            UILabel *l = (UILabel *)v;
            NSString *t = l.text ?: @"";
            if (t.length >= 2 && t.length <= 40) {
                for (NSString *k in kws) {
                    if ([t rangeOfString:k].location != NSNotFound) {
                        if (dtaViewIsHittable(l)) return l;
                        break;
                    }
                }
            }
            continue;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return nil;
}

// 当前是不是「消息列表」页。消息列表里也会出现带「公司/集团」字样的群名，
// 绝不能被当成「选择打卡企业」的列表（否则会点开一个聊天）。
static BOOL dtaLooksLikeConversationList(UIWindow *w) {
    if (!w) return NO;
    NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
    NSInteger visited = 0;
    while (stack.count > 0 && visited < 600) {
        UIView *v = stack.lastObject;
        [stack removeLastObject];
        visited++;
        NSString *cls = NSStringFromClass([v class]);
        if ([cls rangeOfString:@"ConversationCell"].location != NSNotFound
            || [cls rangeOfString:@"ConversationTitleLabel"].location != NSNotFound) {
            if (dtaViewOnScreen(v)) return YES;
        }
        for (UIView *s in v.subviews) [stack addObject:s];
    }
    return NO;
}

static void dtaCollectControls(UIView *v, NSMutableArray<UIControl *> *out, NSInteger depth) {
    if (!v || depth > 10) return;
    if (!dtaViewOnScreen(v)) return;
    if ([v isKindOfClass:[UIControl class]]) [out addObject:(UIControl *)v];
    for (UIView *s in v.subviews) dtaCollectControls(s, out, depth + 1);
}

static BOOL dtaAccessibilityDeep(UIView *v, NSInteger depth) {
    if (!v || depth > 8) return NO;
    @try {
        if (v.isAccessibilityElement && [v respondsToSelector:@selector(accessibilityActivate)]) {
            if ([v accessibilityActivate]) return YES;
        }
    } @catch (NSException *e) {}
    for (UIView *s in v.subviews) {
        if (dtaAccessibilityDeep(s, depth + 1)) return YES;
    }
    return NO;
}

// 表格/集合：除了 delegate，还要真正 select 一下（部分钉钉弹层只认 selectRow）
static BOOL dtaSelectCellHard(UIView *row) {
    UIView *cur = row;
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
        UITableView *tv = (UITableView *)sv;
        if (!tv) return NO;
        NSIndexPath *ip = [tv indexPathForCell:cell];
        if (!ip) return NO;
        @try { [tv selectRowAtIndexPath:ip animated:NO scrollPosition:UITableViewScrollPositionNone]; } @catch (NSException *e) {}
        id del = tv.delegate;
        SEL s = @selector(tableView:didSelectRowAtIndexPath:);
        if (del && [del respondsToSelector:s]) {
            [del performSelector:s withObject:tv withObject:ip];
            dtaLog(@"📋 tableView:didSelectRow 已调（第 %ld 行）", (long)ip.row);
            return YES;
        }
        return NO;
    }
    if ([cur isKindOfClass:[UICollectionViewCell class]]) {
        UICollectionViewCell *cell = (UICollectionViewCell *)cur;
        UIView *sv = cell.superview;
        while (sv && ![sv isKindOfClass:[UICollectionView class]]) sv = sv.superview;
        UICollectionView *cv = (UICollectionView *)sv;
        if (!cv) return NO;
        NSIndexPath *ip = [cv indexPathForCell:cell];
        if (!ip) return NO;
        @try { [cv selectItemAtIndexPath:ip animated:NO scrollPosition:UICollectionViewScrollPositionNone]; } @catch (NSException *e) {}
        id del = cv.delegate;
        SEL s = @selector(collectionView:didSelectItemAtIndexPath:);
        if (del && [del respondsToSelector:s]) {
            [del performSelector:s withObject:cv withObject:ip];
            dtaLog(@"📋 collectionView:didSelectItem 已调（第 %ld 项）", (long)ip.item);
            return YES;
        }
        return NO;
    }
    return NO;
}

// 点一行：多种手法轮流上（每次重试换一种），总有一种能点动钉钉的自定义行
static BOOL dtaTapRowHard(UIView *row, NSInteger attempt) {
    if (!row) return NO;
    UIWindow *win = row.window;
    switch (attempt % 6) {
        case 0:
            return dtaTapHard(row);
        case 1: {
            if (dtaFireTapGesturesDeep(row, 0)) { dtaLog(@"🖐 手势 target/action 已触发"); return YES; }
            return dtaTapHard(row);
        }
        case 2: {
            if (win) {
                CGPoint c = [row convertPoint:CGPointMake(CGRectGetMidX(row.bounds),
                                                          CGRectGetMidY(row.bounds)) toView:win];
                UIView *hit = [win hitTest:c withEvent:nil];
                if (hit && hit != row && dtaTapHard(hit)) {
                    dtaLog(@"🎯 命中点硬点成功(%@)", NSStringFromClass([hit class]));
                    return YES;
                }
            }
            return dtaTapHard(row);
        }
        case 3: {
            NSMutableArray<UIControl *> *ctls = [NSMutableArray array];
            dtaCollectControls(row, ctls, 0);
            for (UIControl *c in ctls) {
                @try {
                    [c sendActionsForControlEvents:UIControlEventTouchDown];
                    [c sendActionsForControlEvents:UIControlEventTouchUpInside];
                } @catch (NSException *e) {}
            }
            if (ctls.count) {
                dtaLog(@"👆 已对行内 %lu 个控件发 down+up", (unsigned long)ctls.count);
                return YES;
            }
            return dtaTapHard(row);
        }
        case 4: {
            if (dtaAccessibilityDeep(row, 0)) { dtaLog(@"♿ accessibilityActivate 已触发"); return YES; }
            return dtaTapHard(row);
        }
        default: {
            if (dtaSelectCellHard(row)) return YES;
            return dtaTapHard(row);
        }
    }
}

// 弹层里若有「确定/进入/下一步」，光选中不生效的情况下再点它一下
static BOOL dtaTapSheetConfirm(UIWindow *win, CGFloat minY) {
    NSArray<NSString *> *kws = @[@"确定", @"确认", @"进入", @"下一步", @"立即进入"];
    for (NSString *k in kws) {
        UILabel *l = dtaFindLabelAny(win, @[k], 0);
        if (!l) continue;
        if (!dtaViewOnScreen(l)) continue;
        CGRect f = [l convertRect:l.bounds toView:win];
        if (f.origin.y < minY - 4.0) continue;
        UIControl *c = dtaAncestorControl(l);
        if (c) { dtaTapHard(c); dtaLog(@"🆗 已点弹层「%@」按钮", k); return YES; }
        if (dtaTapHard(l)) { dtaLog(@"🆗 已点弹层「%@」文字", k); return YES; }
    }
    return NO;
}

// 弹层没法按控件点（例如整块是 H5）时，用 JS 按序号点第 N 个可点条目
static void dtaOrgWebPick(UIWindow *win, NSInteger idx, NSString *name) {
    id web = dtaFindWebView(win);
    if (!web) { dtaLog(@"🏢 弹层内没有 WebView，JS 方案跳过"); return; }
    NSString *js = [NSString stringWithFormat:
        @"(function(){var idx=%ld;var name=%@;var out=[];"
        @"var all=document.querySelectorAll('li,[role=radio],[role=option],[class*=item],[class*=cell],[class*=row]');"
        @"for(var i=0;i<all.length;i++){var e=all[i];if(!e.offsetParent)continue;"
        @"var r=e.getBoundingClientRect();if(r.height<30||r.width<100)continue;"
        @"var t=(e.textContent||'').trim();if(!t||t.length>40)continue;out.push(e);}"
        @"if(!out.length)return 'norow';"
        @"var pick=out[Math.min(idx,out.length)-1];"
        @"if(name&&name.length){for(var k=0;k<out.length;k++){if((out[k].textContent||'').indexOf(name)>=0){pick=out[k];break;}}}"
        @"try{pick.click();}catch(x){}"
        @"var n=pick;for(var m=0;m<3&&n;m++){try{n.click();}catch(x){}n=n.parentElement;}"
        @"return 'clicked:'+(pick.textContent||'').trim().substring(0,20);})()",
        (long)MAX(idx, 1),
        [NSString stringWithFormat:@"'%@'", name.length ? name : @""]];
    SEL sel = NSSelectorFromString(@"evaluateJavaScript:completionHandler:");
    if (sel && [web respondsToSelector:sel]) {
        @try {
            [web performSelector:sel withObject:js withObject:^(id res, id err){
                dtaLog(@"🏢 弹层 JS 结果=%@ err=%@", res, err);
            }];
            dtaLog(@"🏢 弹层改为 JS 点选第 %ld 个", (long)MAX(idx, 1));
        } @catch (NSException *e) { dtaLog(@"弹层 JS 异常: %@", e); }
    }
}

// 弹层结构快照：点不动时把整棵子树（类名+坐标+文字+手势数）打进日志，
// 下次不用再猜「它到底是什么控件」。
static void dtaLogSheetDump(UIWindow *win, NSString *why) {
    @try {
        if (!win) return;
        NSMutableArray<NSString *> *lines = [NSMutableArray array];
        NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:win];
        NSInteger visited = 0;
        while (stack.count > 0 && visited < 100) {
            UIView *v = stack.lastObject;
            [stack removeLastObject];
            visited++;
            NSString *txt = @"";
            if ([v isKindOfClass:[UILabel class]]) txt = [(UILabel *)v text] ?: @"";
            else if ([v isKindOfClass:[UIButton class]]) {
                UIButton *b = (UIButton *)v;
                txt = b.currentTitle ?: [b titleForState:UIControlStateNormal] ?: @"";
            }
            if (!txt.length && v.accessibilityLabel.length) txt = v.accessibilityLabel;
            if (txt.length > 18) txt = [txt substringToIndex:18];
            CGRect f = [v convertRect:v.bounds toView:win];
            NSString *g = v.gestureRecognizers.count
                ? [NSString stringWithFormat:@" g%lu", (unsigned long)v.gestureRecognizers.count] : @"";
            [lines addObject:[NSString stringWithFormat:@"%@(%.0f,%.0f,%.0f,%.0f)%@%@",
                              NSStringFromClass([v class]),
                              f.origin.x, f.origin.y, f.size.width, f.size.height, g,
                              txt.length ? [NSString stringWithFormat:@" 「%@」", txt] : @""]];
            NSArray<UIView *> *subs = v.subviews;
            for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) [stack addObject:subs[i]];
        }
        dtaLog(@"🧾 %@ 弹层结构(%lu 个视图)：\n%@", why ?: @"", (unsigned long)visited,
               [lines componentsJoinedByString:@"\n"]);
    } @catch (NSException *e) {}
}

static BOOL dtaPickOrgIfNeeded(void) {
    @try {
        NSArray<UIWindow *> *wins = dtaAllWindows();
        if (wins.count == 0) return NO;

        // ⚠️ 已经在考勤小程序里时，屏幕上的公司名是「页面标题」，不是「选择企业」弹层。
        //    0.9.24 日志里每一拍都打了 100 个视图的结构快照（刷屏 + 拖慢），就是这里误判。
        UIWindow *kwn = dtaKeyWindowNow();
        if (kwn && dtaLooksLikeMiniAppPage(kwn)) {
            static CFAbsoluteTime lastSkip = 0;
            if (CFAbsoluteTimeGetCurrent() - lastSkip > 60.0) {
                lastSkip = CFAbsoluteTimeGetCurrent();
                dtaLog(@"🏢 已在考勤小程序内（底栏=打卡/设置/统计）→ 不再找「选择企业」弹层");
            }
            gDTA_OrgAttempts = 0;
            gDTA_OrgSig = nil;
            return NO;
        }

        UIWindow *win = nil;
        UILabel *titleL = nil;
        CGFloat minY = 0;

        // 1) 先用标题认弹层（文案各版本略有差异）
        NSArray<NSString *> *titles = @[@"选择打卡企业", @"选择考勤企业", @"选择打卡公司",
                                        @"选择企业", @"选择组织", @"选择团队", @"切换企业",
                                        @"切换组织", @"请选择企业", @"请选择打卡"];
        for (UIWindow *w in wins) {
            UILabel *l = dtaFindVisibleLabelAny(w, titles, 0);
            if (!l) continue;
            win = w;
            titleL = l;
            minY = CGRectGetMaxY([l convertRect:l.bounds toView:w]) + 2.0;
            break;
        }

        NSMutableArray<UIView *> *rows = nil;

        // 2) 标题认不出来时按「结构」认：模态/浮层窗口 + 含「企业/组织/公司」字样 + 2~12 行
        if (!win) {
            for (UIWindow *w in [wins reverseObjectEnumerator]) {
                if (!dtaWindowIsModal(w)) continue;
                // 取 y 最小的那个 label 当标题（企业名本身也可能带「企业」二字，标题一定在上面）
                UILabel *best = nil;
                CGFloat bestY = CGFLOAT_MAX;
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
                NSInteger visited = 0;
                while (stack.count > 0 && visited < 400) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    visited++;
                    if ([v isKindOfClass:[UILabel class]]) {
                        UILabel *l = (UILabel *)v;
                        NSString *t = l.text ?: @"";
                        if (t.length >= 2 && t.length <= 40 && dtaViewOnScreen(l)) {
                            BOOL hit = NO;
                            for (NSString *k in @[@"企业", @"组织", @"公司"]) {
                                if ([t rangeOfString:k].location != NSNotFound) { hit = YES; break; }
                            }
                            if (hit) {
                                CGFloat y = [l convertRect:l.bounds toView:w].origin.y;
                                if (y < bestY && y < w.bounds.size.height * 0.8) { bestY = y; best = l; }
                            }
                        }
                    }
                    for (UIView *s in v.subviews) [stack addObject:s];
                }
                if (!best) continue;
                CGFloat y = CGRectGetMaxY([best convertRect:best.bounds toView:w]) + 2.0;
                NSMutableArray<UIView *> *probe = dtaFindOrgRows(w, y, best);
                if (probe.count < 2 || probe.count > 12) continue;
                win = w;
                titleL = best;
                minY = y;
                rows = probe;
                dtaLog(@"🏢 按结构认出企业弹层（无标题匹配，锚点=「%@」）", best.text);
                break;
            }
        }

        // 2.5) 最后一层兜底：标题既不匹配、窗口也不算模态（弹层是直接盖在页面上的自定义视图）时，
        //      用「取消」按钮所在容器定位：同容器里 2~8 行、且这些行都有人眼可见的文字，就当成企业列表。
        if (!win) {
            for (UIWindow *w in [wins reverseObjectEnumerator]) {
                UILabel *cancel = dtaFindVisibleLabelAny(w, @[@"取消"], 0);
                if (!cancel) continue;
                UIView *anchorView = cancel.superview ?: cancel;
                NSMutableArray<UIView *> *probe = dtaFindOrgRows(w, 0, anchorView);
                if (probe.count < 2 || probe.count > 8) continue;
                win = w;
                titleL = cancel;
                minY = 0;
                rows = probe;
                dtaLog(@"🏢 按结构认出企业弹层（用「取消」定位，共 %lu 行）", (unsigned long)probe.count);
                break;
            }
        }

        // 2.6) 0.9.24 新增：没有标题、没有「取消」、窗口也不算模态时（企业列表就是直接盖在页面上的
        //      自定义列表，钉钉某些版本就是这样），直接按「屏幕上能点到、且像公司名的文字」认列表：
        //      ≥2 行、纵向排列 → 就是「选择打卡企业」。
        //      ⚠️ 一定要求「点得到」(hitTest 命中)，否则会把后台页面/小程序顶栏里的公司名当成企业行。
        if (!win) {
            for (UIWindow *w in [wins reverseObjectEnumerator]) {
                if (dtaLooksLikeConversationList(w)) continue;   // 消息列表里的群名不是企业行
                NSMutableArray<UILabel *> *nameLs = [NSMutableArray array];
                NSMutableArray<UIView *> *stack = [NSMutableArray arrayWithObject:w];
                NSInteger visited = 0;
                while (stack.count > 0 && visited < 1200) {
                    UIView *v = stack.lastObject;
                    [stack removeLastObject];
                    visited++;
                    if ([v isKindOfClass:[UILabel class]]) {
                        UILabel *l = (UILabel *)v;
                        NSString *t = l.text ?: @"";
                        if (t.length >= 4 && t.length <= 40 && dtaLooksLikeCompanyName(t)
                            && !dtaInChromeBar(l) && dtaViewIsHittable(l)) {
                            [nameLs addObject:l];
                        }
                        continue;
                    }
                    for (UIView *s in v.subviews) [stack addObject:s];
                }
                if (nameLs.count < 2 || nameLs.count > 8) continue;
                [nameLs sortUsingComparator:^NSComparisonResult(UILabel *a, UILabel *b) {
                    CGFloat ya = [a convertRect:a.bounds toView:w].origin.y;
                    CGFloat yb = [b convertRect:b.bounds toView:w].origin.y;
                    if (ya < yb) return NSOrderedAscending;
                    if (ya > yb) return NSOrderedDescending;
                    return NSOrderedSame;
                }];
                NSMutableArray<UIView *> *rows2 = [NSMutableArray array];
                CGFloat lastY = -10000;
                for (UILabel *l in nameLs) {
                    CGFloat y = [l convertRect:l.bounds toView:w].origin.y;
                    if (fabs(y - lastY) < 6.0) continue;      // 同一行里的两段文字，只算一行
                    lastY = y;
                    UIView *row = l;
                    UIView *cur = l.superview;
                    NSInteger g2 = 0;
                    while (cur && g2++ < 8) {
                        if ([cur isKindOfClass:[UITableViewCell class]]
                            || [cur isKindOfClass:[UICollectionViewCell class]]) { row = cur; break; }
                        cur = cur.superview;
                    }
                    if (![rows2 containsObject:row]) [rows2 addObject:row];
                }
                if (rows2.count < 2 || rows2.count > 8) continue;
                win = w;
                titleL = nameLs.firstObject;
                minY = 0;
                rows = rows2;
                dtaLog(@"🏢 按「公司名列表」认出企业弹层（共 %lu 行，无标题/无取消/非模态窗口）",
                       (unsigned long)rows2.count);
                break;
            }
        }

        if (!win) {
            // 没认出来，但屏幕上确实有「企业/组织/公司」字样 → 留一份结构快照（20s 最多一次），
            // 这样下次适配不用再靠猜。
            // ⚠️ 只认「点得到」的文字：否则后台页面/小程序顶栏里的公司名会把我们引到错误的结构上。
            static CFAbsoluteTime lastDiag = 0;
            CFAbsoluteTime tDiag = CFAbsoluteTimeGetCurrent();
            if (tDiag - lastDiag > 20.0) {
                for (UIWindow *w in [wins reverseObjectEnumerator]) {
                    UILabel *l = dtaFindHittableLabelAny(w, @[@"企业", @"组织", @"公司"]);
                    if (!l) continue;
                    lastDiag = tDiag;
                    dtaLog(@"🏢 屏幕上有「%@」但没认成企业弹层（窗口=%lu level=%.0f）→ 打印结构",
                           l.text, (unsigned long)wins.count, w.windowLevel);
                    dtaLogSheetDump(w, @"疑似企业弹层未识别");
                    break;
                }
            }
            gDTA_OrgAttempts = 0;
            gDTA_OrgSig = nil;
            return NO;
        }

        // 3) 只取标题下方的元素：标题以上是底层页面（工作台图标等），不能算进企业列表
        NSInteger idx = dtaOrgIndexEffective();          // 0=默认=第1个；1..5=第N个
        if (!rows) rows = dtaFindOrgRows(win, minY, titleL);

        if (rows.count == 0) {
            if (![gDTA_OrgSig isEqualToString:@"norow"]) {
                gDTA_OrgSig = @"norow";
                dtaLog(@"🏢 检测到「%@」弹层，但没扫到可点行（窗口=%lu）",
                       titleL.text, (unsigned long)wins.count);
                dtaLogSheetDump(win, @"没扫到企业行");
                dtaClickState(@"org-norow");
            }
            dtaOrgWebPick(win, idx, nil);   // 可能是 H5 弹层
            return YES;
        }

        // 4) 换了一个弹层（标题/行数变了）就重置重试计数，并把每行文字记下来
        NSString *sig = [NSString stringWithFormat:@"%@#%lu", titleL.text, (unsigned long)rows.count];
        if (![sig isEqualToString:gDTA_OrgSig ?: @""]) {
            gDTA_OrgSig = sig;
            gDTA_OrgAttempts = 0;
            gDTA_LastOrgPick = 0;
            NSMutableArray<NSString *> *names = [NSMutableArray array];
            for (NSUInteger i = 0; i < rows.count; i++) {
                NSString *full = dtaRowPrimaryText(rows[i]);
                NSString *show = full.length > 20 ? [full substringToIndex:20] : full;
                dtaLog(@"🏢 行%lu: %@ <%@>", (unsigned long)(i + 1),
                       show.length ? show : @"(无文字)", [rows[i] class]);
                // 每行都必须占一个位置（取不到文字就用「第N个」占位），否则名称与行号错位
                if (full.length >= 2 && full.length <= 40) {
                    [names addObject:full];
                } else {
                    [names addObject:[NSString stringWithFormat:@"第%lu个", (unsigned long)(i + 1)]];
                }
            }
            NSMutableArray<NSString *> *wl = [NSMutableArray array];
            for (UIWindow *w in wins) {
                [wl addObject:[NSString stringWithFormat:@"%.0f/%@", w.windowLevel, NSStringFromClass([w class])]];
            }
            dtaLog(@"🏢 窗口清单：%@", [wl componentsJoinedByString:@", "]);
            if (names.count > 0) {
                dtaSaveOrgNamesToOwnDomain(names);
                dtaPostNote(kDTA_NoteOrgNames);
                gDTA_OrgNamesCache = [names copy];
                dtaStatusWrite(@"pick-org");
                dtaLog(@"🏢 已缓存企业名称 %lu 个：%@（配置=第 %ld 个）",
                       (unsigned long)names.count, [names componentsJoinedByString:@" / "], (long)idx);
            }
        }

        // 5) 刚点过 → 等它生效（弹层收起有动画），不重复点
        CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
        if (gDTA_LastOrgPick > 0 && now - gDTA_LastOrgPick < 1.2) return YES;

        if (gDTA_OrgAttempts >= 10) {
            if (![gDTA_OrgSig hasSuffix:@"#failed"]) {
                dtaLog(@"🏢 ❌ 连试 10 次仍未选中/关掉企业弹层（行数=%lu，配置=%ld）",
                       (unsigned long)rows.count, (long)idx);
                gDTA_OrgSig = [sig stringByAppendingString:@"#failed"];
                dtaLogSheetDump(win, @"点不动企业行");
                dtaClickState(@"org-fail");
            }
            return YES;
        }

        NSUInteger pick = (NSUInteger)(MIN(MAX(idx, 1), (NSInteger)rows.count) - 1);

        // 6) 名字优先：配置的那一家叫什么，就按名字去当前列表里定位（企业顺序变了也不会点错）
        NSArray<NSString *> *cached = dtaOrgNamesFromDingTalkDomain();
        NSString *want = nil;
        if (cached.count == rows.count && (NSInteger)cached.count >= idx && idx >= 1) {
            want = cached[idx - 1];
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
        dtaLog(@"🏢 选择打卡企业：点第 %lu 个（配置=%ld，共 %lu 个，手法=%ld）文字='%@'",
               (unsigned long)(pick + 1), (long)idx, (unsigned long)rows.count,
               (long)(gDTA_OrgAttempts % 6), dtaRowPrimaryText(row));
        BOOL ok = dtaTapRowHard(row, gDTA_OrgAttempts);
        gDTA_OrgAttempts++;
        gDTA_LastOrgPick = now;

        // 7) 只选中不带跳转的弹层：连点两次行没反应，就顺手点「确定/进入」
        if (!ok || gDTA_OrgAttempts == 3 || gDTA_OrgAttempts == 6) {
            dtaTapSheetConfirm(win, minY);
        }
        dtaClickState(@"pick-org");
        return YES;
    } @catch (NSException *e) {
        dtaLog(@"选择企业异常: %@", e);
        return NO;
    }
}

// 独立看门狗：屏幕上出现「选择打卡企业」时按配置点选。
// ⚠️ 只在「本插件正在执行任务」时才动手（有 pending，或显式开启了自动进入考勤页）：
//   用户自己打开钉钉、自己点进考勤页时，不该被插件抢着选企业。
static void dtaOrgWatchdogTick(void) {
    @try {
        if ([UIApplication sharedApplication].applicationState != UIApplicationStateActive) return;
        BOOL busy = (dtaReadPending() != nil) || dtaBool(kDTA_AutoOpenKey, NO);
        if (!busy) return;
        dtaPickOrgIfNeeded();
    } @catch (NSException *e) {}
}

// 读取「工作台入口名称」偏好（默认 考勤打卡）；用户可改成自家入口名，如「考情助手」
static NSString *dtaEntryKeyword(void) {
    // 点击器读不到偏好域 → 优先用命令文件里带来的入口名
    if (dtaIsClicker() && dtaCmdFresh(gDTA_Cmd)) {
        NSString *e = gDTA_Cmd[@"entry"];
        if ([e isKindOfClass:[NSString class]] && e.length) return e;
    }
    NSString *s = dtaStr(kDTA_EntryKey);
    if (s && s.length) return s;
    return @"考勤打卡";
}

// 祖先里是否有某种类（按类名模糊匹配，钉钉的子类名会带前缀）
static BOOL dtaHasAncestorClass(UIView *v, NSString *clsName, NSInteger maxUp) {
    UIView *cur = v;
    NSInteger guard = 0;
    while (cur && guard++ < maxUp) {
        if ([NSStringFromClass([cur class]) rangeOfString:clsName].location != NSNotFound) return YES;
        cur = cur.superview;
    }
    return NO;
}

// 只找「考勤入口」本身（不含底部 Tab，避免把 Tab 当成入口重复点）
static UIView *dtaFindAttendanceEntry(UIView *root) {
    NSMutableArray<NSString *> *navs = [NSMutableArray array];
    NSString *kw = dtaEntryKeyword();
    if (kw.length) [navs addObject:kw];
    for (NSString *t in @[@"考勤打卡", @"考情助手", @"考勤助手", @"考勤", @"打卡"]) {
        if (![navs containsObject:t]) [navs addObject:t];
    }
    // ① 控件容器（文字可能在子 label 上，老逻辑会漏）
    for (NSString *t in navs) {
        UIControl *c = dtaScanControlSmart(root, t);
        if (!c) continue;
        if (dtaHasAncestorClass(c, @"NavigationBar", 12)) continue;   // 页面标题不是入口
        if (!dtaViewIsHittable(c)) continue;                          // 被盖住的入口点了也没用
        dtaLog(@"找到考勤入口(控件 '%@': %@) 文字='%@'", t, [c class], dtaControlText(c));
        return c;
    }
    // ② 屏幕上可见的文字；跳过顶栏标题、被盖住的、以及「消息列表」里的同名文字
    for (NSString *t in navs) {
        for (UILabel *l in dtaVisibleLabelsMatching(root, t)) {
            if (dtaInChromeBar(l)) continue;                       // 顶栏标题不是入口
            if (!dtaViewIsHittable(l)) continue;                   // 被考勤页/弹层盖住
            if (dtaHasAncestorClass(l, @"UITableViewCell", 14) &&
                !dtaHasAncestorClass(l, @"UICollectionView", 26)) {
                static NSMutableSet *logged = nil;
                if (!logged) logged = [NSMutableSet set];
                if (![logged containsObject:l.text ?: @""]) {
                    [logged addObject:l.text ?: @""];
                    dtaLog(@"跳过消息列表里的 '%@'（不是工作台入口）", l.text);
                }
                continue;
            }
            dtaLog(@"找到考勤入口(label '%@' → %@) 祖先=%@", l.text, [l class], dtaAncestorChain(l));
            return l;
        }
    }
    return nil;
}

// 兼容旧调用：只找考勤入口本身。
// ⚠️ 不要把「工作台」按钮当入口返回 —— 那会让每一拍都去点 Tab，永远进不了考勤页。
static UIView *dtaFindNavEntry(UIView *root) {
    return dtaFindAttendanceEntry(root);
}

// 打开钉钉后自动导航：切「工作台」→ 点进配置的考勤入口（只导航，不打卡）
static NSInteger gDTA_AutoStep = 0;   // 0=未完成 1=已切工作台 2=已点入口
static void dtaAutoNavigateTick(void) {
    @try {
        if (!dtaBool(kDTA_AutoOpenKey, NO)) return;
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

// 收到一条新的触发指令（悬浮球单击 / 立即测试 / 到点）：
// 重置导航进度与「今日已打卡」标记（允许当天补打/下班卡），并立刻打一条状态。
static void dtaOnNewCmd(void) {
    gClickSlot = nil;
    gNavCount = 0;
    gTabClicks = 0;
    gEntryAttempts = 0;
    gLastEntryTap = 0;
    gEnteredAt = 0;
    gEntryGaveUp = NO;
    gDTA_AutoStep = 0;
    gDTA_CmdDone = nil;
    gDTA_LastSkip = nil;
    // 0.9.24：新指令 = 一次全新的打卡尝试，验证/重试状态全部归零
    gDTA_VerifyAt = 0;
    gDTA_VerifyTries = 0;
    gPunchTries = 0;
    if (gDTA_WeakTriedSet) [gDTA_WeakTriedSet removeAllObjects];
    gDTA_PendingWeakSig = nil;
    gDTA_LastPunchText = nil;
    gDTA_WebPunched = NO;
    gDTA_WebText = nil;
    gDTA_LastWebProbeText = nil;
    gDTA_WebOkAt = 0;
    gDTA_LastWebTry = 0;
    gDTA_LastWebNav = 0;
    gMiniTabTries = 0;
    dtaLog(@"📨 收到触发指令：pending=%@ org=%ld entry='%@'",
           dtaReadPending() ?: @"(空)", (long)dtaOrgIndexEffective(), dtaEntryKeyword());
    dtaClickState(@"cmd-armed");
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
            dtaCmdRefresh();
            dtaLog(@"💓 心跳 点击器存活(v%@) 指令 pending=%@ org=%ld entry='%@' doneToday=%d",
                   kDTA_BuildTag,
                   dtaReadPending() ?: @"(无)",
                   (long)dtaOrgIndexEffective(),
                   dtaEntryKeyword(),
                   dtaDoneToday());
            // ⚠️ 钉钉沙盒无法写外域 CFPreferences，所以存活/状态一律改走 Darwin 通知 + 状态文件，
            //    由 SpringBoard 调度器转写 dingtalkClickBeat / dingtalkClickState / dingtalkClickVer。
            dtaPostNote(kDTA_NoteBeatName);
            dtaClickState(@"alive");
        }

        if (!dtaClickShouldRun(&mode, &fromPending)) {
            BOOL done = dtaDoneToday();
            NSString *reason;
            if (done) {
                dtaClickState(@"skip-done");
                reason = @"今日已打卡(done 标记已置位)";
            } else if (!dtaReadPending()) {
                // 没有触发指令（单击悬浮球 / 立即测试 / 到点都没发生）→ 空闲待触发
                dtaClickState(@"idle");
                reason = @"空闲待触发（尚未收到悬浮球/立即测试/定时指令）";
            } else {
                dtaClickState(@"skip-window");
                reason = @"有指令但不在可执行窗口";
            }
            if (![reason isEqualToString:gDTA_LastSkip]) {
                gDTA_LastSkip = reason;
                dtaLog(@"⏸ 待触发：%@", reason);
            }
            dtaStatusDetail(@"%@（企业=%ld 入口=%@）", reason,
                            (long)dtaOrgIndexEffective(), dtaEntryKeyword());
            gClickSlot = nil;
            return;
        }
        dtaClickState(fromPending ? @"run-pending" : @"run-window");
        if (![gDTA_LastSkip isEqualToString:@"(进行中)"]) {
            gDTA_LastSkip = @"(进行中)";
            dtaLog(@"▶️ 进入打卡流程 mode=%ld fromPending=%d", (long)mode, (int)fromPending);
        }

        // 去重键 = 这一条触发指令本身（精确到秒）。
        // ⚠️ 以前用「分钟」做去重，同一分钟内再点一次会被直接 return —— 表现就是「第二次没反应」。
        //    换成指令串后：同一条指令只执行一次，新的一次点击（秒级不同）一定重新执行。
        NSString *trig = dtaReadPending();
        if (!trig.length) {
            NSDateComponents *n2 = [[NSCalendar currentCalendar]
                components:(NSCalendarUnitYear|NSCalendarUnitMonth|NSCalendarUnitDay|
                          NSCalendarUnitHour|NSCalendarUnitMinute|NSCalendarUnitSecond)
                  fromDate:[NSDate date]];
            trig = [NSString stringWithFormat:@"local-%04ld-%02ld-%02ld %02ld:%02ld:%02ld",
                    (long)n2.year, (long)n2.month, (long)n2.day,
                    (long)n2.hour, (long)n2.minute, (long)n2.second];
        }
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

        // ⓪ WebView 文字探测（节流 4s）：考勤页如果是 H5/小程序，UIKit 里什么都看不到，
        //    只有先把页面文字读出来，才谈得上「判断是不是考勤页 / 有没有打卡成功」。
        dtaWebProbe(kw);

        // ⓪.5 「管理员已关闭外勤打卡」是死路：外勤这条线永远打不上，只能走正常打卡
        //      （需在公司 WiFi/蓝牙范围内）。日志里留一行，方便一眼定位到底卡在哪。
        {
            NSString *pt = dtaPageText(kw);
            if ([pt rangeOfString:@"关闭外勤"].location != NSNotFound) {
                static NSString *lastHud = nil;
                if (![lastHud isEqualToString:pt]) {
                    lastHud = [pt copy];
                    dtaLog(@"🚫 考勤页提示「管理员已关闭外勤打卡」→ 外勤路线不可用，只点正常打卡按钮");
                }
            }
        }

        // ① 验证阶段：刚点完（弱特征）打卡 → 等页面给结果。
        //    ⚠️ 这一步必须放在「去重判断」之前，否则点完那一下就把 slot 占住了，永远回不来验证。
        //    ⚠️ 0.9.23 及以前是「点完立刻写 done + 上报 ok」，
        //       于是只点了个小程序顶栏标题也会显示「✅ 已打卡」—— 这是本次最核心的假成功 bug。
        if (gDTA_VerifyAt > 0) {
            double el = CFAbsoluteTimeGetCurrent() - gDTA_VerifyAt;
            BOOL webOk = (gDTA_WebOkAt > 0);
            BOOL confirmed = dtaPunchConfirmed(kw) || webOk;
            if (!confirmed && el < 8.0) {
                gDTA_VerifyTries++;
                return;                              // 给 toast / 页面动画 / H5 一点时间
            }
            gDTA_VerifyAt = 0;
            if (confirmed) {
                gClickSlot = trig;
                dtaClearPending();
                dtaMarkDone();
                dtaClickState(@"ok");
                dtaStatusDetail(@"已确认打卡成功（企业=%ld 入口=%@）",
                                (long)dtaOrgIndexEffective(), dtaEntryKeyword());
                dtaLog(@"✅ 已确认打卡成功（%@）指令=%@",
                       webOk ? @"H5/小程序页面出现成功标志" : @"页面出现「打卡成功/已打卡/更新打卡」", trig);
                return;
            }
            // 没确认 → 绝不置 done
            gDTA_WebPunched = NO;
            gDTA_WebOkAt = 0;
            gClickSlot = nil;      // 放开去重，让本拍继续去试别的目标（入口/切Tab/H5）
            dtaLog(@"⚠️ 点了「%@」后 %.0f 秒内页面上没有出现打卡成功标志 → 不写 done，继续换目标",
                   gDTA_LastPunchText ?: @"打卡", el);
            dtaLogPageSnapshot(@"打卡未确认");
            dtaStatusDetail(@"点了「%@」但页面没出现打卡成功标志（继续重试）", gDTA_LastPunchText ?: @"打卡");
            if (gPunchTries >= 3) {
                gClickSlot = trig;
                dtaClickState(@"punch-fail");
                dtaStatusDetail(@"连点 %ld 次都没确认打卡成功（企业=%ld 入口=%@）",
                                (long)gPunchTries, (long)dtaOrgIndexEffective(), dtaEntryKeyword());
                dtaLog(@"❌ 已尝试 %ld 次仍未确认打卡成功，本次放弃（不写 done，下次触发会重试）",
                       (long)gPunchTries);
                dtaLogPageSnapshot(@"打卡失败");
                dtaClearPending();
                return;
            }
        }

        if ([gClickSlot isEqualToString:trig]) return;

        // ② 「选择打卡企业」弹层：不点掉它，后面永远扫不到打卡按钮
        if (dtaPickOrgIfNeeded()) return;

        // ②.5 考勤小程序：原生层只扫得到底栏标题（打卡/设置/统计），真正的按钮全在 WKWebView 里
        //     → 先在网页层找并点。
        //     ⚠️ 顺序必须先「点打卡」再「切底栏」：反过来会陷入
        //        「以为不在打卡页 → 点打卡 Tab → return」的死循环（0.9.21 就是这么空转 8 拍的）。
        //     ⚠️ 这里刻意不占 gClickSlot：没点中按钮时还要让后面的路继续走。
        if (dtaLooksLikeMiniAppPage(kw) && !gDTA_WebPunched
            && CFAbsoluteTimeGetCurrent() - gDTA_LastWebTry > 6.0) {
            dtaLog(@"🌐 当前是考勤小程序页，改在网页层找打卡按钮（原生层只有底栏标题）");
            dtaWebTryPunch(kw, mode);
            return;
        }

        // ③ 找真正的打卡按钮：强特征直接算成功（只存在于考勤页真按钮上），
        //    弱特征（单一个「打卡」二字）必须等页面确认，避免再次假成功。
        BOOL strong = NO;
        NSString *punchTxt = nil;
        UIView *btn = dtaFindPunchTarget(kw, mode, &strong, &punchTxt);

        // ③.5 网页里也没点到 → 可能停在「设置 / 统计」页，切回「打卡」页再试。
        //     最多 2 次：这类自定义底栏很多版本不回报 selected，无限点会把整个流程卡死。
        if (dtaLooksLikeMiniAppPage(kw) && gMiniTabTries < 2 && dtaTryTabBar(kw, @[@"打卡"])) {
            gMiniTabTries++;
            dtaClickState(@"nav-entry");
            dtaLog(@"🔀 小程序底栏：切回「打卡」页（第 %ld 次）", (long)gMiniTabTries);
            return;
        }

        if (btn) {
            BOOL tapped = dtaTapHard(btn);
            if (tapped) {
                gClickSlot = trig;
                gNavCount = 0;
                gTabClicks = 0;
                gEntryAttempts = 0;
                gLastEntryTap = 0;
                gEntryGaveUp = NO;
                gPunchTries++;
                gDTA_LastPunchText = punchTxt.length ? punchTxt : @"打卡";
                gDTA_LastPunchAt = CFAbsoluteTimeGetCurrent();
                if (strong) {
                    dtaClearPending();
                    dtaMarkDone();
                    dtaClickState(@"ok");
                    dtaStatusDetail(@"已点击「%@」（企业=%ld 入口=%@）",
                                    gDTA_LastPunchText, (long)dtaOrgIndexEffective(), dtaEntryKeyword());
                    dtaLog(@"✅ 已点击打卡按钮「%@」指令=%@ (mode=%ld 目标=%@)",
                           gDTA_LastPunchText, trig, (long)mode, NSStringFromClass([btn class]));
                    return;
                }
                // 弱特征：先别高兴，等页面自己说「打卡成功」
                if (!gDTA_WeakTriedSet) gDTA_WeakTriedSet = [NSMutableSet set];
                if (gDTA_PendingWeakSig.length) [gDTA_WeakTriedSet addObject:gDTA_PendingWeakSig];
                gEnteredAt = CFAbsoluteTimeGetCurrent();   // 别马上切 Tab 把刚打开的页面踢走
                gDTA_VerifyAt = CFAbsoluteTimeGetCurrent();
                dtaClickState(@"verify");
                dtaLog(@"⏳ 已点击「%@」，等 8 秒看页面是否真的打卡成功（不再点完就报成功）",
                       gDTA_LastPunchText);
                return;
            }
        }

        // 2) 当前界面已有考勤入口 → 直接点它（先于切 Tab：可能早就在工作台，反复点 Tab 是死循环）
        CFAbsoluteTime nowT = CFAbsoluteTimeGetCurrent();
        UIView *nav = dtaFindNavEntry(kw);
        BOOL entryCooldown = (gLastEntryTap > 0 && nowT - gLastEntryTap < 2.5);   // 刚点过，等跳页
        if (nav && gEntryAttempts < 3 && !entryCooldown) {
            gLastEntryTap = nowT;
            gEnteredAt = nowT;
            gEntryAttempts++;
            gNavCount++;
            dtaTapHard(nav);
            dtaClickState(@"nav-entry");
            dtaLog(@"⬆️ 点击考勤入口 %@（第 %ld 次）祖先=%@",
                   NSStringFromClass([nav class]), (long)gEntryAttempts, dtaAncestorChain(nav));
            return;
        }
        if (nav && gEntryAttempts >= 3 && !gEntryGaveUp) {
            gEntryGaveUp = YES;
            dtaLog(@"⚠️ 入口已点 %ld 次仍没出现打卡按钮，祖先=%@ → 转去切工作台/兜底",
                   (long)gEntryAttempts, dtaAncestorChain(nav));
            dtaLogPageSnapshot(@"入口点不动");
        }
        if (entryCooldown) return;   // 给上一拍点的入口留出跳页时间

        // 3) 没有可用入口 → 切「工作台」Tab（最多 5 次；已在工作台就不再点，避免空转）
        // ⚠️ 刚点进考勤页时页面要加载，此时切 Tab 会把人踢出去 → 给 12s 宽容期
        BOOL enteringPage = (gEnteredAt > 0 && nowT - gEnteredAt < 12.0);
        if (gTabClicks < 5 && !enteringPage) {
            if (dtaTryTabBar(kw, @[@"工作台", @"工作"])) {
                gTabClicks++;
                dtaClickState(@"tab-workbench");
                dtaLog(@"⬆️ 切到工作台 Tab（第 %ld 次），下一拍继续找考勤入口", (long)gTabClicks);
                dtaLogPageSnapshot(@"切工作台后");
                return;
            }
        }

        // 4) 切完同一拍再找一次（部分机型切换是同步的）
        nav = dtaFindNavEntry(kw);
        if (nav && gEntryAttempts < 3) {
            gLastEntryTap = CFAbsoluteTimeGetCurrent();
            gEnteredAt = gLastEntryTap;
            gEntryAttempts++;
            dtaTapHard(nav);
            dtaClickState(@"nav-entry");
            dtaLog(@"⬆️ 切工作台后点击考勤入口 %@（第 %ld 次）祖先=%@",
                   NSStringFromClass([nav class]), (long)gEntryAttempts, dtaAncestorChain(nav));
            return;
        }

        // 4.5) 工作台本身是 H5 时，考勤入口在网页里 —— 原生层永远扫不到（日志里「入口点击 0 次」）
        //      这里在网页层按文字点「考勤打卡」。
        if (!dtaLooksLikeMiniAppPage(kw)
            && CFAbsoluteTimeGetCurrent() - gDTA_LastWebNav > 8.0) {
            gDTA_LastWebNav = CFAbsoluteTimeGetCurrent();
            gEnteredAt = gDTA_LastWebNav;
            dtaClickState(@"nav-entry");
            dtaLog(@"⬆️ 原生层没有考勤入口 → 改在网页层点（工作台 H5）");
            dtaWebNavToAttendance(kw);
            return;
        }

        // 5) 网页层兜底点打卡：只在「确实在考勤页」时才点，避免在聊天列表里乱点
        BOOL attPage = (dtaLooksLikeMiniAppPage(kw) || dtaAttendanceContext(dtaPageText(kw)));
        if (attPage && !gDTA_WebPunched && CFAbsoluteTimeGetCurrent() - gDTA_LastWebTry > 6.0) {
            dtaClickState(@"noweb");
            dtaLog(@"界面无打卡按钮/导航入口（Tab 切换 %ld 次，入口点击 %ld 次），尝试 WebView 兜底",
                   (long)gTabClicks, (long)gEntryAttempts);
            dtaWebTryPunch(kw, mode);
        }
    } @catch (NSException *e) {
        dtaClickState(@"err");
        dtaLog(@"click tick 异常: %@", e);
    }
}

%ctor {
    @try {
        NSString *bid = [[NSBundle mainBundle] bundleIdentifier] ?: @"(nil)";
        // ⚠️ 不能只按 bundle id 精确匹配钉钉：其真实 id 会随版本变化（曾为 com.laiwang.DingTalk），
        //    一旦不匹配，dylib 就不会注入钉钉进程 → 表现为「能拉起钉钉但从不自动点击」。
        //    filter plist 已改为按可执行文件 DingTalk 匹配，因此这里只要不是 SpringBoard 就按点击器处理。
        BOOL isSB = [bid isEqualToString:@"com.apple.springboard"]
                 || [[[NSProcessInfo processInfo] processName] isEqualToString:@"SpringBoard"];

        if (isSB) {
            gDTA_Proc = @"SCHED";
            // ⚠️ 关键：绝不阻塞 SpringBoard 启动。延迟 + 后台队列初始化，
            //    避免在 %ctor 主线程里做同步 IPC（cfprefsd）导致看门狗杀进程 → 安全模式。
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
                @try {
                    dtaLog(@"钉钉助手 调度器载入 v%@ 进程=%@ pid=%d 日志=%@",
                           kDTA_BuildTag, bid, (int)getpid(), dtaLogPath());
                    dtaProbeDingTalkApps();   // 探测本机钉钉真实 bundleID/可执行名，便于核对 filter
                    // 一次性迁移：早期版本「打开钉钉自动进入考勤页」默认是开，会在用户手动打开钉钉时
                    // 强行跳页。0.9.19 起改为「只在触发时才导航」，这里把旧值改关。
                    if (!dtaBool(@"dingtalkAutoOpenMigrated", NO)) {
                        dtaSetPref(@"dingtalkAutoOpen", @NO);
                        dtaSetPref(@"dingtalkAutoOpenMigrated", @YES);
                        dtaLog(@"🧭 迁移：默认改为「仅触发时进入考勤页」，手动打开钉钉不再跳页");
                    }
                    dtaReschedule();   // 精确定时器，到点整秒触发
                    dtaFloatRefresh(); // 桌面悬浮球（按开关显示）

                    // 3s 轮询「立即测试」标记。不依赖 Darwin 通知是否送达
                    // （宿主进程/通知链路异常时通知可能丢失，轮询是可靠兜底）。
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer * __unused _t){
                            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                                @try {
                                    NSString *v = dtaCopyPref(@"dingtalkTestFire");
                                    if (v && [v isEqualToString:@"1"]) {
                                        dtaSetPref(@"dingtalkTestFire", nil);
                                        dtaLog(@"🧪 检测到【立即测试】标记，立刻执行一次触发（不受定时开关限制）");
                                        dtaManualFire(YES);
                                        dtaReschedule();
                                    }
                                    // 回收点击器状态：心跳/状态码/版本/完成标记（沙盒 App 写不进偏好域，
                                    // 只能由 SpringBoard 读它容器里的状态文件后代写）。
                                    dtaPullClickerStatus();
                                    dtaSyncCmdConfig();
                                    static NSInteger mirrorTick = 0;
                                    if ((++mirrorTick % 3) == 0) dtaMirrorClickLog();
                                    dtaFloatRefresh();   // 顺带刷新悬浮球开关/状态（通知可能丢失）
                                } @catch (NSException *e) {}
                            });
                        }];
                    });

                    // 监听设置变更：改时间/开关后立即重排，不必等 60s 兜底；
                    // 同时处理设置页「立即测试触发一次」写下的 dingtalkTestFire 标记。
                    CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                        dtaPrefsChanged,
                        CFSTR("com.dev.dingtalkassistant/prefs"), NULL,
                        CFNotificationSuspensionBehaviorDeliverImmediately);

                    // 监听点击器(DingTalk 沙盒进程)发来的 Darwin 信标，转写 CFPreferences 供设置页读取。
                    // ⚠️ 钉钉沙盒写不了外域 CFPreferences，所以由非沙盒的 SpringBoard 代为记录。
                    CFNotificationCenterRef nc = CFNotificationCenterGetDarwinNotifyCenter();
                    CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                        (__bridge CFStringRef)kDTA_NoteBeatName, NULL,
                        CFNotificationSuspensionBehaviorDeliverImmediately);
                    // 点击器抓到企业名称列表后发来的通知 → 读钉钉域并转发到本插件域
                    CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                        (__bridge CFStringRef)kDTA_NoteOrgNames, NULL,
                        CFNotificationSuspensionBehaviorDeliverImmediately);
                    for (NSString *c in kDTA_StateCodes()) {
                        NSString *nm = [kDTA_StatePrefix stringByAppendingString:c];
                        CFNotificationCenterAddObserver(nc, NULL, dtaClickerNote,
                            (__bridge CFStringRef)nm, NULL,
                            CFNotificationSuspensionBehaviorDeliverImmediately);
                    }
                    // 60s 兜底重排：设置变更（时间/开关/重复）后能在下个周期生效
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer * __unused _t){
                            @try { dtaReschedule(); } @catch (NSException *e2) {}
                            // 兜底同步「企业名称」：点击器发的通知可能丢失（进程被杀/通知被合并），
                            // 这里主动从钉钉域再拉一次，保证设置页有企业名可显示。
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
                } @catch (NSException *e) {}
            });
        } else {
            // 独立注入（TrollFools/自签 IPA）时进程名未必含 "ding"，因此这里只告警、不拦截：
            // 只要 dylib 被加载进非 SpringBoard 进程，就按「点击器」启用。
            NSString *exe = [[NSProcessInfo processInfo] processName] ?: @"";
            NSString *hay = [NSString stringWithFormat:@"%@ %@", bid, exe].lowercaseString;
            gDTA_Proc = @"CLICK";
            if ([hay rangeOfString:@"ding"].location == NSNotFound) {
                dtaLog(@"⚠️ 进程名不含 ding（bid=%@ exe=%@），仍按独立注入模式启用点击器", bid, exe);
            }
            gNavCount = 0;
            gDTA_AutoStep = 0;
            // ⚠️ 立即上报「已注入钉钉」：钉钉沙盒写不了 CFPreferences 外域，
            //    所以存活/状态只能走 Darwin 通知 + 状态文件，由 SpringBoard 调度器转发。
            dtaPostNote(kDTA_NoteBeatName);
            dtaCmdRefresh();          // 先读触发指令，状态里才能带上「本次触发/企业序号」
            dtaClickState(@"loaded");
            // 延迟 3s 起步：等钉钉 UI 就绪，避免在 App 启动瞬间扫描视图层级
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                @try {
                    dtaLog(@"钉钉助手 点击器载入 v%@ 进程=%@ 可执行=%@ pid=%d pending=%@",
                           kDTA_BuildTag, bid, [[NSProcessInfo processInfo] processName], (int)getpid(),
                           dtaReadPending() ?: @"(空)");
                    if (dtaCmdRefresh()) dtaOnNewCmd();
                    dtaClickTick();
                    [NSTimer scheduledTimerWithTimeInterval:3.0 repeats:YES block:^(NSTimer * __unused _t){
                        @try {
                            // 每拍都重读命令文件：既能在「钉钉已在运行」时接受新触发，
                            // 也能在调度侧撤销 pending 后立刻停手。
                            if (dtaCmdRefresh()) dtaOnNewCmd();
                            dtaClickTick();
                        } @catch (NSException *e2) {}
                    }];
                    // 每 60s 续一期存活信标，证明点击器仍在运行（即使长期静默不打卡）
                    [NSTimer scheduledTimerWithTimeInterval:60.0 repeats:YES block:^(NSTimer * __unused _t){
                        @try { dtaPostNote(kDTA_NoteBeatName); dtaClickState(@"alive"); } @catch (NSException *e2) {}
                    }];

                    // 「选择打卡企业」看门狗：每 1.5s 扫一次，出现就按序号点选。
                    // 与打卡开关、自动导航都解耦——用户手动打开钉钉也能自动选企业。
                    [NSTimer scheduledTimerWithTimeInterval:1.5 repeats:YES block:^(NSTimer * __unused _t){
                        @try { dtaOrgWatchdogTick(); } @catch (NSException *e2) {}
                    }];

                    // ── 自动进入考勤页 ────────────────────────────────────────────────
                    // ⚠️ 默认只在「有 pending 任务」时才导航（悬浮球单击 / 立即测试 / 到点触发）。
                    //    用户手动打开钉钉时不应该自己跳页——那样会打断正常使用。
                    //    只有当设置里显式打开「打开钉钉自动进入考勤页」时，才恢复旧的常驻自动导航。
                    NSString *pendNow = dtaReadPending();
                    BOOL autoNav = dtaBool(kDTA_AutoOpenKey, NO);
                    if (pendNow.length) {
                        // 有 pending：交给 dtaClickTick 串行处理（切工作台→点入口→选企业→打卡），
                        // 这里不再另起一条导航定时器，避免两路同时点造成重复跳转。
                        dtaLog(@"🧭 本次由「触发」驱动（pending=%@），导航与打卡交由打卡流程串行执行", pendNow);
                    } else if (autoNav) {
                        dtaLog(@"🧭 已启用「打开钉钉自动进入考勤页」，入口='%@'", dtaEntryKeyword());
                        // 用自停定时器而不是固定拍数：冷启动慢/首页加载久时（旧机型常见 20s+）
                        // 固定拍数会提前放弃；这里最多跑 60s，一旦导航完成(gDTA_AutoStep>=2)立即停。
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
                    } else {
                        dtaLog(@"🧭 未触发且未开启「自动进入考勤页」：本次不做任何导航（手动打开钉钉时保持原样）");
                    }
                } @catch (NSException *e) {}
            });
        }
    } @catch (NSException *e) {}
}

#pragma clang diagnostic pop
