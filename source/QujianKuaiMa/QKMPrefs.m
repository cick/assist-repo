//
//  QKMPrefs.m — Author: AssitDev
//

#import "QKMCommon.h"

NSString *const QKMPrefsDomain               = @"com.assitdev.qujiankuaima";
NSString *const QKMRecordsChangedNotification = @"com.assitdev.qujiankuaima.recordsChanged";
NSString *const QKMSettingsChangedNotification = @"com.assitdev.qujiankuaima.settingsChanged";

NSString *const QKMKeyID      = @"id";
NSString *const QKMKeyCode    = @"code";
NSString *const QKMKeyStation = @"station";
NSString *const QKMKeyAddress = @"address";
NSString *const QKMKeyRaw     = @"raw";
NSString *const QKMKeyDate    = @"date";
NSString *const QKMKeyDone    = @"done";

@implementation QKMPrefs {
    NSUserDefaults *_defaults;
}

+ (instancetype)shared {
    static QKMPrefs *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        _defaults = [[NSUserDefaults alloc] initWithSuiteName:QKMPrefsDomain];
        // 首次运行的默认值
        NSDictionary *defaults = @{
            @"enabled"       : @YES,
            @"bubbleVisible" : @YES,
            @"autoCapture"   : @YES,
            @"bannerEnabled" : @YES,
            @"keepDays"      : @7,
            @"bubbleAlpha"   : @0.92,
            @"customKeywords": @""
        };
        [_defaults registerDefaults:defaults];
    }
    return self;
}

- (NSUserDefaults *)d { return _defaults; }

- (BOOL)enabled { return [[self d] boolForKey:@"enabled"]; }
- (void)setEnabled:(BOOL)v { [[self d] setBool:v forKey:@"enabled"]; [self notify]; }

- (BOOL)bubbleVisible { return [[self d] boolForKey:@"bubbleVisible"]; }
- (void)setBubbleVisible:(BOOL)v { [[self d] setBool:v forKey:@"bubbleVisible"]; [self notify]; }

- (BOOL)autoCapture { return [[self d] boolForKey:@"autoCapture"]; }
- (void)setAutoCapture:(BOOL)v { [[self d] setBool:v forKey:@"autoCapture"]; [self notify]; }

- (BOOL)bannerEnabled { return [[self d] boolForKey:@"bannerEnabled"]; }
- (void)setBannerEnabled:(BOOL)v { [[self d] setBool:v forKey:@"bannerEnabled"]; [self notify]; }

- (NSInteger)keepDays { return [[self d] integerForKey:@"keepDays"]; }
- (void)setKeepDays:(NSInteger)v {
    if (v < 1) v = 1;
    if (v > 90) v = 90;
    [[self d] setInteger:v forKey:@"keepDays"];
    [self notify];
}

- (CGFloat)bubbleAlpha { return [[self d] floatForKey:@"bubbleAlpha"]; }
- (void)setBubbleAlpha:(CGFloat)v {
    if (v < 0.35) v = 0.35;
    if (v > 1.0) v = 1.0;
    [[self d] setFloat:v forKey:@"bubbleAlpha"];
    [self notify];
}

- (NSString *)customKeywords {
    return [[self d] stringForKey:@"customKeywords"] ?: @"";
}
- (void)setCustomKeywords:(NSString *)v {
    [[self d] setObject:(v ?: @"") forKey:@"customKeywords"];
    [self notify];
}

- (void)notify {
    [[NSNotificationCenter defaultCenter] postNotificationName:QKMSettingsChangedNotification object:nil];
}

@end
