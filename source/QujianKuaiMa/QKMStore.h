//
//  QKMStore.h — 取件快码 Assit / Author: AssitDev
//  纯本机 plist 存储，App 与 SpringBoard 共享一份数据。
//
#import <Foundation/Foundation.h>

@interface QKMStore : NSObject
+ (instancetype)shared;
- (void)reload;                                  // 从磁盘重新读取
- (NSArray<NSDictionary *> *)records;           // 按时间倒序
- (NSUInteger)pendingCount;
- (NSInteger)ingestText:(NSString *)text section:(NSString *)section;
- (void)addManualCode:(NSString *)code station:(NSString *)station;
- (void)setDone:(BOOL)done forID:(NSString *)rid;
- (void)removeID:(NSString *)rid;
- (void)clearDone;
- (void)prune;
@end
