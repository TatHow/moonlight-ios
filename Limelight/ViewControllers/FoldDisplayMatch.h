//
//  FoldDisplayMatch.h
//  Moonlight
//
//  "Match display" mode: the stream resolution follows the size of the
//  view the video is shown in, so the host desktop becomes the phone's
//  resolution (portrait, landscape, outer or inner screen, or one pane
//  of a folded layout). Header-only so it needs no project file changes.
//

#import <UIKit/UIKit.h>

// NSUserDefaults keys (kept out of Core Data to avoid a schema migration)
static NSString* const kFoldMatchDisplayKey = @"FoldMatchDisplay";
static NSString* const kFoldDesktopScaleKey = @"FoldDesktopScale";

// Desktop scale presets: 1.0 = native pixels, smaller = larger UI on the host
static const double kFoldDesktopScales[] = { 1.0, 0.75, 0.5 };
static const int kFoldDesktopScaleCount = 3;

static inline BOOL FoldMatchDisplayEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:kFoldMatchDisplayKey];
}

static inline void FoldSetMatchDisplayEnabled(BOOL enabled) {
    [[NSUserDefaults standardUserDefaults] setBool:enabled forKey:kFoldMatchDisplayKey];
}

static inline double FoldDesktopScale(void) {
    double scale = [[NSUserDefaults standardUserDefaults] doubleForKey:kFoldDesktopScaleKey];
    if (scale < 0.25 || scale > 1.0) {
        return 1.0;
    }
    return scale;
}

static inline void FoldSetDesktopScale(double scale) {
    [[NSUserDefaults standardUserDefaults] setDouble:scale forKey:kFoldDesktopScaleKey];
}

static inline int FoldDesktopScaleIndex(void) {
    double scale = FoldDesktopScale();
    for (int i = 0; i < kFoldDesktopScaleCount; i++) {
        if (fabs(kFoldDesktopScales[i] - scale) < 0.01) {
            return i;
        }
    }
    return 0;
}

// Pixel size for a stream that exactly fills a view of the given point size.
// Dimensions are rounded down to even numbers (video encoders need even sizes)
// and clamped to what the decoder supports.
static inline CGSize FoldStreamSizeForPoints(CGSize points, CGFloat displayScale, int maxDimension) {
    if (displayScale <= 0) {
        displayScale = 1;
    }
    double factor = displayScale * FoldDesktopScale();
    long width = (long)floor(points.width * factor);
    long height = (long)floor(points.height * factor);

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
