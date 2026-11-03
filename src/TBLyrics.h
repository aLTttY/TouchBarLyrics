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
- (void)lyricsForTitle:(NSString *)title artist:(nullable NSString *)artist
            completion:(TBLyricsCallback)completion;
@end

NS_ASSUME_NONNULL_END
