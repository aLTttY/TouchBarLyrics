#import "TBTouchBarController.h"
#import "TBPrivate.h"
#import "TBMediaRemote.h"
#import "TBLyrics.h"
#import <AppKit/AppKit.h>
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

// 固定尺寸的歌词条容器:系统的 item 布局按顶层视图的 intrinsicContentSize 定宽,
// 内部按钮用 autoresizing 填满 —— 不让系统直接布局按钮,避免 frame 被压成 0
@interface TBLyricsContainer : NSView
@property (nonatomic, strong) NSButton *button;
@end
@implementation TBLyricsContainer
- (CGSize)intrinsicContentSize { return CGSizeMake(360, 30); }
- (void)layout { self.button.frame = self.bounds; [super layout]; }
@end

@interface TBTouchBarController ()
@property (nonatomic, strong) NSTouchBar *touchBar;
@property (nonatomic, strong) NSCustomTouchBarItem *lyricsItem;
@property (nonatomic, strong) NSButton *lyricsLabel;
// 播放状态
@property (nonatomic, copy, nullable) NSString *title, *artist;
@property (nonatomic, assign) BOOL playing;
// 进度快照:MediaRemote 的 (elapsed, timestamp, rate)。网易云只在事件
// (切歌/拖动进度/暂停)时重发布快照,平时冻结;推进公式(同 LyricsX
// MediaRemoteAdapter):position = elapsed + (now - timestamp) × rate。
// 暂停判定不用字典 rate(滞后),用实时的 IsPlaying:为假则冻结在 lastPos。
@property (nonatomic, assign) double snapElapsed, snapTS, snapRate;
@property (nonatomic, assign) BOOL hasSnapshot;
@property (nonatomic, assign) double lastPos;
@property (nonatomic, assign) BOOL snapDirty;
// 歌词
@property (nonatomic, copy, nullable) NSArray<TBLyricLine *> *lines;
@property (nonatomic, assign) NSInteger currentLine;
@property (nonatomic, assign) BOOL lyricsLoaded, lyricsPending;
@end

@implementation TBTouchBarController

- (void)start {
    [NSTouchBarItem class]; // 确保链接 AppKit 后私有类别生效
    // Control Strip 常驻 ♪ 按钮:点击展开歌词
    NSCustomTouchBarItem *strip = [[NSCustomTouchBarItem alloc] initWithIdentifier:StripID];
    NSButton *stripBtn = [NSButton buttonWithTitle:@"♪" target:self action:@selector(presentLyrics:)];
    strip.view = stripBtn;
    [NSTouchBarItem addSystemTrayItem:strip];
    tbl_DFRSetControlStripPresence(StripID, YES);

    // 歌词条:[⏮][⏯][⏭][ ——— 歌词 ——— ];收起用左侧系统 ✕ 或再点 ♪
    self.touchBar = [[NSTouchBar alloc] init];
    self.touchBar.templateItems = [NSSet setWithArray:@[
        [self prevItem], [self playItem],
        [self nextItem], self.lyricsItem = [self buildLyricsItem],
    ]];
    self.touchBar.defaultItemIdentifiers = @[PrevID, PlayID, NextID, LyricsID];

    [self render:@"未在播放"];
    [self presentLyrics:nil];   // 启动即展开;之后仅 ♪ / ✕ 改变展开状态
    // 锁屏/解锁或切用户会话后,系统的 system modal 展示会被清掉,重新展开
    [[NSWorkspace sharedWorkspace].notificationCenter
        addObserverForName:NSWorkspaceSessionDidBecomeActiveNotification
                    object:nil queue:[NSOperationQueue mainQueue]
                usingBlock:^(NSNotification *n) { [self presentLyrics:nil]; }];
    [TBMediaRemote.shared startWithHandler:^(NSDictionary *_Nullable info) {
        [self onNowPlaying:info];
    }];
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
    NSButton *label = [NSButton buttonWithTitle:@"" target:nil action:nil];
    label.font = [NSFont monospacedDigitSystemFontOfSize:15 weight:NSFontWeightRegular];
    container.button = label;
    [container addSubview:label];
    self.lyricsLabel = label;
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
    }
    // 记录最新快照。切歌过渡期可能短暂出现新歌名 + 旧进度(网易云分两步
    // 更新字典),下一次重发布即自行修正,无需特判。
    if (elapsed) {
        double e  = elapsed.doubleValue;
        double ts = tsDate ? tsDate.timeIntervalSince1970
                           : [NSDate date].timeIntervalSince1970;
        if (!self.hasSnapshot || e != self.snapElapsed || ts != self.snapTS) {
            self.snapElapsed = e;
            self.snapRate    = rateNum ? rateNum.doubleValue : 1.0;
            self.snapTS      = ts;
            self.hasSnapshot = YES;
            self.snapDirty   = YES;   // 快照重发布(含拖动进度),允许重新计算
        }
    }
    BOOL wasPlaying = self.playing;
    if (playingNum) self.playing = playingNum.boolValue;
    if (self.playing && !wasPlaying) self.snapDirty = YES;   // 恢复播放立即续走

    if (songChanged) [self fetchLyrics];
    [self refreshLine];
}

/// 当前播放进度:播放中按公式推进;暂停时冻结在 lastPos(LyricsX 同款语义)。
/// 暂停期间拖动进度 → 快照重发布(snapDirty)→ 直接落位到新 elapsed。
- (double)displayElapsed {
    if (!self.hasSnapshot) return 0;
    if (self.playing || self.snapDirty) {
        double rate = self.snapRate > 0 ? self.snapRate : 1.0;
        self.lastPos = self.snapElapsed
            + ([[NSDate date] timeIntervalSince1970] - self.snapTS) * rate;
        self.snapDirty = NO;
    }
    return self.lastPos;
}

- (void)fetchLyrics {
    if (self.lyricsPending || !self.title.length) return;
    self.lyricsPending = YES;
    NSString *title = self.title, *artist = self.artist;
    [TBLyrics.shared lyricsForTitle:title artist:artist
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
    // 同文本不刷,减少 Touch Bar 重绘
    if ([self.lyricsLabel.title isEqualToString:s]) return;
    [self.lyricsLabel performSelectorOnMainThread:@selector(setTitle:)
                                        withObject:s waitUntilDone:NO];
}

@end

NS_ASSUME_NONNULL_END
