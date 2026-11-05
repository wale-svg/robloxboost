// RobloxBoost.m — conservative performance helper for a sideloaded Roblox iOS build.
//
// Rules this follows (learned by inspecting RobloxLib):
//  * ObjC runtime only. No inline code patching, so it works without JIT/jailbreak.
//  * It does NOT touch things the engine already manages itself: refresh rate,
//    vsync pacing, drawable count, framebufferOnly, pixel format, thermal step-down.
//  * Every module is a switch below. Flip it and rebuild.

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#import <malloc/malloc.h>
#import <os/proc.h>
#import <pthread/qos.h>
#import <dispatch/dispatch.h>
#import <unistd.h>
#import <time.h>

// ------------------------------ switches ------------------------------
#ifndef RB_RENDER_QOS
#define RB_RENDER_QOS 1     // raise QoS of the thread that calls -[CAMetalLayer nextDrawable]
#endif
#ifndef RB_MEMORY_RELIEF
#define RB_MEMORY_RELIEF 1  // give freed heap pages back on warning / background / low headroom
#endif
#ifndef RB_LOW_MEM_MB
#define RB_LOW_MEM_MB 700   // "low headroom" threshold for os_proc_available_memory()
#endif
#ifndef RB_FRAMERATE_CAP
#define RB_FRAMERATE_CAP 120 // best effort: set FramerateCap in GlobalBasicSettings_13.xml if present (0 = off)
#endif
#ifndef RB_METAL_OPAQUE
#define RB_METAL_OPAQUE 0   // experimental: mark the Metal layer opaque (engine appears to set it to NO)
#endif
#ifndef RB_LOG
#define RB_LOG 1            // small log at Documents/RobloxBoost.log (reset every launch)
#endif

// ------------------------------- logging ------------------------------
#if RB_LOG
static void rb_log(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void rb_log(NSString *fmt, ...) {
    va_list ap;
    va_start(ap, fmt);
    NSString *line = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    static NSString *path;
    static NSObject *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [NSObject new];
        path = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/RobloxBoost.log"];
        [@"" writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
    });
    @synchronized (lock) {
        @try {
            NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:path];
            [fh seekToEndOfFile];
            [fh writeData:[[line stringByAppendingString:@"\n"] dataUsingEncoding:NSUTF8StringEncoding]];
            [fh closeFile];
        } @catch (__unused NSException *e) {}
    }
}
#else
#define rb_log(...) ((void)0)
#endif

// --------------------- 1. render-thread QoS + layer facts ---------------------
// The thread that acquires Metal drawables is the render/submit thread by definition,
// so we find it at runtime instead of guessing thread names or offsets.
// The engine sets explicit priorities on some of its own threads; the OS may refuse a
// QoS change there (rc != 0 in the log). That is harmless.
static IMP rb_orig_nextDrawable;
static __thread BOOL rb_tl_seen;

static id rb_nextDrawable(id self, SEL _cmd) {
    if (!rb_tl_seen) {
        rb_tl_seen = YES;
        CAMetalLayer *ml = (CAMetalLayer *)self;
#if RB_RENDER_QOS
        int rc = pthread_set_qos_class_self_np(QOS_CLASS_USER_INTERACTIVE, 0);
        rb_log(@"[qos] drawable thread (main=%d) -> USER_INTERACTIVE rc=%d", (int)[NSThread isMainThread], rc);
#endif
#if RB_METAL_OPAQUE
        if (!ml.opaque) ml.opaque = YES;
#endif
        rb_log(@"[metal] %.0fx%.0f maxDrawables=%lu framebufferOnly=%d opaque=%d pixelFormat=%lu",
               ml.drawableSize.width, ml.drawableSize.height, (unsigned long)ml.maximumDrawableCount,
               (int)ml.framebufferOnly, (int)ml.opaque, (unsigned long)ml.pixelFormat);
    }
    return ((id (*)(id, SEL))rb_orig_nextDrawable)(self, _cmd);
}

// ------------------------- 2. memory pressure relief -------------------------
#if RB_MEMORY_RELIEF
static dispatch_queue_t rb_mem_q;
static dispatch_source_t rb_mem_timer;
static uint64_t rb_mem_last_ns;
static int rb_mem_events;

// Runs on rb_mem_q only. malloc_zone_pressure_relief returns freed-but-retained pages to the OS.
static void rb_relieve(const char *why, BOOL force) {
    uint64_t now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW);
    if (!force && rb_mem_last_ns && now - rb_mem_last_ns < 10ull * NSEC_PER_SEC) return;
    rb_mem_last_ns = now;
    size_t freed = malloc_zone_pressure_relief(NULL, 0);
    if (rb_mem_events++ < 25)
        rb_log(@"[mem] %s: returned %zu KB, headroom now %zu MB", why, freed / 1024,
               os_proc_available_memory() / (1024 * 1024));
}

static void rb_install_memory_relief(void) {
    rb_mem_q = dispatch_queue_create("rb.boost.mem",
        dispatch_queue_attr_make_with_qos_class(DISPATCH_QUEUE_SERIAL, QOS_CLASS_UTILITY, 0));
    NSNotificationCenter *nc = NSNotificationCenter.defaultCenter;
    [nc addObserverForName:UIApplicationDidReceiveMemoryWarningNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { dispatch_async(rb_mem_q, ^{ rb_relieve("memory-warning", YES); }); }];
    [nc addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                usingBlock:^(NSNotification *n) { dispatch_async(rb_mem_q, ^{ rb_relieve("background", YES); }); }];

    rb_mem_timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, rb_mem_q);
    dispatch_source_set_timer(rb_mem_timer, dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC),
                              3 * NSEC_PER_SEC, 1 * NSEC_PER_SEC);
    dispatch_source_set_event_handler(rb_mem_timer, ^{
        size_t avail = os_proc_available_memory();   // 0 = unknown
        if (avail > 0 && avail < (size_t)RB_LOW_MEM_MB * 1024 * 1024) rb_relieve("low-headroom", NO);
    });
    dispatch_resume(rb_mem_timer);
}
#endif

// ------------------- 3. frame-rate cap in the user settings file -------------------
// Best effort only. If the engine keeps FramerateCap in its settings XML (as the desktop
// client does) we raise it so the engine's own FrameRateManager may target 120 Hz.
// The engine still clamps to the display's real capability. A .rbboost.bak copy is kept.
#if RB_FRAMERATE_CAP > 0
static void rb_seed_framerate_cap(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *home = NSHomeDirectory();
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    for (NSString *rel in @[@"Documents", @"Library", @"Library/Application Support", @"Library/Preferences"]) {
        NSString *d = [home stringByAppendingPathComponent:rel];
        [dirs addObject:d];
        for (NSString *sub in [fm contentsOfDirectoryAtPath:d error:nil]) {
            if ([@[@"Caches", @"WebKit", @"Logs"] containsObject:sub]) continue;
            NSString *full = [d stringByAppendingPathComponent:sub];
            BOOL isDir = NO;
            if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) [dirs addObject:full];
        }
    }
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:@"(<int\\s+name=\"FramerateCap\"\\s*>)(-?\\d+)(</int>)" options:0 error:nil];
    BOOL found = NO;
    for (NSString *d in dirs) {
        for (NSString *name in @[@"GlobalBasicSettings_13.xml", @"GlobalSettings_13.xml"]) {
            NSString *p = [d stringByAppendingPathComponent:name];
            if (![fm fileExistsAtPath:p]) continue;
            found = YES;
            NSString *xml = [NSString stringWithContentsOfFile:p encoding:NSUTF8StringEncoding error:nil];
            if (!xml) { rb_log(@"[fps] cannot read %@", p); continue; }
            NSTextCheckingResult *m = [re firstMatchInString:xml options:0 range:NSMakeRange(0, xml.length)];
            if (!m) { rb_log(@"[fps] %@: no FramerateCap element", name); continue; }
            NSInteger cur = [[xml substringWithRange:[m rangeAtIndex:2]] integerValue];
            if (cur == RB_FRAMERATE_CAP) { rb_log(@"[fps] %@: FramerateCap already %ld", name, (long)cur); continue; }
            NSString *bak = [p stringByAppendingString:@".rbboost.bak"];
            if (![fm fileExistsAtPath:bak]) [fm copyItemAtPath:p toPath:bak error:nil];
            NSString *out = [xml stringByReplacingCharactersInRange:[m rangeAtIndex:2]
                                                         withString:[NSString stringWithFormat:@"%d", (int)RB_FRAMERATE_CAP]];
            BOOL ok = [out writeToFile:p atomically:YES encoding:NSUTF8StringEncoding error:nil];
            rb_log(@"[fps] %@: FramerateCap %ld -> %d (%@)", name, (long)cur, (int)RB_FRAMERATE_CAP, ok ? @"ok" : @"write failed");
        }
    }
    if (!found) rb_log(@"[fps] no GlobalBasicSettings_13.xml yet (normal on the first launch)");
}
#endif

// --------------------------------- entry point ---------------------------------
__attribute__((constructor))
static void rb_init(void) {
    @autoreleasepool {
        rb_log(@"RobloxBoost loaded (pid %d)", (int)getpid());
#if RB_FRAMERATE_CAP > 0
        rb_seed_framerate_cap();
#endif
        Class layerCls = objc_getClass("CAMetalLayer");
        Method m = layerCls ? class_getInstanceMethod(layerCls, @selector(nextDrawable)) : NULL;
        if (m) rb_orig_nextDrawable = method_setImplementation(m, (IMP)rb_nextDrawable);
        else   rb_log(@"[metal] -[CAMetalLayer nextDrawable] not found; QoS/metal log disabled");
#if RB_MEMORY_RELIEF
        rb_install_memory_relief();
#endif
        // One-time facts that tell us what the engine can actually use (UIKit: main thread, after launch).
        dispatch_async(dispatch_get_main_queue(), ^{
            id key = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CADisableMinimumFrameDurationOnPhone"];
            rb_log(@"[env] screenMaxFPS=%ld CADisableMinimumFrameDurationOnPhone=%@ lowPower=%d thermal=%ld iOS=%@",
                   (long)UIScreen.mainScreen.maximumFramesPerSecond, key ?: @"(absent)",
                   (int)NSProcessInfo.processInfo.lowPowerModeEnabled,
                   (long)NSProcessInfo.processInfo.thermalState, UIDevice.currentDevice.systemVersion);
        });
    }
}
