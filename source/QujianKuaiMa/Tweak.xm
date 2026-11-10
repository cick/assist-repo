//
//  Tweak.xm — 取件快码 Assit
//  Author: AssitDev
//
//  只在 SpringBoard 进程内读取「已经投递到本机的通知文本」，
//  在本机做正则解析并落盘。不联网、不读取其它 App 沙盒、不改动原通知。
//

#import "QKMCommon.h"

@interface BBBulletin : NSObject
@property (nonatomic, copy) NSString *bulletinID;
@property (nonatomic, copy) NSString *sectionID;
@property (nonatomic, copy) NSString *title;
@property (nonatomic, copy) NSString *subtitle;
@property (nonatomic, copy) NSString *message;
@property (nonatomic, retain) NSDate *date;
@end

@interface BBServer : NSObject
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysOn:(BOOL)alwaysOn;
- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations;
@end

@interface SpringBoard : NSObject
- (void)applicationDidFinishLaunching:(id)application;
@end

static void QKMProcessBulletin(id obj) {
    if (![QKMPrefs shared].enabled || ![QKMPrefs shared].autoCapture) return;
    if (![obj isKindOfClass:[NSObject class]]) return;

    @try {
        BBBulletin *b = (BBBulletin *)obj;
        NSMutableArray *parts = [NSMutableArray array];
        if ([b respondsToSelector:@selector(title)] && b.title.length) [parts addObject:b.title];
        if ([b respondsToSelector:@selector(subtitle)] && b.subtitle.length) [parts addObject:b.subtitle];
        if ([b respondsToSelector:@selector(message)] && b.message.length) [parts addObject:b.message];
        if (!parts.count) return;
        NSString *text = [parts componentsJoinedByString:@"\n"];
        if (text.length > 2000) text = [text substringToIndex:2000];
        NSString *section = [b respondsToSelector:@selector(sectionID)] ? (b.sectionID ?: @"") : @"";
        [[QKMStore shared] ingestText:text section:section];
    } @catch (__unused NSException *e) {
        // 单个通知解析失败不能影响系统通知流程
    }
}

%hook BBServer

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations alwaysOn:(BOOL)alwaysOn {
    QKMProcessBulletin(bulletin);
    %orig;
}

- (void)publishBulletin:(id)bulletin destinations:(unsigned long long)destinations {
    QKMProcessBulletin(bulletin);
    %orig;
}

%end

// v1.0.1：设置页（Preferences.app）写入偏好后会发这条 Darwin 通知。
// SpringBoard 侧收到后重新读取 defaults 并刷新悬浮球，避免"设置改了没反应"。
static NSString *const QKMPrefsDarwinNotification = @"com.assitdev.qujiankuaima.prefsChanged";

static void QKMPrefsDidChange(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [[QKMPrefs shared] reloadFromDisk];
    [[QKMUI shared] setup];
    [[QKMUI shared] refresh];
}

// v1.0.1：不再 hook SpringBoard 的私有生命周期 selector。
// 该 selector 在 iOS 15/16 各版本并不稳定，一旦不存在，Logos 会自己 addMethod，
// 系统永远不会调用它，悬浮球就再也不会出现（表现就是"装了但什么都没有"）。
// 改为 dylib 被注入时直接安排挂载，并在多个时间点重试，确保拿得到前台 window。
static void QKMBootstrap(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        QKMPrefsDidChange,
                                        (__bridge CFStringRef)QKMPrefsDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
        for (NSNumber *delay in @[@0.8, @2.5, @6.0, @12.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                [[QKMStore shared] prune];
                [[QKMUI shared] setup];
            });
        }
    });
}

%ctor {
    %init;
    QKMBootstrap();
}
