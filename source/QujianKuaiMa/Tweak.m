//
//  Tweak.m — 取件快码 Assit / Author: AssitDev
//  SpringBoard 注入端：只负责打注入标记 + 挂悬浮球，不修改任何系统行为。
//  用普通 constructor 而非 Logos hook，避免依赖任何私有 selector。
//

#import "QKMConfig.h"
#import "QKMBubble.h"

static void QKMMount(void) {
    [[QKMBubble shared] mount];
}

static void QKMPrefsDidChange(CFNotificationCenterRef center, void *observer,
                              CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    [QKMConfig reloadFromDisk];
    [[QKMBubble shared] setEnabled:[QKMConfig bubbleEnabled]];
    QKMMount();
}

__attribute__((constructor)) static void QKMInit(void) {
    @autoreleasepool {
        // App 的「设置 → 运行状态」会读这个标记，用来判断注入是否成功
        [QKMConfig markInjected];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL,
                                        QKMPrefsDidChange,
                                        (__bridge CFStringRef)QKMPrefsDarwinNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);

        // SpringBoard 启动早期可能还没有可用的前台 window，多时间点兜底挂载
        for (NSNumber *d in @[@0.8, @2.5, @6.0, @12.0]) {
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d.doubleValue * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{ QKMMount(); });
        }

        [[NSNotificationCenter defaultCenter] addObserverForName:UIApplicationDidBecomeActiveNotification
            object:nil queue:[NSOperationQueue mainQueue] usingBlock:^(NSNotification *n) { QKMMount(); }];
    }
}
