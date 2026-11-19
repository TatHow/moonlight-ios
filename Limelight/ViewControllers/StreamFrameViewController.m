//
//  StreamFrameViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 1/18/14.
//  Copyright (c) 2015 Moonlight Stream. All rights reserved.
//

#import "StreamFrameViewController.h"
#import "MainFrameViewController.h"
#import "VideoDecoderRenderer.h"
#import "StreamManager.h"
#import "ControllerSupport.h"
#import "DataManager.h"
#import "HttpManager.h"
#import "FoldDisplayMatch.h"
#import "../Input/FoldKeyboard.h"

#import <AVFoundation/AVFoundation.h>

#include <sys/socket.h>
#include <netinet/in.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <Limelight.h>

#if TARGET_OS_TV
#import <AVFoundation/AVDisplayCriteria.h>
#import <AVKit/AVDisplayManager.h>
#import <AVKit/UIWindow.h>
#endif

@interface AVDisplayCriteria()
@property(readonly) int videoDynamicRange;
@property(readonly, nonatomic) float refreshRate;
- (id)initWithRefreshRate:(float)arg1 videoDynamicRange:(int)arg2;
@end

#if !TARGET_OS_TV
#pragma mark - Fold input panel

// Shown on the half of a folded iPhone that isn't showing the stream, like the
// bottom half of a laptop: a full PC keyboard with a trackpad and mouse buttons.
@interface FoldInputPanel : UIView
@property (nonatomic, weak) StreamView* streamView;
@property (nonatomic, copy) void (^fullScreenHandler)(void);
@end

@implementation FoldInputPanel {
    FoldKeyboardView* _keyboard;
    UIView* _trackpad;
    CGPoint _lastPan;
    CGPoint _lastScroll;
    CGPoint _lastDrag;
    float _accumX, _accumY;
    float _scrollAccumX, _scrollAccumY;
    CADisplayLink* _glide;
    CGPoint _glideVelocity;
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.backgroundColor = [UIColor colorWithWhite:0.06 alpha:1.0];
        self.multipleTouchEnabled = YES;

        _keyboard = [[FoldKeyboardView alloc] initWithStyle:FoldKeyboardStyleFull];
        __weak FoldInputPanel* weakSelf = self;
        _keyboard.actionHandler = ^(NSString* action) {
            FoldInputPanel* strongSelf = weakSelf;
            if ([action isEqualToString:@"fullscreen"] && strongSelf.fullScreenHandler) {
                strongSelf.fullScreenHandler();
            }
        };
        [self addSubview:_keyboard];

        _trackpad = [[UIView alloc] init];
        _trackpad.backgroundColor = [UIColor colorWithWhite:0.13 alpha:1.0];
        _trackpad.layer.cornerRadius = 12;
        _trackpad.multipleTouchEnabled = YES;
        [self addSubview:_trackpad];

        UIPanGestureRecognizer* move = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadMoved:)];
        move.maximumNumberOfTouches = 1;
        [_trackpad addGestureRecognizer:move];

        UIPanGestureRecognizer* scroll = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadScrolled:)];
        scroll.minimumNumberOfTouches = 2;
        scroll.maximumNumberOfTouches = 2;
        [_trackpad addGestureRecognizer:scroll];

        // Tap = left click (tap twice to double-click), two-finger tap = right click
        UITapGestureRecognizer* tap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadTapped:)];
        [_trackpad addGestureRecognizer:tap];

        UITapGestureRecognizer* twoTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadTwoFingerTapped:)];
        twoTap.numberOfTouchesRequired = 2;
        [_trackpad addGestureRecognizer:twoTap];

        UITapGestureRecognizer* threeTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadThreeFingerTapped:)];
        threeTap.numberOfTouchesRequired = 3;
        [_trackpad addGestureRecognizer:threeTap];

        // Press and hold, then drag, to click-and-drag
        UILongPressGestureRecognizer* drag = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(trackpadDragged:)];
        drag.minimumPressDuration = 0.35;
        [_trackpad addGestureRecognizer:drag];
        [move requireGestureRecognizerToFail:drag];

    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat pad = 8;
    // Run the trackpad to the bottom edge; the home indicator can share that strip
    UIEdgeInsets insets = self.safeAreaInsets;
    insets.bottom = 0;
    CGRect area = UIEdgeInsetsInsetRect(self.bounds, insets);
    // The panel is laid out while hidden at zero size too; insetting a rect that
    // small produces a null (infinite) rect, which crashes Core Animation.
    if (area.size.width < 120 || area.size.height < 160) {
        return;
    }
    area = CGRectInset(area, pad, pad);

    CGRect keys, pad2;
    if (area.size.width > area.size.height * 2.2) {
        // Short and wide (laptop posture held sideways): keyboard left, trackpad right
        CGFloat kw = floor(area.size.width * 0.7);
        keys = CGRectMake(area.origin.x, area.origin.y, kw, area.size.height);
        pad2 = CGRectMake(area.origin.x + kw + pad, area.origin.y, area.size.width - kw - pad, area.size.height);
    } else {
        // Keyboard on top (next to the fold), trackpad below it like a laptop
        CGFloat kh = MIN(floor(area.size.height * 0.64), 320);
        keys = CGRectMake(area.origin.x, area.origin.y, area.size.width, kh);
        // Trackpad takes the full width of everything below the keyboard
        CGFloat top = CGRectGetMaxY(keys) + pad;
        pad2 = CGRectMake(area.origin.x, top, area.size.width, CGRectGetMaxY(area) - top);
    }
    _keyboard.frame = keys;
    _trackpad.frame = pad2;
}

- (void)click:(int)button {
    LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, button);
    usleep(20 * 1000);
    LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, button);
}

- (void)mouseButtonTapped:(UIButton*)sender {
    [self click:(int)sender.tag];
}

// Pointer acceleration: slow movements stay precise, fast ones cover the screen
- (void)moveByDelta:(CGPoint)delta {
    float speed = hypotf(delta.x, delta.y);
    float gain = 1.6f + MIN(speed / 12.0f, 2.4f);
    _accumX += delta.x * gain;
    _accumY += delta.y * gain;
    short dx = (short)_accumX, dy = (short)_accumY;
    if (dx != 0 || dy != 0) {
        LiSendMouseMoveEvent(dx, dy);
        _accumX -= dx;
        _accumY -= dy;
    }
}

- (void)trackpadMoved:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:_trackpad];
    if (g.state == UIGestureRecognizerStateBegan) {
        [self stopGlide];
        _lastPan = t;
        return;
    }
    [self moveByDelta:CGPointMake(t.x - _lastPan.x, t.y - _lastPan.y)];
    _lastPan = t;
}

// Natural scrolling: content follows the fingers, like an iPhone or a Mac trackpad
- (void)scrollByDelta:(CGPoint)delta {
    _scrollAccumY += delta.y * 8;
    _scrollAccumX += -delta.x * 8;
    short dy = (short)_scrollAccumY, dx = (short)_scrollAccumX;
    if (dy != 0) {
        LiSendHighResScrollEvent(dy);
        _scrollAccumY -= dy;
    }
    if (dx != 0) {
        LiSendHighResHScrollEvent(dx);
        _scrollAccumX -= dx;
    }
}

- (void)trackpadScrolled:(UIPanGestureRecognizer*)g {
    CGPoint t = [g translationInView:_trackpad];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            [self stopGlide];
            _lastScroll = t;
            break;
        case UIGestureRecognizerStateChanged:
            [self scrollByDelta:CGPointMake(t.x - _lastScroll.x, t.y - _lastScroll.y)];
            _lastScroll = t;
            break;
        case UIGestureRecognizerStateEnded: {
            // Keep gliding after the fingers lift, slowing down like iOS scrolling
            CGPoint v = [g velocityInView:_trackpad];
            if (hypot(v.x, v.y) > 150) {
                _glideVelocity = v;
                _glide = [CADisplayLink displayLinkWithTarget:self selector:@selector(glideStep:)];
                [_glide addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
            }
            break;
        }
        default:
            break;
    }
}

- (void)glideStep:(CADisplayLink*)link {
    CFTimeInterval dt = link.targetTimestamp - link.timestamp;
    if (dt <= 0 || dt > 0.1) {
        dt = 1.0 / 60;
    }
    [self scrollByDelta:CGPointMake(_glideVelocity.x * dt, _glideVelocity.y * dt)];
    double decay = pow(0.94, dt * 60);
    _glideVelocity = CGPointMake(_glideVelocity.x * decay, _glideVelocity.y * decay);
    if (hypot(_glideVelocity.x, _glideVelocity.y) < 30) {
        [self stopGlide];
    }
}

- (void)stopGlide {
    [_glide invalidate];
    _glide = nil;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
    // Touching the trackpad stops a glide, like touching the glass on iOS
    [self stopGlide];
    [super touchesBegan:touches withEvent:event];
}

- (void)willMoveToWindow:(UIWindow*)newWindow {
    [super willMoveToWindow:newWindow];
    if (newWindow == nil) {
        [self stopGlide];
        [FoldKeyboardView releaseAllModifiers];
    }
}

- (void)trackpadTapped:(UITapGestureRecognizer*)g {
    [self click:BUTTON_LEFT];
}

- (void)trackpadTwoFingerTapped:(UITapGestureRecognizer*)g {
    [self click:BUTTON_RIGHT];
}

- (void)trackpadThreeFingerTapped:(UITapGestureRecognizer*)g {
    [self click:BUTTON_MIDDLE];
}

- (void)trackpadDragged:(UILongPressGestureRecognizer*)g {
    CGPoint p = [g locationInView:_trackpad];
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            [self stopGlide];
            _lastDrag = p;
            LiSendMouseButtonEvent(BUTTON_ACTION_PRESS, BUTTON_LEFT);
            break;
        case UIGestureRecognizerStateChanged:
            [self moveByDelta:CGPointMake(p.x - _lastDrag.x, p.y - _lastDrag.y)];
            _lastDrag = p;
            break;
        default:
            LiSendMouseButtonEvent(BUTTON_ACTION_RELEASE, BUTTON_LEFT);
            break;
    }
}

@end
#endif

typedef NS_ENUM(NSInteger, FoldLayout) {
    FoldLayoutFull,     // stream fills the screen
    FoldLayoutLaptop,   // fold is horizontal: stream on top, input panel below
    FoldLayoutBook,     // fold is vertical: stream on one side, input panel on the other
};

@implementation StreamFrameViewController {
    ControllerSupport *_controllerSupport;
    StreamManager *_streamMan;
    TemporarySettings *_settings;
    NSTimer *_inactivityTimer;
    NSTimer *_statsUpdateTimer;
    UITapGestureRecognizer *_menuTapGestureRecognizer;
    UITapGestureRecognizer *_menuDoubleTapGestureRecognizer;
    UITapGestureRecognizer *_playPauseTapGestureRecognizer;
    UITextView *_overlayView;
    UILabel *_stageLabel;
    UILabel *_tipLabel;
    UIActivityIndicatorView *_spinner;
    StreamView *_streamView;
    UIScrollView *_scrollView;
    BOOL _userIsInteracting;
    CGSize _keyboardSize;

    // Match display: restart the stream at the view's size when it changes
    CGSize _lastLayoutSize;
    NSTimer *_resizeTimer;
    BOOL _streamActive;
    BOOL _reconfiguring;
    NSMutableArray<CALayer*> *_staleVideoLayers;

    // Leaving the app keeps the stream; if the connection drops while we're
    // away it is picked up again on return (_backgroundPaused)
    BOOL _inBackground;
    CFTimeInterval _foregroundedAt;
    BOOL _backgroundPaused;
    BOOL _stopInFlight;
    BOOL _startWhenStopped;

    // Clipboard sent to the PC: the pasteboard changeCount last read, so the
    // same contents aren't read (and iOS doesn't ask to paste) again
    NSInteger _clipboardChangeCount;
    BOOL _clipboardSendInFlight;
    UILabel *_toastLabel;

    // Foldable postures
    FoldLayout _foldLayout;
    CGRect _foldDivision;          // fold band in self.view coordinates (when folded)
    BOOL _foldFullScreenOverride;  // user asked for full screen in the current posture
    NSInteger _hingeStatus;        // UIHingeStatus raw value, 0 when unknown / no hinge
#if !TARGET_OS_TV
    FoldInputPanel *_foldPanel;
    UIView *_foldRail;
    BOOL _foldPanelForced;
    UIView *_foldRailButtons;
    NSArray<UIButton*> *_foldRailButtonList;
#endif
    
#if !TARGET_OS_TV
    UIScreenEdgePanGestureRecognizer *_exitSwipeRecognizer;
#endif
}

- (void)viewDidAppear:(BOOL)animated
{
    [super viewDidAppear:animated];
    
#if !TARGET_OS_TV
    [[self revealViewController] setPrimaryViewController:self];
#endif
}

#if TARGET_OS_TV
- (void)controllerPauseButtonPressed:(id)sender { }
- (void)controllerPauseButtonDoublePressed:(id)sender {
    Log(LOG_I, @"Menu double-pressed -- backing out of stream");
    [self returnToMainFrame];
}
- (void)controllerPlayPauseButtonPressed:(id)sender {
    Log(LOG_I, @"Play/Pause button pressed -- backing out of stream");
    [self returnToMainFrame];
}
#endif


- (void)viewDidLoad
{
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES animated:YES];
    
    [UIApplication sharedApplication].idleTimerDisabled = YES;
    
    _settings = [[[DataManager alloc] init] getSettings];
    // Each connection starts on touchpad for Desktop, touchscreen for Virtual
    FoldSetSessionTouchscreen(self.streamConfig.foldVirtual);
    _settings.absoluteTouchMode = self.streamConfig.foldVirtual;
    
    _stageLabel = [[UILabel alloc] init];
    [_stageLabel setUserInteractionEnabled:NO];
    [_stageLabel setText:[NSString stringWithFormat:@"Starting %@...", self.streamConfig.appName]];
    [_stageLabel sizeToFit];
    _stageLabel.textAlignment = NSTextAlignmentCenter;
    _stageLabel.textColor = [UIColor whiteColor];
    _stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2);
    
    _spinner = [[UIActivityIndicatorView alloc] init];
    [_spinner setUserInteractionEnabled:NO];
#if TARGET_OS_TV
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhiteLarge];
#else
    [_spinner setActivityIndicatorViewStyle:UIActivityIndicatorViewStyleWhite];
#endif
    [_spinner sizeToFit];
    [_spinner startAnimating];
    _spinner.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height / 2 - _stageLabel.frame.size.height - _spinner.frame.size.height);
    
    _controllerSupport = [[ControllerSupport alloc] initWithConfig:self.streamConfig delegate:self];
    _inactivityTimer = nil;
    
    _streamView = [[StreamView alloc] initWithFrame:self.view.bounds];
    _streamView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _staleVideoLayers = [[NSMutableArray alloc] init];
    _lastLayoutSize = self.view.bounds.size;
    [_streamView setupStreamView:_controllerSupport interactionDelegate:self config:self.streamConfig];
    
#if TARGET_OS_TV
    if (!_menuTapGestureRecognizer || !_menuDoubleTapGestureRecognizer || !_playPauseTapGestureRecognizer) {
        _menuTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonPressed:)];
        _menuTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];

        _playPauseTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPlayPauseButtonPressed:)];
        _playPauseTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypePlayPause)];
        
        _menuDoubleTapGestureRecognizer = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(controllerPauseButtonDoublePressed:)];
        _menuDoubleTapGestureRecognizer.numberOfTapsRequired = 2;
        [_menuTapGestureRecognizer requireGestureRecognizerToFail:_menuDoubleTapGestureRecognizer];
        _menuDoubleTapGestureRecognizer.allowedPressTypes = @[@(UIPressTypeMenu)];
    }
    
    [self.view addGestureRecognizer:_menuTapGestureRecognizer];
    [self.view addGestureRecognizer:_menuDoubleTapGestureRecognizer];
    [self.view addGestureRecognizer:_playPauseTapGestureRecognizer];

#else
    _exitSwipeRecognizer = [[UIScreenEdgePanGestureRecognizer alloc] initWithTarget:self action:@selector(edgeSwiped)];
    _exitSwipeRecognizer.edges = UIRectEdgeLeft;
    _exitSwipeRecognizer.delaysTouchesBegan = NO;
    _exitSwipeRecognizer.delaysTouchesEnded = NO;
    
    [self.view addGestureRecognizer:_exitSwipeRecognizer];
#endif
    
    _tipLabel = [[UILabel alloc] init];
    [_tipLabel setUserInteractionEnabled:NO];
    
#if TARGET_OS_TV
    [_tipLabel setText:@"Tip: Tap the Play/Pause button on the Apple TV Remote to disconnect from your PC"];
#else
    [_tipLabel setText:@"Tip: Swipe from the left edge for settings and Disconnect"];
#endif
    
    [_tipLabel sizeToFit];
    _tipLabel.textColor = [UIColor whiteColor];
    _tipLabel.textAlignment = NSTextAlignmentCenter;
    _tipLabel.center = CGPointMake(self.view.frame.size.width / 2, self.view.frame.size.height * 0.9);
    
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationWillResignActive:)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidBecomeActive:)
                                                 name: UIApplicationDidBecomeActiveNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(applicationDidEnterBackground:)
                                                 name: UIApplicationDidEnterBackgroundNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(foldSettingsClosed:)
                                                 name:kFoldSettingsClosedNotification
                                               object:nil];
    
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(foldDisconnectRequested:)
                                                 name:kFoldDisconnectNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(foldOpenSettingsRequested:)
                                                 name:kFoldOpenSettingsNotification
                                               object:nil];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(foldApplyTouchMode)
                                                 name:kFoldTouchModeChangedNotification
                                               object:nil];

    _clipboardChangeCount = -1;
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(foldSendClipboardRequested:)
                                                 name:kFoldSendClipboardNotification
                                               object:nil];

#if 0
    // FIXME: This doesn't work reliably on iPad for some reason. Showing and hiding the keyboard
    // several times in a row will not correctly restore the state of the UIScrollView.
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillShow:)
                                                 name: UIKeyboardWillShowNotification
                                               object: nil];
    
    [[NSNotificationCenter defaultCenter] addObserver: self
                                             selector: @selector(keyboardWillHide:)
                                                 name: UIKeyboardWillHideNotification
                                               object: nil];
#endif
    
    // Fold build: touchscreen mode sends real touches to the PC (two-finger
    // scroll and pinch included), so the local pan/zoom view is not used
    if (NO) {
        _scrollView = [[UIScrollView alloc] initWithFrame:self.view.bounds];
        _scrollView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
#if !TARGET_OS_TV
        [_scrollView.panGestureRecognizer setMinimumNumberOfTouches:2];
#endif
        [_scrollView setShowsHorizontalScrollIndicator:NO];
        [_scrollView setShowsVerticalScrollIndicator:NO];
        [_scrollView setDelegate:self];
        [_scrollView setMaximumZoomScale:10.0f];
        
        // Add StreamView inside a UIScrollView for absolute mode
        [_scrollView addSubview:_streamView];
        [self.view addSubview:_scrollView];
    }
    else {
        // Add StreamView directly in relative mode
        [self.view addSubview:_streamView];
    }
    
    [self.view addSubview:_stageLabel];
    [self.view addSubview:_spinner];
    [self.view addSubview:_tipLabel];
    
    [self setupFoldSupport];
}

- (UIView *)viewForZoomingInScrollView:(UIScrollView *)scrollView {
    return _streamView;
}

- (void)willMoveToParentViewController:(UIViewController *)parent {
    // Only cleanup when we're being destroyed
    if (parent == nil) {
        _reconfiguring = NO;
        _streamActive = NO;
        [_resizeTimer invalidate];
        _resizeTimer = nil;
        [_streamView foldSetOnScreenControls:OnScreenControlsLevelOff];
        [_controllerSupport cleanup];
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        [_streamMan stopStream];
        if (_inactivityTimer != nil) {
            [_inactivityTimer invalidate];
            _inactivityTimer = nil;
        }
        [[NSNotificationCenter defaultCenter] removeObserver:self];
    }
}

#if 0
- (void)keyboardWillShow:(NSNotification *)notification {
    _keyboardSize = [[[notification userInfo] objectForKey:UIKeyboardFrameBeginUserInfoKey] CGRectValue].size;

    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height -= self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}

-(void)keyboardWillHide:(NSNotification *)notification {
    // NOTE: UIKeyboardFrameEndUserInfoKey returns a different keyboard size
    // than UIKeyboardFrameBeginUserInfoKey, so it's unsuitable for use here
    // to undo the changes made by keyboardWillShow.
    
    [UIView animateWithDuration:0.3 animations:^{
        CGRect frame = self->_scrollView.frame;
        frame.size.height += self->_keyboardSize.height;
        self->_scrollView.frame = frame;
    }];
}
#endif

- (void)updateStatsOverlay {
    NSString* overlayText = [self->_streamMan getStatsOverlayText];
    
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updateOverlayText:overlayText];
    });
}

- (void)updateOverlayText:(NSString*)text {
    if (_overlayView == nil) {
        _overlayView = [[UITextView alloc] init];
#if !TARGET_OS_TV
        [_overlayView setEditable:NO];
#endif
        [_overlayView setUserInteractionEnabled:NO];
        [_overlayView setSelectable:NO];
        [_overlayView setScrollEnabled:NO];
        
        // HACK: If not using stats overlay, center the text
        if (_statsUpdateTimer == nil) {
            [_overlayView setTextAlignment:NSTextAlignmentCenter];
        }
        
        [_overlayView setTextColor:[UIColor lightGrayColor]];
        [_overlayView setBackgroundColor:[UIColor blackColor]];
#if TARGET_OS_TV
        [_overlayView setFont:[UIFont systemFontOfSize:24]];
#else
        [_overlayView setFont:[UIFont systemFontOfSize:12]];
#endif
        [_overlayView setAlpha:0.5];
        [self.view addSubview:_overlayView];
    }
    
    if (text != nil) {
        // We set our bounds to the maximum width in order to work around a bug where
        // sizeToFit interacts badly with the UITextView's line breaks, causing the
        // width to get smaller and smaller each time as more line breaks are inserted.
        [_overlayView setBounds:CGRectMake(self.view.frame.origin.x,
                                           _overlayView.frame.origin.y,
                                           self.view.frame.size.width,
                                           _overlayView.frame.size.height)];
        [_overlayView setText:text];
        [_overlayView sizeToFit];
        [_overlayView setCenter:CGPointMake(self.view.frame.size.width / 2, _overlayView.frame.size.height / 2)];
        [_overlayView setHidden:NO];
    }
    else {
        [_overlayView setHidden:YES];
    }
}

- (void) returnToMainFrame {
#if !TARGET_OS_TV
    // Close the settings pane if it was opened over the stream
    SWRevealViewController* reveal = self.revealViewController;
    if (reveal != nil && reveal.frontViewPosition != FrontViewPositionLeft) {
        [reveal setFrontViewPosition:FrontViewPositionLeft animated:NO];
    }
#endif
    _backgroundPaused = NO;
    _startWhenStopped = NO;
    
    // Reset display mode back to default
    [self updatePreferredDisplayMode:NO];
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    [self.navigationController popToRootViewControllerAnimated:YES];
}

// This will fire if the user opens control center or gets a low battery message
- (void)applicationWillResignActive:(NSNotification *)notification {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
    }
    
    // Fold build: the stream is kept (paused in the background) instead of
    // being ended after a minute of inactivity
}

- (void)inactiveTimerExpired:(NSTimer*)timer {
    Log(LOG_I, @"Terminating stream after inactivity");

    [self returnToMainFrame];
    
    _inactivityTimer = nil;
}

- (void)applicationDidBecomeActive:(NSNotification *)notification {
    // Stop the background timer, since we're foregrounded again
    if (_inactivityTimer != nil) {
        Log(LOG_I, @"Stopping inactivity timer after becoming active again");
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    if (_inBackground) {
        _inBackground = NO;
        _foregroundedAt = CACurrentMediaTime();
        if (!_backgroundPaused && (_streamActive || _reconfiguring)) {
            // Still connected: the decoder was torn down by iOS, so ask the host for a
            // full frame and the renderer rebuilds its layer from it
            Log(LOG_I, @"Back in the foreground, stream still connected");
            [self ensureFreshVideo];
            [self scheduleResolutionMatch];
            // Something may have been copied in another app
            [self sendClipboardToHost:NO];
        }
    }
    
    if (_backgroundPaused) {
        Log(LOG_I, @"Back in the foreground, reconnecting to the running session");
        _backgroundPaused = NO;
        [UIApplication sharedApplication].idleTimerDisabled = YES;
        [self showStageText:@"Reconnecting..."];
        if (self.streamConfig.foldVirtual) {
            // The screen may have changed (folded, rotated) while we were away
            CGSize target = FoldStreamSizeForView([self streamContainer], [self maxStreamDimension]);
            self.streamConfig.width = (int)target.width;
            self.streamConfig.height = (int)target.height;
        }
        if (_stopInFlight) {
            _startWhenStopped = YES;
        }
        else {
            [self startReplacementStream];
        }
    }
}

// This fires when the home button is pressed
- (void)applicationDidEnterBackground:(UIApplication *)application {
    if (_inactivityTimer != nil) {
        [_inactivityTimer invalidate];
        _inactivityTimer = nil;
    }
    
    // Fold build: keep the connection open (audio keeps the app running in the
    // background). Video isn't drawn while we're away; if the host drops us
    // anyway, we reconnect when we come back.
    Log(LOG_I, @"Entering background, keeping the stream connected");
    _inBackground = YES;
}

- (void)ensureFreshVideo {
    LiRequestIdrFrame();
    // A second request shortly after covers a renderer that was still failing
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self->_streamActive) {
            LiRequestIdrFrame();
        }
    });
}

// Stops the current connection; runs `then` (or a pending restart) once it is down
- (void)stopStreamThen:(void (^)(void))then {
    _stopInFlight = YES;
    [_streamMan stopStreamWithCompletion:^{
        self->_stopInFlight = NO;
        if (then != nil) {
            then();
        }
        if (self->_startWhenStopped) {
            self->_startWhenStopped = NO;
            [self startReplacementStream];
        }
    }];
}

// Starts a new connection to the session that is still running on the host,
// keeping the last frame on screen until the new stream draws
- (void)startReplacementStream {
    if (self.parentViewController == nil) {
        return;
    }
    _reconfiguring = YES;
    for (CALayer* layer in _streamView.layer.sublayers) {
        if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]] && ![_staleVideoLayers containsObject:layer]) {
            [_staleVideoLayers addObject:layer];
        }
    }
    [_streamView streamGeometryChanged:self.streamConfig];
    
    // StreamManager resumes the running app since the host reports it as busy
    _streamMan = [[StreamManager alloc] initWithConfig:self.streamConfig
                                            renderView:_streamView
                                   connectionCallbacks:self];
    NSOperationQueue* opQueue = [[NSOperationQueue alloc] init];
    [opQueue addOperation:_streamMan];
}

- (void)showStageText:(NSString*)text {
    [_stageLabel setText:text];
    [_stageLabel sizeToFit];
    _stageLabel.center = CGPointMake(CGRectGetMidX([self streamContainer].frame), CGRectGetMidY([self streamContainer].frame));
    _stageLabel.hidden = NO;
    [self.view bringSubviewToFront:_stageLabel];
}

// Fold build: the left-edge swipe opens settings over the running stream
- (void)edgeSwiped {
#if !TARGET_OS_TV
    if (_exitSwipeRecognizer.state != UIGestureRecognizerStateBegan) {
        return;
    }
    [self foldOpenSettings];
#else
    [self returnToMainFrame];
#endif
}

// The on-screen gamepad's gear button
- (void)foldOpenSettingsRequested:(NSNotification*)note {
#if !TARGET_OS_TV
    [self foldOpenSettings];
#endif
}

#if !TARGET_OS_TV
- (void)foldOpenSettings {
    SWRevealViewController* reveal = self.revealViewController;
    if (reveal == nil) {
        [self returnToMainFrame];
        return;
    }
    if (reveal.frontViewPosition == FrontViewPositionLeft) {
        Log(LOG_I, @"User swiped to open settings");
        [self.view endEditing:YES];
        CGFloat width = self.view.window ? self.view.window.bounds.size.width : self.view.bounds.size.width;
        reveal.rearViewRevealWidth = MIN(510.0f, MAX(260.0f, width - 64.0f));
        [reveal setFrontViewPosition:FrontViewPositionRight animated:YES];
        [self foldAddSettingsShield];
    }
}
#endif

// While settings are open, the visible strip of the stream closes them on tap
// (and doesn't send touches to the PC)
- (void)foldAddSettingsShield {
    [self foldRemoveSettingsShield];
    UIView* shield = [[UIView alloc] initWithFrame:self.view.bounds];
    shield.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    shield.backgroundColor = [UIColor colorWithWhite:0 alpha:0.25];
    shield.tag = 0xF01D;
    [shield addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(foldCloseSettings)]];
    [self.view addSubview:shield];
}

- (void)foldRemoveSettingsShield {
    [[self.view viewWithTag:0xF01D] removeFromSuperview];
}

- (void)foldCloseSettings {
    SWRevealViewController* reveal = self.revealViewController;
    if (reveal != nil && reveal.frontViewPosition != FrontViewPositionLeft) {
        [reveal setFrontViewPosition:FrontViewPositionLeft animated:YES];
    }
    [self foldRemoveSettingsShield];
}

- (void)foldDisconnectRequested:(NSNotification*)note {
    Log(LOG_I, @"User asked to disconnect from settings");
    [self returnToMainFrame];
}

- (void)foldApplyTouchMode {
    BOOL touchscreen = FoldSessionTouchscreen();
    if (self.parentViewController != nil && touchscreen != _settings.absoluteTouchMode) {
        _settings.absoluteTouchMode = touchscreen;
        [_streamView foldSetTouchscreen:touchscreen];
    }
}

// Apply settings changed while the stream was running
- (void)foldSettingsClosed:(NSNotification*)note {
    if (self.parentViewController == nil) {
        return;
    }
    TemporarySettings* fresh = [[[DataManager alloc] init] getSettings];
    
    [self foldRemoveSettingsShield];
    [self foldApplyTouchMode];
    [_streamView foldSetOnScreenControls:(OnScreenControlsLevel)[fresh.onscreenControls integerValue]];
    
    int width = self.streamConfig.width, height = self.streamConfig.height;
    int dpi = FoldVirtualDpi();
    if (!self.streamConfig.foldVirtual) {
        CGSize size = FoldDesktopStreamSize();
        if (size.width > [self maxStreamDimension]) {
            size = kFoldRenderScaleSizes[1];
        }
        width = (int)size.width;
        height = (int)size.height;
    }
    int fps = [fresh.framerate intValue];
    if (fps > [UIScreen mainScreen].maximumFramesPerSecond) {
        fps = (int)[UIScreen mainScreen].maximumFramesPerSecond;
    }
    int bitrate = [fresh.bitrate intValue];
    
    if (width == self.streamConfig.width && height == self.streamConfig.height && dpi == self.streamConfig.foldDpi &&
        fps == self.streamConfig.frameRate && bitrate == self.streamConfig.bitRate) {
        return;
    }
    
    Log(LOG_I, @"Settings changed, restarting stream at %dx%d %d FPS %d kbps (%d%%)", width, height, fps, bitrate, dpi);
    self.streamConfig.width = width;
    self.streamConfig.height = height;
    self.streamConfig.foldDpi = dpi;
    self.streamConfig.frameRate = fps;
    self.streamConfig.bitRate = bitrate;
    
    if (_backgroundPaused) {
        return;
    }
    _streamActive = NO;
    _reconfiguring = YES;
    [_resizeTimer invalidate];
    _resizeTimer = nil;
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    [self showStageText:@"Applying settings..."];
    if (_stopInFlight) {
        _startWhenStopped = YES;
    }
    else {
        [self stopStreamThen:^{
            [self startReplacementStream];
        }];
    }
}

- (void) connectionStarted {
    Log(LOG_I, @"Connection started");
    dispatch_async(dispatch_get_main_queue(), ^{
        self->_streamActive = YES;
        self->_reconfiguring = NO;
        
        // A new connection starts out OKAY and only reports changes, so a
        // "slow connection" warning left over from the stream we just replaced
        // (resize, settings change, reconnect) would never be cleared.
        if (self->_statsUpdateTimer == nil) {
            [self updateOverlayText:nil];
        }
        
        // Leave the spinner spinning until it's obscured by
        // the first frame of video.
        self->_stageLabel.hidden = YES;
        self->_tipLabel.hidden = YES;
        
        [self->_streamView showOnScreenControls];
        
        [self->_controllerSupport connectionEstablished];
        
        if (self->_settings.statsOverlay && self->_statsUpdateTimer == nil) {
            self->_statsUpdateTimer = [NSTimer scheduledTimerWithTimeInterval:1.0f
                                                                       target:self
                                                                     selector:@selector(updateStatsOverlay)
                                                                     userInfo:nil
                                                                      repeats:YES];
        }
        
        // The view may have changed size again while we were reconnecting
        [self scheduleResolutionMatch];
        
        [self sendClipboardToHost:NO];
    });
}

#pragma mark - Clipboard to PC

- (void)foldSendClipboardRequested:(NSNotification*)note {
#if !TARGET_OS_TV
    [self foldCloseSettings];
#endif
    [self sendClipboardToHost:YES];
}

// Puts the iPhone's clipboard text on the PC's clipboard (Apollo's
// /actions/clipboard). Automatic sends only happen when the clipboard changed
// since the last one, so iOS asks to paste at most once per copy.
- (void)sendClipboardToHost:(BOOL)userAsked {
#if !TARGET_OS_TV
    if (!_streamActive) {
        if (userAsked) {
            [self showToast:@"Not connected to the PC yet"];
        }
        return;
    }
    UIPasteboard* pasteboard = [UIPasteboard generalPasteboard];
    NSInteger changeCount = pasteboard.changeCount;
    if (!userAsked) {
        if (!FoldClipboardAuto() || changeCount == _clipboardChangeCount) {
            return;
        }
        // hasStrings doesn't trigger the paste prompt
        if (!pasteboard.hasStrings) {
            _clipboardChangeCount = changeCount;
            return;
        }
    }
    if (_clipboardSendInFlight) {
        return;
    }
    // Reading may show iOS's "Allow Paste" prompt; nil if the user declined
    NSString* text = pasteboard.string;
    _clipboardChangeCount = changeCount;
    if (text.length == 0) {
        if (userAsked) {
            [self showToast:@"No text on the clipboard"];
        }
        return;
    }
    
    _clipboardSendInFlight = YES;
    StreamConfiguration* config = self.streamConfig;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        HttpManager* hMan = [[HttpManager alloc] initWithAddress:config.host httpsPort:config.httpsPort serverCert:config.serverCert];
        NSInteger status = [hMan sendClipboardText:text];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_clipboardSendInFlight = NO;
            if (status == 200) {
                [self showToast:@"Clipboard sent to PC"];
            }
            else if (status == 401) {
                [self showToast:@"PC refused the clipboard: in Apollo's Clients page, allow \"Set clipboard\" for this iPhone"];
            }
            else if (status == 403) {
                [self showToast:@"PC refused the clipboard: this iPhone isn't streaming from it"];
            }
            else if (status == 404) {
                [self showToast:@"This host doesn't support receiving the clipboard (needs Apollo)"];
            }
            else {
                [self showToast:status > 0 ? [NSString stringWithFormat:@"Couldn't send clipboard (error %ld)", (long)status]
                                           : @"Couldn't send clipboard to PC"];
                // Let the next automatic attempt try the same contents again
                self->_clipboardChangeCount = -1;
            }
        });
    });
#endif
}

- (void)showToast:(NSString*)text {
    if (_toastLabel == nil) {
        _toastLabel = [[UILabel alloc] init];
        _toastLabel.userInteractionEnabled = NO;
        _toastLabel.textColor = [UIColor whiteColor];
        _toastLabel.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _toastLabel.textAlignment = NSTextAlignmentCenter;
        _toastLabel.numberOfLines = 0;
        _toastLabel.backgroundColor = [UIColor colorWithWhite:0.1 alpha:0.85];
        _toastLabel.layer.cornerRadius = 14;
        _toastLabel.clipsToBounds = YES;
    }
    [_toastLabel.layer removeAllAnimations];
    _toastLabel.text = text;
    CGRect area = _streamView.frame;
    if (CGRectIsEmpty(area)) {
        area = self.view.bounds;
    }
    CGFloat maxWidth = MIN(area.size.width - 40, 420);
    CGSize size = [_toastLabel sizeThatFits:CGSizeMake(maxWidth - 28, CGFLOAT_MAX)];
    CGFloat width = MIN(size.width + 28, maxWidth);
    CGFloat height = size.height + 16;
    _toastLabel.frame = CGRectMake(CGRectGetMidX(area) - width / 2, area.origin.y + MAX(self.view.safeAreaInsets.top, 12) + 12, width, height);
    [self.view addSubview:_toastLabel];
    [self.view bringSubviewToFront:_toastLabel];
    _toastLabel.alpha = 1;
    UILabel* label = _toastLabel;
    [UIView animateWithDuration:0.4 delay:(text.length > 40 ? 4.0 : 1.6) options:UIViewAnimationOptionBeginFromCurrentState animations:^{
        label.alpha = 0;
    } completion:^(BOOL finished) {
        if (finished) {
            [label removeFromSuperview];
        }
    }];
}

- (void)connectionTerminated:(int)errorCode {
    Log(LOG_I, @"Connection terminated: %d", errorCode);
    
    unsigned int portFlags = LiGetPortFlagsFromTerminationErrorCode(errorCode);
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portFlags);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        if (errorCode != ML_ERROR_GRACEFUL_TERMINATION &&
            (self->_inBackground || CACurrentMediaTime() - self->_foregroundedAt < 8)) {
            // Dropped because iOS suspended us: reconnect quietly instead of an error
            Log(LOG_I, @"Connection dropped around backgrounding, will reconnect");
            self->_streamActive = NO;
            self->_reconfiguring = YES;
            [self->_statsUpdateTimer invalidate];
            self->_statsUpdateTimer = nil;
            if (self->_inBackground) {
                self->_backgroundPaused = YES;
                [self stopStreamThen:nil];
            }
            else {
                [self showStageText:@"Reconnecting..."];
                [self stopStreamThen:^{
                    [self startReplacementStream];
                }];
            }
            return;
        }
        
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* title;
        NSString* message;
        
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            title = @"Connection Error";
            message = @"Your device's network connection is blocking Moonlight. Streaming may not work while connected to this network.";
        }
        else {
            switch (errorCode) {
                case ML_ERROR_GRACEFUL_TERMINATION:
                    [self returnToMainFrame];
                    return;
                    
                case ML_ERROR_NO_VIDEO_TRAFFIC:
                    title = @"Connection Error";
                    message = @"No video received from host.";
                    if (portFlags != 0) {
                        char failingPorts[256];
                        LiStringifyPortFlags(portFlags, "\n", failingPorts, sizeof(failingPorts));
                        message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
                    }
                    break;
                    
                case ML_ERROR_NO_VIDEO_FRAME:
                    title = @"Connection Error";
                    message = @"Your network connection isn't performing well. Reduce your video bitrate setting or try a faster connection.";
                    break;
                    
                case ML_ERROR_UNEXPECTED_EARLY_TERMINATION:
                case ML_ERROR_PROTECTED_CONTENT:
                    title = @"Connection Error";
                    message = @"Something went wrong on your host PC when starting the stream.\n\nMake sure you don't have any DRM-protected content open on your host PC. You can also try restarting your host PC.\n\nIf the issue persists, try reinstalling your GPU drivers and GeForce Experience.";
                    break;
                    
                case ML_ERROR_FRAME_CONVERSION:
                    title = @"Connection Error";
                    message = @"The host PC reported a fatal video encoding error.\n\nTry disabling HDR mode, changing the streaming resolution, or changing your host PC's display resolution.";
                    break;
                    
                default:
                {
                    NSString* errorString;
                    if (abs(errorCode) > 1000) {
                        // We'll assume large errors are hex values
                        errorString = [NSString stringWithFormat:@"%08X", (uint32_t)errorCode];
                    }
                    else {
                        // Smaller values will just be printed as decimal (probably errno.h values)
                        errorString = [NSString stringWithFormat:@"%d", errorCode];
                    }
                    
                    title = @"Connection Terminated";
                    message = [NSString stringWithFormat: @"The connection was terminated\n\nError code: %@", errorString];
                    break;
                }
            }
        }
        
        UIAlertController* conTermAlert = [UIAlertController alertControllerWithTitle:title
                                                                              message:message
                                                                       preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:conTermAlert];
        [conTermAlert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:conTermAlert animated:YES completion:nil];
    });

    [_streamMan stopStream];
}

- (void) stageStarting:(const char*)stageName {
    Log(LOG_I, @"Starting %s", stageName);
    dispatch_async(dispatch_get_main_queue(), ^{
        NSString* lowerCase = [NSString stringWithFormat:@"%s in progress...", stageName];
        NSString* titleCase = [[[lowerCase substringToIndex:1] uppercaseString] stringByAppendingString:[lowerCase substringFromIndex:1]];
        [self->_stageLabel setText:titleCase];
        [self->_stageLabel sizeToFit];
        self->_stageLabel.center = CGPointMake(self.view.frame.size.width / 2, self->_stageLabel.center.y);
    });
}

- (void) stageComplete:(const char*)stageName {
}

- (void) stageFailed:(const char*)stageName withError:(int)errorCode portTestFlags:(int)portTestFlags {
    Log(LOG_I, @"Stage %s failed: %d", stageName, errorCode);
    
    unsigned int portTestResults = LiTestClientConnectivity(CONN_TEST_SERVER, 443, portTestFlags);

    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        NSString* message = [NSString stringWithFormat:@"%s failed with error %d", stageName, errorCode];
        if (portTestFlags != 0) {
            char failingPorts[256];
            LiStringifyPortFlags(portTestFlags, "\n", failingPorts, sizeof(failingPorts));
            message = [message stringByAppendingString:[NSString stringWithFormat:@"\n\nCheck your firewall and port forwarding rules for port(s):\n%s", failingPorts]];
        }
        if (portTestResults != ML_TEST_RESULT_INCONCLUSIVE && portTestResults != 0) {
            message = [message stringByAppendingString:@"\n\nYour device's network connection is blocking Moonlight. Streaming may not work while connected to this network."];
        }
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Failed"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
    
    [_streamMan stopStream];
}

- (void) launchFailed:(NSString*)message {
    Log(LOG_I, @"Launch failed: %@", message);
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // Allow the display to go to sleep now
        [UIApplication sharedApplication].idleTimerDisabled = NO;
        
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Connection Error"
                                                                       message:message
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [Utils addHelpOptionToDialog:alert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction* action){
            [self returnToMainFrame];
        }]];
        [self presentViewController:alert animated:YES completion:nil];
    });
}

- (void)rumble:(unsigned short)controllerNumber lowFreqMotor:(unsigned short)lowFreqMotor highFreqMotor:(unsigned short)highFreqMotor {
    Log(LOG_I, @"Rumble on gamepad %d: %04x %04x", controllerNumber, lowFreqMotor, highFreqMotor);
    
    [_controllerSupport rumble:controllerNumber lowFreqMotor:lowFreqMotor highFreqMotor:highFreqMotor];
}

- (void) rumbleTriggers:(uint16_t)controllerNumber leftTrigger:(uint16_t)leftTrigger rightTrigger:(uint16_t)rightTrigger {
    Log(LOG_I, @"Trigger rumble on gamepad %d: %04x %04x", controllerNumber, leftTrigger, rightTrigger);
    
    [_controllerSupport rumbleTriggers:controllerNumber leftTrigger:leftTrigger rightTrigger:rightTrigger];
}

- (void) setMotionEventState:(uint16_t)controllerNumber motionType:(uint8_t)motionType reportRateHz:(uint16_t)reportRateHz {
    Log(LOG_I, @"Set motion state on gamepad %d: %02x %u Hz", controllerNumber, motionType, reportRateHz);
    
    [_controllerSupport setMotionEventState:controllerNumber motionType:motionType reportRateHz:reportRateHz];
}

- (void) setControllerLed:(uint16_t)controllerNumber r:(uint8_t)r g:(uint8_t)g b:(uint8_t)b {
    Log(LOG_I, @"Set controller LED on gamepad %d: l%02x%02x%02x", controllerNumber, r, g, b);
    
    [_controllerSupport setControllerLed:controllerNumber r:r g:g b:b];
}

- (void)connectionStatusUpdate:(int)status {
    Log(LOG_W, @"Connection status update: %d", status);

    // The stats overlay takes precedence over these warnings
    if (_statsUpdateTimer != nil) {
        return;
    }
    
    dispatch_async(dispatch_get_main_queue(), ^{
        // The stats overlay may have started while this was queued
        if (self->_statsUpdateTimer != nil) {
            return;
        }
        
        // Drop a late warning from a connection that is being torn down or
        // replaced: the next connection would never send OKAY to clear it.
        if (status == CONN_STATUS_POOR && (!self->_streamActive || self->_reconfiguring)) {
            return;
        }
        
        switch (status) {
            case CONN_STATUS_OKAY:
                [self updateOverlayText:nil];
                break;
                
            case CONN_STATUS_POOR:
                if (self->_streamConfig.bitRate > 5000) {
                    [self updateOverlayText:@"Slow connection to PC\nReduce your bitrate"];
                }
                else {
                    [self updateOverlayText:@"Poor connection to PC"];
                }
                break;
        }
    });
}

- (void) updatePreferredDisplayMode:(BOOL)streamActive {
#if TARGET_OS_TV
    if (@available(tvOS 11.2, *)) {
        UIWindow* window = [[[UIApplication sharedApplication] delegate] window];
        AVDisplayManager* displayManager = [window avDisplayManager];
        
        // This logic comes from Kodi and MrMC
        if (streamActive) {
            int dynamicRange;
            
            if (LiGetCurrentHostDisplayHdrMode()) {
                dynamicRange = 2; // HDR10
            }
            else {
                dynamicRange = 0; // SDR
            }
            
            AVDisplayCriteria* displayCriteria = [[AVDisplayCriteria alloc] initWithRefreshRate:[_settings.framerate floatValue]
                                                                              videoDynamicRange:dynamicRange];
            displayManager.preferredDisplayCriteria = displayCriteria;
        }
        else {
            // Switch back to the default display mode
            displayManager.preferredDisplayCriteria = nil;
        }
    }
#endif
}

- (void) setHdrMode:(bool)enabled {
    Log(LOG_I, @"HDR is now: %s", enabled ? "active" : "inactive");
    dispatch_async(dispatch_get_main_queue(), ^{
        [self updatePreferredDisplayMode:YES];
    });
}

- (void) videoContentShown {
    // The new stream is on screen, so drop the frozen frame from the previous one
    for (CALayer* layer in _staleVideoLayers) {
        [layer removeFromSuperlayer];
    }
    [_staleVideoLayers removeAllObjects];
    
    [_spinner stopAnimating];
    [self.view setBackgroundColor:[UIColor blackColor]];
}

#pragma mark - Match display (dynamic resolution)

- (void)viewDidLayoutSubviews {
    [super viewDidLayoutSubviews];
    
    [self applyFoldLayout];
    
    UIView* container = [self streamContainer];
    if (!CGSizeEqualToSize(container.bounds.size, _lastLayoutSize)) {
        _lastLayoutSize = container.bounds.size;
        [self viewSizeChanged];
    }
}

- (UIView*)streamContainer {
    return _scrollView != nil ? _scrollView : _streamView;
}

#pragma mark - Foldable postures

- (void)setupFoldSupport {
#if !TARGET_OS_TV
    _foldPanel = [[FoldInputPanel alloc] initWithFrame:CGRectMake(0, 0, 320, 320)];
    _foldPanel.streamView = _streamView;
    _foldPanel.hidden = YES;
    __weak typeof(self) weakSelf = self;
    _foldPanel.fullScreenHandler = ^{
        typeof(self) strongSelf = weakSelf;
        if (strongSelf) {
            strongSelf->_foldFullScreenOverride = YES;
            [strongSelf.view setNeedsLayout];
        }
    };
    [self.view addSubview:_foldPanel];
    [self setupFoldRail];
    
#if __has_include(<UIKit/UIHinge.h>)
    if (@available(iOS 27.1, *)) {
        UIHingeInteraction* hinge = [[UIHingeInteraction alloc] initWithUpdateHandler:^(UIHingeInteraction* interaction, UIHingeInteractionUpdate* update) {
            typeof(self) strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            NSInteger status = update.hinge != nil ? (NSInteger)update.hinge.status : 0;
            if (status != strongSelf->_hingeStatus) {
                Log(LOG_I, @"Hinge status %ld -> %ld (angle %.2f rad)", (long)strongSelf->_hingeStatus, (long)status, update.hinge.angle);
                strongSelf->_hingeStatus = status;
                // A new posture clears the "full screen" override
                strongSelf->_foldFullScreenOverride = NO;
                [strongSelf.view setNeedsLayout];
            }
        }];
        [self.view addInteraction:hinge];
    }
#endif
#endif
}

// Works out the layout from the fold region UIKit reports for this view.
- (FoldLayout)currentFoldLayout {
#if !TARGET_OS_TV && __has_include(<UIKit/UIHinge.h>)
    if (@available(iOS 27.1, *)) {
        if (_foldFullScreenOverride || _hingeStatus != UIHingeStatusPartiallyOpen) {
            return FoldLayoutFull;
        }
        NSArray<UIViewReservedRegion*>* regions = [self.view reservedRegionsOfKind:[UIViewReservedRegionKind divisionRegionKind]];
        for (UIViewReservedRegion* region in regions) {
            if (!region.isActive) {
                continue;
            }
            CGRect fold = region.frame;
            // Ignore a fold that doesn't split the view into two usable halves
            if (CGRectGetWidth(fold) >= CGRectGetHeight(fold)) {
                if (CGRectGetMinY(fold) < 120 || CGRectGetMaxY(fold) > self.view.bounds.size.height - 120) {
                    continue;
                }
                _foldDivision = fold;
                return FoldLayoutLaptop;
            } else {
                if (CGRectGetMinX(fold) < 120 || CGRectGetMaxX(fold) > self.view.bounds.size.width - 120) {
                    continue;
                }
                _foldDivision = fold;
                return FoldLayoutBook;
            }
        }
    }
#endif
    return FoldLayoutFull;
}

#if !TARGET_OS_TV
// Fold fork: a slim control rail in the strip the system keeps for its status
// bubble (time, Wi-Fi) on the iPhone Duo inner screen, like Yosei. The stream
// gets the rest of the screen, at exactly that size.
- (UIButton*)railButtonWithSymbol:(NSString*)symbol title:(NSString*)title action:(SEL)action {
    UIButton* b = [UIButton buttonWithType:UIButtonTypeSystem];
    UIImage* image = symbol ? [UIImage systemImageNamed:symbol withConfiguration:[UIImageSymbolConfiguration configurationWithPointSize:20 weight:UIImageSymbolWeightMedium]] : nil;
    if (image) {
        [b setImage:image forState:UIControlStateNormal];
    } else {
        [b setTitle:title forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
    }
    b.tintColor = [UIColor whiteColor];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    [b addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    return b;
}

- (void)setupFoldRail {
    _foldRail = [[UIView alloc] init];
    _foldRail.backgroundColor = [UIColor blackColor];
    _foldRail.hidden = YES;

    _foldRailButtonList = @[
        [self railButtonWithSymbol:@"keyboard" title:@"⌨︎" action:@selector(railKeyboard)],
        [self railButtonWithSymbol:@"escape" title:@"Esc" action:@selector(railEscape)],
        [self railButtonWithSymbol:nil title:@"Win" action:@selector(railWindows)],
        [self railButtonWithSymbol:@"rectangle.split.1x2" title:@"▤" action:@selector(railTogglePanel)],
        [self railButtonWithSymbol:@"doc.on.clipboard" title:@"📋" action:@selector(railClipboard)],
        [self railButtonWithSymbol:@"xmark" title:@"✕" action:@selector(railExit)],
    ];
    // Laid out by hand (see layoutFoldRail:) rather than with a stack view
    _foldRailButtons = [[UIView alloc] init];
    _foldRailButtons.backgroundColor = [UIColor colorWithWhite:0.17 alpha:1];
    _foldRailButtons.layer.cornerRadius = 26;
    for (UIButton* b in _foldRailButtonList) {
        [_foldRailButtons addSubview:b];
    }
    [_foldRail addSubview:_foldRailButtons];
    [self.view addSubview:_foldRail];
}

- (void)railKeyboard {
    [_streamView toggleKeyboard];
}

- (void)railTap:(short)vk {
    dispatch_async([FoldKeyboardView keyQueue], ^{
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_DOWN, 0);
        usleep(30 * 1000);
        LiSendKeyboardEvent(0x8000 | vk, KEY_ACTION_UP, 0);
    });
}

- (void)railEscape {
    [self railTap:0x1B];
}

- (void)railWindows {
    [self railTap:0x5B];
}

// Shows the keyboard and trackpad below the stream even when the phone is flat
- (void)railTogglePanel {
    _foldPanelForced = !_foldPanelForced;
    _foldFullScreenOverride = NO;
    [self.view setNeedsLayout];
}

- (void)railClipboard {
    [self sendClipboardToHost:YES];
}

- (void)railExit {
    [self returnToMainFrame];
}

// The rail rectangle, or CGRectZero when the system keeps no strip at the side
- (CGRect)foldRailRect {
#if __has_include(<UIKit/UIHinge.h>)
    if (@available(iOS 27.1, *)) {
        CGRect bounds = self.view.bounds;
        // Outer screen (phone closed): the stream goes all the way to the edge
        BOOL outerScreen = _hingeStatus == UIHingeStatusClosed ||
            (_hingeStatus == UIHingeStatusUnknown && MIN(bounds.size.width, bounds.size.height) < 500);
        if (outerScreen) {
            return CGRectZero;
        }
        NSArray<UIViewReservedRegion*>* regions = [self.view reservedRegionsOfKind:[UIViewReservedRegionKind occlusionRegionKind]];
        for (UIViewReservedRegion* region in regions) {
            if (!region.isActive) {
                continue;
            }
            CGRect r = region.frame;
            // A status bubble in a top corner; ignore a camera hole in the middle
            if (CGRectGetMinY(r) > 40 || CGRectGetWidth(r) > bounds.size.width / 4) {
                continue;
            }
            CGFloat w = MAX(CGRectGetWidth(r) + 16, 76);
            if (CGRectGetMaxX(r) >= bounds.size.width - 40) {
                return CGRectMake(bounds.size.width - w, 0, w, bounds.size.height);
            }
            if (CGRectGetMinX(r) <= 40) {
                return CGRectMake(0, 0, w, bounds.size.height);
            }
        }
    }
#endif
    return CGRectZero;
}

static CGRect FoldRectOutsideRail(CGRect r, CGRect rail) {
    CGRect cut = CGRectIntersection(r, rail);
    if (CGRectIsNull(cut) || cut.size.width <= 0) {
        return r;
    }
    if (CGRectGetMinX(rail) > 0) {
        r.size.width = CGRectGetMinX(rail) - r.origin.x;
    } else {
        CGFloat right = CGRectGetMaxX(r);
        r.origin.x = CGRectGetMaxX(rail);
        r.size.width = right - r.origin.x;
    }
    return r;
}

- (void)layoutFoldRail:(CGRect)rail streamFrame:(CGRect*)streamFrame panelFrame:(CGRect*)panelFrame {
    _foldRail.hidden = CGRectIsEmpty(rail);
    if (_foldRail.hidden) {
        return;
    }
    // Take the rail's strip off the side of the stream and the panel
    *streamFrame = FoldRectOutsideRail(*streamFrame, rail);
    *panelFrame = FoldRectOutsideRail(*panelFrame, rail);
    _foldRail.frame = rail;
    CGFloat w = 56;
    CGFloat h = 54 * _foldRailButtonList.count + 16;
    // Below the status bubble, centered in what's left of the rail
    CGFloat top = 170;
    CGFloat y = MAX(top, (rail.size.height - h) / 2);
    _foldRailButtons.frame = CGRectMake((rail.size.width - w) / 2, MIN(y, rail.size.height - h - 20), w, h);
    for (NSUInteger i = 0; i < _foldRailButtonList.count; i++) {
        _foldRailButtonList[i].frame = CGRectMake(0, 8 + 54 * i, w, 54);
    }
    [self.view bringSubviewToFront:_foldRail];
}
#endif

- (void)applyFoldLayout {
    FoldLayout layout = [self currentFoldLayout];
    CGRect bounds = self.view.bounds;
    CGRect streamFrame = bounds;
    CGRect panelFrame = CGRectZero;
    
    switch (layout) {
        case FoldLayoutLaptop:
            streamFrame = CGRectMake(0, 0, bounds.size.width, CGRectGetMinY(_foldDivision));
            panelFrame = CGRectMake(0, CGRectGetMaxY(_foldDivision), bounds.size.width, bounds.size.height - CGRectGetMaxY(_foldDivision));
            break;
        case FoldLayoutBook:
            streamFrame = CGRectMake(0, 0, CGRectGetMinX(_foldDivision), bounds.size.height);
            panelFrame = CGRectMake(CGRectGetMaxX(_foldDivision), 0, bounds.size.width - CGRectGetMaxX(_foldDivision), bounds.size.height);
            break;
        case FoldLayoutFull:
            break;
    }
#if !TARGET_OS_TV
    if (layout == FoldLayoutFull && _foldPanelForced) {
        // Panel shown on a flat screen: stream on top, keyboard and trackpad below
        CGFloat panelH = MIN(bounds.size.height * 0.45, 460);
        streamFrame = CGRectMake(0, 0, bounds.size.width, bounds.size.height - panelH);
        panelFrame = CGRectMake(0, bounds.size.height - panelH, bounds.size.width, panelH);
    }
    [self layoutFoldRail:[self foldRailRect] streamFrame:&streamFrame panelFrame:&panelFrame];
#endif
    
    if (layout != _foldLayout) {
        Log(LOG_I, @"Fold layout %ld -> %ld", (long)_foldLayout, (long)layout);
        _foldLayout = layout;
    }
    
    UIView* container = [self streamContainer];
    if (!CGRectEqualToRect(container.frame, streamFrame)) {
        container.frame = streamFrame;
        if (_scrollView != nil) {
            _streamView.frame = _scrollView.bounds;
        }
    }
#if !TARGET_OS_TV
    _foldPanel.hidden = (layout == FoldLayoutFull && !_foldPanelForced);
    if (!_foldPanel.hidden) {
        _foldPanel.frame = panelFrame;
        [self.view bringSubviewToFront:_foldPanel];
    }
#endif
}

- (void)viewSizeChanged {
    Log(LOG_I, @"Stream view resized to %.0fx%.0f points", self.view.bounds.size.width, self.view.bounds.size.height);
    
    // Keep showing the current video, aspect-fit into the new bounds, until
    // the stream has been restarted at the new size.
    [_streamView streamGeometryChanged:self.streamConfig];
    [self fitVideoLayers];
    
    CGRect area = [self streamContainer].frame;
    _stageLabel.center = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area));
    _spinner.center = CGPointMake(CGRectGetMidX(area), CGRectGetMidY(area) - _stageLabel.frame.size.height - _spinner.frame.size.height);
    _tipLabel.center = CGPointMake(CGRectGetMidX(area), area.origin.y + area.size.height * 0.9);
    
    [self scheduleResolutionMatch];
}

- (void)fitVideoLayers {
    float aspect = (float)self.streamConfig.width / (float)self.streamConfig.height;
    CGRect bounds = _streamView.bounds;
    CGSize videoSize;
    if (bounds.size.width > bounds.size.height * aspect) {
        videoSize = CGSizeMake(bounds.size.height * aspect, bounds.size.height);
    } else {
        videoSize = CGSizeMake(bounds.size.width, bounds.size.width / aspect);
    }
    
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    for (CALayer* layer in _streamView.layer.sublayers) {
        if ([layer isKindOfClass:[AVSampleBufferDisplayLayer class]]) {
            layer.position = CGPointMake(CGRectGetMidX(bounds), CGRectGetMidY(bounds));
            layer.bounds = CGRectMake(0, 0, videoSize.width, videoSize.height);
        }
    }
    [CATransaction commit];
}

- (int)maxStreamDimension {
    return (self.streamConfig.supportedVideoFormats & VIDEO_FORMAT_MASK_H265) ? 8192 : 4096;
}

- (void)scheduleResolutionMatch {
#if !TARGET_OS_TV
    if (!self.streamConfig.foldVirtual || !_streamActive || _reconfiguring) {
        return;
    }
    
    CGSize target = FoldStreamSizeForView([self streamContainer], [self maxStreamDimension]);
    [_resizeTimer invalidate];
    _resizeTimer = nil;
    
    if ((int)target.width == self.streamConfig.width && (int)target.height == self.streamConfig.height) {
        return;
    }
    
    // Wait briefly for the size to settle (rotation or a fold in progress) before reconnecting
    _resizeTimer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                                    target:self
                                                  selector:@selector(resizeTimerFired:)
                                                  userInfo:nil
                                                   repeats:NO];
#endif
}

- (void)resizeTimerFired:(NSTimer*)timer {
    _resizeTimer = nil;
    if (!_streamActive || _reconfiguring) {
        return;
    }
    
    CGSize target = FoldStreamSizeForView([self streamContainer], [self maxStreamDimension]);
    int width = (int)target.width;
    int height = (int)target.height;
    if (width == self.streamConfig.width && height == self.streamConfig.height) {
        return;
    }
    
    Log(LOG_I, @"Match display: restarting stream at %dx%d (was %dx%d)", width, height, self.streamConfig.width, self.streamConfig.height);
    
    _streamActive = NO;
    _reconfiguring = YES;
    
    [_statsUpdateTimer invalidate];
    _statsUpdateTimer = nil;
    
    // No message: the last frame stays up until the resized stream draws
    
    if (_stopInFlight) {
        self.streamConfig.width = width;
        self.streamConfig.height = height;
        _startWhenStopped = YES;
        return;
    }
    [self stopStreamThen:^{
        if (!self->_reconfiguring || self->_backgroundPaused) {
            // The user left the stream while we were stopping
            return;
        }
        self.streamConfig.width = width;
        self.streamConfig.height = height;
        [self startReplacementStream];
    }];
}

- (void)didReceiveMemoryWarning
{
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)gamepadPresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)mousePresenceChanged {
#if !TARGET_OS_TV
    if (@available(iOS 14.0, *)) {
        [self setNeedsUpdateOfPrefersPointerLocked];
    }
#endif
}

- (void) streamExitRequested {
    Log(LOG_I, @"Gamepad combo requested stream exit");
    
    [self returnToMainFrame];
}

- (void)userInteractionBegan {
    // Disable hiding home bar when user is interacting.
    // iOS will force it to be shown anyway, but it will
    // also discard our edges deferring system gestures unless
    // we willingly give up home bar hiding preference.
    _userIsInteracting = YES;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

- (void)userInteractionEnded {
    // Enable home bar hiding again if conditions allow
    _userIsInteracting = NO;
#if !TARGET_OS_TV
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
    }
#endif
}

#if !TARGET_OS_TV
// Require a confirmation when streaming to activate a system gesture
- (UIRectEdge)preferredScreenEdgesDeferringSystemGestures {
    return UIRectEdgeAll;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
    if ([_controllerSupport getConnectedGamepadCount] > 0 &&
        [_streamView getCurrentOscState] == OnScreenControlsLevelOff &&
        _userIsInteracting == NO) {
        // Autohide the home bar when a gamepad is connected
        // and the on-screen controls are disabled. We can't
        // do this all the time because any touch on the display
        // will cause the home indicator to reappear, and our
        // preferredScreenEdgesDeferringSystemGestures will also
        // be suppressed (leading to possible errant exits of the
        // stream).
        return YES;
    }
    
    return NO;
}

- (BOOL)shouldAutorotate {
    return YES;
}

- (BOOL)prefersPointerLocked {
    // Pointer lock breaks the UIKit mouse APIs, which is a problem because
    // GCMouse is horribly broken on iOS 14.0 for certain mice. Only lock
    // the cursor if there is a GCMouse present.
    return [GCMouse mice].count > 0;
}
#endif

@end
