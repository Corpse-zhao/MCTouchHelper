// MCTouchHelper - SpringBoard 内 HID 触摸注入
// 监听 Darwin 通知 com.corpsezhao.motocarplay.gesture,
// 模拟一次"状态栏右区向左滑动"手势 (SquidGesture Pro 可识别区域)。
// 坐标为归一化值 (0~1), 默认从 /var/mobile/Documents/MCTouchHelper/config.plist 读取,
// 读不到就用内置默认值。

#import <Foundation/Foundation.h>
#import <CoreFoundation/CoreFoundation.h>
#import <UIKit/UIKit.h>
#import <dlfcn.h>
#import <mach/mach_time.h>

#define kMCNotifyName CFSTR("com.corpsezhao.motocarplay.gesture")

static dispatch_queue_t mcQueue = nil;
static volatile BOOL mcBusy = NO;
static volatile CGSize mcScreen = {0.0, 0.0};

// ---- IOKit HID 动态符号 ----
static void *gIOKit = NULL;

typedef void *IOHIDClientRef;
typedef void *IOHIDEventRef;

typedef IOHIDClientRef (*MCClientCreateFn)(uint32_t type);
typedef void (*MCScheduleFn)(IOHIDClientRef, CFRunLoopRef, CFStringRef);
typedef void (*MCDispatchFn)(IOHIDClientRef, IOHIDEventRef);
typedef IOHIDEventRef (*MCFingerEventFn)(CFAllocatorRef allocator, uint64_t timestamp,
                                         uint32_t index, uint32_t identity,
                                         uint32_t eventMask, uint32_t buttonMask,
                                         float x, float y, float z,
                                         float tipPressure, float twist,
                                         Boolean range, Boolean touch, uint32_t options);
typedef void (*MCSetSenderIDFn)(IOHIDEventRef, uint64_t);

// digitizer 事件掩码
#define MC_EVT_RANGE    (1 << 0)
#define MC_EVT_TOUCH    (1 << 1)
#define MC_EVT_POSITION (1 << 2)

// 读取可选配置 (App 侧写入), 支持多个候选路径
static NSDictionary *MCLoadConfig(void) {
    NSArray *candidates = @[
        @"/var/mobile/Documents/MCTouchHelper/config.plist",
        @"/var/mobile/Library/Preferences/com.corpsezhao.mctouchhelper.plist"
    ];
    for (NSString *p in candidates) {
        NSDictionary *d = [NSDictionary dictionaryWithContentsOfFile:p];
        if ([d isKindOfClass:[NSDictionary class]]) {
            NSLog(@"[MCTouchHelper] config loaded: %@", p);
            return d;
        }
    }
    return nil;
}

static float MCCfgFloat(NSDictionary *cfg, NSString *key, float def) {
    if (!cfg) return def;
    id v = cfg[key];
    if ([v isKindOfClass:[NSNumber class]]) {
        float f = [v floatValue];
        if (f > 0.001f && f < 0.999f) return f;
    }
    return def;
}

// 核心注入: 在 SpringBoard 进程内派发一组 digitizer 手指事件
static void MCInjectSwipe(float fx0, float fy0, float fx1, float fy1) {
    if (!gIOKit) {
        gIOKit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
    }
    if (!gIOKit) {
        NSLog(@"[MCTouchHelper] dlopen IOKit failed: %s", dlerror());
        return;
    }

    MCClientCreateFn clientCreate = (MCClientCreateFn)dlsym(gIOKit, "IOHIDEventSystemClientCreate");
    MCScheduleFn schedule = (MCScheduleFn)dlsym(gIOKit, "IOHIDEventSystemClientScheduleWithRunLoop");
    MCDispatchFn dispatchEvt = (MCDispatchFn)dlsym(gIOKit, "IOHIDEventSystemClientDispatchEvent");
    MCFingerEventFn fingerEvent = (MCFingerEventFn)dlsym(gIOKit, "IOHIDEventCreateDigitizerFingerEvent");
    MCSetSenderIDFn setSender = (MCSetSenderIDFn)dlsym(gIOKit, "IOHIDEventSetSenderID");
    if (!clientCreate || !schedule || !dispatchEvt || !fingerEvent) {
        NSLog(@"[MCTouchHelper] missing IOKit symbols");
        return;
    }

    IOHIDClientRef client = clientCreate(0);
    if (!client) {
        NSLog(@"[MCTouchHelper] create HID client failed");
        return;
    }
    // 把 client 调度到当前 (工作) 线程的 runloop 上
    schedule(client, CFRunLoopGetCurrent(), kCFRunLoopDefaultMode);

    CGSize s = mcScreen;
    if (s.width < 1.0) {
        // 此时主队列已在正常运行（不在 dyld 初始化阶段），同步取一次是安全的
        dispatch_sync(dispatch_get_main_queue(), ^{
            s = [UIScreen mainScreen].bounds.size;
        });
    }
    float x0 = fx0 * s.width,  y0 = fy0 * s.height;
    float x1 = fx1 * s.width,  y1 = fy1 * s.height;
    NSLog(@"[MCTouchHelper] swipe (%.1f,%.1f) -> (%.1f,%.1f) screen %.0fx%.0f", x0, y0, x1, y1, s.width, s.height);

    const int steps = 10;

    // 手指按下: Range + Touch
    IOHIDEventRef down = fingerEvent(NULL, mach_absolute_time(), 1, 1,
                                     MC_EVT_RANGE | MC_EVT_TOUCH, 1,
                                     x0, y0, 0, 1.0f, 0, TRUE, TRUE, 0);
    if (!down) return;
    if (setSender) setSender(down, 0xdefaced);
    dispatchEvt(client, down);
    usleep(18000);

    // 滑动: Touch + Position
    for (int i = 1; i <= steps; i++) {
        float t = (float)i / (float)steps;
        float x = x0 + (x1 - x0) * t;
        float y = y0 + (y1 - y0) * t;
        IOHIDEventRef move = fingerEvent(NULL, mach_absolute_time(), 1, 1,
                                         MC_EVT_TOUCH | MC_EVT_POSITION, 1,
                                         x, y, 0, 1.0f, 0, TRUE, TRUE, 0);
        if (move) {
            if (setSender) setSender(move, 0xdefaced);
            dispatchEvt(client, move);
        }
        usleep(22000);
    }

    // 抬起: Range + Touch 掩码但 range/touch = false, 压力 = 0
    IOHIDEventRef up = fingerEvent(NULL, mach_absolute_time(), 1, 1,
                                   MC_EVT_RANGE | MC_EVT_TOUCH, 1,
                                   x1, y1, 0, 0.0f, 0, FALSE, FALSE, 0);
    if (up) {
        if (setSender) setSender(up, 0xdefaced);
        dispatchEvt(client, up);
    }
    usleep(30000);
    NSLog(@"[MCTouchHelper] swipe done");
}

static void MCCallback(CFNotificationCenterRef center, void *observer,
                       CFStringRef name, const void *object, CFDictionaryRef userInfo) {
    if (mcBusy) return;
    mcBusy = YES;
    dispatch_async(mcQueue, ^{
        @autoreleasepool {
            float x0 = 0.86f, y0 = 0.05f, x1 = 0.62f, y1 = 0.05f;
            NSDictionary *cfg = MCLoadConfig();
            if (cfg) {
                x0 = MCCfgFloat(cfg, @"x0", x0);
                y0 = MCCfgFloat(cfg, @"y0", y0);
                x1 = MCCfgFloat(cfg, @"x1", x1);
                y1 = MCCfgFloat(cfg, @"y1", y1);
            }
            MCInjectSwipe(x0, y0, x1, y1);
        }
        mcBusy = NO;
    });
}

%ctor {
    @autoreleasepool {
        mcQueue = dispatch_queue_create("com.corpsezhao.mctouchhelper.inject", DISPATCH_QUEUE_SERIAL);
        // 注意：%ctor 运行在 dyld 加载库阶段，主队列尚未开始运行，
        // 这里绝不能 dispatch_sync 到主队列（会死锁导致 SpringBoard 黑屏转圈）。
        // 屏幕尺寸延迟到注入时再取（见 MCInjectSwipe）。
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        NULL, MCCallback, kMCNotifyName,
                                        NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
        NSLog(@"[MCTouchHelper] loaded, listening for %@", kMCNotifyName);
    }
}
