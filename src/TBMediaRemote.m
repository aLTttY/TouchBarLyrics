#import "TBMediaRemote.h"
#import <AppKit/AppKit.h>
#import <dlfcn.h>

// ---- MediaRemote 私有函数类型 ----
typedef void (*MRGetNowPlayingInfoFn)(dispatch_queue_t, void (^)(CFDictionaryRef _Nullable));
typedef void (*MRRegisterNotificationsFn)(dispatch_queue_t);
typedef void (*MRGetPlayingFn)(dispatch_queue_t, void (^)(Boolean));

NS_ASSUME_NONNULL_BEGIN

@interface TBMediaRemote ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy, nullable) TBNowPlayingHandler handler;
@property (nonatomic, strong, nullable) NSTimer *timer;
@end

NS_ASSUME_NONNULL_END

// NowPlaying info 字典键(MediaRemote 导出的全局 CFStringRef 变量,经 dlsym 解引用)
static NSString *kTitle, *kArtist, *kAlbum, *kElapsed, *kDuration, *kRate, *kTimestamp;
// 函数指针
static MRGetNowPlayingInfoFn mrGetInfo;
static MRRegisterNotificationsFn mrRegister;
static MRGetPlayingFn mrGetPlaying;
// Sonoma 签名:bool MRMediaRemoteSendCommand(int command, id userInfo)
static BOOL (*mrSendCommand)(int, id) = NULL;

@implementation TBMediaRemote

+ (nullable instancetype)shared {
    static TBMediaRemote *s = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        s = [[TBMediaRemote alloc] init];
    });
    return s;
}

- (nullable instancetype)init {
    self = [super init];
    if (!self) return nil;
    // 解析全局 CFStringRef 变量:dlsym 拿到的是变量的地址,需解引用
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
    if (!h) return nil;
    #define TB_KEY(dst, sym) do { \
        CFStringRef *p = (CFStringRef *)dlsym(h, sym); \
        dst = p ? (__bridge NSString *)*p : nil; \
    } while (0)
    TB_KEY(kTitle,   "kMRMediaRemoteNowPlayingInfoTitle");
    TB_KEY(kArtist,  "kMRMediaRemoteNowPlayingInfoArtist");
    TB_KEY(kAlbum,   "kMRMediaRemoteNowPlayingInfoAlbum");
    TB_KEY(kElapsed, "kMRMediaRemoteNowPlayingInfoElapsedTime");
    TB_KEY(kDuration,"kMRMediaRemoteNowPlayingInfoDuration");
    TB_KEY(kRate,    "kMRMediaRemoteNowPlayingInfoPlaybackRate");
    TB_KEY(kTimestamp,"kMRMediaRemoteNowPlayingInfoTimestamp");
    #undef TB_KEY
    mrGetInfo     = (MRGetNowPlayingInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    mrRegister    = (MRRegisterNotificationsFn)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
    mrGetPlaying  = (MRGetPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    if (!mrGetInfo || !mrRegister) return nil;
    _queue = dispatch_queue_create("com.tbl.mediaremote", DISPATCH_QUEUE_SERIAL);
    return self;
}

- (void)startWithHandler:(TBNowPlayingHandler)handler {
    self.handler = handler;
    // 启用框架内通知(通知名即以下字符串,post 到本进程 NSNotificationCenter)
    mrRegister(_queue);
    NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
    for (NSString *name in @[
            @"MRMediaRemoteNowPlayingInfoDidChangeNotification",
            @"MRMediaRemoteNowPlayingApplicationIsPlayingDidChangeNotification",
            @"MRMediaRemoteNowPlayingApplicationDidChangeNotification"]) {
        [nc addObserverForName:name object:nil queue:[NSOperationQueue mainQueue]
                      usingBlock:^(NSNotification *n) { [self pollNow]; }];
    }
    // 轮询兜底:通知偶尔丢失时保证歌词仍走
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 target:self
                                                selector:@selector(pollNow) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.timer forMode:NSRunLoopCommonModes];
    [self pollNow];
}

- (void)pollNow {
    if (!self.handler) return;
    mrGetInfo(_queue, ^(CFDictionaryRef _Nullable rawInfo) {
        NSMutableDictionary *out = [NSMutableDictionary dictionary];
        NSDictionary *info = (__bridge NSDictionary *)rawInfo;
        if (info) {
            if (kTitle)    out[@"title"]   = info[kTitle];
            if (kArtist)   out[@"artist"]  = info[kArtist];
            if (kAlbum)    out[@"album"]   = info[kAlbum];
            if (kElapsed)  out[@"elapsed"] = info[kElapsed];
            if (kDuration) out[@"duration"]= info[kDuration];
            if (kRate)     out[@"rate"]    = info[kRate];
            // Timestamp:elapsed 快照的生效时刻(NSDate);真实进度 = elapsed + (now - ts) × rate
            if (kTimestamp) out[@"timestamp"] = info[kTimestamp];
        }
        BOOL hasTitle = [(out[@"title"] ?: @"") length] > 0;
        // 播放状态:IsPlaying 更准;拿不到时用 rate>0 兜底
        if (mrGetPlaying && hasTitle) {
            mrGetPlaying(_queue, ^(Boolean playing) {
                out[@"playing"] = @(playing);
                [self deliver:out];
            });
        } else {
            if (hasTitle && out[@"rate"]) out[@"playing"] = @([out[@"rate"] doubleValue] > 0.01);
            [self deliver:out];
        }
    });
}

- (void)deliver:(NSDictionary *)out {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.handler) self.handler(out.count ? out : nil);
    });
}

+ (BOOL)sendCommand:(int)command {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (h) mrSendCommand = (BOOL (*)(int, id))dlsym(h, "MRMediaRemoteSendCommand");
    });
    if (!mrSendCommand) return NO;
    return mrSendCommand(command, nil) ? YES : NO;
}

@end
