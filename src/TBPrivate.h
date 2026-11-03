// TBPrivate.h — Sonoma 上仍然可用的 Touch Bar / MediaRemote 私有 API 声明
#pragma once
#import <AppKit/AppKit.h>
#import <dlfcn.h>

NS_ASSUME_NONNULL_BEGIN

// NSTouchBarItem 私有类方法:把 item 注册进系统 Control Strip(功能区)
@interface NSTouchBarItem (TBPrivate)
+ (void)addSystemTrayItem:(NSTouchBarItem *)item;
+ (void)removeSystemTrayItem:(NSTouchBarItem *)item;
@end

// NSTouchBar 私有类方法:以系统模态形式接管 Touch Bar(常驻,直到收起)
@interface NSTouchBar (TBPrivate)
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
        systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)presentSystemModalTouchBar:(NSTouchBar *)touchBar
                          placement:(long long)placement
        systemTrayItemIdentifier:(NSTouchBarItemIdentifier)identifier;
+ (void)minimizeSystemModalTouchBar:(NSTouchBar *)touchBar;
+ (void)dismissSystemModalTouchBar:(NSTouchBar *)touchBar;
@end

/// dlopen DFRFoundation 并解析所需 C 函数;失败返回 NO(此时 Touch Bar 无法接管)
BOOL TBLoadDFRFoundation(void);
/// 声明:void DFRElementSetControlStripPresenceForIdentifier(id, BOOL)
extern void (*tbl_DFRSetControlStripPresence)(id identifier, BOOL presence) __attribute__((visibility("default")));
/// 声明:void DFRSystemModalShowsCloseBoxWhenFrontMost(BOOL)
extern void (*tbl_DFRCloseBox)(BOOL) __attribute__((visibility("default")));

NS_ASSUME_NONNULL_END
