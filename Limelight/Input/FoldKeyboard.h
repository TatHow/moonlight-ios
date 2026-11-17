//
//  FoldKeyboard.h
//  Moonlight
//
//  On-screen PC keyboard for the Fold build. Two styles:
//  - Bar: one scrollable row (Esc, Tab, Ctrl, Alt, Shift, Win, Fn, arrows...)
//    shown above the iOS keyboard.
//  - Full: a complete Windows keyboard, shown on the bottom half of a folded
//    iPhone (laptop posture) or the side pane of book posture.
//
//  Modifiers are sticky: tap once to apply to the next key, tap again to lock,
//  tap a third time to release. Fn swaps the number row to F1-F12 and the
//  arrows to Home/End/PgUp/PgDn.
//
//  The implementation lives in FoldKeyboardImpl.h, compiled into StreamView.m
//  (header-only so no project file changes are needed).
//

#import <UIKit/UIKit.h>

typedef NS_ENUM(NSInteger, FoldKeyboardStyle) {
    FoldKeyboardStyleBar,
    FoldKeyboardStyleFull,
};

@interface FoldKeyboardView : UIView

- (instancetype)initWithStyle:(FoldKeyboardStyle)style;

@property (nonatomic, readonly) FoldKeyboardStyle style;

// Called for the non-key buttons: @"hide" (close the iOS keyboard) and
// @"fullscreen" (leave the folded layout).
@property (nonatomic, copy) void (^actionHandler)(NSString* action);

// Height the bar style wants (the full style fills whatever it is given).
+ (CGFloat)barHeight;

// Serial queue every key event goes through, so modifier presses and releases
// stay in order with the keys they apply to.
+ (dispatch_queue_t)keyQueue;

// Call after sending a key that didn't come from this keyboard (the iOS
// keyboard), so one-shot modifiers are released after it.
+ (void)externalKeySent;

// Release every held modifier on the host (keyboard closed, stream ended).
+ (void)releaseAllModifiers;

@end
