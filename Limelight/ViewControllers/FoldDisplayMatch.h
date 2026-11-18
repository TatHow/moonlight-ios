//
//  FoldDisplayMatch.h
//  Moonlight
//
//  Fold build stream modes. The mode follows the app that is opened:
//  - Desktop (any normal app): streams the PC's physical display at a fixed
//    "render scale" of 4K, touch defaults to touchpad.
//  - Virtual (Apollo's virtual display app): the host creates a display at
//    exactly this screen's size (it follows rotation and folding) and sets
//    Windows scaling on it; touch defaults to touchscreen.
//  Header-only so it needs no project file changes.
//

#import <UIKit/UIKit.h>

// NSUserDefaults keys (kept out of Core Data to avoid a schema migration)
static NSString* const kFoldRenderScaleKey = @"FoldRenderScaleIndex";
static NSString* const kFoldVirtualDpiKey = @"FoldVirtualDpi";
static NSString* const kFoldVirtualTouchscreenKey = @"FoldVirtualTouchscreen";

// Posted by the settings screen; observed by the stream
static NSString* const kFoldSettingsClosedNotification = @"FoldSettingsClosed";
static NSString* const kFoldDisconnectNotification = @"FoldDisconnectRequested";
// Posted by the on-screen gamepad's gear button
static NSString* const kFoldOpenSettingsNotification = @"FoldOpenSettingsRequested";

// Desktop render scale, relative to 3840x2160
static const int kFoldRenderScaleCount = 4;
static const int kFoldRenderScaleDefault = 1; // 2/3 = 1440p
static NSString* const kFoldRenderScaleTitles[] = { @"1× 4K", @"⅔ 1440p", @"½ 1080p", @"⅓ 720p" };
static const CGSize kFoldRenderScaleSizes[] = { {3840, 2160}, {2560, 1440}, {1920, 1080}, {1280, 720} };

// Windows scaling for the virtual display
static const int kFoldVirtualDpiCount = 5;
static const int kFoldVirtualDpis[] = { 150, 200, 225, 250, 300 };
static const int kFoldVirtualDpiDefault = 250;

static inline int FoldRenderScaleIndex(void) {
    NSNumber* value = [[NSUserDefaults standardUserDefaults] objectForKey:kFoldRenderScaleKey];
    if (value == nil) {
        return kFoldRenderScaleDefault;
    }
    int index = [value intValue];
    return (index < 0 || index >= kFoldRenderScaleCount) ? kFoldRenderScaleDefault : index;
}

static inline void FoldSetRenderScaleIndex(int index) {
    [[NSUserDefaults standardUserDefaults] setInteger:index forKey:kFoldRenderScaleKey];
}

static inline CGSize FoldDesktopStreamSize(void) {
    return kFoldRenderScaleSizes[FoldRenderScaleIndex()];
}

static inline int FoldVirtualDpi(void) {
    NSInteger dpi = [[NSUserDefaults standardUserDefaults] integerForKey:kFoldVirtualDpiKey];
    return dpi >= 100 && dpi <= 500 ? (int)dpi : kFoldVirtualDpiDefault;
}

static inline void FoldSetVirtualDpi(int dpi) {
    [[NSUserDefaults standardUserDefaults] setInteger:dpi forKey:kFoldVirtualDpiKey];
}

static inline int FoldVirtualDpiIndex(void) {
    int dpi = FoldVirtualDpi();
    for (int i = 0; i < kFoldVirtualDpiCount; i++) {
        if (kFoldVirtualDpis[i] == dpi) {
            return i;
        }
    }
    return 3;
}

static inline BOOL FoldVirtualTouchscreen(void) {
    NSNumber* value = [[NSUserDefaults standardUserDefaults] objectForKey:kFoldVirtualTouchscreenKey];
    return value == nil ? YES : [value boolValue];
}

static inline void FoldSetVirtualTouchscreen(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFoldVirtualTouchscreenKey];
}

// Touch mode of the running session: each connection starts on touchpad for
// Desktop and touchscreen for Virtual, and the settings toggle changes it
static NSString* const kFoldSessionTouchscreenKey = @"FoldSessionTouchscreen";

static inline BOOL FoldSessionTouchscreen(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kFoldSessionTouchscreenKey];
}

static inline void FoldSetSessionTouchscreen(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFoldSessionTouchscreenKey];
}

// Apollo's built-in virtual display app ("Virtual Display" / "Virtual Desktop")
static inline BOOL FoldIsVirtualApp(NSString* appName) {
    return appName != nil && [appName rangeOfString:@"virtual" options:NSCaseInsensitiveSearch].location != NSNotFound;
}

// Pixel size for a stream that exactly fills a view of the given point size.
// Dimensions are rounded down to even numbers (video encoders need even sizes)
// and clamped to what the decoder supports.
static inline CGSize FoldStreamSizeForPoints(CGSize points, CGFloat displayScale, int maxDimension) {
    if (displayScale <= 0) {
        displayScale = 1;
    }
    long width = (long)floor(points.width * displayScale);
    long height = (long)floor(points.height * displayScale);

    // Keep the aspect ratio if we have to clamp down
    if (width > maxDimension || height > maxDimension) {
        double shrink = (double)maxDimension / (double)MAX(width, height);
        width = (long)floor(width * shrink);
        height = (long)floor(height * shrink);
    }

    width = MAX(width, 256) & ~1L;
    height = MAX(height, 256) & ~1L;
    return CGSizeMake(width, height);
}

static inline CGSize FoldStreamSizeForView(UIView* view, int maxDimension) {
    return FoldStreamSizeForPoints(view.bounds.size, view.traitCollection.displayScale, maxDimension);
}
