//
//  QKMConfig.m — 取件快码 Assit / Author: AssitDev
//

#import "QKMConfig.h"

NSString *const QKMPrefsDomain            = @"com.assitdev.qujiankuaima";
NSString *const QKMAppScheme             = @"qujiankuaima://";
NSString *const QKMPrefsDarwinNotification = @"com.assitdev.qujiankuaima.prefsChanged";

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

static NSUserDefaults *QKMDefaults(void) {
    static NSUserDefaults *d;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        d = [[NSUserDefaults alloc] initWithSuiteName:QKMPrefsDomain];
        [d registerDefaults:@{ @"bubbleEnabled": @YES }];
    });
    return d;
}

@implementation QKMConfig

+ (NSArray<QKMEntry *> *)identityEntries {
    static NSArray *a;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        a = @[
            QKMMake(YES, @"id_taobao", @"淘宝身份码",   @"驿站扫码出示", @"淘", QKMRGB(255, 90, 20),  @"taobao://",          @"https://www.taobao.com"),
            QKMMake(YES, @"id_pdd",    @"拼多多身份码", @"驿站扫码出示", @"拼", QKMRGB(226, 46, 31),  @"pinduoduo://",       @"https://mobile.yangkeduo.com"),
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
            QKMMake(NO, @"q_taobao",   @"淘宝待取",   @"查看待取包裹", @"淘", QKMRGB(255, 90, 20),  @"taobao://",          @"https://www.taobao.com"),
            QKMMake(NO, @"q_pdd",      @"拼多多待取", @"查看待取包裹", @"拼", QKMRGB(226, 46, 31),  @"pinduoduo://",       @"https://mobile.yangkeduo.com"),
            QKMMake(NO, @"q_jd",       @"京东待取",   @"查看订单物流", @"京", QKMRGB(225, 37, 27),  @"openapp.jdmobile://", @"https://m.jd.com"),
            QKMMake(NO, @"q_douyin",   @"抖音待取",   @"查看订单物流", @"抖", QKMRGB(28, 28, 30),   @"snssdk1128://",      @"https://www.douyin.com"),
            QKMMake(NO, @"q_kuaishou", @"快手待取",   @"查看订单物流", @"快", QKMRGB(255, 105, 30), @"kwai://",            @"https://www.kuaishou.com"),
            QKMMake(NO, @"q_dewu",     @"得物待取",   @"查看订单物流", @"得", QKMRGB(28, 28, 30),   @"dewu://",            @"https://www.dewu.com"),
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

+ (BOOL)bubbleEnabled { return [QKMDefaults() boolForKey:@"bubbleEnabled"]; }
+ (void)setBubbleEnabled:(BOOL)on {
    [QKMDefaults() setBool:on forKey:@"bubbleEnabled"];
    [QKMDefaults() synchronize];
}

+ (void)reloadFromDisk {
    [QKMDefaults() synchronize];
}

+ (NSString *)markerPath {
    NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QujianKuaiMa"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"injected.txt"];
}

+ (void)markInjected {
    NSString *s = [NSString stringWithFormat:@"%.0f", [[NSDate date] timeIntervalSince1970]];
    [s writeToFile:[self markerPath] atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

+ (BOOL)injectionDetected {
    // App 若被沙盒化，NSHomeDirectory() 会不同于 SpringBoard，额外试一次绝对路径
    NSArray *paths = @[[self markerPath],
                       @"/var/mobile/Library/Application Support/QujianKuaiMa/injected.txt"];
    for (NSString *p in paths) {
        NSString *s = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
        if (!s.length) continue;
        NSTimeInterval t = [s doubleValue];
        // 24 小时内有过注入即认为有效（重启后需重新越狱才会再写）
        if (t > 0 && ([[NSDate date] timeIntervalSince1970] - t) < 86400) return YES;
    }
    return NO;
}

@end
