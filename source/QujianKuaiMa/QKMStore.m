//
//  QKMStore.m — Author: AssitDev
//  纯本机 plist 存储；不联网、不上传、不跨沙盒读取。
//

#import "QKMCommon.h"

@implementation QKMStore {
    NSMutableArray<NSDictionary *> *_records;
    NSString *_filePath;
}

+ (instancetype)shared {
    static QKMStore *inst;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[self alloc] init]; });
    return inst;
}

- (instancetype)init {
    if ((self = [super init])) {
        NSString *dir = [NSHomeDirectory() stringByAppendingPathComponent:@"Library/Application Support/QujianKuaiMa"];
        [[NSFileManager defaultManager] createDirectoryAtPath:dir
                                  withIntermediateDirectories:YES attributes:nil error:nil];
        _filePath = [dir stringByAppendingPathComponent:@"codes.plist"];

        NSArray *loaded = [NSArray arrayWithContentsOfFile:_filePath];
        _records = [loaded isKindOfClass:[NSArray class]] ? [loaded mutableCopy] : [NSMutableArray array];
        [self prune];
    }
    return self;
}

- (NSArray<NSDictionary *> *)records {
    return [_records sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSDate *da = a[QKMKeyDate] ?: [NSDate distantPast];
        NSDate *db = b[QKMKeyDate] ?: [NSDate distantPast];
        return [db compare:da];
    }];
}

- (NSUInteger)pendingCount {
    NSUInteger n = 0;
    for (NSDictionary *r in _records) if (![r[QKMKeyDone] boolValue]) n++;
    return n;
}

- (void)save {
    @try {
        [[self records] writeToFile:_filePath atomically:YES];
    } @catch (__unused NSException *e) { }
    [[NSNotificationCenter defaultCenter] postNotificationName:QKMRecordsChangedNotification
                                                        object:nil userInfo:nil];
}

- (BOOL)hasDuplicate:(NSDictionary *)candidate {
    NSString *code = candidate[QKMKeyCode];
    NSString *station = candidate[QKMKeyStation];
    for (NSDictionary *r in _records) {
        if (![r[QKMKeyCode] isEqualToString:code]) continue;
        if (station.length && ![r[QKMKeyStation] isEqualToString:station]) continue;
        if (![r[QKMKeyDone] boolValue]) return YES;   // 待取里已有 → 直接忽略
        NSDate *d = r[QKMKeyDate] ?: [NSDate distantPast];
        if (-[d timeIntervalSinceNow] < 12 * 3600) return YES; // 刚标记已取，别又冒出来
    }
    return NO;
}

- (NSInteger)ingestText:(NSString *)text section:(NSString *)section {
    if (![QKMPrefs shared].enabled || ![QKMPrefs shared].autoCapture) return 0;
    NSArray *parsed = [QKMParser recordsFromText:text section:section];
    if (!parsed.count) return 0;

    NSMutableArray *added = [NSMutableArray array];
    for (NSDictionary *r in parsed) {
        if ([self hasDuplicate:r]) continue;
        [_records addObject:r];
        [added addObject:r];
    }
    if (!added.count) return 0;

    [self prune];
    [self save];
    [[NSNotificationCenter defaultCenter] postNotificationName:QKMRecordsChangedNotification
                                                        object:nil
                                                      userInfo:@{ @"added": added }];
    return (NSInteger)added.count;
}

- (void)addManualCode:(NSString *)code station:(NSString *)station {
    NSString *c = [code stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (!c.length) return;
    NSDictionary *r = @{
        QKMKeyID      : [[NSUUID UUID] UUIDString],
        QKMKeyCode    : c,
        QKMKeyStation : station.length ? station : @"手动添加",
        QKMKeyAddress : @"",
        QKMKeyRaw     : @"",
        QKMKeyDate    : [NSDate date],
        QKMKeyDone    : @NO
    };
    [_records addObject:r];
    [self save];
}

- (void)setDone:(BOOL)done forID:(NSString *)rid {
    for (NSUInteger i = 0; i < _records.count; i++) {
        NSDictionary *r = _records[i];
        if ([r[QKMKeyID] isEqualToString:rid]) {
            NSMutableDictionary *m = [r mutableCopy];
            m[QKMKeyDone] = @(done);
            _records[i] = m;
            break;
        }
    }
    [self save];
}

- (void)removeID:(NSString *)rid {
    NSMutableIndexSet *idx = [NSMutableIndexSet indexSet];
    [_records enumerateObjectsUsingBlock:^(NSDictionary *r, NSUInteger i, BOOL *stop) {
        if ([r[QKMKeyID] isEqualToString:rid]) [idx addIndex:i];
    }];
    [_records removeObjectsAtIndexes:idx];
    [self save];
}

- (void)clearDone {
    NSMutableIndexSet *idx = [NSMutableIndexSet indexSet];
    [_records enumerateObjectsUsingBlock:^(NSDictionary *r, NSUInteger i, BOOL *stop) {
        if ([r[QKMKeyDone] boolValue]) [idx addIndex:i];
    }];
    [_records removeObjectsAtIndexes:idx];
    [self save];
}

- (void)prune {
    NSInteger days = [QKMPrefs shared].keepDays;
    NSTimeInterval ttl = MAX(days, 1) * 24 * 3600;
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-ttl];
    NSMutableIndexSet *idx = [NSMutableIndexSet indexSet];
    [_records enumerateObjectsUsingBlock:^(NSDictionary *r, NSUInteger i, BOOL *stop) {
        NSDate *d = r[QKMKeyDate];
        if (![d isKindOfClass:[NSDate class]] || [d compare:cutoff] == NSOrderedAscending) [idx addIndex:i];
    }];
    [_records removeObjectsAtIndexes:idx];
    // 上限保护
    if (_records.count > 300) {
        NSArray *sorted = [self records];
        NSArray *keep = [sorted subarrayWithRange:NSMakeRange(0, 300)];
        [_records setArray:keep];
    }
}

@end
