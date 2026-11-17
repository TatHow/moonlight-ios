//
//  FoldKeyboardImpl.h
//  Moonlight
//
//  Implementation of FoldKeyboardView. Include this from exactly one .m file
//  (StreamView.m); everything else imports FoldKeyboard.h.
//

#import "FoldKeyboard.h"
#include <Limelight.h>
#include <unistd.h>

#pragma mark - Key table

typedef NS_ENUM(int, FoldKeyKind) {
    FoldKeyNormal,
    FoldKeyRepeat,     // repeats while held (backspace, arrows, space)
    FoldKeyModifier,   // vk is the modifier's index into sFoldMods
    FoldKeyFn,
    FoldKeyAction,     // label is the action name
    FoldKeyEnd,        // end of row
};

typedef struct {
    const char* label;
    const char* fnLabel;   // NULL = same as label
    short vk;
    short fnVk;            // 0 = same as vk
    float width;
    FoldKeyKind kind;
} FoldKeyDef;

#define K(l, v)                 { l, NULL, v, 0, 1, FoldKeyNormal }
#define KW(l, v, w)             { l, NULL, v, 0, w, FoldKeyNormal }
#define KF(l, v, fl, fv)        { l, fl, v, fv, 1, FoldKeyNormal }
#define KR(l, v, w)             { l, NULL, v, 0, w, FoldKeyRepeat }
#define KRF(l, v, fl, fv, w)    { l, fl, v, fv, w, FoldKeyRepeat }
#define KMOD(l, i, w)           { l, NULL, i, 0, w, FoldKeyModifier }
#define KFN(w)                  { "Fn", NULL, 0, 0, w, FoldKeyFn }
#define KACT(l, name, w)        { l, name, 0, 0, w, FoldKeyAction }
#define KEND                    { NULL, NULL, 0, 0, 0, FoldKeyEnd }

// Modifier indexes
enum { FoldModCtrl, FoldModAlt, FoldModShift, FoldModWin, FoldModCount };

static const short kFoldModVk[FoldModCount] = { 0xA2, 0xA4, 0xA0, 0x5B };
static const char kFoldModFlag[FoldModCount] = { MODIFIER_CTRL, MODIFIER_ALT, MODIFIER_SHIFT, MODIFIER_META };

static const FoldKeyDef kFoldBarKeys[] = {
    KACT("⌄", "hide", 1),
    K("Esc", 0x1B), K("Tab", 0x09),
    KMOD("Ctrl", FoldModCtrl, 1.1), KMOD("Alt", FoldModAlt, 1), KMOD("Shift", FoldModShift, 1.2), KMOD("Win", FoldModWin, 1),
    KFN(1),
    KRF("←", 0x25, "F1", 0x70, 1), KRF("↑", 0x26, "F2", 0x71, 1), KRF("↓", 0x28, "F3", 0x72, 1), KRF("→", 0x27, "F4", 0x73, 1),
    KRF("Del", 0x2E, "F5", 0x74, 1), KF("Home", 0x24, "F6", 0x75), KF("End", 0x23, "F7", 0x76),
    KF("PgUp", 0x21, "F8", 0x77), KF("PgDn", 0x22, "F9", 0x78), KF("`", 0xC0, "F10", 0x79),
    KF("Ins", 0x2D, "F11", 0x7A), KF("PrtSc", 0x2C, "F12", 0x7B),
    KEND
};

// Five rows of 14.8 units each
static const FoldKeyDef kFoldFullKeys[] = {
    KW("Esc", 0x1B, 1.2),
    KF("1", 0x31, "F1", 0x70), KF("2", 0x32, "F2", 0x71), KF("3", 0x33, "F3", 0x72), KF("4", 0x34, "F4", 0x73),
    KF("5", 0x35, "F5", 0x74), KF("6", 0x36, "F6", 0x75), KF("7", 0x37, "F7", 0x76), KF("8", 0x38, "F8", 0x77),
    KF("9", 0x39, "F9", 0x78), KF("0", 0x30, "F10", 0x79), KF("-", 0xBD, "F11", 0x7A), KF("=", 0xBB, "F12", 0x7B),
    KRF("⌫", 0x08, "Del", 0x2E, 1.6),
    KEND,
    KW("Tab", 0x09, 1.5),
    K("Q", 0x51), K("W", 0x57), K("E", 0x45), K("R", 0x52), K("T", 0x54), K("Y", 0x59), K("U", 0x55),
    K("I", 0x49), K("O", 0x4F), K("P", 0x50), K("[", 0xDB), K("]", 0xDD), KW("\\", 0xDC, 1.3),
    KEND,
    KW("`", 0xC0, 1.7),
    K("A", 0x41), K("S", 0x53), K("D", 0x44), K("F", 0x46), K("G", 0x47), K("H", 0x48), K("J", 0x4A),
    K("K", 0x4B), K("L", 0x4C), K(";", 0xBA), K("'", 0xDE), KW("Enter", 0x0D, 2.1),
    KEND,
    KMOD("Shift", FoldModShift, 2.3),
    K("Z", 0x5A), K("X", 0x58), K("C", 0x43), K("V", 0x56), K("B", 0x42), K("N", 0x4E), K("M", 0x4D),
    K(",", 0xBC), K(".", 0xBE), K("/", 0xBF),
    KRF("↑", 0x26, "PgUp", 0x21, 1.2), KRF("Del", 0x2E, "Ins", 0x2D, 1.3),
    KEND,
    KFN(1.2), KMOD("Ctrl", FoldModCtrl, 1.3), KMOD("Win", FoldModWin, 1.2), KMOD("Alt", FoldModAlt, 1.3),
    KR("Space", 0x20, 5.0), KACT("⤢", "fullscreen", 1.2),
    KRF("←", 0x25, "Home", 0x24, 1.2), KRF("↓", 0x28, "PgDn", 0x22, 1.2), KRF("→", 0x27, "End", 0x23, 1.2),
    KEND,
    KEND,
};

#pragma mark - Shared modifier state

// 0 = off, 1 = applies to the next key, 2 = locked
static int sFoldMods[FoldModCount];
static NSString* const kFoldKeyboardStateChanged = @"FoldKeyboardStateChanged";

static char FoldActiveModifierFlags(void) {
    char flags = 0;
    for (int i = 0; i < FoldModCount; i++) {
        if (sFoldMods[i]) {
            flags |= kFoldModFlag[i];
        }
    }
    return flags;
}

static void FoldPostStateChanged(void) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:kFoldKeyboardStateChanged object:nil];
    });
}

#pragma mark - Key button

@interface FoldKeyButton : UIButton
@property (nonatomic) FoldKeyDef def;
@end

@implementation FoldKeyButton
@end

#pragma mark - Keyboard view

@implementation FoldKeyboardView {
    NSMutableArray<FoldKeyButton*>* _buttons;
    NSMutableArray<NSNumber*>* _rowStarts;   // index into _buttons where each row starts
    UIScrollView* _scroll;
    BOOL _fn;
    NSTimer* _repeatTimer;
    UIImpactFeedbackGenerator* _haptic;
}

+ (CGFloat)barHeight {
    return 48;
}

+ (dispatch_queue_t)keyQueue {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.moonlight.fold.keys", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

// Releases modifiers that were only meant for one key. Runs on the key queue.
+ (void)releaseOneShotModifiers {
    BOOL changed = NO;
    for (int i = 0; i < FoldModCount; i++) {
        if (sFoldMods[i] == 1) {
            sFoldMods[i] = 0;
            LiSendKeyboardEvent(0x8000 | kFoldModVk[i], KEY_ACTION_UP, FoldActiveModifierFlags());
            changed = YES;
        }
    }
    if (changed) {
        FoldPostStateChanged();
    }
}

+ (void)externalKeySent {
    dispatch_async([self keyQueue], ^{
        [self releaseOneShotModifiers];
    });
}

+ (void)releaseAllModifiers {
    dispatch_async([self keyQueue], ^{
        for (int i = 0; i < FoldModCount; i++) {
            if (sFoldMods[i]) {
                sFoldMods[i] = 0;
                LiSendKeyboardEvent(0x8000 | kFoldModVk[i], KEY_ACTION_UP, 0);
            }
        }
        FoldPostStateChanged();
    });
}

- (instancetype)initWithStyle:(FoldKeyboardStyle)style {
    self = [super initWithFrame:CGRectMake(0, 0, 320, style == FoldKeyboardStyleBar ? [FoldKeyboardView barHeight] : 240)];
    if (self) {
        _style = style;
        _buttons = [NSMutableArray array];
        _rowStarts = [NSMutableArray array];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];
        self.backgroundColor = style == FoldKeyboardStyleBar ? [UIColor colorWithWhite:0.1 alpha:0.96] : [UIColor clearColor];
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth;

        UIView* container = self;
        if (style == FoldKeyboardStyleBar) {
            _scroll = [[UIScrollView alloc] init];
            _scroll.showsHorizontalScrollIndicator = NO;
            _scroll.delaysContentTouches = NO;
            [self addSubview:_scroll];
            container = _scroll;
        }

        const FoldKeyDef* table = style == FoldKeyboardStyleBar ? kFoldBarKeys : kFoldFullKeys;
        [_rowStarts addObject:@0];
        for (int i = 0; ; i++) {
            if (table[i].kind == FoldKeyEnd) {
                if (style == FoldKeyboardStyleBar || table[i + 1].kind == FoldKeyEnd) {
                    break;
                }
                [_rowStarts addObject:@(_buttons.count)];
                continue;
            }
            FoldKeyButton* b = [FoldKeyButton buttonWithType:UIButtonTypeCustom];
            b.def = table[i];
            b.layer.cornerRadius = 7;
            b.titleLabel.adjustsFontSizeToFitWidth = YES;
            b.titleLabel.minimumScaleFactor = 0.6;
            [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
            [b setTitleColor:[UIColor colorWithWhite:0.7 alpha:1] forState:UIControlStateHighlighted];
            [b addTarget:self action:@selector(keyDown:) forControlEvents:UIControlEventTouchDown];
            [b addTarget:self action:@selector(keyUp:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside | UIControlEventTouchCancel];
            [container addSubview:b];
            [_buttons addObject:b];
        }
        [_rowStarts addObject:@(_buttons.count)];

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(refreshKeys) name:kFoldKeyboardStateChanged object:nil];
        [self refreshKeys];
    }
    return self;
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [_repeatTimer invalidate];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, _style == FoldKeyboardStyleBar ? [FoldKeyboardView barHeight] : UIViewNoIntrinsicMetric);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    if (area.size.width < 100 || area.size.height < 30) {
        return;
    }
    CGFloat gap = 5;

    if (_style == FoldKeyboardStyleBar) {
        _scroll.frame = area;
        CGFloat h = area.size.height - 10;
        CGFloat unit = 48;
        CGFloat x = 6;
        for (FoldKeyButton* b in _buttons) {
            CGFloat w = unit * b.def.width;
            b.frame = CGRectMake(x, 5, w, h);
            x += w + gap;
        }
        _scroll.contentSize = CGSizeMake(x + 6, area.size.height);
        return;
    }

    NSInteger rows = _rowStarts.count - 1;
    CGFloat rowH = (area.size.height - gap * (rows - 1)) / rows;
    for (NSInteger r = 0; r < rows; r++) {
        NSInteger start = _rowStarts[r].integerValue, end = _rowStarts[r + 1].integerValue;
        float units = 0;
        for (NSInteger i = start; i < end; i++) {
            units += _buttons[i].def.width;
        }
        CGFloat unit = (area.size.width - gap * (end - start - 1)) / units;
        CGFloat x = area.origin.x;
        CGFloat y = area.origin.y + r * (rowH + gap);
        for (NSInteger i = start; i < end; i++) {
            CGFloat w = unit * _buttons[i].def.width;
            _buttons[i].frame = CGRectMake(x, y, w, rowH);
            x += w + gap;
        }
    }
    CGFloat fontSize = MIN(20, MAX(12, rowH * 0.38));
    for (FoldKeyButton* b in _buttons) {
        b.titleLabel.font = [UIFont systemFontOfSize:fontSize weight:UIFontWeightMedium];
    }
}

- (void)refreshKeys {
    for (FoldKeyButton* b in _buttons) {
        FoldKeyDef d = b.def;
        const char* label = (_fn && d.fnLabel && d.kind != FoldKeyAction) ? d.fnLabel : d.label;
        [b setTitle:[NSString stringWithUTF8String:label] forState:UIControlStateNormal];
        if (_style == FoldKeyboardStyleBar) {
            b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
        }

        UIColor* bg = [UIColor colorWithWhite:0.22 alpha:1];
        b.layer.borderWidth = 0;
        if (d.kind == FoldKeyModifier) {
            int state = sFoldMods[d.vk];
            bg = state == 0 ? [UIColor colorWithWhite:0.15 alpha:1] : [UIColor colorWithRed:0.25 green:0.45 blue:0.9 alpha:state == 2 ? 1.0 : 0.6];
            b.layer.borderWidth = state == 2 ? 2 : 0;
            b.layer.borderColor = [UIColor whiteColor].CGColor;
        } else if (d.kind == FoldKeyFn) {
            bg = _fn ? [UIColor colorWithRed:0.25 green:0.45 blue:0.9 alpha:1] : [UIColor colorWithWhite:0.15 alpha:1];
        } else if (d.kind == FoldKeyAction || d.width > 1.15) {
            bg = [UIColor colorWithWhite:0.15 alpha:1];
        }
        b.backgroundColor = bg;
    }
}

- (short)vkForKey:(FoldKeyDef)d {
    return (_fn && d.fnVk) ? d.fnVk : d.vk;
}

- (void)sendKey:(short)vk {
    dispatch_async([FoldKeyboardView keyQueue], ^{
        char flags = FoldActiveModifierFlags();
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_DOWN, flags);
        usleep(25 * 1000);
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_UP, flags);
        [FoldKeyboardView releaseOneShotModifiers];
    });
}

- (void)keyDown:(FoldKeyButton*)b {
    [_haptic impactOccurred];
    FoldKeyDef d = b.def;
    switch (d.kind) {
        case FoldKeyModifier: {
            int idx = d.vk;
            dispatch_async([FoldKeyboardView keyQueue], ^{
                int state = (sFoldMods[idx] + 1) % 3;
                if (state == 1) {
                    LiSendKeyboardEvent(0x8000 | kFoldModVk[idx], KEY_ACTION_DOWN, FoldActiveModifierFlags() | kFoldModFlag[idx]);
                } else if (state == 0) {
                    LiSendKeyboardEvent(0x8000 | kFoldModVk[idx], KEY_ACTION_UP, FoldActiveModifierFlags() & ~kFoldModFlag[idx]);
                }
                sFoldMods[idx] = state;
                FoldPostStateChanged();
            });
            break;
        }
        case FoldKeyFn:
            _fn = !_fn;
            [[NSNotificationCenter defaultCenter] postNotificationName:kFoldKeyboardStateChanged object:nil];
            break;
        case FoldKeyAction:
            if (self.actionHandler) {
                self.actionHandler([NSString stringWithUTF8String:d.fnLabel]);
            }
            break;
        case FoldKeyRepeat: {
            short vk = [self vkForKey:d];
            [self sendKey:vk];
            [_repeatTimer invalidate];
            __weak FoldKeyboardView* weakSelf = self;
            _repeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.45 repeats:NO block:^(NSTimer* t) {
                FoldKeyboardView* strongSelf = weakSelf;
                if (!strongSelf) {
                    return;
                }
                strongSelf->_repeatTimer = [NSTimer scheduledTimerWithTimeInterval:0.08 repeats:YES block:^(NSTimer* t2) {
                    [weakSelf sendKey:vk];
                }];
            }];
            break;
        }
        default:
            [self sendKey:[self vkForKey:d]];
            break;
    }
}

- (void)keyUp:(FoldKeyButton*)b {
    [_repeatTimer invalidate];
    _repeatTimer = nil;
}

- (void)willMoveToWindow:(UIWindow*)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil) {
        [_repeatTimer invalidate];
        _repeatTimer = nil;
    }
}

@end

#undef K
#undef KW
#undef KF
#undef KR
#undef KRF
#undef KMOD
#undef KFN
#undef KACT
#undef KEND
