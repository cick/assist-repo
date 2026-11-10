//
//  QKMConfig.h — 取件快码 Assit / Author: AssitDev
//  App 与 SpringBoard tweak 共用的入口定义与偏好读写。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const QKMPrefsDomain;
FOUNDATION_EXPORT NSString *const QKMAppScheme;
FOUNDATION_EXPORT NSString *const QKMPrefsDarwinNotification;

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

+ (BOOL)bubbleEnabled;
+ (void)setBubbleEnabled:(BOOL)on;
/// Preferences.app 改过设置后，跨进程强制重新读取
+ (void)reloadFromDisk;

/// tweak 注入成功时打标记，App 据此显示自检状态
+ (NSString *)markerPath;
+ (void)markInjected;
+ (BOOL)injectionDetected;
@end
