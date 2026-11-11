//
//  QKMConfig.m — 取件快码 Assit / Author: AssitDev
//

#import "QKMConfig.h"

NSString *const QKMPrefsDomain              = @"com.assitdev.qujiankuaima";
NSString *const QKMAppScheme               = @"qujiankuaima://";
NSString *const QKMPrefsDarwinNotification = @"com.assitdev.qujiankuaima.prefsChanged";
NSString *const QKMCodesDarwinNotification = @"com.assitdev.qujiankuaima.codesChanged";

NSString *const QKMKeyID      = @"id";
NSString *const QKMKeyCode    = @"code";
NSString *const QKMKeyStation = @"station";
NSString *const QKMKeyAddress = @"address";
NSString *const QKMKeyRaw     = @"raw";
NSString *const QKMKeyDate    = @"date";
NSString *const QKMKeyDone    = @"done";

static UIColor *QKMRGB(CGFloat r, CGFloat g, CGFloat b) {
    return [UIColor colorWithRed:r/255.0 green:g/255.0 blue:b/255.0 alpha:1.0];
}

@interface QKMEntry ()
@property (nonatomic, copy, readwrite) NSString *key;
@property (nonatomic, copy, readwrite) NSString *title;
@property (nonatomic, copy, readwrite) NSString *subtitle;
@property (nonatomic, copy, readwrite) NSString *badge;
@property (nonatomic, strong, readwrite) UIColor *badgeColor;
@property (nonatomic, copy, readwrite) NSString *defaultURL;
@property (nonatomic, copy, readwrite) NSString *webURL;
@property (nonatomic, assign, readwrite) BOOL identity;
@end

@implementation QKMEntry
@end

static QKMEntry *QKMMake(BOOL identity, NSString *key, NSString *title, NSString *subtitle,
                         NSString *badge, UIColor *color, NSString *url, NSString *web) {
    QKMEntry *e = [[QKMEntry alloc] init];
    e.identity   = identity;
    e.key        = key;
    e.title      = title;
    e.subtitle   = subtitle;
    e.badge      = badge;
    e.badgeColor = color;
    e.defaultURL = url;
    e.webURL     = web;
    return e;
}

// 偏好对象可在跨进程通知后重建，确保读到 Preferences.app 刚写入的值
static NSUserDefaults *_qkmDefaults = nil;

static NSUserDefaults *QKMDefaults(void) {
    @synchronized([QKMConfig class]) {
        if (!_qkmDefaults) {
            _qkmDefaults = [[NSUserDefaults alloc] initWithSuiteName:QKMPrefsDomain];
            [_qkmDefaults registerDefaults:@{
                @"bubbleEnabled" : @YES,
                @"autoCapture"   : @YES,
                @"bannerEnabled" : @YES,
                @"keepDays"      : @7,
                @"customKeywords": @""
            }];
        }
        return _qkmDefaults;
    }
}

@implementation QKMConfig

+ (NSArray<QKMEntry *> *)identityEntries {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            QKMMake(YES, @"id_taobao", @"淘宝身份码",   @"驿站扫码出示", @"淘", QKMRGB(255, 90, 20),  @"taobao://",           @"https://www.taobao.com"),
            QKMMake(YES, @"id_pdd",    @"拼多多身份码", @"驿站扫码出示", @"拼", QKMRGB(226, 46, 31),  @"pinduoduo://",        @"https://mobile.yangkeduo.com"),
            QKMMake(YES, @"id_jd",     @"京东身份码",   @"订单内查看",   @"京", QKMRGB(225, 37, 27),  @"openapp.jdmobile://", @"https://m.jd.com"),
        ];
    });
    return a;
}

+ (NSArray<QKMEntry *> *)queryEntries {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            QKMMake(NO, @"q_taobao",   @"淘宝待取",   @"查看待取包裹", @"淘", QKMRGB(255, 90, 20),  @"taobao://",           @"https://www.taobao.com"),
            QKMMake(NO, @"q_pdd",      @"拼多多待取", @"查看待取包裹", @"拼", QKMRGB(226, 46, 31),  @"pinduoduo://",        @"https://mobile.yangkeduo.com"),
            QKMMake(NO, @"q_jd",       @"京东待取",   @"查看订单物流", @"京", QKMRGB(225, 37, 27),  @"openapp.jdmobile://", @"https://m.jd.com"),
            QKMMake(NO, @"q_douyin",   @"抖音待取",   @"查看订单物流", @"抖", QKMRGB(28, 28, 30),   @"snssdk1128://",       @"https://www.douyin.com"),
            QKMMake(NO, @"q_kuaishou", @"快手待取",   @"查看订单物流", @"快", QKMRGB(255, 105, 30), @"kwai://",             @"https://www.kuaishou.com"),
            QKMMake(NO, @"q_dewu",     @"得物待取",   @"查看订单物流", @"得", QKMRGB(28, 28, 30),   @"dewu://",             @"https://www.dewu.com"),
        ];
    });
    return a;
}

+ (NSArray<QKMEntry *> *)allEntries {
    return [[self identityEntries] arrayByAddingObjectsFromArray:[self queryEntries]];
}

+ (NSString *)customKeyFor:(QKMEntry *)entry {
    return [@"url_" stringByAppendingString:entry.key];
}

+ (NSString *)urlForEntry:(QKMEntry *)entry {
    NSString *custom = [QKMDefaults() stringForKey:[self customKeyFor:entry]];
    if (custom.length) return custom;
    return entry.defaultURL;
}

+ (void)setCustomURL:(NSString *)url forEntry:(QKMEntry *)entry {
    NSString *v = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (v.length) [QKMDefaults() setObject:v forKey:[self customKeyFor:entry]];
    else [QKMDefaults() removeObjectForKey:[self customKeyFor:entry]];
    [QKMDefaults() synchronize];
}

+ (void)resetAllCustomURLs {
    for (QKMEntry *e in [self allEntries]) [QKMDefaults() removeObjectForKey:[self customKeyFor:e]];
    [QKMDefaults() synchronize];
}

+ (BOOL)bubbleEnabled  { return [QKMDefaults() boolForKey:@"bubbleEnabled"]; }
+ (void)setBubbleEnabled:(BOOL)on {
    [QKMDefaults() setBool:on forKey:@"bubbleEnabled"];
    [QKMDefaults() synchronize];
}
+ (BOOL)autoCapture { return [QKMDefaults() boolForKey:@"autoCapture"]; }
+ (void)setAutoCapture:(BOOL)on {
    [QKMDefaults() setBool:on forKey:@"autoCapture"];
    [QKMDefaults() synchronize];
}
+ (BOOL)bannerEnabled { return [QKMDefaults() boolForKey:@"bannerEnabled"]; }
+ (NSInteger)keepDays {
    NSInteger d = [QKMDefaults() integerForKey:@"keepDays"];
    return d > 0 ? d : 7;
}
+ (void)setKeepDays:(NSInteger)d {
    [QKMDefaults() setInteger:MAX(1, MIN(d, 90)) forKey:@"keepDays"];
    [QKMDefaults() synchronize];
}
+ (NSString *)customKeywords { return [QKMDefaults() stringForKey:@"customKeywords"] ?: @""; }
+ (void)setCustomKeywords:(NSString *)s {
    [QKMDefaults() setObject:(s ?: @"") forKey:@"customKeywords"];
    [QKMDefaults() synchronize];
}

+ (void)reloadFromDisk {
    CFPreferencesAppSynchronize((__bridge CFStringRef)QKMPrefsDomain);
    @synchronized([QKMConfig class]) { _qkmDefaults = nil; }   // 下次访问重建，读到最新磁盘值
}

+ (NSString *)sharedDir {
    NSString *p = @"/var/mobile/Library/Application Support/QujianKuaiMa";
    [[NSFileManager defaultManager] createDirectoryAtPath:p
                              withIntermediateDirectories:YES attributes:nil error:nil];
    return p;
}

+ (NSString *)codesFilePath {
    return [[self sharedDir] stringByAppendingPathComponent:@"codes.plist"];
}

+ (NSString *)installLogPath {
    return [[self sharedDir] stringByAppendingPathComponent:@"install.log"];
}

+ (void)postCodesChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
        (__bridge CFStringRef)QKMCodesDarwinNotification, NULL, NULL, true);
}

+ (void)markInjected {
    NSString *s = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    [s writeToFile:[[self sharedDir] stringByAppendingPathComponent:@"injected.txt"]
        atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (BOOL)injectionDetected {
    NSString *p = [[self sharedDir] stringByAppendingPathComponent:@"injected.txt"];
    NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
    if (!s.length) return NO;
    NSTimeInterval t = [s doubleValue];
    return t > 0 && ([[NSDate date] timeIntervalSince1970] - t) < 86400;
}

@end
