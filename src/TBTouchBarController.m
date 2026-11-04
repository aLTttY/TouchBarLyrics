#import "TBTouchBarController.h"
#import "TBPrivate.h"
#import "TBMediaRemote.h"
#import "TBLyrics.h"
#import "TBMenuBarLyric.h"
#import <AppKit/AppKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreGraphics/CGEvent.h>

// NX 媒体键码(IOKit/hidsystem/ev_keymap.h 摘录)
enum {
    NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_NEXT = 17, NX_KEYTYPE_PREVIOUS = 18,
    NX_KEYTYPE_FAST = 19, NX_KEYTYPE_REWIND = 20,
};

static NSString * const StripID   = @"com.github.alty.tbl.strip";
static NSString * const PrevID    = @"com.github.alty.tbl.prev";
static NSString * const PlayID    = @"com.github.alty.tbl.play";
static NSString * const NextID    = @"com.github.alty.tbl.next";
static NSString * const LyricsID  = @"com.github.alty.tbl.lyrics";

NS_ASSUME_NONNULL_BEGIN

// 固定尺寸的歌词条容器:系统的 item 布局按顶层视图的 intrinsicContentSize 定宽。
// 文本用 CATextLayer 渲染,超出宽度时来回滚动(marquee)。
@interface TBLyricsContainer : NSView
@property (nonatomic, strong) CATextLayer *textLayer;
@property (nonatomic, strong) NSFont *font;
@property (nonatomic, copy) NSString *currentText;
@end
@implementation TBLyricsContainer
- (instancetype)initWithFrame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layer.masksToBounds = YES;
        self.textLayer = [CATextLayer layer];
        self.textLayer.contentsScale = 2;   // Touch Bar 屏为 2x
        self.textLayer.anchorPoint = CGPointMake(0, 0.5);
        [self.layer addSublayer:self.textLayer];
        self.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightRegular];
    }
    return self;
}
- (CGSize)intrinsicContentSize { return CGSizeMake(360, 30); }

- (void)setLyricsText:(NSString *)s {
    if (!s || [s isEqualToString:self.currentText]) return;
    self.currentText = s;
    NSAttributedString *as = [[NSAttributedString alloc] initWithString:s attributes:@{
        NSFontAttributeName: self.font,
        NSForegroundColorAttributeName: NSColor.whiteColor,
    }];
    CGFloat w = ceil(as.size.width) + 4, h = ceil(as.size.height);
    CGFloat barW = self.bounds.size.width, pad = 8;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];   // 换行时禁止隐式动画
    self.textLayer.string = as;
    self.textLayer.bounds = CGRectMake(0, 0, w, h);
    self.textLayer.position = CGPointMake(pad, 15);   // anchor(0,0.5) → 纵向居中
    [self.textLayer removeAnimationForKey:@"marquee"];
    if (w <= barW - pad * 2) {
        // 放得下:水平居中
        self.textLayer.position = CGPointMake((barW - w) / 2, 15);
    } else {
        // 放不下:从左缘滚到露出尾部,再滚回来,循环
        CGFloat travel = w - (barW - pad * 2);
        self.textLayer.position = CGPointMake(pad, 15);
        CABasicAnimation *a = [CABasicAnimation animationWithKeyPath:@"position.x"];
        a.fromValue = @(pad);
        a.toValue = @(pad - travel);
        a.duration = MAX(4, travel / 25.0);   // 约 25pt/s,过快看不清
        a.autoreverses = YES;
        a.repeatCount = HUGE_VALF;
        a.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
        [self.textLayer addAnimation:a forKey:@"marquee"];
    }
    [CATransaction commit];
}
@end

@interface TBTouchBarController ()
@property (nonatomic, strong) NSTouchBar *touchBar;
@property (nonatomic, strong) NSCustomTouchBarItem *lyricsItem;
@property (nonatomic, strong) TBLyricsContainer *lyricsView;
// 播放状态
@property (nonatomic, copy, nullable) NSString *title, *artist;
@property (nonatomic, assign) BOOL playing;
// 进度快照:MediaRemote 的 (elapsed, timestamp, rate)。网易云只在事件
// (切歌/拖动进度/暂停)时重发布快照,平时冻结;推进公式(同 LyricsX
// MediaRemoteAdapter):position = elapsed + (now - timestamp) × rate。
// 暂停判定不用字典 rate(滞后),用实时的 IsPlaying:为假则冻结在 lastPos。
@property (nonatomic, assign) double snapElapsed, snapTS, snapRate, snapDuration;
@property (nonatomic, assign) BOOL hasSnapshot;
@property (nonatomic, assign) double lastPos;
@property (nonatomic, assign) BOOL snapDirty, everPlaying;
// 菜单栏歌词同步(地面真值)
@property (nonatomic, assign) NSInteger hintIdx;
@property (nonatomic, assign) NSInteger hintNoMatch;
@property (nonatomic, assign) CFAbsoluteTime lastAnchorWall;
@property (nonatomic, copy) NSString *lastFallbackCand;
// 歌词
@property (nonatomic, copy, nullable) NSArray<TBLyricLine *> *lines;
@property (nonatomic, assign) NSInteger currentLine;
@property (nonatomic, assign) BOOL lyricsLoaded, lyricsPending;
@end

@implementation TBTouchBarController

- (void)start {
    [NSTouchBarItem class]; // 确保链接 AppKit 后私有类别生效
    // 歌词条:[⏮][⏯][⏭][ ——— 歌词 ——— ];收起用左侧系统 ✕ 或再点 ♪
    self.touchBar = [[NSTouchBar alloc] init];
    self.touchBar.templateItems = [NSSet setWithArray:@[
        [self prevItem], [self playItem],
        [self nextItem], self.lyricsItem = [self buildLyricsItem],
    ]];
    self.touchBar.defaultItemIdentifiers = @[PrevID, PlayID, NextID, LyricsID];

    // Control Strip ♪ 注册 + 展开:开机瞬间 DFR 服务可能未就绪导致注册
    // 静默失败,故注册后自检 presence,未生效则重试
    [self registerStripAndPresent];

    [self render:@"未在播放"];
    // 锁屏/熄屏会清掉 system modal 展示;解锁/唤醒后重新注册 + 展开
    // (observer token 保存在静态数组中,app 生命周期内不移除)
    static NSArray<id> *observers = nil;
    NSWorkspace *ws = [NSWorkspace sharedWorkspace];
    observers = @[
        [ws.notificationCenter addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                                           object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *n) { [self registerStripAndPresent]; }],
        [ws.notificationCenter addObserverForName:NSWorkspaceScreensDidWakeNotification
                                           object:nil queue:[NSOperationQueue mainQueue]
                                      usingBlock:^(NSNotification *n) { [self registerStripAndPresent]; }],
    ];
    (void)observers;   // token 仅用于延长生命周期
    [TBMediaRemote.shared startWithHandler:^(NSDictionary *_Nullable info) {
        [self onNowPlaying:info];
    }];
    // 菜单栏歌词 = 网易云自己算的进度,是最佳同步基准
    [[TBMenuBarLyric shared] startWithHandler:^(NSString *_Nullable text) {
        [self applyLyricHint:text];
    }];
}

/// 注册 ♪ 到 Control Strip 并展开歌词条;presence 未生效时最多重试 30 次
- (void)registerStripAndPresent {
    static NSCustomTouchBarItem *stripItem = nil;
    static int retryCount = 0;
    if (!stripItem) {
        stripItem = [[NSCustomTouchBarItem alloc] initWithIdentifier:StripID];
        stripItem.view = [NSButton buttonWithTitle:@"♪" target:self action:@selector(presentLyrics:)];
        [NSTouchBarItem addSystemTrayItem:stripItem];
    }
    tbl_DFRSetControlStripPresence(StripID, YES);
    [self presentLyrics:nil];

    BOOL present = tbl_DFRGetControlStripPresence ? tbl_DFRGetControlStripPresence(StripID) : YES;
    if (!present && retryCount < 30) {
        retryCount++;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [self registerStripAndPresent]; });
        return;
    }
    retryCount = 0;
}

#pragma mark - Touch Bar item 组装

- (NSButtonTouchBarItem *)prevItem {
    return [NSButtonTouchBarItem buttonTouchBarItemWithIdentifier:PrevID
        title:@"⏮" target:self action:@selector(prevTrack:)];
}
- (NSButtonTouchBarItem *)playItem {
    return [NSButtonTouchBarItem buttonTouchBarItemWithIdentifier:PlayID
        title:@"⏯" target:self action:@selector(togglePlay:)];
}
- (NSButtonTouchBarItem *)nextItem {
    return [NSButtonTouchBarItem buttonTouchBarItemWithIdentifier:NextID
        title:@"⏭" target:self action:@selector(nextTrack:)];
}
- (NSCustomTouchBarItem *)buildLyricsItem {
    NSCustomTouchBarItem *item = [[NSCustomTouchBarItem alloc] initWithIdentifier:LyricsID];
    TBLyricsContainer *container = [[TBLyricsContainer alloc]
        initWithFrame:NSMakeRect(0, 0, 360, 30)];
    self.lyricsView = container;
    item.view = container;
    return item;
}

- (void)presentLyrics:(nullable id)sender {
    [NSTouchBar presentSystemModalTouchBar:self.touchBar systemTrayItemIdentifier:StripID];
}

- (void)minimize:(id)sender {
    [NSTouchBar minimizeSystemModalTouchBar:self.touchBar];
}

#pragma mark - 播放控制(MRMediaRemoteSendCommand,HID 媒体键兜底)

// MRCommand 枚举(LyricsX mediaremote-adapter-framework 同款):
// kMRPlay=0 kMRPause=1 kMRTogglePlayPause=2 kMRNextTrack=4 kMRPreviousTrack=5
// 注意:HID 媒体键(16/17-20)对网易云的切歌无效,必须走 SendCommand。
static void postMediaKey(int key) {
    for (int down = 1; down >= 0; down--) {
        NSEvent *e = [NSEvent otherEventWithType:NSEventTypeSystemDefined
                                        location:NSZeroPoint modifierFlags:0
                                       timestamp:0 windowNumber:0 context:nil
                                         subtype:8
                                           data1:(key << 16) | (0xA00 | down)
                                           data2:key << 16];
        if (e.CGEvent) CGEventPost(kCGHIDEventTap, e.CGEvent);
    }
}
- (void)sendOrKey:(int)cmd key:(int)key {
    if (![TBMediaRemote sendCommand:cmd]) postMediaKey(key);
}
- (void)togglePlay:(id)sender { [self sendOrKey:2 key:NX_KEYTYPE_PLAY];   }
- (void)nextTrack:(id)sender  { [self sendOrKey:4 key:NX_KEYTYPE_NEXT];   }
- (void)prevTrack:(id)sender  { [self sendOrKey:5 key:NX_KEYTYPE_PREVIOUS]; }

#pragma mark - 播放信息 → 歌词同步

- (void)onNowPlaying:(NSDictionary *)info {
    if (!info) {
        if (!self.title) [self render:@"未在播放"];
        return;
    }
    NSString *title  = [info[@"title"] isKindOfClass:[NSString class]]  ? info[@"title"]  : nil;
    NSString *artist = [info[@"artist"] isKindOfClass:[NSString class]] ? info[@"artist"] : nil;
    NSNumber *elapsed = [info[@"elapsed"] isKindOfClass:[NSNumber class]] ? info[@"elapsed"] : nil;
    NSNumber *playingNum = [info[@"playing"] isKindOfClass:[NSNumber class]] ? info[@"playing"] : nil;
    NSNumber *rateNum  = [info[@"rate"] isKindOfClass:[NSNumber class]] ? info[@"rate"] : nil;
    NSDate   *tsDate   = [info[@"timestamp"] isKindOfClass:[NSDate class]] ? info[@"timestamp"] : nil;

    BOOL songChanged = NO;
    if (title.length && ![title isEqualToString:self.title ?: @""]) {
        songChanged = YES;
        self.title = title;
        self.artist = artist;
        self.lines = nil;
        self.lyricsLoaded = NO;
        self.currentLine = -1;
        self.hintIdx = NSNotFound;
        self.hintNoMatch = 0;
    }
    // 记录最新快照。切歌过渡期可能短暂出现新歌名 + 旧进度(网易云分两步
    // 更新字典),下一次重发布即自行修正,无需特判。
    if (elapsed) {
        double e  = elapsed.doubleValue;
        double ts = tsDate ? tsDate.timeIntervalSince1970
                           : [NSDate date].timeIntervalSince1970;
        NSNumber *durNum = [info[@"duration"] isKindOfClass:[NSNumber class]] ? info[@"duration"] : nil;
        if (!self.hasSnapshot || e != self.snapElapsed || ts != self.snapTS) {
            self.snapElapsed  = e;
            self.snapRate     = rateNum ? rateNum.doubleValue : 1.0;
            self.snapTS       = ts;
            self.snapDuration = durNum ? durNum.doubleValue : 0;
            self.hasSnapshot  = YES;
            self.snapDirty    = YES;   // 快照重发布(含拖动进度),允许重新计算
        }
    }
    BOOL wasPlaying = self.playing, wasEver = self.everPlaying;
    if (playingNum) {
        self.playing = playingNum.boolValue;
        if (self.playing) self.everPlaying = YES;
    }
    // 恢复播放:网易云未必重发快照,旧 timestamp 含整段暂停时长,会让歌词
    // 大幅超前(如暂停 3 分钟则超前 3 分钟)。以冻结位置为基准重置插值时钟。
    // (app 启动首帧 wasEver=NO,跳过以免覆盖真实快照)
    if (self.playing && !wasPlaying && wasEver && self.hasSnapshot) {
        self.snapElapsed = self.lastPos;
        self.snapTS = [[NSDate date] timeIntervalSince1970];
        self.snapDirty = YES;
    }

    if (songChanged) [self fetchLyrics];
    [self refreshLine];
}

/// 当前播放进度:播放中按公式推进;暂停时冻结在 lastPos(LyricsX 同款语义)。
/// 暂停期间拖动进度 → 快照重发布(snapDirty)→ 直接落位到新 elapsed。
- (double)displayElapsed {
    if (!self.hasSnapshot) return 0;
    if (self.playing || self.snapDirty) {
        double rate = self.snapRate > 0 ? self.snapRate : 1.0;
        double pos = self.snapElapsed
            + ([[NSDate date] timeIntervalSince1970] - self.snapTS) * rate;
        // 歌已结束但快照未更新时钳在末尾,防止越界
        if (self.snapDuration > 1 && pos > self.snapDuration - 0.5) pos = self.snapDuration - 0.5;
        if (pos < 0) pos = 0;
        self.lastPos = pos;
        self.snapDirty = NO;
    }
    return self.lastPos;
}

- (void)fetchLyrics {
    if (self.lyricsPending || !self.title.length) return;
    self.lyricsPending = YES;
    NSString *title = self.title, *artist = self.artist;
    [TBLyrics.shared lyricsForTitle:title artist:artist duration:self.snapDuration
                         completion:^(NSArray<TBLyricLine *> *_Nullable lines) {
        // 期间切歌则丢弃本次结果
        if (![title isEqualToString:self.title ?: @""]) return;
        self.lyricsPending = NO;
        self.lyricsLoaded = YES;
        self.lines = lines;
        self.currentLine = -1;
        [self refreshLine];
    }];
}

/// 依据 elapsed 找当前歌词行并刷新显示
- (void)refreshLine {
    if (!self.title.length) { [self render:@"未在播放"]; return; }
    NSString *songLabel = self.artist.length
        ? [NSString stringWithFormat:@"%@ — %@", self.title, self.artist] : self.title;

    if (!self.lines) {
        [self render:self.lyricsLoaded
            ? [NSString stringWithFormat:@"🎵 %@ · 未找到歌词", songLabel]
            : [NSString stringWithFormat:@"🎵 %@ · 查词中…", songLabel]];
        return;
    }
    NSInteger idx = -1;
    for (NSInteger i = 0; i < (NSInteger)self.lines.count; i++) {
        if (self.lines[i].time <= [self displayElapsed] + 0.15) idx = i; else break;
    }
    if (idx != self.currentLine) self.currentLine = idx;
    TBLyricLine *line = idx >= 0 ? self.lines[idx] : nil;
    NSString *text = line ? line.text : @"♪";
    [self render:[NSString stringWithFormat:@"  %@  ", text]];
}

- (void)render:(NSString *)s {
    // 同文本不刷,减少 Touch Bar 重绘(去重逻辑在 container 内部)
    [self.lyricsView performSelectorOnMainThread:@selector(setLyricsText:)
                                      withObject:s waitUntilDone:NO];
}

#pragma mark - 菜单栏歌词同步(地面真值)

static NSString *TBNormalize(NSString *s) {
    // 只保留字母数字与 CJK,小写化,抵消 OCR 空格/标点噪声
    NSCharacterSet *keep = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"];
    NSMutableString *out = [NSMutableString string];
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        NSString *ch = [NSString stringWithCharacters:&c length:1];
        if (c >= 0x4e00 && c <= 0x9fff) [out appendString:ch];
        else if ([keep characterIsMember:c]) [out appendString:[ch lowercaseString]];
    }
    return out;
}
static BOOL TBFuzzyMatch(NSString *a, NSString *b) {
    NSString *na = TBNormalize(a), *nb = TBNormalize(b);
    if (na.length < 2 || nb.length < 2) return NO;
    if ([na containsString:nb] || [nb containsString:na]) return YES;
    // 字符重合率(以短串为分母),容忍 OCR 错字
    NSString *shorter = na.length <= nb.length ? na : nb;
    NSString *longer  = na.length <= nb.length ? nb : na;
    NSMutableCharacterSet *cs = [NSMutableCharacterSet characterSetWithCharactersInString:shorter];
    NSInteger hit = 0;
    for (NSUInteger i = 0; i < longer.length; i++)
        if ([cs characterIsMember:[longer characterAtIndex:i]]) { hit++; [cs removeCharactersInString:[NSString stringWithFormat:@"%C", [longer characterAtIndex:i]]]; }
    return (double)hit / (double)shorter.length >= 0.6;
}

/// 是否为时钟/日期类菜单栏垃圾(11月4日周三 20:12 之类)
static BOOL TBJunkText(NSString *s) {
    static NSRegularExpression *re = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        re = [NSRegularExpression regularExpressionWithPattern:
            @"\\d{1,2}月\\d{1,2}日|周[一二三四五六日天]|\\d{1,2}:\\d{2}" options:0 error:NULL];
    });
    return [re numberOfMatchesInString:s options:0 range:NSMakeRange(0, s.length)] > 0;
}
/// 是否"像歌词":含 ≥2 个 CJK 字符,或 ≥4 个连续字母,且不是时钟垃圾
static BOOL TBLyricLike(NSString *s) {
    if (TBJunkText(s)) return NO;
    NSInteger cjk = 0, letters = 0, run = 0, bestRun = 0;
    for (NSUInteger i = 0; i < s.length; i++) {
        unichar c = [s characterAtIndex:i];
        if (c >= 0x4e00 && c <= 0x9fff) { cjk++; run = 0; }
        else if ((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')) { run++; bestRun = MAX(bestRun, run); letters++; }
        else run = 0;
    }
    return (cjk >= 2) || (letters >= 4 && bestRun >= 4);
}

/// 用菜单栏歌词校准播放位置。OCR 候选逐个对 LRC 行模糊匹配(取离当前位置
/// 最近的命中行),命中行变化时把位置锚定到该行时间;重复副歌不会跳回开头。
/// 全部匹配不上(网易云用了不同版本歌词)且候选稳定时,直接显示 OCR 文本兜底。
- (void)applyLyricHint:(NSArray<NSString *> *)candidates {
    if (!self.playing) return;
    NSMutableArray<NSString *> *pool = [NSMutableArray array];
    for (NSString *c in candidates) if (TBLyricLike(c)) [pool addObject:c];
    if (!pool.count) return;

    if (!self.lines) {
        // 没抓到我们自己的歌词:显示稳定的歌词候选(连续两轮相同才上屏)
        NSString *c = pool.firstObject;
        if ([c isEqualToString:self.lastFallbackCand])
            [self render:[NSString stringWithFormat:@"  %@  ", c]];
        self.lastFallbackCand = c;
        return;
    }
    double pos = [self displayElapsed];
    NSInteger bestIdx = NSNotFound;
    double bestDist = 1e9;
    for (NSString *c in pool) {
        for (NSInteger i = 0; i < (NSInteger)self.lines.count; i++) {
            NSString *t = self.lines[i].text;
            if (t.length < 2 || [t isEqualToString:@"♪"]) continue;
            if (!TBFuzzyMatch(c, t)) continue;
            double d = fabs(self.lines[i].time - pos);
            if (d < bestDist) { bestDist = d; bestIdx = i; }
        }
    }
    if (bestIdx == NSNotFound) {
        // 连续多轮匹配不上且候选稳定:显示 OCR 文本兜底(网易云版本与我们的不同)
        self.hintNoMatch++;
        NSString *c = pool.firstObject;
        if (self.hintNoMatch >= 6 && self.hintIdx == NSNotFound &&
            [c isEqualToString:self.lastFallbackCand])
            [self render:[NSString stringWithFormat:@"  %@  ", c]];
        self.lastFallbackCand = c;
        return;
    }
    self.hintNoMatch = 0;
    self.lastFallbackCand = nil;
    if (bestIdx == self.hintIdx) return;
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (self.hintIdx != NSNotFound && now - self.lastAnchorWall < 0.5) return;   // 防抖
    self.hintIdx = bestIdx;
    self.currentLine = bestIdx;
    self.snapElapsed = self.lines[bestIdx].time;
    self.snapTS = [[NSDate date] timeIntervalSince1970];
    self.snapRate = self.snapRate > 0 ? self.snapRate : 1.0;
    self.snapDirty = YES;
    self.lastAnchorWall = now;
    [self refreshLine];
}

@end

NS_ASSUME_NONNULL_END
