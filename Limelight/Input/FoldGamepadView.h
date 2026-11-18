//
//  FoldGamepadView.h
//  Moonlight
//
//  Fold build on-screen gamepad, a generic Xbox controller laid out like a handheld:
//    top-left  LT, LS, LB         top-right  RT, RS, RB
//    top-center  View  (gear)  Menu
//    bottom-left  d-pad          bottom-right  A/B/X/Y diamond
//    sticks float: a touch anywhere else on the left/right half spawns one
//  It sends controller 0 straight to the host and takes every touch while on.
//  Header-only: include it from exactly one .m file (StreamView.m).
//

#import <UIKit/UIKit.h>
#include <Limelight.h>

#import "../ViewControllers/FoldDisplayMatch.h"

typedef NS_ENUM(int, FoldPadKind) {
    FoldPadButton,
    FoldPadTrigger,
    FoldPadStick,
    FoldPadDpad,
    FoldPadGear,
};

@interface FoldPadControl : NSObject
@property (nonatomic) FoldPadKind kind;
@property (nonatomic) int flag;        // button flag, or 0/1 for left/right trigger and stick
@property (nonatomic) BOOL pressed;
@property (nonatomic) CGPoint stickValue; // -1..1, y up
@property (nonatomic) int dpadFlags;
@property (nonatomic, strong) UIView* view;
@property (nonatomic, strong) UIView* knob;
@property (nonatomic, strong) NSArray<UIView*>* dpadButtons; // up, down, left, right
@property (nonatomic) CGRect hitRect;
@end

@implementation FoldPadControl
@end

@interface FoldGamepadView : UIView
- (void)releaseAll;
@end

@implementation FoldGamepadView {
    NSMutableArray<FoldPadControl*>* _controls;
    NSMutableDictionary<NSValue*, FoldPadControl*>* _touches;
    FoldPadControl *_zl, *_zr, *_l, *_r, *_l3, *_r3, *_minus, *_plus, *_gear;
    FoldPadControl *_lstick, *_rstick, *_dpad, *_a, *_b, *_x, *_y;
    CGFloat _stickDiameter;
    int _lastFlags;
    unsigned char _lastLt, _lastRt;
    short _lastLx, _lastLy, _lastRx, _lastRy;
    BOOL _sentOnce;
    UIImpactFeedbackGenerator* _haptic;
}

static UIColor* FoldPadFill(BOOL pressed) {
    return [UIColor colorWithWhite:pressed ? 0.85 : 0.2 alpha:pressed ? 0.55 : 0.35];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor clearColor];
        self.multipleTouchEnabled = YES;
        self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        _controls = [NSMutableArray array];
        _touches = [NSMutableDictionary dictionary];
        _haptic = [[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleLight];

        _zl = [self addButton:@"LT" kind:FoldPadTrigger flag:0];
        _zr = [self addButton:@"RT" kind:FoldPadTrigger flag:1];
        _l = [self addButton:@"LB" kind:FoldPadButton flag:LB_FLAG];
        _r = [self addButton:@"RB" kind:FoldPadButton flag:RB_FLAG];
        _l3 = [self addButton:@"LS" kind:FoldPadButton flag:LS_CLK_FLAG];
        _r3 = [self addButton:@"RS" kind:FoldPadButton flag:RS_CLK_FLAG];
        _minus = [self addButton:@"⧉" kind:FoldPadButton flag:BACK_FLAG];
        _plus = [self addButton:@"≡" kind:FoldPadButton flag:PLAY_FLAG];
        _gear = [self addButton:@"⚙︎" kind:FoldPadGear flag:0];
        // Positions follow the usual Xbox layout so PC games show the right prompts
        _y = [self addButton:@"Y" kind:FoldPadButton flag:Y_FLAG];
        _x = [self addButton:@"X" kind:FoldPadButton flag:X_FLAG];
        _b = [self addButton:@"B" kind:FoldPadButton flag:B_FLAG];
        _a = [self addButton:@"A" kind:FoldPadButton flag:A_FLAG];
        _lstick = [self addStick:0];
        _rstick = [self addStick:1];
        _dpad = [self addDpad];
    }
    return self;
}

- (UIView*)styledView {
    UIView* v = [[UIView alloc] init];
    v.userInteractionEnabled = NO;
    v.backgroundColor = FoldPadFill(NO);
    v.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
    v.layer.borderWidth = 1.5;
    [self addSubview:v];
    return v;
}

- (UILabel*)labelIn:(UIView*)v text:(NSString*)text {
    UILabel* label = [[UILabel alloc] init];
    label.text = text;
    label.textAlignment = NSTextAlignmentCenter;
    label.textColor = [UIColor colorWithWhite:1 alpha:0.9];
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    label.tag = 1;
    [v addSubview:label];
    return label;
}

- (FoldPadControl*)addButton:(NSString*)title kind:(FoldPadKind)kind flag:(int)flag {
    FoldPadControl* c = [[FoldPadControl alloc] init];
    c.kind = kind;
    c.flag = flag;
    c.view = [self styledView];
    [self labelIn:c.view text:title];
    [_controls addObject:c];
    return c;
}

- (FoldPadControl*)addStick:(int)which {
    FoldPadControl* c = [[FoldPadControl alloc] init];
    c.kind = FoldPadStick;
    c.flag = which;
    c.view = [self styledView];
    c.view.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.25];
    c.knob = [self styledView];
    c.knob.backgroundColor = [UIColor colorWithWhite:0.8 alpha:0.45];
    c.view.hidden = YES;
    c.knob.hidden = YES;
    [_controls addObject:c];
    return c;
}

- (FoldPadControl*)addDpad {
    FoldPadControl* c = [[FoldPadControl alloc] init];
    c.kind = FoldPadDpad;
    NSMutableArray* buttons = [NSMutableArray array];
    for (NSString* arrow in @[@"▲", @"▼", @"◀", @"▶"]) {
        UIView* v = [self styledView];
        [self labelIn:v text:arrow];
        [buttons addObject:v];
    }
    c.dpadButtons = buttons;
    [_controls addObject:c];
    return c;
}

#pragma mark - Layout

static void FoldPadPlace(FoldPadControl* c, CGRect frame, CGFloat radius, CGFloat font, CGFloat slop) {
    c.view.frame = frame;
    c.view.layer.cornerRadius = radius;
    UILabel* label = [c.view viewWithTag:1];
    label.frame = c.view.bounds;
    label.font = [UIFont systemFontOfSize:font weight:UIFontWeightSemibold];
    c.hitRect = CGRectInset(frame, -slop, -slop);
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGRect r = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
    r = CGRectInset(r, 12, 10);
    CGFloat s = MIN(1.35, MAX(0.7, MIN(r.size.width, r.size.height) / 420.0));
    CGFloat minX = CGRectGetMinX(r), maxX = CGRectGetMaxX(r);
    CGFloat minY = CGRectGetMinY(r), maxY = CGRectGetMaxY(r);
    CGFloat slop = 6 * s;

    // Shoulders: LT / RT on top with the stick clicks beside them, L / R below
    CGFloat tw = 80 * s, th = 44 * s, cl = 44 * s, gap = 10 * s;
    FoldPadPlace(_zl, CGRectMake(minX, minY, tw, th), th / 2, 17 * s, slop);
    FoldPadPlace(_zr, CGRectMake(maxX - tw, minY, tw, th), th / 2, 17 * s, slop);
    FoldPadPlace(_l3, CGRectMake(minX + tw + gap, minY, cl, cl), cl / 2, 14 * s, slop);
    FoldPadPlace(_r3, CGRectMake(maxX - tw - gap - cl, minY, cl, cl), cl / 2, 14 * s, slop);
    FoldPadPlace(_l, CGRectMake(minX, minY + th + gap, tw, 40 * s), 12 * s, 17 * s, slop);
    FoldPadPlace(_r, CGRectMake(maxX - tw, minY + th + gap, tw, 40 * s), 12 * s, 17 * s, slop);

    // View, gear, Menu in the middle of the top row, or one row down if the screen is narrow
    CGFloat pw = 46 * s, ph = 30 * s, gd = 36 * s;
    CGFloat groupW = pw * 2 + gd + gap * 2;
    CGFloat sideW = tw + gap + cl;
    CGFloat groupY = minY;
    if (r.size.width < sideW * 2 + groupW + gap * 4) {
        groupY = minY + th + gap + 2 * s;
    }
    CGFloat midX = CGRectGetMidX(r);
    FoldPadPlace(_minus, CGRectMake(midX - gd / 2 - gap - pw, groupY + (gd - ph) / 2, pw, ph), ph / 2, 20 * s, slop);
    FoldPadPlace(_gear, CGRectMake(midX - gd / 2, groupY, gd, gd), gd / 2, 20 * s, slop);
    FoldPadPlace(_plus, CGRectMake(midX + gd / 2 + gap, groupY + (gd - ph) / 2, pw, ph), ph / 2, 20 * s, slop);

    // Bottom corners: d-pad on the left, ABXY mirrored on the right.
    // The sticks float: they appear wherever a touch starts on that half.
    CGFloat dp = 140 * s, ab = 140 * s;
    CGPoint dpC = CGPointMake(minX + dp / 2, maxY - dp / 2);
    CGPoint abC = CGPointMake(maxX - ab / 2, maxY - ab / 2);
    _stickDiameter = 130 * s;

    CGFloat db = dp * 0.36;
    NSArray<NSValue*>* offsets = @[[NSValue valueWithCGPoint:CGPointMake(0, -1)], [NSValue valueWithCGPoint:CGPointMake(0, 1)],
                                   [NSValue valueWithCGPoint:CGPointMake(-1, 0)], [NSValue valueWithCGPoint:CGPointMake(1, 0)]];
    for (int i = 0; i < 4; i++) {
        CGPoint o = offsets[i].CGPointValue;
        UIView* v = _dpad.dpadButtons[i];
        v.frame = CGRectMake(dpC.x + o.x * (dp - db) / 2 - db / 2, dpC.y + o.y * (dp - db) / 2 - db / 2, db, db);
        v.layer.cornerRadius = db / 2;
        UILabel* label = [v viewWithTag:1];
        label.frame = v.bounds;
        label.font = [UIFont systemFontOfSize:15 * s];
    }
    _dpad.hitRect = CGRectMake(dpC.x - dp / 2 - slop, dpC.y - dp / 2 - slop, dp + slop * 2, dp + slop * 2);

    CGFloat bd = ab * 0.36;
    FoldPadPlace(_y, CGRectMake(abC.x - bd / 2, abC.y - ab / 2, bd, bd), bd / 2, 20 * s, slop);
    FoldPadPlace(_a, CGRectMake(abC.x - bd / 2, abC.y + ab / 2 - bd, bd, bd), bd / 2, 20 * s, slop);
    FoldPadPlace(_x, CGRectMake(abC.x - ab / 2, abC.y - bd / 2, bd, bd), bd / 2, 20 * s, slop);
    FoldPadPlace(_b, CGRectMake(abC.x + ab / 2 - bd, abC.y - bd / 2, bd, bd), bd / 2, 20 * s, slop);
}

- (void)placeStick:(FoldPadControl*)c center:(CGPoint)center diameter:(CGFloat)d {
    c.view.frame = CGRectMake(center.x - d / 2, center.y - d / 2, d, d);
    c.view.layer.cornerRadius = d / 2;
    CGFloat k = d * 0.46;
    c.knob.bounds = CGRectMake(0, 0, k, k);
    c.knob.layer.cornerRadius = k / 2;
    c.knob.center = CGPointMake(center.x + c.stickValue.x * d / 2, center.y - c.stickValue.y * d / 2);
}

#pragma mark - Touches

- (FoldPadControl*)controlAt:(CGPoint)p {
    // Exact hits first, then the enlarged touch areas
    for (FoldPadControl* c in _controls) {
        if (c.kind != FoldPadDpad && c.kind != FoldPadStick && CGRectContainsPoint(c.view.frame, p)) {
            return c;
        }
    }
    for (FoldPadControl* c in _controls) {
        if (c.kind != FoldPadStick && CGRectContainsPoint(c.hitRect, p)) {
            return c;
        }
    }
    // Anywhere else: the floating stick for that half, if it isn't held already
    FoldPadControl* stick = p.x < CGRectGetMidX(self.bounds) ? _lstick : _rstick;
    return stick.pressed ? nil : stick;
}

// The gamepad takes the whole screen while it's on
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
    return !self.hidden;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    BOOL pressedSomething = NO;
    for (UITouch* touch in touches) {
        CGPoint p = [touch locationInView:self];
        FoldPadControl* c = [self controlAt:p];
        if (c == nil) {
            continue;
        }
        if (c.kind == FoldPadGear) {
            [self releaseAll];
            [[NSNotificationCenter defaultCenter] postNotificationName:kFoldOpenSettingsNotification object:nil];
            return;
        }
        _touches[[NSValue valueWithNonretainedObject:touch]] = c;
        if (c.kind == FoldPadStick) {
            c.stickValue = CGPointZero;
            [self placeStick:c center:p diameter:_stickDiameter];
        }
        else {
            pressedSomething = YES;
        }
        [self touch:touch movedOn:c];
    }
    if (pressedSomething) {
        [_haptic impactOccurred];
    }
    [self refresh];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        FoldPadControl* c = _touches[[NSValue valueWithNonretainedObject:touch]];
        if (c != nil && (c.kind == FoldPadStick || c.kind == FoldPadDpad)) {
            [self touch:touch movedOn:c];
        }
    }
    [self refresh];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    for (UITouch* touch in touches) {
        NSValue* key = [NSValue valueWithNonretainedObject:touch];
        FoldPadControl* c = _touches[key];
        [_touches removeObjectForKey:key];
        if (c != nil && ![[_touches allValues] containsObject:c]) {
            c.pressed = NO;
            c.stickValue = CGPointZero;
            c.dpadFlags = 0;
        }
    }
    [self refresh];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    [self touchesEnded:touches withEvent:event];
}

- (void)touch:(UITouch*)touch movedOn:(FoldPadControl*)c {
    CGPoint p = [touch locationInView:self];
    if (c.kind == FoldPadStick) {
        CGPoint center = CGPointMake(CGRectGetMidX(c.view.frame), CGRectGetMidY(c.view.frame));
        CGFloat radius = c.view.frame.size.width / 2;
        CGFloat dx = (p.x - center.x) / radius, dy = (center.y - p.y) / radius;
        CGFloat len = sqrt(dx * dx + dy * dy);
        if (len > 1) {
            dx /= len;
            dy /= len;
            // Drag the stick along so the finger never runs off it
            CGPoint moved = CGPointMake(p.x - dx * radius, p.y + dy * radius);
            [self placeStick:c center:moved diameter:c.view.frame.size.width];
        }
        c.stickValue = CGPointMake(dx, dy);
        c.pressed = YES;
    }
    else if (c.kind == FoldPadDpad) {
        CGRect box = c.hitRect;
        CGFloat dx = p.x - CGRectGetMidX(box), dy = p.y - CGRectGetMidY(box);
        CGFloat dead = box.size.width * 0.12;
        int flags = 0;
        if (sqrt(dx * dx + dy * dy) > dead) {
            // 8 directions: a diagonal when the angle is within 22.5° of one
            double angle = atan2(-dy, dx) * 180.0 / M_PI;
            if (angle < 0) angle += 360;
            int sector = (int)floor((angle + 22.5) / 45.0) % 8;
            static const int dirs[8] = {
                RIGHT_FLAG, RIGHT_FLAG | UP_FLAG, UP_FLAG, UP_FLAG | LEFT_FLAG,
                LEFT_FLAG, LEFT_FLAG | DOWN_FLAG, DOWN_FLAG, DOWN_FLAG | RIGHT_FLAG,
            };
            flags = dirs[sector];
        }
        if (flags != c.dpadFlags && flags != 0) {
            [_haptic impactOccurred];
        }
        c.dpadFlags = flags;
        c.pressed = flags != 0;
    }
    else {
        c.pressed = YES;
    }
}

- (void)releaseAll {
    [_touches removeAllObjects];
    for (FoldPadControl* c in _controls) {
        c.pressed = NO;
        c.stickValue = CGPointZero;
        c.dpadFlags = 0;
    }
    [self refresh];
}

#pragma mark - State

- (void)refresh {
    int flags = 0;
    unsigned char lt = 0, rt = 0;
    for (FoldPadControl* c in _controls) {
        if (c.kind == FoldPadButton) {
            c.view.backgroundColor = FoldPadFill(c.pressed);
            if (c.pressed) flags |= c.flag;
        }
        else if (c.kind == FoldPadTrigger) {
            c.view.backgroundColor = FoldPadFill(c.pressed);
            if (c.pressed) {
                if (c.flag == 0) lt = 0xFF; else rt = 0xFF;
            }
        }
        else if (c.kind == FoldPadDpad) {
            flags |= c.dpadFlags;
            int bits[4] = { UP_FLAG, DOWN_FLAG, LEFT_FLAG, RIGHT_FLAG };
            for (int i = 0; i < 4; i++) {
                c.dpadButtons[i].backgroundColor = FoldPadFill((c.dpadFlags & bits[i]) != 0);
            }
        }
        else if (c.kind == FoldPadStick) {
            CGRect f = c.view.frame;
            c.knob.center = CGPointMake(CGRectGetMidX(f) + c.stickValue.x * f.size.width / 2,
                                        CGRectGetMidY(f) - c.stickValue.y * f.size.height / 2);
            c.knob.backgroundColor = [UIColor colorWithWhite:0.85 alpha:0.6];
            c.view.hidden = !c.pressed;
            c.knob.hidden = !c.pressed;
        }
    }
    short lx = (short)(_lstick.stickValue.x * 32767), ly = (short)(_lstick.stickValue.y * 32767);
    short rx = (short)(_rstick.stickValue.x * 32767), ry = (short)(_rstick.stickValue.y * 32767);
    BOOL idle = flags == 0 && lt == 0 && rt == 0 && lx == 0 && ly == 0 && rx == 0 && ry == 0;
    if (!_sentOnce && idle) {
        return;
    }
    if (_sentOnce && flags == _lastFlags && lt == _lastLt && rt == _lastRt &&
        lx == _lastLx && ly == _lastLy && rx == _lastRx && ry == _lastRy) {
        return;
    }
    _sentOnce = YES;
    _lastFlags = flags; _lastLt = lt; _lastRt = rt;
    _lastLx = lx; _lastLy = ly; _lastRx = rx; _lastRy = ry;
    LiSendMultiControllerEvent(0, 0x1, flags, lt, rt, lx, ly, rx, ry);
}

@end
