#import "TBLyrics.h"

NS_ASSUME_NONNULL_BEGIN

@interface TBLyrics ()
@property (nonatomic, strong) NSCache<NSString *, NSArray<TBLyricLine *> *> *cache;
@end

@implementation TBLyricLine
- (instancetype)initWithTime:(double)t text:(NSString *)s {
    self = [super init];
    if (self) { _time = t; _text = s; }
    return self;
}
@end

@implementation TBLyrics

+ (instancetype)shared {
    static TBLyrics *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[TBLyrics alloc] init]; });
    return s;
}

- (instancetype)init {
    self = [super init];
    if (self) { _cache = [[NSCache alloc] init]; _cache.countLimit = 32; }
    return self;
}

- (void)lyricsForTitle:(NSString *)title artist:(nullable NSString *)artist
            completion:(TBLyricsCallback)completion {
    NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
    NSArray<TBLyricLine *> *hit = [self.cache objectForKey:key];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ completion(hit); }); return; }

    NSString *query = artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
    [self search:query completion:^(NSNumber *_Nullable songId) {
        // 乐队/歌手名干扰时退化为仅歌名搜索
        if (!songId) {
            [self search:title completion:^(NSNumber *_Nullable fallbackId) {
                [self fetch:songId ?: fallbackId key:key completion:completion];
            }];
            return;
        }
        [self fetch:songId key:key completion:completion];
    }];
}

#pragma mark - 网络请求

- (void)search:(NSString *)query completion:(void (^)(NSNumber *_Nullable songId))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get/web?s=%@&type=1&limit=8",
        [query stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]]];
    [self getJSON:urlStr completion:^(id _Nullable json) {
        NSNumber *songId = nil;
        NSArray *songs = json[@"result"][@"songs"];
        if ([songs isKindOfClass:[NSArray class]]) {
            for (NSDictionary *song in songs) {
                NSString *name = song[@"name"];
                if (![name isKindOfClass:[NSString class]]) continue;
                // 精确同名优先,否则取第一个
                if (!songId) {
                    id sid = song[@"id"];
                    if ([sid isKindOfClass:[NSNumber class]]) songId = sid;
                }
                if ([name isEqualToString:query] || [name isEqualToString:[query componentsSeparatedByString:@" "].firstObject]) break;
            }
        }
        completion(songId);
    }];
}

- (void)fetch:(NSNumber *_Nullable)songId key:(NSString *)key completion:(TBLyricsCallback)completion {
    if (!songId) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    NSString *urlStr = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric?id=%@&lv=1&kv=1&tv=-1", songId];
    [self getJSON:urlStr completion:^(id _Nullable json) {
        NSString *lrcText = json[@"lrc"][@"lyric"];
        NSArray<TBLyricLine *> *lines = [lrcText isKindOfClass:[NSString class]]
            ? [TBLyrics parseLRC:lrcText] : nil;
        if (lines) [self.cache setObject:lines forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
    }];
}

- (void)getJSON:(NSString *)urlStr completion:(void (^)(id _Nullable json))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    // 网易云接口要求带浏览器 UA + Referer,否则 403/空结果
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:@"https://music.163.com/" forHTTPHeaderField:@"Referer"];
    req.timeoutInterval = 10;
    [[[NSURLSession sharedSession] dataTaskWithRequest:req
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
            id json = nil;
            if (data && (!err || !data.length)) {
                json = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
            }
            completion(json);
        }] resume];
}

#pragma mark - LRC 解析

+ (nullable NSArray<TBLyricLine *> *)parseLRC:(NSString *)lrc {
    NSMutableArray<TBLyricLine *> *lines = [NSMutableArray array];
    [lrc enumerateLinesUsingBlock:^(NSString *rawLine, BOOL *stop) {
        NSString *line = [rawLine stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!line.length) return;
        // 收集行首所有 [mm:ss(.xx)] 时间戳
        NSMutableArray<NSNumber *> *times = [NSMutableArray array];
        NSRange search = NSMakeRange(0, line.length);
        NSRegularExpression *re = [NSRegularExpression
            regularExpressionWithPattern:@"^\\[(\\d{1,2}):(\\d{1,2})(?:[.:](\\d{1,3}))?\\]"
                                 options:0 error:NULL];
        while (search.location < line.length) {
            NSTextCheckingResult *m = [re firstMatchInString:line options:0 range:search];
            if (!m || m.range.location != search.location) break;
            int min = (int)[[line substringWithRange:[m rangeAtIndex:1]] intValue];
            int sec = (int)[[line substringWithRange:[m rangeAtIndex:2]] intValue];
            NSString *fracStr = [m rangeAtIndex:3].location != NSNotFound
                ? [line substringWithRange:[m rangeAtIndex:3]] : @"";
            double frac = 0;
            if (fracStr.length) {
                // ".5" / ".50" / ".500" 均为 500ms — 逐位缩小,按实际位数归一
                frac = [fracStr doubleValue];
                for (int i = 0; i < (int)fracStr.length; i++) frac /= 10.0;
            }
            [times addObject:@(min * 60 + sec + frac)];
            search = NSMakeRange(NSMaxRange(m.range), line.length - NSMaxRange(m.range));
        }
        if (!times.count) return;
        NSString *text = [line substringWithRange:search];
        text = [text stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
        if (!text.length) text = @"♪";
        for (NSNumber *t in times)
            [lines addObject:[[TBLyricLine alloc] initWithTime:t.doubleValue text:text]];
    }];
    if (!lines.count) return nil;
    [lines sortUsingComparator:^NSComparisonResult(TBLyricLine *a, TBLyricLine *b) {
        return a.time == b.time ? NSOrderedSame : (a.time < b.time ? NSOrderedAscending : NSOrderedDescending);
    }];
    return lines;
}

@end

NS_ASSUME_NONNULL_END
