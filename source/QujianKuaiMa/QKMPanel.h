#import <Foundation/Foundation.h>

/// SpringBoard 内的快捷面板：不依赖桌面 App 是否注册成功。
@interface QKMPanel : NSObject
+ (instancetype)shared;
- (void)toggle;
- (void)dismiss;
@end
