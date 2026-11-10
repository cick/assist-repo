#import <Foundation/Foundation.h>

@interface QKMBubble : NSObject
+ (instancetype)shared;
/// 在 SpringBoard 的窗口上挂载悬浮球（可重复调用，会做去重与置顶）
- (void)mount;
/// 按偏好显示 / 隐藏
- (void)setEnabled:(BOOL)on;
@end
