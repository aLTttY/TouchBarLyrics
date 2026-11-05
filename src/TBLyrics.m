#import "TBLyrics.h"
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *TBLowerNoSpace(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@" " withString:@""]
        lowercaseString];
}

@implementation TBLyricLine
- (instancetype)initWithTime:(double)t text:(NSString *)s {
    self = [super init];
    if (self) { _time = t; _text = s; }
    return self;
}
@end

@interface TBLyrics ()
@property (nonatomic, strong) NSCache<NSString *, NSArray<TBLyricLine *> *> *cache;
@end

@implementation TBLyrics

+ (instancetype)shared {
    static TBLyrics *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

/// 从网易云客户端本地数据库读当前歌曲的精确 song id(播放历史最新 30 行里
/// 找与标题匹配的行)。拿到 id 后按 id 取词,彻底绕过搜索匹配的错版问题。
+ (nullable NSNumber *)historySongIdForTitle:(NSString *)title {
    NSString *dbPath = [@"/Users/lumingyuan/Library/Application Support/com.netease.163music/Documents/storage/sqlite_storage.sqlite3"
        stringByExpandingTildeInPath];
    NSString *copyPath = [NSTemporaryDirectory() stringByAppendingPathComponent:@"tbl_nm_history.sqlite3"];
    NSFileManager *fm = [NSFileManager defaultManager];
    [fm removeItemAtPath:copyPath error:NULL];
    if (![fm copyItemAtPath:dbPath toPath:copyPath error:NULL]) return nil;

    NSNumber *result = nil;
    sqlite3 *db = NULL;
    if (sqlite3_open_v2(copyPath.fileSystemRepresentation, &db, SQLITE_OPEN_READONLY, NULL) == SQLITE_OK) {
        sqlite3_stmt *stmt = NULL;
        if (sqlite3_prepare_v2(db, "SELECT jsonStr FROM historyTracks ORDER BY playtime DESC LIMIT 30",
                               -1, &stmt, NULL) == SQLITE_OK) {
            NSString *want = TBLowerNoSpace(title);
            while (sqlite3_step(stmt) == SQLITE_ROW) {
                const unsigned char *js = sqlite3_column_text(stmt, 0);
                if (!js) continue;
                id json = [NSJSONSerialization JSONObjectWithData:
                    [NSData dataWithBytes:js length:strlen((const char *)js)] options:0 error:NULL];
                NSString *name = [json isKindOfClass:[NSDictionary class]] ? json[@"name"] : nil;
                if (![name isKindOfClass:[NSString class]]) continue;
                if ([TBLowerNoSpace(name) isEqualToString:want]) {
                    id sid = json[@"id"];
                    if ([sid isKindOfClass:[NSNumber class]]) result = sid;
                    break;
                }
            }
            sqlite3_finalize(stmt);
        }
        sqlite3_close(db);
    }
    [fm removeItemAtPath:copyPath error:NULL];
    return result;
}

/// 依次尝试多个「来源 × 查询词」组合,任一成功即返回;全失败 completion(nil)。
/// 顺序:网易(歌名+歌手) → 网易(歌名) → QQ(歌名+歌手) → QQ(歌名)。
/// target 为正在播放的时长(秒),用于多版本候选中挑时长最接近的。
- (void)lyricsForTitle:(NSString *)title artist:(nullable NSString *)artist
              duration:(double)targetSec
            completion:(TBLyricsCallback)completion {
    NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
    NSArray<TBLyricLine *> *hit = [self.cache objectForKey:key];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ completion(hit); }); return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __weak typeof(self) wself = self;
        // 最优来源:网易云客户端历史库里的精确 song id(用户就在网易云听,
        // 该 id 与播放内容必然一致),按 id 取词零歧义
        NSNumber *hid = [TBLyrics historySongIdForTitle:title];
        if (hid) {
            [self fetchNetEaseLyric:hid completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (lines) {
                    [wself.cache setObject:lines forKey:key];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
                    return;
                }
                // 该 id 在网易云也没词 → QQ 兜底(换平台碰运气)
                NSString *withArtist = artist.length
                    ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
                [wself searchQQ:withArtist target:targetSec completion:^(NSString *_Nullable mid) {
                    if (!mid) {
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
                        return;
                    }
                    [wself fetchQQLyric:mid completion:^(NSArray<TBLyricLine *> *_Nullable qlines) {
                        if (qlines) [wself.cache setObject:qlines forKey:key];
                        dispatch_async(dispatch_get_main_queue(), ^{ completion(qlines); });
                    }];
                }];
            }];
            return;
        }
        // 历史库不可用(路径变了/没在网易云听):常规搜索链
        NSString *withArtist = artist.length
            ? [NSString stringWithFormat:@"%@ %@", title, artist] : title;
        NSArray<NSString *> *queries = @[withArtist, title, withArtist, title];
        [self runAttempt:0 queries:queries target:targetSec key:key completion:completion];
    });
}

- (void)runAttempt:(NSInteger)i queries:(NSArray<NSString *> *)queries
            target:(double)target key:(NSString *)key
        completion:(TBLyricsCallback)completion {
    if (i >= queries.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    BOOL isQQ = (i >= 2);
    NSString *query = queries[i];
    __weak typeof(self) wself = self;
    void (^fail)(void) = ^{
        [wself runAttempt:i + 1 queries:queries target:target key:key completion:completion];
    };
    void (^succeed)(NSArray<TBLyricLine *> *) = ^(NSArray<TBLyricLine *> *lines) {
        [wself.cache setObject:lines forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
    };

    if (!isQQ) {
        [self searchNetEase:query target:target completion:^(NSNumber *_Nullable songId) {
            if (!songId) return fail();
            [wself fetchNetEaseLyric:songId completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (!lines) return fail();
                succeed(lines);
            }];
        }];
    } else {
        [self searchQQ:query target:target completion:^(NSString *_Nullable mid) {
            if (!mid) return fail();
            [wself fetchQQLyric:mid completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (!lines) return fail();
                succeed(lines);
            }];
        }];
    }
}

#pragma mark - 网易云

/// 搜索:精确同名优先;同名或全部候选中挑时长最接近 target 的
/// (翻唱/伴奏/现场版时长差异明显),避免搜到错误版本。
- (void)searchNetEase:(NSString *)query target:(double)targetSec
           completion:(void (^)(NSNumber *_Nullable songId))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get/web?s=%@&type=1&limit=8",
        [query stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]]];
    [self getJSON:urlStr referer:@"https://music.163.com/" completion:^(id _Nullable json) {
        NSArray *songs = json[@"result"][@"songs"];
        if (![songs isKindOfClass:[NSArray class]]) { completion(nil); return; }
        NSNumber *exact = nil, *exactDur = nil, *anyBest = nil;
        double anyBestDiff = 1e9;
        for (NSDictionary *song in songs) {
            NSString *name = song[@"name"];
            if (![name isKindOfClass:[NSString class]]) continue;
            id sid = song[@"id"];
            if (![sid isKindOfClass:[NSNumber class]]) continue;
            id durVal = song[@"duration"];
            double dur = [durVal isKindOfClass:[NSNumber class]]
                ? [(NSNumber *)durVal doubleValue] / 1000.0 : 0;
            double diff = (targetSec > 1 && dur > 1) ? fabs(dur - targetSec) : 0;
            BOOL exactName = [name isEqualToString:query];
            if (exactName && !exact) { exact = sid; exactDur = @(dur); continue; }
            if (exactName && targetSec > 1 && dur > 1) {
                double cur = exactDur ? exactDur.doubleValue : 0;
                if (diff < fabs(cur - targetSec)) { exact = sid; exactDur = @(dur); }
            }
            if (targetSec > 1 && dur > 1 && diff < anyBestDiff) {
                anyBestDiff = diff; anyBest = sid;
            }
        }
        if (exact && targetSec > 1) {
            double d = exactDur ? fabs(exactDur.doubleValue - targetSec) : 1e9;
            if (d > 8 && anyBest && anyBestDiff < d) exact = anyBest;
        }
        if (!exact) exact = anyBest;
        completion(exact);
    }];
}

- (void)fetchNetEaseLyric:(NSNumber *)songId
               completion:(void (^)(NSArray<TBLyricLine *> *_Nullable lines))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://music.163.com/api/song/lyric?id=%@&lv=1&kv=1&tv=-1", songId];
    [self getJSON:urlStr referer:@"https://music.163.com/" completion:^(id _Nullable json) {
        NSString *lrcText = json[@"lrc"][@"lyric"];
        completion([lrcText isKindOfClass:[NSString class]]
            ? [TBLyrics parseLRC:lrcText] : nil);
    }];
}

#pragma mark - QQ 音乐(网易云缺词时的第二来源)

- (void)searchQQ:(NSString *)query target:(double)targetSec
      completion:(void (^)(NSString *_Nullable songMid))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=%@&format=json",
        [query stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]]];
    [self getJSON:urlStr referer:@"https://y.qq.com/" completion:^(id _Nullable json) {
        NSArray *songs = json[@"data"][@"song"][@"list"];
        if (![songs isKindOfClass:[NSArray class]]) { completion(nil); return; }
        NSString *exact = nil, *anyBest = nil;
        double exactDiff = 1e9, anyBestDiff = 1e9;
        for (NSDictionary *song in songs) {
            NSString *mid = song[@"songmid"];
            NSString *name = song[@"songname"];
            if (![mid isKindOfClass:[NSString class]]) continue;
            double dur = [song[@"interval"] isKindOfClass:[NSNumber class]]
                ? [song[@"interval"] doubleValue] : 0;
            double diff = (targetSec > 1 && dur > 1) ? fabs(dur - targetSec) : 0;
            BOOL exactName = [name isKindOfClass:[NSString class]] && [name isEqualToString:query];
            if (exactName && diff < exactDiff) { exactDiff = diff; exact = mid; }
            if (targetSec > 1 && dur > 1 && diff < anyBestDiff) {
                anyBestDiff = diff; anyBest = mid;
            }
        }
        if (exact && anyBest && anyBestDiff < exactDiff) exact = anyBest;
        if (!exact) exact = anyBest;
        completion(exact);
    }];
}

- (void)fetchQQLyric:(NSString *)mid
          completion:(void (^)(NSArray<TBLyricLine *> *_Nullable lines))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://c.y.qq.com/lyric/fcgi-bin/fcg_query_lyric_new.fcg?songmid=%@&g_tk=5381&format=json", mid];
    [self getJSON:urlStr referer:@"https://y.qq.com/" completion:^(id _Nullable json) {
        NSString *b64 = json[@"lyric"];
        if (![b64 isKindOfClass:[NSString class]] || !b64.length) { completion(nil); return; }
        NSData *data = [[NSData alloc] initWithBase64EncodedString:b64 options:0];
        NSString *lrcText = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        completion([TBLyrics parseLRC:lrcText ?: @""]);
    }];
}

#pragma mark - 通用请求与解析

- (void)getJSON:(NSString *)urlStr referer:(NSString *)referer
     completion:(void (^)(id _Nullable json))completion {
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:urlStr]];
    // 两家接口都要求浏览器 UA + 对应域名 Referer,否则 403/空结果
    [req setValue:@"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15"
        forHTTPHeaderField:@"User-Agent"];
    [req setValue:referer forHTTPHeaderField:@"Referer"];
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
