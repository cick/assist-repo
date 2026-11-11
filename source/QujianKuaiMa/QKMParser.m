//
//  QKMParser.m — Author: AssitDev
//  本机正则解析：只处理传入的一段通知文本，不联网、不读取其它 App 数据。
//

#import "QKMParser.h"
#import "QKMConfig.h"

static NSArray<NSString *> *QKMBuiltinKeywords(void) {
    static NSArray *k;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        k = @[@"取件码", @"取货码", @"取餐码", @"提货码", @"取件编号", @"取货编号",
              @"快递码", @"开箱码", @"货架号", @"架号", @"格口", @"凭证码",
              @"取件", @"取餐", @"口令", @"验证码"];
    });
    return k;
}

static NSDictionary<NSString *, NSString *> *QKMStationMap(void) {
    static NSDictionary *m;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        m = @{
            @"菜鸟驿站": @"菜鸟驿站", @"菜鸟": @"菜鸟驿站", @"妈妈驿站": @"妈妈驿站",
            @"兔喜": @"兔喜快递超市", @"快宝": @"快宝驿站",
            @"丰巢": @"丰巢快递柜", @"快递柜": @"快递柜", @"智能柜": @"智能柜",
            @"中通": @"中通快递", @"圆通": @"圆通速递", @"申通": @"申通快递",
            @"韵达": @"韵达快递", @"极兔": @"极兔速递", @"邮政": @"中国邮政",
            @"EMS": @"EMS", @"京东": @"京东物流", @"顺丰": @"顺丰速运",
            @"拼多多": @"拼多多", @"多多买菜": @"多多买菜", @"美团": @"美团",
            @"饿了么": @"饿了么", @"淘宝": @"淘宝", @"抖音": @"抖音商城",
            @"自提点": @"自提点", @"驿站": @"驿站"
        };
    });
    return m;
}

static NSString *QKMSectionName(NSString *sectionID) {
    if (!sectionID.length) return nil;
    NSDictionary *m = @{
        @"com.apple.MobileSMS": @"短信",
        @"com.tencent.xin": @"微信",
        @"com.cainiao.wireless": @"菜鸟",
        @"com.tencent.qq": @"QQ",
        @"com.alipay.iphoneclient": @"支付宝"
    };
    return m[sectionID];
}

static NSString *QKMCleanCode(NSString *raw) {
    NSCharacterSet *trim = [NSCharacterSet characterSetWithCharactersInString:@" \t\r\n　:：,，.。;；!！、|/\\\"'()（）[]【】"];
    NSString *s = [raw stringByTrimmingCharactersInSet:trim];
    s = [s stringByReplacingOccurrencesOfString:@" " withString:@""];
    s = [s stringByReplacingOccurrencesOfString:@"\n" withString:@""];
    return s;
}

static BOOL QKMCodeLooksValid(NSString *code) {
    if (code.length < 3 || code.length > 18) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-"];
    if ([code rangeOfCharacterFromSet:[allowed invertedSet]].location != NSNotFound) return NO;
    // 11 位 1 开头纯数字基本是手机号，不是取件码
    if (code.length == 11 && [code hasPrefix:@"1"]) {
        NSCharacterSet *notDigit = [[NSCharacterSet decimalDigitCharacterSet] invertedSet];
        if ([code rangeOfCharacterFromSet:notDigit].location == NSNotFound) return NO;
    }
    return YES;
}

static NSArray<NSString *> *QKMMatches(NSString *text, NSString *pattern) {
    NSError *err = nil;
    NSRegularExpression *re = [NSRegularExpression regularExpressionWithPattern:pattern
                                                                       options:NSRegularExpressionCaseInsensitive
                                                                         error:&err];
    if (!re) return @[];
    NSMutableArray *out = [NSMutableArray array];
    [re enumerateMatchesInString:text options:0 range:NSMakeRange(0, text.length)
                      usingBlock:^(NSTextCheckingResult *r, NSMatchingFlags flags, BOOL *stop) {
        if (r.numberOfRanges < 2) return;
        NSRange range = [r rangeAtIndex:1];
        if (range.location == NSNotFound) return;
        NSString *code = QKMCleanCode([text substringWithRange:range]);
        if (QKMCodeLooksValid(code)) [out addObject:code];
    }];
    return out;
}

@implementation QKMParser

+ (NSArray<NSString *> *)codesFromText:(NSString *)text {
    if (!text.length) return @[];

    NSMutableArray<NSString *> *keywords = [QKMBuiltinKeywords() mutableCopy];
    NSString *custom = [QKMConfig customKeywords] ?: @"";
    for (NSString *part in [custom componentsSeparatedByCharactersInSet:
                            [NSCharacterSet characterSetWithCharactersInString:@",，、 \n"]]) {
        NSString *k = [part stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
        if (k.length >= 2 && k.length <= 12) [keywords addObject:k];
    }

    // 用 NSRegularExpression 转义后的关键词拼 alternation
    NSMutableArray *escaped = [NSMutableArray array];
    for (NSString *k in keywords) [escaped addObject:[NSRegularExpression escapedPatternForString:k]];
    NSString *kw = [escaped componentsJoinedByString:@"|"];

    NSMutableArray *codes = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    void (^add)(NSArray *) = ^(NSArray *arr) {
        for (NSString *c in arr) {
            if (![seen containsObject:c]) { [seen addObject:c]; [codes addObject:c]; }
        }
    };

    // ① 「取件码 / 取餐码 / 货架号 …」后面跟的码
    NSString *p1 = [NSString stringWithFormat:
        @"(?:%@)[^0-9A-Za-z]{0,8}([0-9A-Za-z][0-9A-Za-z\\-\\s]{1,20})", kw];
    add(QKMMatches(text, p1));

    // ② 驿站三段式货架号，例如 3-2-1056 / 6–12–3055
    add(QKMMatches(text, @"(\\d{1,2}\\s*[-–—]\\s*\\d{1,3}\\s*[-–—]\\s*\\d{1,5})"));

    // ③ 「凭 XXXX 取件」「XXXX 到驿站取」这类没有显式关键词的写法
    add(QKMMatches(text, @"凭\\s*([0-9A-Za-z][0-9A-Za-z\\-]{2,17})\\s*(?:取|领|取件|取餐)"));

    // ④ 兜底：驿站/快递柜语境里的 4~8 位纯数字码
    add(QKMMatches(text, @"(?:驿站|快递柜|丰巢|智能柜|货架|取件|取餐|自提)[^0-9]{0,12}(\\d{4,8})(?![0-9])"));

    return codes;
}

+ (NSArray<NSDictionary *> *)recordsFromText:(NSString *)text section:(NSString *)section {
    NSArray *codes = [self codesFromText:text];
    if (!codes.count) return @[];

    NSString *station = nil;
    NSDictionary *map = QKMStationMap();
    // 按 key 长度从长到短匹配，优先命中更精确的名字
    NSArray *keys = [[map allKeys] sortedArrayUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return a.length < b.length ? NSOrderedDescending : (a.length > b.length ? NSOrderedAscending : NSOrderedSame);
    }];
    for (NSString *k in keys) {
        if ([text rangeOfString:k].location != NSNotFound) { station = map[k]; break; }
    }
    if (!station) station = QKMSectionName(section) ?: @"其它";

    NSString *address = @"";
    NSRegularExpression *addrRe = [NSRegularExpression regularExpressionWithPattern:
        @"(?:取件地址|地址|位于|请至|请到)[:：\\s]?([^\\s，,。；;]{4,40})" options:0 error:nil];
    NSTextCheckingResult *m = [addrRe firstMatchInString:text options:0 range:NSMakeRange(0, text.length)];
    if (m && m.numberOfRanges > 1) address = [text substringWithRange:[m rangeAtIndex:1]];

    NSString *raw = text.length > 240 ? [text substringToIndex:240] : text;
    NSDate *now = [NSDate date];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *code in codes) {
        [out addObject:@{
            QKMKeyID      : [[NSUUID UUID] UUIDString],
            QKMKeyCode    : code,
            QKMKeyStation : station,
            QKMKeyAddress : address ?: @"",
            QKMKeyRaw     : raw,
            QKMKeyDate    : now,
            QKMKeyDone    : @NO
        }];
    }
    return out;
}

@end
