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

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [[QKMStore shared] prune];
        [[QKMUI shared] setup];
    });
}

%end

%ctor {
    %init;
}
