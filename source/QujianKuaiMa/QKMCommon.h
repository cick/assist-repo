//
//  QKMCommon.h
//  取件快码 Assit — Author: AssitDev
//
//  设计约束（同时为了兼容 rootless 无根 与 roothide 隐根）：
//   · 不出现任何硬编码的 /var/jb、/Library/MobileSubstrate 等越狱根路径
//   · 所有持久化走 NSHomeDirectory() / NSUserDefaults（都是系统真实路径）
//   · 不访问网络、不读取其它 App 沙盒，只处理注入进程（SpringBoard）收到的通知
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

FOUNDATION_EXPORT NSString *const QKMPrefsDomain;
FOUNDATION_EXPORT NSString *const QKMRecordsChangedNotification;
FOUNDATION_EXPORT NSString *const QKMSettingsChangedNotification;

// 记录字典的键
FOUNDATION_EXPORT NSString *const QKMKeyID;
FOUNDATION_EXPORT NSString *const QKMKeyCode;
FOUNDATION_EXPORT NSString *const QKMKeyStation;
FOUNDATION_EXPORT NSString *const QKMKeyAddress;
FOUNDATION_EXPORT NSString *const QKMKeyRaw;
FOUNDATION_EXPORT NSString *const QKMKeyDate;
FOUNDATION_EXPORT NSString *const QKMKeyDone;

#pragma mark - 设置

@interface QKMPrefs : NSObject
+ (instancetype)shared;
@property (nonatomic, assign) BOOL enabled;        // 总开关
@property (nonatomic, assign) BOOL bubbleVisible;  // 悬浮球
@property (nonatomic, assign) BOOL autoCapture;    // 自动抓码
@property (nonatomic, assign) BOOL bannerEnabled;  // 新码横幅
@property (nonatomic, assign) NSInteger keepDays;  // 保留天数
@property (nonatomic, assign) CGFloat bubbleAlpha; // 悬浮球透明度
@property (nonatomic, copy) NSString *customKeywords; // 逗号分隔的自定义关键词
@end

#pragma mark - 解析

@interface QKMParser : NSObject
/// 从一段通知文本里解析出若干条取件码记录（已去重，未落盘）
+ (NSArray<NSDictionary *> *)recordsFromText:(NSString *)text section:(NSString *)section;
/// 只取码，用于剪贴板 / 手动输入的快速识别
+ (NSArray<NSString *> *)codesFromText:(NSString *)text;
@end

#pragma mark - 存储

@interface QKMStore : NSObject
+ (instancetype)shared;
/// 全部记录，按时间倒序
- (NSArray<NSDictionary *> *)records;
- (NSUInteger)pendingCount;
/// 解析通知文本并落盘，返回新增条数
- (NSInteger)ingestText:(NSString *)text section:(NSString *)section;
- (void)addManualCode:(NSString *)code station:(NSString *)station;
- (void)setDone:(BOOL)done forID:(NSString *)rid;
- (void)removeID:(NSString *)rid;
- (void)clearDone;
- (void)prune;
@end

#pragma mark - 界面

@interface QKMUI : NSObject
+ (instancetype)shared;
- (void)setup;
- (void)refresh;
- (void)togglePanel;
/// 新码到达时的顶部横幅
- (void)showBannerWithCode:(NSString *)code station:(NSString *)station;
@end
