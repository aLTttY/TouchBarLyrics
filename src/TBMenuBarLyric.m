#import "TBMenuBarLyric.h"
#import <AppKit/AppKit.h>
#import <Vision/Vision.h>
#import <CoreGraphics/CoreGraphics.h>

// 菜单栏区域:主屏宽度 × 菜单栏高度。全宽歌词窗口就贴在这个条里。
static const CGFloat kBarHeight = 24;
static const NSTimeInterval kPollInterval = 0.6;

@interface TBMenuBarLyric ()
@property (nonatomic, strong) dispatch_queue_t queue;
@property (nonatomic, copy) void (^handler)(NSArray<NSString *> *_Nullable);
@end

@implementation TBMenuBarLyric

+ (instancetype)shared {
    static TBMenuBarLyric *s;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[self alloc] init]; });
    return s;
}

- (void)startWithHandler:(void (^)(NSArray<NSString *> *_Nullable))handler {
    self.handler = handler;
    self.queue = dispatch_queue_create("com.github.alty.tbl.menubar", DISPATCH_QUEUE_SERIAL);
    if (!CGPreflightScreenCaptureAccess()) {
        CGRequestScreenCaptureAccess();   // 触发系统授权提示(一次性)
    }
    dispatch_async(self.queue, ^{ [self poll]; });
}

- (void)poll {
    @autoreleasepool {
        NSArray<NSString *> *cands = [self captureAndOCR];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.handler) self.handler(cands);
        });
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(kPollInterval * NSEC_PER_SEC)),
                   self.queue, ^{ [self poll]; });
}

- (nullable NSArray<NSString *> *)captureAndOCR {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    CGFloat barW = NSScreen.mainScreen.frame.size.width ?: 1440;
    CGImageRef img = CGWindowListCreateImage(
        CGRectMake(0, 0, barW, kBarHeight),
        kCGWindowListOptionOnScreenOnly, kCGNullWindowID, kCGWindowImageBoundsIgnoreFraming);
#pragma clang diagnostic pop
    if (!img) return nil;

    NSMutableArray<NSString *> *cands = [NSMutableArray array];
    VNRecognizeTextRequest *req = [[VNRecognizeTextRequest alloc]
        initWithCompletionHandler:^(VNRequest *request, NSError *e2) {
        (void)e2;
        for (VNRecognizedTextObservation *obs in request.results) {
            VNRecognizedText *t = [obs topCandidates:1].firstObject;
            if (!t || t.confidence < 0.3 || t.string.length < 2) continue;
            [cands addObject:t.string];
        }
    }];
    req.recognitionLevel = VNRequestTextRecognitionLevelAccurate;
    req.recognitionLanguages = @[@"zh-Hans", @"en-US"];
    req.usesLanguageCorrection = NO;
    VNImageRequestHandler *rh = [[VNImageRequestHandler alloc] initWithCGImage:img options:@{}];
    [rh performRequests:@[req] error:NULL];
    CFRelease(img);
    return cands.count ? cands : nil;
}

@end
