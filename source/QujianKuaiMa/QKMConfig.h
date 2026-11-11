//
//  QKMConfig.h — 取件快码 Assit / Author: AssitDev
//  App 与 SpringBoard tweak 共用的入口定义、偏好读写与共享数据路径。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const QKMPrefsDomain;
FOUNDATION_EXPORT NSString *const QKMAppScheme;
FOUNDATION_EXPORT NSString *const QKMPrefsDarwinNotification;
FOUNDATION_EXPORT NSString *const QKMCodesDarwinNotification;

// 取件码记录字典的键
FOUNDATION_EXPORT NSString *const QKMKeyID;
FOUNDATION_EXPORT NSString *const QKMKeyCode;
FOUNDATION_EXPORT NSString *const QKMKeyStation;
FOUNDATION_EXPORT NSString *const QKMKeyAddress;
FOUNDATION_EXPORT NSString *const QKMKeyRaw;
FOUNDATION_EXPORT NSString *const QKMKeyDate;
FOUNDATION_EXPORT NSString *const QKMKeyDone;

@interface QKMEntry : NSObject
@property (nonatomic, copy, readonly) NSString *key;
@property (nonatomic, copy, readonly) NSString *title;
@property (nonatomic, copy, readonly) NSString *subtitle;
@property (nonatomic, copy, readonly) NSString *badge;
@property (nonatomic, strong, readonly) UIColor *badgeColor;
@property (nonatomic, copy, readonly) NSString *defaultURL;
@property (nonatomic, copy, readonly) NSString *webURL;
@property (nonatomic, assign, readonly) BOOL identity;
@end

@interface QKMConfig : NSObject
+ (NSArray<QKMEntry *> *)identityEntries;
+ (NSArray<QKMEntry *> *)queryEntries;
+ (NSArray<QKMEntry *> *)allEntries;

/// 自定义链接优先，没填则用默认 URL Scheme
+ (NSString *)urlForEntry:(QKMEntry *)entry;
+ (void)setCustomURL:(NSString *)url forEntry:(QKMEntry *)entry;
+ (void)resetAllCustomURLs;

// 运行开关（App 悬浮球面板 / iOS 设置页 / tweak 三方共享）
+ (BOOL)bubbleEnabled;
+ (void)setBubbleEnabled:(BOOL)on;
+ (BOOL)autoCapture;
+ (void)setAutoCapture:(BOOL)on;
+ (BOOL)bannerEnabled;
+ (NSInteger)keepDays;
+ (NSString *)customKeywords;
+ (void)setCustomKeywords:(NSString *)s;

/// Preferences.app 改过设置后，跨进程强制重新读取
+ (void)reloadFromDisk;

/// App 与 SpringBoard 共用的数据目录 / 文件（绝对真实路径，避开沙盒差异）
+ (NSString *)sharedDir;
+ (NSString *)codesFilePath;
+ (NSString *)installLogPath;
+ (void)postCodesChanged;

/// tweak 注入成功时打标记，App 据此显示自检状态
+ (void)markInjected;
+ (BOOL)injectionDetected;
@end
