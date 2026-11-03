#import "TBTouchBarController.h"
#import "TBPrivate.h"
#import "TBMediaRemote.h"
#import "TBLyrics.h"
#import <AppKit/AppKit.h>
#import <CoreGraphics/CGEvent.h>

// NX 媒体键码(IOKit/hidsystem/ev_keymap.h 摘录)
enum { NX_KEYTYPE_PLAY = 16, NX_KEYTYPE_FAST = 19, NX_KEYTYPE_REWIND = 20 };

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
// elapsed 插值锚点:网易云只在事件时上报进度快照,播放中需本地推进
@property (nonatomic, assign) double anchorElapsed;
@property (nonatomic, assign) CFAbsoluteTime anchorTime;
@property (nonatomic, assign) double lastSnapshotElapsed;
@property (nonatomic, assign) BOOL hasSnapshot;
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

#pragma mark - 媒体键(⏮ ⏯ ⏭ 经系统媒体键控制网易云)

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
- (void)togglePlay:(id)sender { postMediaKey(NX_KEYTYPE_PLAY);   }
- (void)nextTrack:(id)sender  { postMediaKey(NX_KEYTYPE_FAST);   }
- (void)prevTrack:(id)sender  { postMediaKey(NX_KEYTYPE_REWIND); }

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

    BOOL songChanged = NO;
    if (title.length && ![title isEqualToString:self.title ?: @""]) {
        songChanged = YES;
        self.title = title;
        self.artist = artist;
        self.lines = nil;
        self.lyricsLoaded = NO;
        self.currentLine = -1;
        // 切歌:进度直接锚定到新快照
        self.anchorElapsed = elapsed ? elapsed.doubleValue : 0;
        self.anchorTime = CFAbsoluteTimeGetCurrent();
    }
    BOOL playing = playingNum ? playingNum.boolValue : YES;
    if (elapsed) [self reconcileElapsed:elapsed.doubleValue playing:playing];

    if (songChanged) [self fetchLyrics];
    [self refreshLine];
}

/// 用新快照校准插值锚点。
/// 网易云的 elapsed 快照经常长时间不变(stale),因此只有当快照值本身出现
/// 变化(首次 / 切歌 / 拖动进度 / 客户端补报)时才重新锚定;快照不变则信任
/// 本地插值继续推进。
- (void)reconcileElapsed:(double)snapshot playing:(BOOL)playing {
    CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
    if (!self.hasSnapshot || fabs(snapshot - self.lastSnapshotElapsed) > 0.3) {
        self.anchorElapsed = snapshot;
        self.anchorTime = now;
        self.lastSnapshotElapsed = snapshot;
        self.hasSnapshot = YES;
    } else if (playing && !self.playing) {
        // 暂停 → 播放:从冻结点继续走
        self.anchorTime = now;
    } else if (!playing && self.playing) {
        // 播放 → 暂停:冻结在当前推进点
        self.anchorElapsed = [self displayElapsed];
        self.anchorTime = now;
    }
    self.playing = playing;
}

/// 插值后的当前播放进度
- (double)displayElapsed {
    return self.playing
        ? self.anchorElapsed + (CFAbsoluteTimeGetCurrent() - self.anchorTime)
        : self.anchorElapsed;
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
    [self render:self.playing
        ? [NSString stringWithFormat:@"  %@  ", text]
        : [NSString stringWithFormat:@"⏸ %@", text]];
}

- (void)render:(NSString *)s {
    // 同文本不刷,减少 Touch Bar 重绘
    if ([self.lyricsLabel.title isEqualToString:s]) return;
    [self.lyricsLabel performSelectorOnMainThread:@selector(setTitle:)
                                        withObject:s waitUntilDone:NO];
}

@end

NS_ASSUME_NONNULL_END
