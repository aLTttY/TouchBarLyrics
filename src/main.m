// TouchBarLyrics — 在 MacBook Touch Bar 上常驻显示网易云音乐歌词
#import <AppKit/AppKit.h>
#import "TBPrivate.h"
#import "TBTouchBarController.h"
#import "TBMediaRemote.h"

@interface AppDelegate : NSObject <NSApplicationDelegate> {
    TBTouchBarController *_controller;
}
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)n {
    if (!TBLoadDFRFoundation()) {
        [self fatal:@"无法加载 Touch Bar 私有框架(DFRFoundation)。\n"
                  @"本 app 仅支持带 Touch Bar 的 Intel MacBook Pro(macOS 13+)。"];
        return;
    }
    if (![TBMediaRemote shared]) {
        [self fatal:@"无法加载系统播放信息服务(MediaRemote)。"];
        return;
    }
    _controller = [[TBTouchBarController alloc] init];
    [_controller start];
    NSLog(@"[TouchBarLyrics] running pid=%d", getpid());
}

- (void)fatal:(NSString *)msg {
    // LSUIElement app 也能弹窗
    NSAlert *a = [[NSAlert alloc] init];
    a.messageText = @"TouchBarLyrics 无法启动";
    a.informativeText = msg;
    [a runModal];
    [NSApp terminate:nil];
}

@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        NSApplication *app = [NSApplication sharedApplication];
        [app setActivationPolicy:NSApplicationActivationPolicyAccessory]; // 无 Dock 图标
        [app setDelegate:[[AppDelegate alloc] init]];
        [app run];
    }
    return 0;
}
