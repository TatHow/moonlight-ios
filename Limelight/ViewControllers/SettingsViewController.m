//
//  SettingsViewController.m
//  Moonlight
//
//  Created by Diego Waxemberg on 10/27/14.
//  Copyright (c) 2014 Moonlight Stream. All rights reserved.
//

#import "SettingsViewController.h"
#import "TemporarySettings.h"
#import "DataManager.h"
#import "FoldDisplayMatch.h"
#import "SWRevealViewController.h"
#import "StreamConfiguration.h"

#import <VideoToolbox/VideoToolbox.h>
#import <AVFoundation/AVFoundation.h>

@implementation SettingsViewController {
    NSInteger _bitrate;
    NSInteger _lastSelectedResolutionIndex;
    UISegmentedControl* _desktopScaleSelector;   // Virtual display scaling
    UISegmentedControl* _virtualTouchSelector;
    UIButton* _doneButton;
    UIButton* _disconnectButton;
    CGFloat _laidOutWidth;
    CGFloat _laidOutLeft;
}


@dynamic overrideUserInterfaceStyle;

static NSString* bitrateFormat = @"Bitrate: %.1f Mbps";
static const int bitrateTable[] = {
    500,
    1000,
    1500,
    2000,
    2500,
    3000,
    4000,
    5000,
    6000,
    7000,
    8000,
    9000,
    10000,
    12000,
    15000,
    18000,
    20000,
    30000,
    40000,
    50000,
    60000,
    70000,
    80000,
    100000,
    120000,
    150000,
};

const int RESOLUTION_TABLE_SIZE = 7;
const int RESOLUTION_TABLE_CUSTOM_INDEX = RESOLUTION_TABLE_SIZE - 1;
CGSize resolutionTable[RESOLUTION_TABLE_SIZE];

-(int)getSliderValueForBitrate:(NSInteger)bitrate {
    int i;
    
    for (i = 0; i < (sizeof(bitrateTable) / sizeof(*bitrateTable)); i++) {
        if (bitrate <= bitrateTable[i]) {
            return i;
        }
    }
    
    // Return the last entry in the table
    return i - 1;
}

// This view is rooted at a ScrollView. To make it scrollable,
// we'll update content size here.
-(void)viewDidLayoutSubviews {
    [self updateDisconnectButton];
    [self foldLayoutToWidth];
    CGFloat highestViewY = 0;
    
    // Enumerate the scroll view's subviews looking for the
    // highest view Y value to set our scroll view's content
    // size.
    for (UIView* view in self.scrollView.subviews) {
        // UIScrollViews have 2 default child views
        // which represent the horizontal and vertical scrolling
        // indicators. Ignore any views we don't recognize.
        if (![view isKindOfClass:[UILabel class]] &&
            ![view isKindOfClass:[UISegmentedControl class]] &&
            ![view isKindOfClass:[UISlider class]]) {
            continue;
        }
        
        CGFloat currentViewY = view.frame.origin.y + view.frame.size.height;
        if (currentViewY > highestViewY) {
            highestViewY = currentViewY;
        }
    }
    
    // Add a bit of padding so the view doesn't end right at the button of the display
    self.scrollView.contentSize = CGSizeMake(self.scrollView.bounds.size.width,
                                             highestViewY + 20);
}

// Fold build: the controls are laid out to the pane's width in
// viewDidLayoutSubviews instead of being nudged right for the safe area
// (which added up every time the safe area changed).

BOOL isCustomResolution(CGSize res) {
    if (res.width == 0 && res.height == 0) {
        return NO;
    }
    
    for (int i = 0; i < RESOLUTION_TABLE_CUSTOM_INDEX; i++) {
        if (res.width == resolutionTable[i].width && res.height == resolutionTable[i].height) {
            return NO;
        }
    }
    
    return YES;
}

- (void)viewDidLoad {
    [super viewDidLoad];

    // Always run settings in dark mode because we want the light fonts
    if (@available(iOS 13.0, tvOS 13.0, *)) {
        self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
    }
    
    DataManager* dataMan = [[DataManager alloc] init];
    TemporarySettings* currentSettings = [dataMan getSettings];
    
    // Ensure we pick a bitrate that falls exactly onto a slider notch
    _bitrate = bitrateTable[[self getSliderValueForBitrate:[currentSettings.bitrate intValue]]];

    // Get the size of the screen with and without safe area insets
    UIWindow *window = UIApplication.sharedApplication.windows.firstObject;
    CGFloat screenScale = window.screen.scale;
    CGFloat safeAreaWidth = (window.frame.size.width - window.safeAreaInsets.left - window.safeAreaInsets.right) * screenScale;
    CGFloat fullScreenWidth = window.frame.size.width * screenScale;
    CGFloat fullScreenHeight = window.frame.size.height * screenScale;
    
    self.resolutionDisplayView.layer.cornerRadius = 10;
    self.resolutionDisplayView.clipsToBounds = YES;
    UITapGestureRecognizer *resolutionDisplayViewTap = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(resolutionDisplayViewTapped:)];
    [self.resolutionDisplayView addGestureRecognizer:resolutionDisplayViewTap];
    
    resolutionTable[0] = CGSizeMake(640, 360);
    resolutionTable[1] = CGSizeMake(1280, 720);
    resolutionTable[2] = CGSizeMake(1920, 1080);
    resolutionTable[3] = CGSizeMake(3840, 2160);
    resolutionTable[4] = CGSizeMake(safeAreaWidth, fullScreenHeight);
    resolutionTable[5] = CGSizeMake(fullScreenWidth, fullScreenHeight);
    resolutionTable[6] = CGSizeMake([currentSettings.width integerValue], [currentSettings.height integerValue]); // custom initial value
    
    // Don't populate the custom entry unless we have a custom resolution
    if (!isCustomResolution(resolutionTable[6])) {
        resolutionTable[6] = CGSizeMake(0, 0);
    }
    
    NSInteger framerate;
    switch ([currentSettings.framerate integerValue]) {
        case 30:
            framerate = 0;
            break;
        default:
        case 60:
            framerate = 1;
            break;
        case 120:
            framerate = 2;
            break;
    }

    NSInteger resolution = 1;
    for (int i = 0; i < RESOLUTION_TABLE_SIZE; i++) {
        if ((int) resolutionTable[i].height == [currentSettings.height intValue]
            && (int) resolutionTable[i].width == [currentSettings.width intValue]) {
            resolution = i;
            break;
        }
    }

    // Only show the 120 FPS option if we have a > 60-ish Hz display
    bool enable120Fps = false;
    if (@available(iOS 10.3, tvOS 10.3, *)) {
        if ([UIScreen mainScreen].maximumFramesPerSecond > 62) {
            enable120Fps = true;
        }
    }
    if (!enable120Fps) {
        [self.framerateSelector removeSegmentAtIndex:2 animated:NO];
    }

    // Disable codec selector segments for unsupported codecs
#if defined(__IPHONE_16_0) || defined(__TVOS_16_0)
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_AV1))
#endif
    {
        [self.codecSelector removeSegmentAtIndex:2 animated:NO];
    }
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        [self.codecSelector removeSegmentAtIndex:1 animated:NO];

        // Only enable the 4K option for "recent" devices. We'll judge that by whether
        // they support HEVC decoding (A9 or later).
        [self.resolutionSelector setEnabled:NO forSegmentAtIndex:3];
    }
    switch (currentSettings.preferredCodec) {
        case CODEC_PREF_AUTO:
            [self.codecSelector setSelectedSegmentIndex:self.codecSelector.numberOfSegments - 1];
            break;
            
        case CODEC_PREF_AV1:
            [self.codecSelector setSelectedSegmentIndex:2];
            break;
            
        case CODEC_PREF_HEVC:
            [self.codecSelector setSelectedSegmentIndex:1];
            break;
            
        case CODEC_PREF_H264:
            [self.codecSelector setSelectedSegmentIndex:0];
            break;
    }
    
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) || !(AVPlayer.availableHDRModes & AVPlayerHDRModeHDR10)) {
        [self.hdrSelector removeAllSegments];
        [self.hdrSelector insertSegmentWithTitle:@"Unsupported on this device" atIndex:0 animated:NO];
        [self.hdrSelector setEnabled:NO];
    }
    else {
        [self.hdrSelector setSelectedSegmentIndex:currentSettings.enableHdr ? 1 : 0];
    }
    
    // Fold build: the resolution picker becomes the Desktop render scale; the
    // Virtual display always matches this screen.
    [self.resolutionSelector removeAllSegments];
    for (int i = 0; i < kFoldRenderScaleCount; i++) {
        [self.resolutionSelector insertSegmentWithTitle:kFoldRenderScaleTitles[i] atIndex:i animated:NO];
    }
    self.resolutionSelector.apportionsSegmentWidthsByContent = YES;
    if (!VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
        [self.resolutionSelector setEnabled:NO forSegmentAtIndex:0];
    }
    resolution = FoldRenderScaleIndex();
    [self renameLabelWithPrefix:@"Resolution" to:@"Desktop Render Scale"];
    [self.resolutionDisplayView removeGestureRecognizer:resolutionDisplayViewTap];
    [self addDesktopScaleSelector];
    [self addVirtualTouchSelector];
    [self addTopBar];
    
    [self.touchModeSelector setSelectedSegmentIndex:currentSettings.absoluteTouchMode ? 1 : 0];
    [self renameLabelWithPrefix:@"Touch Mode" to:@"Touch Mode (Desktop)"];
    [self.touchModeSelector addTarget:self action:@selector(touchModeChanged) forControlEvents:UIControlEventValueChanged];
    [self.statsOverlaySelector setSelectedSegmentIndex:currentSettings.statsOverlay ? 1 : 0];
    [self.btMouseSelector setSelectedSegmentIndex:currentSettings.btMouseSupport ? 1 : 0];
    [self.optimizeSettingsSelector setSelectedSegmentIndex:currentSettings.optimizeGames ? 1 : 0];
    [self.framePacingSelector setSelectedSegmentIndex:currentSettings.useFramePacing ? 1 : 0];
    [self.multiControllerSelector setSelectedSegmentIndex:currentSettings.multiController ? 1 : 0];
    [self.swapABXYButtonsSelector setSelectedSegmentIndex:currentSettings.swapABXYButtons ? 1 : 0];
    [self.audioOnPCSelector setSelectedSegmentIndex:currentSettings.playAudioOnPC ? 1 : 0];
    NSInteger onscreenControls = [currentSettings.onscreenControls integerValue];
    _lastSelectedResolutionIndex = resolution;
    [self.resolutionSelector setSelectedSegmentIndex:resolution];
    [self.resolutionSelector addTarget:self action:@selector(newResolutionChosen) forControlEvents:UIControlEventValueChanged];
    [self.framerateSelector setSelectedSegmentIndex:framerate];
    [self.framerateSelector addTarget:self action:@selector(updateBitrate) forControlEvents:UIControlEventValueChanged];
    [self.onscreenControlSelector setSelectedSegmentIndex:onscreenControls];
    [self.onscreenControlSelector setEnabled:YES];
    [self.bitrateSlider setMinimumValue:0];
    [self.bitrateSlider setMaximumValue:(sizeof(bitrateTable) / sizeof(*bitrateTable)) - 1];
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    [self.bitrateSlider addTarget:self action:@selector(bitrateSliderMoved) forControlEvents:UIControlEventValueChanged];
    [self updateBitrateText];
    [self updateResolutionDisplayViewText];
}

- (UILabel*) labelWithPrefix:(NSString*)prefix {
    for (UIView* view in self.scrollView.subviews) {
        if ([view isKindOfClass:[UILabel class]] && [((UILabel*)view).text hasPrefix:prefix]) {
            return (UILabel*)view;
        }
    }
    return nil;
}

- (void) renameLabelWithPrefix:(NSString*)prefix to:(NSString*)title {
    UILabel* label = [self labelWithPrefix:prefix];
    label.text = title;
    CGRect frame = label.frame;
    frame.size.width = MAX(frame.size.width, [label sizeThatFits:CGSizeMake(CGFLOAT_MAX, frame.size.height)].width);
    label.frame = frame;
}

- (UISegmentedControl*) newSelectorWithItems:(NSArray<NSString*>*)items {
    UISegmentedControl* selector = [[UISegmentedControl alloc] initWithItems:items];
    selector.tintColor = self.touchModeSelector.tintColor;
    if (@available(iOS 13.0, *)) {
        selector.selectedSegmentTintColor = self.touchModeSelector.selectedSegmentTintColor;
    }
    return selector;
}

// Adds a titled row under `anchor` and pushes the rest of the (frame-based)
// settings layout down to make room for it.
- (void) insertRowBelow:(UIView*)anchor title:(NSString*)title control:(UIView*)control {
    CGFloat top = CGRectGetMaxY(anchor.frame) + 8;
    
    UILabel* label = [[UILabel alloc] init];
    label.text = title;
    label.font = [UIFont boldSystemFontOfSize:17];
    label.textColor = [UIColor colorWithRed:0.95 green:0.975 blue:1.0 alpha:1.0];
    [label sizeToFit];
    label.frame = CGRectMake(anchor.frame.origin.x + 6, top, label.frame.size.width, 21);
    control.frame = CGRectMake(anchor.frame.origin.x, top + 27, anchor.frame.size.width > 100 ? MIN(anchor.frame.size.width, 360) : 300, 32);
    
    CGFloat shift = 27 + 32 + 12;
    CGFloat anchorBottom = CGRectGetMaxY(anchor.frame);
    for (UIView* view in self.scrollView.subviews) {
        if (view != anchor && view.frame.origin.y >= anchorBottom) {
            view.frame = CGRectOffset(view.frame, 0, shift);
        }
    }
    
    [self.scrollView addSubview:label];
    [self.scrollView addSubview:control];
}

- (void) addDesktopScaleSelector {
    NSMutableArray* items = [[NSMutableArray alloc] init];
    for (int i = 0; i < kFoldVirtualDpiCount; i++) {
        [items addObject:[NSString stringWithFormat:@"%d%%", kFoldVirtualDpis[i]]];
    }
    _desktopScaleSelector = [self newSelectorWithItems:items];
    _desktopScaleSelector.selectedSegmentIndex = FoldVirtualDpiIndex();
    [self insertRowBelow:self.resolutionDisplayView title:@"Virtual Display Scaling" control:_desktopScaleSelector];
}

- (void) addVirtualTouchSelector {
    _virtualTouchSelector = [self newSelectorWithItems:@[@"Touchpad", @"Touchscreen"]];
    _virtualTouchSelector.selectedSegmentIndex = FoldVirtualTouchscreen() ? 1 : 0;
    [self insertRowBelow:self.touchModeSelector title:@"Touch Mode (Virtual)" control:_virtualTouchSelector];
}

// Lay every row out across the visible width of the pane with a small margin
- (void) foldLayoutToWidth {
    CGFloat paneWidth = self.view.bounds.size.width;
    SWRevealViewController* reveal = self.revealViewController;
    if (reveal != nil && reveal.rearViewRevealWidth > 0) {
        paneWidth = MIN(paneWidth, reveal.rearViewRevealWidth);
    }
    CGFloat left = MAX(self.view.safeAreaInsets.left, 0) + 16;
    CGFloat width = MAX(paneWidth - left - 16, 200);
    if (fabs(width - _laidOutWidth) < 1 && fabs(left - _laidOutLeft) < 1) {
        return;
    }
    _laidOutWidth = width;
    _laidOutLeft = left;
    
    for (UIView* view in self.scrollView.subviews) {
        CGRect frame = view.frame;
        if (view == _doneButton) {
            frame.origin.x = left;
        }
        else if (view == _disconnectButton) {
            frame.origin.x = left + _doneButton.frame.size.width + 12;
        }
        else if ([view isKindOfClass:[UILabel class]]) {
            frame.origin.x = left + 4;
            frame.size.width = width - 4;
        }
        else if ([view isKindOfClass:[UISegmentedControl class]] || [view isKindOfClass:[UISlider class]] ||
                 view == self.resolutionDisplayView) {
            frame.origin.x = left;
            frame.size.width = width;
        }
        else {
            continue;
        }
        view.frame = frame;
    }
    [self updateResolutionDisplayViewText];
}

// The mode of the stream running behind the pane, if any
- (BOOL) streamingVirtual:(BOOL*)isVirtual {
    UIViewController* front = self.revealViewController.frontViewController;
    if ([front isKindOfClass:[UINavigationController class]]) {
        front = ((UINavigationController*)front).topViewController;
    }
    if (![front isKindOfClass:NSClassFromString(@"StreamFrameViewController")]) {
        return NO;
    }
    StreamConfiguration* config = [front valueForKey:@"streamConfig"];
    *isVirtual = config.foldVirtual;
    return YES;
}

// Done (close settings) and Disconnect (end the stream) above everything else
- (void) addTopBar {
    CGFloat minY = CGFLOAT_MAX;
    CGFloat minX = 16;
    for (UIView* view in self.scrollView.subviews) {
        if ([view isKindOfClass:[UILabel class]] || [view isKindOfClass:[UISegmentedControl class]]) {
            if (view.frame.origin.y < minY) {
                minY = view.frame.origin.y;
                minX = view.frame.origin.x;
            }
        }
    }
    if (minY == CGFLOAT_MAX) {
        minY = 20;
    }
    CGFloat shift = 56;
    for (UIView* view in self.scrollView.subviews) {
        if (view.frame.origin.y >= minY) {
            view.frame = CGRectOffset(view.frame, 0, shift);
        }
    }
    
    UIColor* accent = [UIColor colorWithRed:0.62 green:0.58 blue:0.96 alpha:1.0];
    if (@available(iOS 13.0, *)) {
        if (self.touchModeSelector.selectedSegmentTintColor != nil) {
            accent = self.touchModeSelector.selectedSegmentTintColor;
        }
    }
    _doneButton = [self pillButton:@"Done" color:accent];
    _doneButton.frame = CGRectMake(MAX(minX - 6, 10), minY, 104, 40);
    [_doneButton addTarget:self action:@selector(doneTapped) forControlEvents:UIControlEventTouchUpInside];
    
    _disconnectButton = [self pillButton:@"Disconnect" color:[UIColor colorWithRed:0.86 green:0.24 blue:0.24 alpha:1.0]];
    _disconnectButton.frame = CGRectMake(CGRectGetMaxX(_doneButton.frame) + 12, minY, 132, 40);
    [_disconnectButton addTarget:self action:@selector(disconnectTapped) forControlEvents:UIControlEventTouchUpInside];
    
    [self.scrollView addSubview:_doneButton];
    [self.scrollView addSubview:_disconnectButton];
    [self updateDisconnectButton];
}

- (UIButton*) pillButton:(NSString*)title color:(UIColor*)color {
    UIButton* button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal];
    [button setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    button.titleLabel.font = [UIFont boldSystemFontOfSize:17];
    button.backgroundColor = color;
    button.layer.cornerRadius = 20;
    button.clipsToBounds = YES;
    return button;
}

- (BOOL) isStreaming {
    UIViewController* front = self.revealViewController.frontViewController;
    if ([front isKindOfClass:[UINavigationController class]]) {
        front = ((UINavigationController*)front).topViewController;
    }
    return [front isKindOfClass:NSClassFromString(@"StreamFrameViewController")];
}

- (void) updateDisconnectButton {
    BOOL isVirtual = NO;
    BOOL streaming = [self streamingVirtual:&isVirtual];
    _disconnectButton.hidden = !streaming;
    // The render scale only applies to Desktop; Virtual always matches this screen
    BOOL renderScaleApplies = !(streaming && isVirtual);
    if (self.resolutionSelector.enabled != renderScaleApplies) {
        self.resolutionSelector.enabled = renderScaleApplies;
        self.resolutionSelector.alpha = renderScaleApplies ? 1.0 : 0.4;
        [self updateResolutionDisplayViewText];
    }
}

- (void) viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self updateDisconnectButton];
    [self updateResolutionDisplayViewText];
}

- (void) doneTapped {
    [self.revealViewController revealToggleAnimated:YES];
}

- (void) disconnectTapped {
    [[NSNotificationCenter defaultCenter] postNotificationName:kFoldDisconnectNotification object:nil];
}

- (void) touchModeChanged {
    // Disable on-screen controls in absolute touch mode
    // Fold build: the on-screen gamepad works with either touch mode
}

- (void) updateBitrate {
    NSInteger fps = [self getChosenFrameRate];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger defaultBitrate;
    
    // This logic is shamelessly stolen from Moonlight Qt:
    // https://github.com/moonlight-stream/moonlight-qt/blob/master/app/settings/streamingpreferences.cpp
    
    // Don't scale bitrate linearly beyond 60 FPS. It's definitely not a linear
    // bitrate increase for frame rate once we get to values that high.
    float frameRateFactor = (fps <= 60 ? fps : (sqrtf(fps / 60.f) * 60.f)) / 30.f;

    // TODO: Collect some empirical data to see if these defaults make sense.
    // We're just using the values that the Shield used, as we have for years.
    struct {
        NSInteger pixels;
        int factor;
    } resTable[] = {
        { 640 * 360, 1 },
        { 854 * 480, 2 },
        { 1280 * 720, 5 },
        { 1920 * 1080, 10 },
        { 2560 * 1440, 20 },
        { 3840 * 2160, 40 },
        { -1, -1 }
    };

    // Calculate the resolution factor by linear interpolation of the resolution table
    float resolutionFactor;
    NSInteger pixels = width * height;
    for (int i = 0;; i++) {
        if (pixels == resTable[i].pixels) {
            // We can bail immediately for exact matches
            resolutionFactor = resTable[i].factor;
            break;
        }
        else if (pixels < resTable[i].pixels) {
            if (i == 0) {
                // Never go below the lowest resolution entry
                resolutionFactor = resTable[i].factor;
            }
            else {
                // Interpolate between the entry greater than the chosen resolution (i) and the entry less than the chosen resolution (i-1)
                resolutionFactor = ((float)(pixels - resTable[i-1].pixels) / (resTable[i].pixels - resTable[i-1].pixels)) * (resTable[i].factor - resTable[i-1].factor) + resTable[i-1].factor;
            }
            break;
        }
        else if (resTable[i].pixels == -1) {
            // Never go above the highest resolution entry
            resolutionFactor = resTable[i-1].factor;
            break;
        }
    }

    defaultBitrate = round(resolutionFactor * frameRateFactor) * 1000;
    _bitrate = MIN(defaultBitrate, 100000);
    [self.bitrateSlider setValue:[self getSliderValueForBitrate:_bitrate] animated:YES];
    
    [self updateBitrateText];
}

- (void) newResolutionChosen {
    [self updateBitrate];
    [self updateResolutionDisplayViewText];
    _lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
}

- (void) promptCustomResolutionDialog {
    UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Enter Custom Resolution" message:nil preferredStyle:UIAlertControllerStyleAlert];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Width";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].width];
        }
    }];

    [alertController addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"Video Height";
        textField.clearButtonMode = UITextFieldViewModeAlways;
        textField.borderStyle = UITextBorderStyleRoundedRect;
        textField.keyboardType = UIKeyboardTypeNumberPad;
        
        if (resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height == 0) {
            textField.text = @"";
        }
        else {
            textField.text = [NSString stringWithFormat:@"%d", (int) resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX].height];
        }
    }];

    [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:^(UIAlertAction *action) {
        NSArray * textfields = alertController.textFields;
        UITextField *widthField = textfields[0];
        UITextField *heightField = textfields[1];
        
        long width = [widthField.text integerValue];
        long height = [heightField.text integerValue];
        if (width <= 0 || height <= 0) {
            // Restore the previous selection
            [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
            return;
        }
        
        // H.264 maximum
        int maxResolutionDimension = 4096;
        if (@available(iOS 11.0, tvOS 11.0, *)) {
            if (VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC)) {
                // HEVC maximum
                maxResolutionDimension = 8192;
            }
        }
        
        // Cap to maximum valid dimensions
        width = MIN(width, maxResolutionDimension);
        height = MIN(height, maxResolutionDimension);
        
        // Cap to minimum valid dimensions
        width = MAX(width, 256);
        height = MAX(height, 256);

        resolutionTable[RESOLUTION_TABLE_CUSTOM_INDEX] = CGSizeMake(width, height);
        [self updateBitrate];
        [self updateResolutionDisplayViewText];
        self->_lastSelectedResolutionIndex = [self.resolutionSelector selectedSegmentIndex];
        
        UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"Custom Resolution Selected" message: @"Custom resolutions are not officially supported by GeForce Experience, so it will not set your host display resolution. You will need to set it manually while in game.\n\nResolutions that are not supported by your client or host PC may cause streaming errors." preferredStyle:UIAlertControllerStyleAlert];
        [alertController addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [self presentViewController:alertController animated:YES completion:nil];
    }]];

    [alertController addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:^(UIAlertAction *action) {
        // Restore the previous selection
        [self.resolutionSelector setSelectedSegmentIndex:self->_lastSelectedResolutionIndex];
    }]];

    [self presentViewController:alertController animated:YES completion:nil];
}

- (void)resolutionDisplayViewTapped:(UITapGestureRecognizer *)sender {
    NSURL *url = [NSURL URLWithString:@"https://moonlight-stream.org/custom-resolution"];
    if ([[UIApplication sharedApplication] canOpenURL:url]) {
        [[UIApplication sharedApplication] openURL:url options:@{} completionHandler:nil];
    }
}

- (void) updateResolutionDisplayViewText {
    for (UIView *subview in self.resolutionDisplayView.subviews) {
        [subview removeFromSuperview];
    }
    BOOL isVirtual = NO;
    BOOL streaming = [self streamingVirtual:&isVirtual];
    CGSize matched = [self matchedStreamSize];
    NSString* text;
    if (streaming && isVirtual) {
        text = [NSString stringWithFormat:@"Virtual matches this screen: %d x %d", (int)matched.width, (int)matched.height];
    }
    else if (streaming) {
        text = [NSString stringWithFormat:@"Desktop streams at %d x %d", (int)[self getChosenStreamWidth], (int)[self getChosenStreamHeight]];
    }
    else {
        text = [NSString stringWithFormat:@"Desktop %d x %d  ·  Virtual %d x %d", (int)[self getChosenStreamWidth], (int)[self getChosenStreamHeight], (int)matched.width, (int)matched.height];
    }
    
    CGFloat padding = 10;
    UILabel *label = [[UILabel alloc] initWithFrame:CGRectInset(self.resolutionDisplayView.bounds, padding, 0)];
    label.text = text;
    label.font = [UIFont systemFontOfSize:[UIFont smallSystemFontSize]];
    label.adjustsFontSizeToFitWidth = YES;
    label.minimumScaleFactor = 0.7;
    label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.resolutionDisplayView addSubview:label];
}

- (void) bitrateSliderMoved {
    assert(self.bitrateSlider.value < (sizeof(bitrateTable) / sizeof(*bitrateTable)));
    _bitrate = bitrateTable[(int)self.bitrateSlider.value];
    [self updateBitrateText];
}

- (void) updateBitrateText {
    // Display bitrate in Mbps
    [self.bitrateLabel setText:[NSString stringWithFormat:bitrateFormat, _bitrate / 1000.]];
}

- (NSInteger) getChosenFrameRate {
    switch ([self.framerateSelector selectedSegmentIndex]) {
        case 0:
            return 30;
        case 1:
            return 60;
        case 2:
            return 120;
        default:
            abort();
    }
}

- (uint32_t) getChosenCodecPreference {
    // Auto is always the last segment
    if (self.codecSelector.selectedSegmentIndex == self.codecSelector.numberOfSegments - 1) {
        return CODEC_PREF_AUTO;
    }
    else {
        switch (self.codecSelector.selectedSegmentIndex) {
            case 0:
                return CODEC_PREF_H264;
                
            case 1:
                return CODEC_PREF_HEVC;
                
            case 2:
                return CODEC_PREF_AV1;
                
            default:
                abort();
        }
    }
}

- (CGSize) matchedStreamSize {
    UIView* hostView = self.view.window != nil ? (UIView*)self.view.window : self.view;
    int maxDimension = VTIsHardwareDecodeSupported(kCMVideoCodecType_HEVC) ? 8192 : 4096;
    return FoldStreamSizeForView(hostView, maxDimension);
}

- (NSInteger) chosenRenderScaleIndex {
    NSInteger index = [self.resolutionSelector selectedSegmentIndex];
    return (index < 0 || index >= kFoldRenderScaleCount) ? kFoldRenderScaleDefault : index;
}

- (NSInteger) getChosenStreamHeight {
    return (NSInteger)kFoldRenderScaleSizes[[self chosenRenderScaleIndex]].height;
}

- (NSInteger) getChosenStreamWidth {
    return (NSInteger)kFoldRenderScaleSizes[[self chosenRenderScaleIndex]].width;
}

- (void) saveSettings {
    DataManager* dataMan = [[DataManager alloc] init];
    NSInteger framerate = [self getChosenFrameRate];
    NSInteger height = [self getChosenStreamHeight];
    NSInteger width = [self getChosenStreamWidth];
    NSInteger onscreenControls = [self.onscreenControlSelector selectedSegmentIndex];
    BOOL optimizeGames = [self.optimizeSettingsSelector selectedSegmentIndex] == 1;
    BOOL multiController = [self.multiControllerSelector selectedSegmentIndex] == 1;
    BOOL swapABXYButtons = [self.swapABXYButtonsSelector selectedSegmentIndex] == 1;
    BOOL audioOnPC = [self.audioOnPCSelector selectedSegmentIndex] == 1;
    uint32_t preferredCodec = [self getChosenCodecPreference];
    BOOL btMouseSupport = [self.btMouseSelector selectedSegmentIndex] == 1;
    BOOL useFramePacing = [self.framePacingSelector selectedSegmentIndex] == 1;
    BOOL absoluteTouchMode = [self.touchModeSelector selectedSegmentIndex] == 1;
    BOOL statsOverlay = [self.statsOverlaySelector selectedSegmentIndex] == 1;
    BOOL enableHdr = [self.hdrSelector selectedSegmentIndex] == 1;
    FoldSetRenderScaleIndex((int)[self chosenRenderScaleIndex]);
    if (_desktopScaleSelector != nil && _desktopScaleSelector.selectedSegmentIndex >= 0) {
        FoldSetVirtualDpi(kFoldVirtualDpis[_desktopScaleSelector.selectedSegmentIndex]);
    }
    if (_virtualTouchSelector != nil) {
        FoldSetVirtualTouchscreen(_virtualTouchSelector.selectedSegmentIndex == 1);
    }
    [dataMan saveSettingsWithBitrate:_bitrate
                           framerate:framerate
                              height:height
                               width:width
                         audioConfig:2 // Stereo
                    onscreenControls:onscreenControls
                       optimizeGames:optimizeGames
                     multiController:multiController
                     swapABXYButtons:swapABXYButtons
                           audioOnPC:audioOnPC
                      preferredCodec:preferredCodec
                      useFramePacing:useFramePacing
                           enableHdr:enableHdr
                      btMouseSupport:btMouseSupport
                   absoluteTouchMode:absoluteTouchMode
                        statsOverlay:statsOverlay];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}


#pragma mark - Navigation

- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
}


@end
