//
//  QKMParser.h — 取件快码 Assit / Author: AssitDev
//  本机正则解析，不联网、不读取其它 App 数据。
//
#import <Foundation/Foundation.h>

@interface QKMParser : NSObject
/// 从一段通知文本里解析出若干条取件码记录（已去重，未落盘）
+ (NSArray<NSDictionary *> *)recordsFromText:(NSString *)text section:(NSString *)section;
/// 只取码，用于剪贴板 / 手动输入的快速识别
+ (NSArray<NSString *> *)codesFromText:(NSString *)text;
@end
