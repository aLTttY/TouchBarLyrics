// TBLyrics.h — 网易云音乐歌词获取:搜索匹配 + LRC 拉取解析 + 内存缓存
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TBLyricLine : NSObject
@property (nonatomic, assign) double time;   // 秒
@property (nonatomic, copy) NSString *text;
@end

typedef void (^TBLyricsCallback)(NSArray<TBLyricLine *> *_Nullable lines);

@interface TBLyrics : NSObject
+ (instancetype)shared;
/// 异步取歌词;completion 恒在主线程。lines == nil 表示没找到/网络失败。
/// durationSec:正在播放的时长(秒),用于在多个同名版本(翻唱/伴奏/现场)
/// 中挑时长最接近的;传 0 表示未知,退化为纯歌名匹配。
- (void)lyricsForTitle:(NSString *)title artist:(nullable NSString *)artist
              duration:(double)durationSec
            completion:(TBLyricsCallback)completion;
@end

NS_ASSUME_NONNULL_END
