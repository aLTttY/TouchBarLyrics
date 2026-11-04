// TBMenuBarLyric.h — 从网易云的菜单栏歌词(状态栏/全宽歌词条)读取当前歌词行,
// 作为同步的"地面真值"。
// 原理:定时截取屏幕顶部菜单栏区域 → Vision OCR → 上抛候选文本。
// 需要「屏幕录制」权限;未授权时捕获为空,app 自动退回 LRC 插值同步。
#pragma once
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TBMenuBarLyric : NSObject
+ (instancetype)shared;
/// 开始轮询;handler 在主线程回调,形参为当前菜单栏文本(可能为 nil = 本次没读到)。
- (void)startWithHandler:(void (^)(NSString *_Nullable text))handler;
@end

NS_ASSUME_NONNULL_END
