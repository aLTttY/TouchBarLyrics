// TBMediaRemote.h — MediaRemote 私有框架桥:读取系统"正在播放"信息(网易云/Music/QQ 音乐等)
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// info 键:title / artist / album(NSString)、elapsed / duration(double)、playing(BOOL)
typedef void (^TBNowPlayingHandler)(NSDictionary *_Nullable info);

@interface TBMediaRemote : NSObject
+ (nullable instancetype)shared;
/// 安装监听(通知 + 轮询兜底)。handler 恒在主线程回调;info 为 nil 表示拿不到。
- (void)startWithHandler:(TBNowPlayingHandler)handler;
/// 立即拉取一次
- (void)pollNow;
/// 向"正在播放"app 发控制命令(kMRPlay=0 kMRPause=1 kMRTogglePlayPause=2
/// kMRNextTrack=4 kMRPreviousTrack=5)。返回 NO 表示本机不支持该入口。
+ (BOOL)sendCommand:(int)command;
@end

NS_ASSUME_NONNULL_END
