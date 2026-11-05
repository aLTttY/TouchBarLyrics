#import "TBLyrics.h"
#import <sqlite3.h>

NS_ASSUME_NONNULL_BEGIN

static NSString *TBLowerNoSpace(NSString *s) {
    return [[s stringByReplacingOccurrencesOfString:@" " withString:@""]
        lowercaseString];
}

static NSString *TBNorm(NSString *s) {
    return TBLowerNoSpace(s ?: @"");
}

/// 版本后缀降权:伴奏/和声/DJ/加速/翻唱等常无词或词不同
static BOOL TBVersionSuffix(NSString *name) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
            @"伴奏|和声|DJ|Remix|remix|加速|降速|0\\.9x|1\\.2x|[Ll]ive|现场|[Cc]over|翻唱|纯音乐|Instrumental"
            options:0 error:NULL];
    });
    return [re numberOfMatchesInString:name ?: @""
                               options:0 range:NSMakeRange(0, (name ?: @"").length)] > 0;
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

/// 从网易云客户端本地数据库读当前歌曲的精确 song id。行写入有延迟
/// (开播后约 30~90s 才入库),故需要轮询重试。
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

- (void)lyricsForTitle:(NSString *)title artist:(nullable NSString *)artist
              duration:(double)targetSec
            completion:(TBLyricsCallback)completion {
    NSString *key = [NSString stringWithFormat:@"%@|%@", title, artist ?: @""];
    NSArray<TBLyricLine *> *hit = [self.cache objectForKey:key];
    if (hit) { dispatch_async(dispatch_get_main_queue(), ^{ completion(hit); }); return; }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __weak typeof(self) wself = self;
        __block BOOL done = NO;
        void (^finish)(NSArray<TBLyricLine *> *_Nullable lines, BOOL cacheIt) =
            ^(NSArray<TBLyricLine *> *_Nullable lines, BOOL cacheIt) {
            if (cacheIt) [wself.cache setObject:lines forKey:key];
            dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
        };
        void (^searchChainThenPoll)(void) = ^{
            [wself runAttempt:0 queries:@[
                    artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title,
                    title,
                    artist.length ? [NSString stringWithFormat:@"%@ %@", title, artist] : title,
                    title]
                target:targetSec artist:artist key:key
                completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (done) return;
                done = YES;
                dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
                // 搜索链出词后,后台轮询历史库:行入库后按精确 id 重取歌词,
                // 再次回调替换(controller 幂等消费)——纠错可能选错的版本
                [wself pollHistoryUpgrade:title artist:artist key:key
                    completion:^(NSArray<TBLyricLine *> *_Nullable better) {
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(better); });
                }];
            }];
        };

        // 1) 开播瞬间历史库可能尚未写入本行(延迟 30~90s);命中(重放场景)
        //    则按精确 id 直取,拿词即终结,不跑搜索链
        NSNumber *hid0 = [TBLyrics historySongIdForTitle:title];
        if (hid0) {
            [wself fetchNetEaseLyric:hid0 completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (lines) {
                    done = YES;
                    finish(lines, YES);
                    return;
                }
                // 精确 id 在网易云也没词 → 搜索链(含 QQ)先出,轮询不再需要:
                // 历史库 id 相同,轮询取词结果也为空。但 QQ 可能有 → 已含在链中
                if (!done) searchChainThenPoll();
            }];
            return;
        }
        // 2) 未命中:搜索链先出词,随后轮询历史库纠错
        searchChainThenPoll();
    });
}

/// 播放开始后历史库行延迟入库:15s/35s/70s 三次轮询,拿到精确 id 后
/// 重取歌词并再次回调(completion 会被 controller 幂等消费,替换显示)。
- (void)pollHistoryUpgrade:(NSString *)title artist:(nullable NSString *)artist
                       key:(NSString *)key
                completion:(TBLyricsCallback)completion {
    // 注意:递归块必须 __block 声明,否则块内引用到的是赋值前的未初始化
    // 指针,第一次重试即段错误(已实测崩溃)
    __block void (^tryOnce)(void);
    __block NSInteger attempt = 0;
    __weak typeof(self) wself = self;
    static const double delays[] = {15, 35, 70};
    tryOnce = ^{
        if (attempt >= 3 || !wself) return;
        double d = delays[attempt];
        attempt++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(d * NSEC_PER_SEC)),
            dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
                NSNumber *hid = [TBLyrics historySongIdForTitle:title];
                if (!hid) { tryOnce(); return; }
                [wself fetchNetEaseLyric:hid completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                    if (!lines) { tryOnce(); return; }
                    [wself.cache setObject:lines forKey:key];
                    dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
                }];
        });
    };
    tryOnce();
}

- (void)runAttempt:(NSInteger)i queries:(NSArray<NSString *> *)queries
            target:(double)target artist:(nullable NSString *)artist key:(NSString *)key
        completion:(void (^)(NSArray<TBLyricLine *> *_Nullable lines))completion {
    if (i >= queries.count) {
        dispatch_async(dispatch_get_main_queue(), ^{ completion(nil); });
        return;
    }
    BOOL isQQ = (i >= 2);
    NSString *query = queries[i];
    __weak typeof(self) wself = self;
    void (^fail)(void) = ^{
        [wself runAttempt:i + 1 queries:queries target:target artist:artist key:key completion:completion];
    };
    void (^succeed)(NSArray<TBLyricLine *> *) = ^(NSArray<TBLyricLine *> *lines) {
        [wself.cache setObject:lines forKey:key];
        dispatch_async(dispatch_get_main_queue(), ^{ completion(lines); });
    };

    if (!isQQ) {
        [self searchNetEase:query target:target artist:artist
            completion:^(NSNumber *_Nullable songId) {
            if (!songId) return fail();
            [wself fetchNetEaseLyric:songId completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (!lines) return fail();
                succeed(lines);
            }];
        }];
    } else {
        [self searchQQ:query target:target artist:artist completion:^(NSString *_Nullable mid) {
            if (!mid) return fail();
            [wself fetchQQLyric:mid completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
                if (!lines) return fail();
                succeed(lines);
            }];
        }];
    }
}

#pragma mark - 候选评分(歌手匹配优先,版本后缀降权,时长就近)

/// 候选综合分:越小越好 = 时长差 + 歌手不匹配罚 20 + 版本后缀罚 15
+ (double)scoreCandidateName:(NSString *)name
                candidateArt:(NSString *)candidateArtists
                       query:(NSString *)query
               playingArtist:(NSString *)playingArtist
                   targetSec:(double)targetSec
                candidateSec:(double)candSec {
    double diff = (targetSec > 1 && candSec > 1) ? fabs(candSec - targetSec) : 15;
    double score = diff;
    NSString *pa = TBNorm(playingArtist);
    NSString *ca = TBNorm(candidateArtists);
    if (pa.length >= 2 && ca.length >= 2 && [ca containsString:pa]) score += 0;
    else score += 20;
    if (TBVersionSuffix(name)) score += 15;
    (void)query;
    return score;
}

#pragma mark - 网易云

- (void)searchNetEase:(NSString *)query target:(double)targetSec
               artist:(nullable NSString *)artist
           completion:(void (^)(NSNumber *_Nullable songId))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://music.163.com/api/search/get/web?s=%@&type=1&limit=8",
        [query stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]]];
    [self getJSON:urlStr referer:@"https://music.163.com/" completion:^(id _Nullable json) {
        NSArray *songs = json[@"result"][@"songs"];
        if (![songs isKindOfClass:[NSArray class]]) { completion(nil); return; }
        NSString *bestId = nil, *bestName = nil;
        double bestScore = 1e9;
        for (NSDictionary *song in songs) {
            NSString *name = song[@"name"];
            id sid = song[@"id"];
            if (![name isKindOfClass:[NSString class]] || ![sid isKindOfClass:[NSNumber class]]) continue;
            id durVal = song[@"duration"];
            double dur = [durVal isKindOfClass:[NSNumber class]]
                ? [(NSNumber *)durVal doubleValue] / 1000.0 : 0;
            NSMutableString *art = [NSMutableString string];
            for (NSDictionary *a in [song[@"artists"] isKindOfClass:[NSArray class]]
                    ? song[@"artists"] : @[])
                [art appendFormat:@"%@ ", a[@"name"] ?: @""];
            double score = [TBLyrics scoreCandidateName:name candidateArt:art query:query
                playingArtist:artist ?: @"" targetSec:targetSec candidateSec:dur];
            if (score < bestScore) { bestScore = score; bestId = sid; bestName = name; }
        }
        completion(bestId);
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
          artist:(nullable NSString *)artist
      completion:(void (^)(NSString *_Nullable songMid))completion {
    NSString *urlStr = [NSString stringWithFormat:
        @"https://c.y.qq.com/soso/fcgi-bin/client_search_cp?w=%@&format=json",
        [query stringByAddingPercentEncodingWithAllowedCharacters:
            [NSCharacterSet URLQueryAllowedCharacterSet]]];
    [self getJSON:urlStr referer:@"https://y.qq.com/" completion:^(id _Nullable json) {
        NSArray *songs = json[@"data"][@"song"][@"list"];
        if (![songs isKindOfClass:[NSArray class]]) { completion(nil); return; }
        NSString *bestMid = nil;
        double bestScore = 1e9;
        for (NSDictionary *song in songs) {
            NSString *mid = song[@"songmid"];
            NSString *name = song[@"songname"];
            if (![mid isKindOfClass:[NSString class]]) continue;
            double dur = [song[@"interval"] isKindOfClass:[NSNumber class]]
                ? [song[@"interval"] doubleValue] : 0;
            NSMutableString *art = [NSMutableString string];
            for (NSDictionary *a in [song[@"singer"] isKindOfClass:[NSArray class]]
                    ? song[@"singer"] : @[])
                [art appendFormat:@"%@ ", a[@"name"] ?: @""];
            double score = [TBLyrics scoreCandidateName:name candidateArt:art query:query
                playingArtist:artist ?: @"" targetSec:targetSec candidateSec:dur];
            if (score < bestScore) { bestScore = score; bestMid = mid; }
        }
        completion(bestMid);
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
