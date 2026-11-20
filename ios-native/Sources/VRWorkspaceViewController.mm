// Dedicated 120 FPS VR Box Parsec Cinema app controlled by Xbox / MFi controller (GameController.framework).
// Features tunable VR Box inward viewport spacing for crisp eye fusion, zero-disparity stereo axis,
// Cinema Black 120 FPS mode or optional ARKit room passthrough, and full Mouse + native Xbox 360 gamepad pass-through.

#import "VRWorkspaceViewController.h"
#import "VRBridge.h"
#import <ARKit/ARKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <SceneKit/SceneKit.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace
{
    constexpr float kBaseScreenWidth = 1.72f;
    constexpr float kDefaultScreenScale = 1.05f;
    constexpr float kDefaultScreenDist = 1.35f;
    constexpr float kDefaultLensSpacing = 0.40f; // 40% of landscape width per eye (~56 mm center-to-center on iPhone 14 Pro)
    constexpr float kDefaultEyeHeight = 0.86f;
    constexpr float kDefaultFov = 78.0f;
    constexpr const char *kKeychainSessionKey = "cardboardxr_native_parsec_session_v1";

    NSString *const kPrefLensSpacing = @"vrbox_lens_spacing_v1";
    NSString *const kPrefEyeHeight = @"vrbox_eye_height_v1";
    NSString *const kPrefScreenScale = @"vrbox_screen_scale_v1";
    NSString *const kPrefScreenDist = @"vrbox_screen_dist_v1";

    // ParsecSDK ParsecGamepadState bitmask values (from parsec.h)
    constexpr uint16_t kParsecBtnDpadUp = 0x0001;
    constexpr uint16_t kParsecBtnDpadDown = 0x0002;
    constexpr uint16_t kParsecBtnDpadLeft = 0x0004;
    constexpr uint16_t kParsecBtnDpadRight = 0x0008;
    constexpr uint16_t kParsecBtnStart = 0x0010;
    constexpr uint16_t kParsecBtnBack = 0x0020;
    constexpr uint16_t kParsecBtnLThumb = 0x0040;
    constexpr uint16_t kParsecBtnRThumb = 0x0080;
    constexpr uint16_t kParsecBtnLShoulder = 0x0100;
    constexpr uint16_t kParsecBtnRShoulder = 0x0200;
    constexpr uint16_t kParsecBtnGuide = 0x0400;
    constexpr uint16_t kParsecBtnA = 0x1000;
    constexpr uint16_t kParsecBtnB = 0x2000;
    constexpr uint16_t kParsecBtnX = 0x4000;
    constexpr uint16_t kParsecBtnY = 0x8000;

    enum class LoginField
    {
        Email = 0,
        Password = 1,
        Tfa = 2,
    };

    struct VRButtonHit
    {
        CGRect uvRect;
        NSString *buttonId;
        NSString *label;
        BOOL selected;
        BOOL disabled;
    };

    struct VRRayHit
    {
        SCNNode *node = nil;
        CGPoint uv = CGPointZero;
        float dist = 1e9f;
    };

    static UIColor *ColorHex(uint32_t hex, CGFloat alpha = 1.0)
    {
        CGFloat r = ((hex >> 16) & 0xFF) / 255.0;
        CGFloat g = ((hex >> 8) & 0xFF) / 255.0;
        CGFloat b = (hex & 0xFF) / 255.0;
        return [UIColor colorWithRed:r green:g blue:b alpha:alpha];
    }

    static NSString *FormatParsecStatus(int st)
    {
        switch (st)
        {
            case 0: return @"Connected";
            case 6: return @"Waiting for approval on host PC";
            case 8: return @"Host declined connection";
            case 9: return @"Connection canceled";
            case 11: return @"Host has no free slots";
            case 20: return @"Connecting to host...";
            case 99: return @"Host went offline";
            case -3: return @"Idle";
            case -3008: return @"Parsec session expired";
            case -6023: case -6024: case -6033: return @"P2P NAT negotiation failed";
            default: return [NSString stringWithFormat:@"Status %d", st];
        }
    }

    static float ApplyDeadzone(float v, float dz)
    {
        float av = fabsf(v);
        if (av <= dz)
            return 0.0f;
        float scaled = (av - dz) / (1.0f - dz);
        return (v < 0.0f) ? -scaled : scaled;
    }

    static int16_t FloatToThumbAxis(float v)
    {
        float dz = ApplyDeadzone(v, 0.08f);
        float clamped = std::max(-1.0f, std::min(1.0f, dz));
        return static_cast<int16_t>(clamped * 32767.0f);
    }

    static uint8_t FloatToTriggerByte(float v)
    {
        float clamped = std::max(0.0f, std::min(1.0f, v));
        if (clamped < 0.03f)
            return 0;
        return static_cast<uint8_t>(clamped * 255.0f);
    }
}

@interface VRWorkspaceViewController () <ARSessionDelegate>
@property (nonatomic, strong) ARSession *arSession;
@property (nonatomic, strong) SCNScene *scene;
@property (nonatomic, strong) SCNView *leftView;
@property (nonatomic, strong) SCNView *rightView;
@property (nonatomic, strong) SCNNode *headNode;
@property (nonatomic, strong) SCNNode *leftEyeNode;
@property (nonatomic, strong) SCNNode *rightEyeNode;
@property (nonatomic, strong) SCNNode *cinemaRootNode;
@property (nonatomic, strong) SCNNode *screenAnchorNode;
@property (nonatomic, strong) SCNNode *parsecScreenNode;
@property (nonatomic, strong) SCNNode *parsecPanelNode;
@property (nonatomic, strong) SCNNode *parsecBarNode;
@property (nonatomic, strong) SCNNode *parsecCursorNode;
@property (nonatomic, strong) SCNNode *floorNode;

@property (nonatomic, strong) UIView *dividerLine;
@property (nonatomic, strong) UIView *leftReticle;
@property (nonatomic, strong) UIView *rightReticle;
@property (nonatomic, strong) UIButton *quickSetupButton;
@property (nonatomic, strong) UIButton *viewModeButton;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t passthroughQueue;

@property (nonatomic, copy) NSString *emailText;
@property (nonatomic, copy) NSString *passwordText;
@property (nonatomic, copy) NSString *tfaText;
@property (nonatomic, copy) NSString *sessionId;
@property (nonatomic, copy) NSString *connectedHostName;
@property (nonatomic, copy) NSString *parsecStateMessage;
@property (nonatomic, assign) BOOL parsecStateIsError;
@property (nonatomic, assign) BOOL requiresTfa;
@property (nonatomic, assign) BOOL isAuthBusy;
@property (nonatomic, assign) BOOL isHostsBusy;
@property (nonatomic, assign) BOOL showsHostList;
@property (nonatomic, assign) BOOL parsecConnecting;
@property (nonatomic, assign) BOOL parsecConnected;
@property (nonatomic, strong) NSArray<NSDictionary *> *hosts;
@property (nonatomic, assign) int hostWidth;
@property (nonatomic, assign) int hostHeight;
@property (nonatomic, assign) LoginField loginField;

// VR Box optical & cinema settings
@property (nonatomic, assign) float lensSpacingRatio;
@property (nonatomic, assign) float eyeHeightRatio;
@property (nonatomic, assign) float screenScale;
@property (nonatomic, assign) float screenDistance;
@property (nonatomic, assign) BOOL headLockMode;
@property (nonatomic, assign) BOOL passthroughOn;
@property (nonatomic, assign) BOOL passthroughBusy;
@property (nonatomic, assign) CFTimeInterval nextPassthroughAt;
@property (nonatomic, assign) BOOL singleScreenTouchMode;
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, assign) BOOL hasRecenteredOnce;

// Xbox / MFi Controller state
@property (nonatomic, strong) GCController *activeController;
@property (nonatomic, assign) BOOL gamepadPassthroughMode;
@property (nonatomic, assign) NSInteger selectedMenuIndex;
@property (nonatomic, assign) CGPoint cursorUv;
@property (nonatomic, assign) int lastMousePx;
@property (nonatomic, assign) int lastMousePy;
@property (nonatomic, assign) BOOL parsecMouseHeld;
@property (nonatomic, assign) int heldMouseButton;
@property (nonatomic, assign) CFTimeInterval lastTickAt;
@property (nonatomic, assign) CFTimeInterval nextNavRepeatAt;
@property (nonatomic, assign) CFTimeInterval nextComboRepeatAt;
@property (nonatomic, assign) CFTimeInterval nextBarRedrawAt;
@property (nonatomic, assign) CFTimeInterval nextGamepadHeartbeatAt;
@property (nonatomic, assign) CFTimeInterval barToastUntil;
@property (nonatomic, copy) NSString *barToastText;
@property (nonatomic, assign) uint16_t lastSentButtons;
@property (nonatomic, assign) int16_t lastSentLX;
@property (nonatomic, assign) int16_t lastSentLY;
@property (nonatomic, assign) int16_t lastSentRX;
@property (nonatomic, assign) int16_t lastSentRY;
@property (nonatomic, assign) uint8_t lastSentLT;
@property (nonatomic, assign) uint8_t lastSentRT;

// Edge-trigger memory for UI / mouse mode controller buttons
@property (nonatomic, assign) BOOL prevBtnA;
@property (nonatomic, assign) BOOL prevBtnB;
@property (nonatomic, assign) BOOL prevBtnX;
@property (nonatomic, assign) BOOL prevBtnY;
@property (nonatomic, assign) BOOL prevBtnLB;
@property (nonatomic, assign) BOOL prevBtnRB;
@property (nonatomic, assign) BOOL prevBtnMenu;
@property (nonatomic, assign) BOOL suppressMenuUntilRelease;
@property (nonatomic, assign) BOOL prevComboToggle;
@property (nonatomic, assign) BOOL prevComboRecenter;
@property (nonatomic, assign) BOOL prevDpadL;
@property (nonatomic, assign) BOOL prevDpadR;
@property (nonatomic, assign) BOOL prevDpadU;
@property (nonatomic, assign) BOOL prevDpadD;
@property (nonatomic, assign) BOOL isTwoFingerScrolling;
@property (nonatomic, assign) CGFloat twoFingerScrollLastY;
@end

@implementation VRWorkspaceViewController
{
    std::vector<VRButtonHit> _parsecPanelHits;
    std::vector<VRButtonHit> _parsecBarHits;
}

- (BOOL)prefersStatusBarHidden { return YES; }
- (BOOL)prefersHomeIndicatorAutoHidden { return YES; }
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskLandscape; }

- (void)viewDidLoad
{
    [super viewDidLoad];
    self.view.backgroundColor = [UIColor blackColor];
    self.view.multipleTouchEnabled = YES;

    self.emailText = @"";
    self.passwordText = @"";
    self.tfaText = @"";
    self.sessionId = @"";
    self.connectedHostName = @"";
    self.parsecStateMessage = @"Sign in via Setup button or connect your Xbox controller.";
    self.hosts = @[];
    self.hostWidth = 1920;
    self.hostHeight = 1080;
    self.loginField = LoginField::Email;
    self.cursorUv = CGPointMake(0.5, 0.5);
    self.lastMousePx = -1;
    self.lastMousePy = -1;
    self.heldMouseButton = 1;
    self.selectedMenuIndex = 0;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    float savedLens = [ud floatForKey:kPrefLensSpacing];
    float savedEyeH = [ud floatForKey:kPrefEyeHeight];
    float savedScale = [ud floatForKey:kPrefScreenScale];
    float savedDist = [ud floatForKey:kPrefScreenDist];
    self.lensSpacingRatio = (savedLens >= 0.28f && savedLens <= 0.50f) ? savedLens : kDefaultLensSpacing;
    self.eyeHeightRatio = (savedEyeH >= 0.65f && savedEyeH <= 1.00f) ? savedEyeH : kDefaultEyeHeight;
    self.screenScale = (savedScale >= 0.60f && savedScale <= 2.40f) ? savedScale : kDefaultScreenScale;
    self.screenDistance = (savedDist >= 0.80f && savedDist <= 2.60f) ? savedDist : kDefaultScreenDist;

    self.passthroughOn = NO; // Cinema Black gives razor-sharp contrast and ice-cold 120 FPS.
    self.headLockMode = NO;  // World 6DoF locked by default; Y button recenters anytime.

    self.ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    self.passthroughQueue = dispatch_queue_create("com.brenpoly.cardboardxr.passthrough", DISPATCH_QUEUE_SERIAL);

    [self setupSceneAndStereoViews];
    [self buildCinemaNodes];
    [self setupOverlayViews];
    [self setupArSession];
    [self setupGameControllers];

    VRParsecInit();

    [self restoreSavedSession];
    [self applyScreenLayoutAndScale];
    [self applyWorkspaceVisibility];
    [self redrawAllPanels];

    self.lastTickAt = CACurrentMediaTime();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
    if (@available(iOS 15.0, *))
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.displayLink invalidate];
    [self.arSession pause];
    VRParsecUnplugGamepad();
    VRParsecDisconnect();
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self updateStereoOrFullLayout];
}

#pragma mark - VR Box Optical Viewport Layout

- (void)saveVrBoxPreferences
{
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setFloat:self.lensSpacingRatio forKey:kPrefLensSpacing];
    [ud setFloat:self.eyeHeightRatio forKey:kPrefEyeHeight];
    [ud setFloat:self.screenScale forKey:kPrefScreenScale];
    [ud setFloat:self.screenDistance forKey:kPrefScreenDist];
}

- (void)updateStereoOrFullLayout
{
    CGRect bounds = self.view.bounds;
    CGFloat W = bounds.size.width;
    CGFloat H = bounds.size.height;
    if (W <= 0 || H <= 0)
        return;

    if (self.singleScreenTouchMode)
    {
        self.leftView.frame = bounds;
        self.rightView.hidden = YES;
        self.rightView.rendersContinuously = NO;
        self.dividerLine.hidden = YES;
        self.leftReticle.hidden = YES;
        self.rightReticle.hidden = YES;
        self.quickSetupButton.alpha = 0.92;
        self.viewModeButton.alpha = 0.92;
        return;
    }

    self.rightView.hidden = NO;
    self.rightView.rendersContinuously = YES;
    self.dividerLine.hidden = NO;

    CGFloat midX = W * 0.5;
    CGFloat eyeW = floor(W * self.lensSpacingRatio);
    CGFloat eyeH = floor(H * self.eyeHeightRatio);
    CGFloat eyeY = floor((H - eyeH) * 0.5);

    self.leftView.frame = CGRectMake(midX - eyeW - 1.0, eyeY, eyeW, eyeH);
    self.rightView.frame = CGRectMake(midX + 1.0, eyeY, eyeW, eyeH);
    self.dividerLine.frame = CGRectMake(midX - 0.5, 0.0, 1.0, H);

    BOOL showReticles = !self.parsecConnected;
    self.leftReticle.hidden = !showReticles;
    self.rightReticle.hidden = !showReticles;

    CGFloat rSize = 8.0;
    self.leftReticle.center = CGPointMake(midX - 1.0 - eyeW * 0.5, H * 0.5);
    self.leftReticle.bounds = CGRectMake(0, 0, rSize, rSize);
    self.rightReticle.center = CGPointMake(midX + 1.0 + eyeW * 0.5, H * 0.5);
    self.rightReticle.bounds = CGRectMake(0, 0, rSize, rSize);

    // Subtle in VR Box so corners stay clean behind lens edge.
    self.quickSetupButton.alpha = 0.28;
    self.viewModeButton.alpha = 0.28;
}

#pragma mark - Scene & Cinema Nodes

- (void)setupSceneAndStereoViews
{
    self.scene = [SCNScene scene];
    self.scene.background.contents = [UIColor blackColor];

    self.headNode = [SCNNode node];
    [self.scene.rootNode addChildNode:self.headNode];

    // Zero-disparity MonoEyes optical axis prevents double vision on flat cinema screen inside VR Box lenses.
    SCNCamera *leftCam = [SCNCamera camera];
    leftCam.zNear = 0.05;
    leftCam.zFar = 50.0;
    leftCam.fieldOfView = kDefaultFov;
    self.leftEyeNode = [SCNNode node];
    self.leftEyeNode.camera = leftCam;
    self.leftEyeNode.position = SCNVector3Zero;
    [self.headNode addChildNode:self.leftEyeNode];

    SCNCamera *rightCam = [SCNCamera camera];
    rightCam.zNear = 0.05;
    rightCam.zFar = 50.0;
    rightCam.fieldOfView = kDefaultFov;
    self.rightEyeNode = [SCNNode node];
    self.rightEyeNode.camera = rightCam;
    self.rightEyeNode.position = SCNVector3Zero;
    [self.headNode addChildNode:self.rightEyeNode];

    self.leftView = [[SCNView alloc] initWithFrame:CGRectZero];
    self.leftView.scene = self.scene;
    self.leftView.pointOfView = self.leftEyeNode;
    self.leftView.backgroundColor = [UIColor blackColor];
    self.leftView.antialiasingMode = SCNAntialiasingModeNone;
    self.leftView.preferredFramesPerSecond = 120;
    self.leftView.rendersContinuously = YES;
    self.leftView.userInteractionEnabled = NO;
    [self.view addSubview:self.leftView];

    self.rightView = [[SCNView alloc] initWithFrame:CGRectZero];
    self.rightView.scene = self.scene;
    self.rightView.pointOfView = self.rightEyeNode;
    self.rightView.backgroundColor = [UIColor blackColor];
    self.rightView.antialiasingMode = SCNAntialiasingModeNone;
    self.rightView.preferredFramesPerSecond = 120;
    self.rightView.rendersContinuously = YES;
    self.rightView.userInteractionEnabled = NO;
    [self.view addSubview:self.rightView];
}

- (SCNNode *)makePlaneNode:(NSString *)name width:(CGFloat)w height:(CGFloat)h color:(UIColor *)color
{
    SCNPlane *plane = [SCNPlane planeWithWidth:w height:h];
    plane.cornerRadius = 0.025;
    SCNMaterial *mat = [SCNMaterial material];
    mat.lightingModelName = SCNLightingModelConstant;
    mat.diffuse.contents = color;
    mat.doubleSided = YES;
    plane.materials = @[mat];
    SCNNode *node = [SCNNode nodeWithGeometry:plane];
    node.name = name;
    return node;
}

- (UIGraphicsImageRenderer *)makeUiRendererWithSize:(CGSize)sz
{
    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
    fmt.scale = 1.0;
    fmt.opaque = NO;
    return [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
}

- (void)buildCinemaNodes
{
    self.cinemaRootNode = [SCNNode node];
    [self.scene.rootNode addChildNode:self.cinemaRootNode];

    SCNPlane *floorGeo = [SCNPlane planeWithWidth:20.0 height:20.0];
    SCNMaterial *floorMat = [SCNMaterial material];
    floorMat.lightingModelName = SCNLightingModelConstant;
    floorMat.diffuse.contents = ColorHex(0x060609);
    floorGeo.materials = @[floorMat];
    self.floorNode = [SCNNode nodeWithGeometry:floorGeo];
    self.floorNode.position = SCNVector3Make(0, -1.75f, 0);
    self.floorNode.eulerAngles = SCNVector3Make(-M_PI_2, 0, 0);
    self.floorNode.hidden = YES;
    [self.cinemaRootNode addChildNode:self.floorNode];

    self.screenAnchorNode = [SCNNode node];
    self.screenAnchorNode.position = SCNVector3Make(0, 0.0f, -self.screenDistance);
    [self.cinemaRootNode addChildNode:self.screenAnchorNode];

    self.parsecScreenNode = [self makePlaneNode:@"parsec_screen" width:kBaseScreenWidth height:(kBaseScreenWidth * 9.0 / 16.0) color:ColorHex(0x101014)];
    [self.screenAnchorNode addChildNode:self.parsecScreenNode];

    self.parsecPanelNode = [self makePlaneNode:@"parsec_panel" width:1.36 height:0.96 color:ColorHex(0x1D1B22)];
    [self.screenAnchorNode addChildNode:self.parsecPanelNode];

    self.parsecBarNode = [self makePlaneNode:@"parsec_bar" width:1.96 height:0.26 color:ColorHex(0x1D1B22)];
    self.parsecBarNode.position = SCNVector3Make(0, -1.16f, 0.02f);
    [self.screenAnchorNode addChildNode:self.parsecBarNode];

    SCNSphere *cGeo = [SCNSphere sphereWithRadius:0.016];
    SCNMaterial *cMat = [SCNMaterial material];
    cMat.lightingModelName = SCNLightingModelConstant;
    cMat.diffuse.contents = ColorHex(0x5EEAD4, 0.96);
    cMat.writesToDepthBuffer = NO;
    cGeo.materials = @[cMat];
    self.parsecCursorNode = [SCNNode nodeWithGeometry:cGeo];
    self.parsecCursorNode.renderingOrder = 25;
    self.parsecCursorNode.hidden = YES;
    [self.parsecScreenNode addChildNode:self.parsecCursorNode];
}

- (void)setupOverlayViews
{
    self.dividerLine = [[UIView alloc] initWithFrame:CGRectZero];
    self.dividerLine.backgroundColor = ColorHex(0xFFFFFF, 0.25);
    self.dividerLine.userInteractionEnabled = NO;
    [self.view addSubview:self.dividerLine];

    auto makeReticle = ^UIView *() {
        UIView *v = [[UIView alloc] initWithFrame:CGRectMake(0, 0, 8, 8)];
        v.layer.cornerRadius = 4.0;
        v.layer.borderWidth = 1.5;
        v.layer.borderColor = [UIColor whiteColor].CGColor;
        v.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.35];
        v.userInteractionEnabled = NO;
        return v;
    };
    self.leftReticle = makeReticle();
    self.rightReticle = makeReticle();
    [self.view addSubview:self.leftReticle];
    [self.view addSubview:self.rightReticle];

    self.quickSetupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.quickSetupButton.frame = CGRectMake(14, 14, 140, 32);
    self.quickSetupButton.backgroundColor = ColorHex(0x2B2930, 0.88);
    self.quickSetupButton.layer.cornerRadius = 16;
    [self.quickSetupButton setTitle:@"Parsec Setup" forState:UIControlStateNormal];
    [self.quickSetupButton setTitleColor:ColorHex(0xE6E0E9) forState:UIControlStateNormal];
    self.quickSetupButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.quickSetupButton addTarget:self action:@selector(openQuickSetupAlert) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.quickSetupButton];

    self.viewModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.viewModeButton.frame = CGRectMake(162, 14, 130, 32);
    self.viewModeButton.backgroundColor = ColorHex(0x2B2930, 0.88);
    self.viewModeButton.layer.cornerRadius = 16;
    [self.viewModeButton setTitle:@"View: VR Box" forState:UIControlStateNormal];
    [self.viewModeButton setTitleColor:ColorHex(0xD0BCFF) forState:UIControlStateNormal];
    self.viewModeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.viewModeButton addTarget:self action:@selector(toggleSingleScreenTouchMode) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.viewModeButton];
}

- (void)toggleSingleScreenTouchMode
{
    self.singleScreenTouchMode = !self.singleScreenTouchMode;
    [self.viewModeButton setTitle:(self.singleScreenTouchMode ? @"View: Full 2D" : @"View: VR Box") forState:UIControlStateNormal];
    [self updateStereoOrFullLayout];
}

- (void)applyScreenLayoutAndScale
{
    double aspect = (self.hostWidth > 0 && self.hostHeight > 0)
        ? (static_cast<double>(self.hostHeight) / static_cast<double>(self.hostWidth))
        : (9.0 / 16.0);
    aspect = std::max(0.32, std::min(1.0, aspect));

    CGFloat w = kBaseScreenWidth * self.screenScale;
    CGFloat h = w * aspect;
    SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
    pl.width = w;
    pl.height = h;

    self.screenAnchorNode.position = SCNVector3Make(0, 0.0f, -self.screenDistance);
    CGFloat barY = -h * 0.5 - 0.17;
    self.parsecBarNode.position = SCNVector3Make(0, static_cast<float>(barY), 0.02f);
}

#pragma mark - ARKit 120Hz Head Tracking + Optional Passthrough

- (void)setupArSession
{
    self.arSession = [[ARSession alloc] init];
    self.arSession.delegate = self;
    self.arSession.delegateQueue = dispatch_get_main_queue();

    ARWorldTrackingConfiguration *cfg = [[ARWorldTrackingConfiguration alloc] init];
    cfg.worldAlignment = ARWorldAlignmentGravity;
    [self.arSession runWithConfiguration:cfg];
}

- (UIInterfaceOrientation)currentInterfaceOrientation
{
    if (self.view.window.windowScene != nil)
        return self.view.window.windowScene.interfaceOrientation;
    return UIInterfaceOrientationLandscapeLeft;
}

- (void)session:(ARSession *)session didUpdateFrame:(ARFrame *)frame
{
    (void)session;
    UIInterfaceOrientation orient = [self currentInterfaceOrientation];
    simd_float4x4 viewMat = [frame.camera viewMatrixForOrientation:orient];
    simd_float4x4 camToWorld = simd_inverse(viewMat);
    self.headNode.simdTransform = camToWorld;

    if (!self.hasRecenteredOnce)
    {
        self.hasRecenteredOnce = YES;
        [self recenterWorkspace];
    }

    if (self.passthroughOn && !self.passthroughBusy)
    {
        CFTimeInterval now = CACurrentMediaTime();
        if (now >= self.nextPassthroughAt)
        {
            self.nextPassthroughAt = now + (1.0 / 30.0);
            self.passthroughBusy = YES;
            CVPixelBufferRef pb = CVPixelBufferRetain(frame.capturedImage);
            __weak VRWorkspaceViewController *weakSelf = self;
            dispatch_async(self.passthroughQueue, ^{
                VRWorkspaceViewController *strongSelf = weakSelf;
                if (strongSelf)
                    [strongSelf updatePassthroughBackground:pb orientation:orient];
                else
                    CVPixelBufferRelease(pb);
            });
        }
    }
}

- (void)updatePassthroughBackground:(CVPixelBufferRef)pixelBuffer orientation:(UIInterfaceOrientation)orient
{
    if (!pixelBuffer)
    {
        __weak VRWorkspaceViewController *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            weakSelf.passthroughBusy = NO;
        });
        return;
    }

    CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImagePropertyOrientation cgOrient = (orient == UIInterfaceOrientationLandscapeLeft)
        ? kCGImagePropertyOrientationDown
        : kCGImagePropertyOrientationUp;
    ci = [ci imageByApplyingOrientation:cgOrient];
    CGRect e0 = ci.extent;
    UIImage *bg = nil;
    if (e0.size.width > 0 && e0.size.height > 0)
    {
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeTranslation(-e0.origin.x, -e0.origin.y)];
        ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(0.25, 0.25)];
        CGImageRef cg = [self.ciContext createCGImage:ci fromRect:ci.extent];
        if (cg)
        {
            bg = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
        }
    }
    CVPixelBufferRelease(pixelBuffer);

    __weak VRWorkspaceViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWorkspaceViewController *strongSelf = weakSelf;
        if (strongSelf)
        {
            if (bg && strongSelf.passthroughOn)
                strongSelf.scene.background.contents = bg;
            strongSelf.passthroughBusy = NO;
        }
    });
}

#pragma mark - Xbox / MFi Controller Engine

- (void)setupGameControllers
{
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onControllerConnected:)
                                                 name:GCControllerDidConnectNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(onControllerDisconnected:)
                                                 name:GCControllerDidDisconnectNotification
                                               object:nil];
    [GCController startWirelessControllerDiscoveryWithCompletionHandler:nil];
    [self refreshActiveController];
}

- (void)onControllerConnected:(NSNotification *)note
{
    (void)note;
    [self refreshActiveController];
    [self showBarToast:@"Xbox Kolu Baglandi!"];
    [self redrawAllPanels];
}

- (void)onControllerDisconnected:(NSNotification *)note
{
    (void)note;
    if (self.parsecConnected && self.gamepadPassthroughMode)
    {
        VRParsecSendGamepadState(0, 0, 0, 0, 0, 0, 0);
        VRParsecUnplugGamepad();
    }
    [self refreshActiveController];
    [self showBarToast:@"Xbox Kolu Baglantisi Kesildi"];
    [self redrawAllPanels];
}

- (void)refreshActiveController
{
    GCController *picked = nil;
    for (GCController *c in [GCController controllers])
    {
        if (c.extendedGamepad)
        {
            picked = c;
            break;
        }
    }
    self.activeController = picked;
    if (picked)
        picked.playerIndex = GCControllerPlayerIndex1;
}

- (void)showBarToast:(NSString *)text
{
    self.barToastText = text;
    self.barToastUntil = CACurrentMediaTime() + 2.2;
}

- (void)adjustLensSpacingBy:(float)delta
{
    self.lensSpacingRatio = std::max(0.28f, std::min(0.50f, self.lensSpacingRatio + delta));
    [self saveVrBoxPreferences];
    [self updateStereoOrFullLayout];
    [self showBarToast:[NSString stringWithFormat:@"VR Box Goz Araligi: %.0f%%", self.lensSpacingRatio * 100.0f]];
    [self redrawParsecBar];
    if (!self.parsecConnected)
        [self redrawParsecPanel];
}

- (void)adjustScreenScaleBy:(float)delta
{
    self.screenScale = std::max(0.60f, std::min(2.40f, self.screenScale + delta));
    [self saveVrBoxPreferences];
    [self applyScreenLayoutAndScale];
    [self showBarToast:[NSString stringWithFormat:@"Ekran Boyutu: %.0f%%", self.screenScale * 100.0f]];
    [self redrawParsecBar];
}

- (void)adjustScreenDistBy:(float)delta
{
    self.screenDistance = std::max(0.80f, std::min(2.60f, self.screenDistance + delta));
    [self saveVrBoxPreferences];
    [self applyScreenLayoutAndScale];
    [self showBarToast:[NSString stringWithFormat:@"Ekran Mesafesi: %.2fm", self.screenDistance]];
    [self redrawParsecBar];
}

- (void)toggleGamepadMode
{
    self.gamepadPassthroughMode = !self.gamepadPassthroughMode;
    AudioServicesPlaySystemSound(1104);
    if (!self.gamepadPassthroughMode)
    {
        if (self.parsecMouseHeld)
        {
            self.parsecMouseHeld = NO;
            VRParsecSendMouseButton(self.heldMouseButton, 0);
        }
        VRParsecSendGamepadState(0, 0, 0, 0, 0, 0, 0);
        VRParsecUnplugGamepad();
        self.prevBtnA = YES;
        self.prevBtnB = YES;
        self.prevBtnX = YES;
        self.prevBtnY = YES;
        self.prevBtnLB = YES;
        self.prevBtnRB = YES;
        [self showBarToast:@"FARE MODU (L-Stick: Fare, MENU: Oyun Kolu)"];
    }
    else
    {
        self.suppressMenuUntilRelease = YES;
        if (self.parsecMouseHeld)
        {
            self.parsecMouseHeld = NO;
            VRParsecSendMouseButton(self.heldMouseButton, 0);
        }
        [self showBarToast:@"XBOX OYUN KOLU MODU (View+Menu: Fare Modu)"];
    }
    self.parsecCursorNode.hidden = !self.parsecConnected || self.gamepadPassthroughMode;
    [self redrawParsecBar];
}

- (void)pollXboxControllerAtTime:(CFTimeInterval)now dt:(float)dt
{
    if (!self.activeController || !self.activeController.extendedGamepad)
    {
        [self refreshActiveController];
        if (!self.activeController || !self.activeController.extendedGamepad)
            return;
    }

    GCExtendedGamepad *gp = self.activeController.extendedGamepad;
    BOOL btnA = gp.buttonA.pressed;
    BOOL btnB = gp.buttonB.pressed;
    BOOL btnX = gp.buttonX.pressed;
    BOOL btnY = gp.buttonY.pressed;
    BOOL btnLB = gp.leftShoulder.pressed;
    BOOL btnRB = gp.rightShoulder.pressed;
    BOOL btnMenu = gp.buttonMenu.pressed;
    BOOL btnView = (gp.buttonOptions != nil && gp.buttonOptions.pressed);
    BOOL btnHome = (gp.buttonHome != nil && gp.buttonHome.pressed);
    BOOL btnL3 = (gp.leftThumbstickButton != nil && gp.leftThumbstickButton.pressed);
    BOOL btnR3 = (gp.rightThumbstickButton != nil && gp.rightThumbstickButton.pressed);

    BOOL dpU = gp.dpad.up.pressed;
    BOOL dpD = gp.dpad.down.pressed;
    BOOL dpL = gp.dpad.left.pressed;
    BOOL dpR = gp.dpad.right.pressed;

    float lx = gp.leftThumbstick.xAxis.value;
    float ly = gp.leftThumbstick.yAxis.value;
    float rx = gp.rightThumbstick.xAxis.value;
    float ry = gp.rightThumbstick.yAxis.value;
    float lt = gp.leftTrigger.value;
    float rt = gp.rightTrigger.value;

    // Connected + Xbox 360 Native Gamepad Mode
    if (self.parsecConnected && self.gamepadPassthroughMode)
    {
        BOOL comboToggle = (btnView && btnMenu);
        if (comboToggle && !self.prevComboToggle)
        {
            self.prevComboToggle = YES;
            self.prevBtnMenu = YES;
            [self toggleGamepadMode];
            return;
        }
        self.prevComboToggle = comboToggle;

        BOOL comboRecenter = (btnView && btnY);
        if (comboRecenter && !self.prevComboRecenter)
        {
            self.prevComboRecenter = YES;
            [self recenterWorkspace];
            [self showBarToast:@"Ekran Ortalandi"];
            return;
        }
        self.prevComboRecenter = comboRecenter;

        if (btnView && (dpL || dpR || dpU || dpD))
        {
            if (now >= self.nextComboRepeatAt)
            {
                self.nextComboRepeatAt = now + 0.08;
                if (dpL) [self adjustLensSpacingBy:-0.008f];
                if (dpR) [self adjustLensSpacingBy:0.008f];
                if (dpU) [self adjustScreenScaleBy:0.08f];
                if (dpD) [self adjustScreenScaleBy:-0.08f];
            }
        }

        if (!btnMenu)
            self.suppressMenuUntilRelease = NO;

        uint16_t mask = 0;
        if (dpU) mask |= kParsecBtnDpadUp;
        if (dpD) mask |= kParsecBtnDpadDown;
        if (dpL) mask |= kParsecBtnDpadLeft;
        if (dpR) mask |= kParsecBtnDpadRight;
        if (btnMenu && !self.suppressMenuUntilRelease) mask |= kParsecBtnStart;
        if (btnView && !btnMenu && !btnY && !dpL && !dpR && !dpU && !dpD) mask |= kParsecBtnBack;
        if (btnL3) mask |= kParsecBtnLThumb;
        if (btnR3) mask |= kParsecBtnRThumb;
        if (btnLB) mask |= kParsecBtnLShoulder;
        if (btnRB) mask |= kParsecBtnRShoulder;
        if (btnHome) mask |= kParsecBtnGuide;
        if (btnA) mask |= kParsecBtnA;
        if (btnB) mask |= kParsecBtnB;
        if (btnX) mask |= kParsecBtnX;
        if (btnY && !btnView) mask |= kParsecBtnY;

        int16_t sLX = FloatToThumbAxis(lx);
        int16_t sLY = FloatToThumbAxis(ly);
        int16_t sRX = FloatToThumbAxis(rx);
        int16_t sRY = FloatToThumbAxis(ry);
        uint8_t uLT = FloatToTriggerByte(lt);
        uint8_t uRT = FloatToTriggerByte(rt);

        BOOL changed = (mask != self.lastSentButtons ||
                        abs(sLX - self.lastSentLX) > 64 || abs(sLY - self.lastSentLY) > 64 ||
                        abs(sRX - self.lastSentRX) > 64 || abs(sRY - self.lastSentRY) > 64 ||
                        abs((int)uLT - (int)self.lastSentLT) > 2 || abs((int)uRT - (int)self.lastSentRT) > 2);
        if (changed || now >= self.nextGamepadHeartbeatAt)
        {
            self.lastSentButtons = mask;
            self.lastSentLX = sLX;
            self.lastSentLY = sLY;
            self.lastSentRX = sRX;
            self.lastSentRY = sRY;
            self.lastSentLT = uLT;
            self.lastSentRT = uRT;
            self.nextGamepadHeartbeatAt = now + 0.08;
            VRParsecSendGamepadState(mask, sLX, sLY, sRX, sRY, uLT, uRT);
        }

        self.prevBtnMenu = btnMenu;
        return;
    }

    // UI Panel Navigation (before Parsec is connected)
    if (!self.parsecConnected)
    {
        int navDir = 0;
        if (dpU || ly > 0.55f) navDir = -1;
        else if (dpD || ly < -0.55f) navDir = 1;

        if (navDir != 0)
        {
            if (now >= self.nextNavRepeatAt)
            {
                self.nextNavRepeatAt = now + 0.20;
                NSUInteger count = _parsecPanelHits.size();
                if (count > 0)
                {
                    NSInteger nextIdx = (self.selectedMenuIndex + navDir + static_cast<NSInteger>(count)) % static_cast<NSInteger>(count);
                    self.selectedMenuIndex = nextIdx;
                    AudioServicesPlaySystemSound(1104);
                    [self redrawParsecPanel];
                }
            }
        }
        else
        {
            self.nextNavRepeatAt = 0.0;
        }

        if ((dpL && !self.prevDpadL) || (dpR && !self.prevDpadR))
            [self adjustLensSpacingBy:(dpR ? 0.008f : -0.008f)];
        if (btnLB && !self.prevBtnLB)
            [self adjustScreenScaleBy:-0.10f];
        if (btnRB && !self.prevBtnRB)
            [self adjustScreenScaleBy:0.10f];

        if (btnA && !self.prevBtnA)
        {
            if (!_parsecPanelHits.empty())
            {
                NSInteger idx = std::max<NSInteger>(0, std::min<NSInteger>(self.selectedMenuIndex, static_cast<NSInteger>(_parsecPanelHits.size()) - 1));
                NSString *bId = _parsecPanelHits[static_cast<size_t>(idx)].buttonId;
                AudioServicesPlaySystemSound(1104);
                [self handleButtonClick:bId];
            }
        }
        if (btnX && !self.prevBtnX)
        {
            AudioServicesPlaySystemSound(1104);
            if (self.showsHostList) [self refreshHosts];
            else [self startParsecSignIn];
        }
        if (btnB && !self.prevBtnB && self.parsecConnecting)
        {
            AudioServicesPlaySystemSound(1104);
            [self cancelConnect];
        }
        if (btnY && !self.prevBtnY)
        {
            AudioServicesPlaySystemSound(1104);
            [self recenterWorkspace];
            [self showBarToast:@"Ekran Ortalandi"];
        }
    }
    else
    {
        // Connected + VR Mouse & Cinema Control Mode
        if (btnMenu && !self.prevBtnMenu)
        {
            self.prevBtnMenu = YES;
            [self toggleGamepadMode];
            return;
        }

        // Left Stick moves PC mouse cursor across giant cinema screen with smooth precision curve
        float mx = ApplyDeadzone(lx, 0.09f);
        float my = ApplyDeadzone(ly, 0.09f);
        if (mx != 0.0f || my != 0.0f)
        {
            float curveX = mx * (0.35f + 0.65f * fabsf(mx));
            float curveY = my * (0.35f + 0.65f * fabsf(my));
            float speed = 0.58f;
            double nx = std::max(0.0, std::min(1.0, self.cursorUv.x + curveX * speed * dt));
            double ny = std::max(0.0, std::min(1.0, self.cursorUv.y - curveY * speed * dt));
            self.cursorUv = CGPointMake(nx, ny);
            [self pushCursorUvToParsec];
        }

        // Right Stick Y scrolls mouse wheel on PC
        float sy = ApplyDeadzone(ry, 0.14f);
        if (sy != 0.0f && now >= self.nextNavRepeatAt)
        {
            self.nextNavRepeatAt = now + 0.035;
            VRParsecSendMouseWheel(0, static_cast<int>(sy * 110.0f));
        }

        // A Button: Left Mouse Hold & Drag
        if (btnA && !self.prevBtnA)
        {
            AudioServicesPlaySystemSound(1104);
            self.heldMouseButton = 1;
            self.parsecMouseHeld = YES;
            VRParsecSendMouseButton(1, 1);
        }
        else if (!btnA && self.prevBtnA && self.parsecMouseHeld)
        {
            self.parsecMouseHeld = NO;
            VRParsecSendMouseButton(self.heldMouseButton, 0);
        }

        // B Button: Right Mouse Click
        if (btnB && !self.prevBtnB)
        {
            AudioServicesPlaySystemSound(1104);
            VRParsecSendMouseButton(3, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VRParsecSendMouseButton(3, 0);
            });
        }

        // X Button: Quick Double Left Click (opens desktop shortcuts easily)
        if (btnX && !self.prevBtnX)
        {
            AudioServicesPlaySystemSound(1104);
            VRParsecSendMouseButton(1, 1);
            VRParsecSendMouseButton(1, 0);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.07 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VRParsecSendMouseButton(1, 1);
                VRParsecSendMouseButton(1, 0);
            });
        }

        // Y Button: Recenter cinema screen
        if (btnY && !self.prevBtnY)
        {
            AudioServicesPlaySystemSound(1104);
            [self recenterWorkspace];
            [self showBarToast:@"Ekran Ortalandi"];
            [self redrawParsecBar];
        }

        // D-Pad L/R: Live VR Box IPD lens convergence
        if (dpL || dpR || dpU || dpD)
        {
            if (now >= self.nextComboRepeatAt)
            {
                self.nextComboRepeatAt = now + 0.09;
                if (dpL) [self adjustLensSpacingBy:-0.008f];
                if (dpR) [self adjustLensSpacingBy:0.008f];
                if (dpU) [self adjustScreenScaleBy:0.08f];
                if (dpD) [self adjustScreenScaleBy:-0.08f];
            }
        }

        // LB / RB: Distance closer / further
        if (btnLB && !self.prevBtnLB)
            [self adjustScreenDistBy:0.12f];
        if (btnRB && !self.prevBtnRB)
            [self adjustScreenDistBy:-0.12f];

        // View button alone in Mouse Mode toggles Head-Lock vs World 6DoF Lock
        if (btnView && !self.prevComboToggle && now >= self.nextNavRepeatAt)
        {
            self.nextNavRepeatAt = now + 0.30;
            self.headLockMode = !self.headLockMode;
            AudioServicesPlaySystemSound(1104);
            [self showBarToast:(self.headLockMode ? @"Kafa Takip Modu: ACIK" : @"Odaya Sabit 6DoF Modu")];
            [self redrawParsecBar];
        }
    }

    self.prevBtnA = btnA;
    self.prevBtnB = btnB;
    self.prevBtnX = btnX;
    self.prevBtnY = btnY;
    self.prevBtnLB = btnLB;
    self.prevBtnRB = btnRB;
    self.prevBtnMenu = btnMenu;
    self.prevDpadL = dpL;
    self.prevDpadR = dpR;
    self.prevDpadU = dpU;
    self.prevDpadD = dpD;
}

- (void)pushCursorUvToParsec
{
    int maxW = std::max(1, self.hostWidth - 1);
    int maxH = std::max(1, self.hostHeight - 1);
    int px = static_cast<int>(self.cursorUv.x * maxW);
    int py = static_cast<int>(self.cursorUv.y * maxH);
    if (px != self.lastMousePx || py != self.lastMousePy)
    {
        self.lastMousePx = px;
        self.lastMousePy = py;
        VRParsecSendStreamMousePosition(0, px, py);
    }

    SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
    self.parsecCursorNode.hidden = !self.parsecConnected || self.gamepadPassthroughMode;
    self.parsecCursorNode.position = SCNVector3Make((self.cursorUv.x - 0.5) * pl.width,
                                                    (0.5 - self.cursorUv.y) * pl.height,
                                                    0.015f);
}

#pragma mark - 120 Hz Frame Tick

- (void)onTick:(CADisplayLink *)link
{
    (void)link;
    CFTimeInterval now = CACurrentMediaTime();
    float dt = static_cast<float>(std::max(0.001, std::min(0.05, now - self.lastTickAt)));
    self.lastTickAt = now;

    if (self.headLockMode && self.parsecConnected)
    {
        SCNMatrix4 m = self.headNode.worldTransform;
        SCNVector3 headPos = SCNVector3Make(m.m41, m.m42, m.m43);
        SCNVector3 curPos = self.cinemaRootNode.position;
        self.cinemaRootNode.position = SCNVector3Make(curPos.x + (headPos.x - curPos.x) * 0.14f,
                                                      curPos.y + (headPos.y - curPos.y) * 0.14f,
                                                      curPos.z + (headPos.z - curPos.z) * 0.14f);
        float fx = -m.m31;
        float fz = -m.m33;
        float targetYaw = atan2f(-fx, -fz);
        float curYaw = self.cinemaRootNode.eulerAngles.y;
        float diff = targetYaw - curYaw;
        while (diff > M_PI) diff -= 2.0f * static_cast<float>(M_PI);
        while (diff < -M_PI) diff += 2.0f * static_cast<float>(M_PI);
        self.cinemaRootNode.eulerAngles = SCNVector3Make(0, curYaw + diff * 0.12f, 0);
    }

    [self pollXboxControllerAtTime:now dt:dt];
    [self updateParsecStream];

    if (self.barToastText != nil && now >= self.barToastUntil)
    {
        self.barToastText = nil;
        [self redrawParsecBar];
    }

    if (self.parsecConnected && now >= self.nextBarRedrawAt)
    {
        self.nextBarRedrawAt = now + 2.0;
        [self redrawParsecBar];
    }
}

#pragma mark - Fallback Gaze & Screen Touch Interaction

- (BOOL)isCandidateVisible:(SCNNode *)node
{
    if (!node || node.hidden || !node.geometry)
        return NO;
    for (SCNNode *p = node.parentNode; p != nil; p = p.parentNode)
    {
        if (p.hidden)
            return NO;
    }
    return YES;
}

- (void)testPlaneNode:(SCNNode *)node
            rayOrigin:(simd_float3)origin
               rayDir:(simd_float3)dir
              bestHit:(VRRayHit &)best
{
    if (![self isCandidateVisible:node])
        return;

    simd_float4x4 wt = node.simdWorldTransform;
    simd_float4x4 inv = simd_inverse(wt);
    simd_float4 lo = simd_mul(inv, simd_make_float4(origin.x, origin.y, origin.z, 1.0f));
    simd_float4 ld = simd_mul(inv, simd_make_float4(dir.x, dir.y, dir.z, 0.0f));
    if (fabsf(ld.z) < 1e-5f)
        return;

    float t = -lo.z / ld.z;
    if (t <= 0.02f || t > 14.0f)
        return;

    float hx = lo.x + t * ld.x;
    float hy = lo.y + t * ld.y;
    SCNPlane *pl = (SCNPlane *)node.geometry;
    if (fabsf(hx) > static_cast<float>(pl.width * 0.5) || fabsf(hy) > static_cast<float>(pl.height * 0.5))
        return;

    simd_float4 hw = simd_mul(wt, simd_make_float4(hx, hy, 0.0f, 1.0f));
    float dist = simd_length(hw.xyz - origin);
    if (dist < best.dist)
    {
        float u = std::max(0.0f, std::min(1.0f, hx / std::max(1e-4f, static_cast<float>(pl.width)) + 0.5f));
        float v = std::max(0.0f, std::min(1.0f, 0.5f - hy / std::max(1e-4f, static_cast<float>(pl.height))));
        best.node = node;
        best.uv = CGPointMake(u, v);
        best.dist = dist;
    }
}

- (VRRayHit)raycastOrigin:(SCNVector3)origin dir:(SCNVector3)dir
{
    VRRayHit best;
    simd_float3 o = simd_make_float3(origin.x, origin.y, origin.z);
    simd_float3 d = simd_make_float3(dir.x, dir.y, dir.z);
    [self testPlaneNode:self.parsecBarNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.parsecPanelNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.parsecScreenNode rayOrigin:o rayDir:d bestHit:best];
    return best;
}

- (VRRayHit)raycastCenterGaze
{
    simd_float4x4 hm = self.headNode.simdWorldTransform;
    simd_float4 wo = simd_mul(hm, simd_make_float4(0, 0, 0, 1));
    simd_float4 wd = simd_mul(hm, simd_make_float4(0, 0, -1, 0));
    simd_float3 d = simd_normalize(wd.xyz);
    return [self raycastOrigin:SCNVector3Make(wo.x, wo.y, wo.z) dir:SCNVector3Make(d.x, d.y, d.z)];
}

- (VRRayHit)raycastTouchPoint:(CGPoint)ptInView
{
    SCNView *targetView = (self.singleScreenTouchMode || ptInView.x <= self.view.bounds.size.width * 0.5)
        ? self.leftView
        : self.rightView;
    CGPoint localPt = [targetView convertPoint:ptInView fromView:self.view];
    SCNVector3 pNear = [targetView unprojectPoint:SCNVector3Make(localPt.x, localPt.y, 0.0f)];
    SCNVector3 pFar = [targetView unprojectPoint:SCNVector3Make(localPt.x, localPt.y, 1.0f)];
    float dx = pFar.x - pNear.x;
    float dy = pFar.y - pNear.y;
    float dz = pFar.z - pNear.z;
    float len = sqrtf(dx * dx + dy * dy + dz * dz);
    if (len < 1e-5f)
        return VRRayHit{};
    return [self raycastOrigin:pNear dir:SCNVector3Make(dx / len, dy / len, dz / len)];
}

- (NSString *)buttonAtUv:(CGPoint)uv inList:(const std::vector<VRButtonHit> &)list
{
    for (const auto &b : list)
    {
        if (!b.disabled && CGRectContainsPoint(b.uvRect, uv))
            return b.buttonId;
    }
    return nil;
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSSet<UITouch *> *all = event.allTouches;
    if (all.count >= 2)
    {
        CGFloat sy = 0.0;
        for (UITouch *t in all) sy += [t locationInView:self.view].y;
        self.isTwoFingerScrolling = YES;
        self.twoFingerScrollLastY = sy / all.count;
        return;
    }

    UITouch *touch = [touches anyObject];
    if (!touch) return;
    CGPoint pt = [touch locationInView:self.view];
    VRRayHit hit = [self raycastTouchPoint:pt];
    if (!hit.node && !self.singleScreenTouchMode)
        hit = [self raycastCenterGaze];
    if (!hit.node) return;

    if (hit.node == self.parsecScreenNode && self.parsecConnected)
    {
        self.cursorUv = hit.uv;
        [self pushCursorUvToParsec];
        self.heldMouseButton = 1;
        self.parsecMouseHeld = YES;
        VRParsecSendMouseButton(1, 1);
        return;
    }

    NSString *btnId = nil;
    if (hit.node == self.parsecPanelNode) btnId = [self buttonAtUv:hit.uv inList:_parsecPanelHits];
    else if (hit.node == self.parsecBarNode) btnId = [self buttonAtUv:hit.uv inList:_parsecBarHits];
    if (btnId)
    {
        AudioServicesPlaySystemSound(1104);
        [self handleButtonClick:btnId];
    }
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSSet<UITouch *> *all = event.allTouches;
    if (self.isTwoFingerScrolling && all.count >= 2)
    {
        CGFloat sy = 0.0;
        for (UITouch *t in all) sy += [t locationInView:self.view].y;
        CGFloat avgY = sy / all.count;
        CGFloat dy = avgY - self.twoFingerScrollLastY;
        if (fabs(dy) >= 2.0 && self.parsecConnected)
        {
            self.twoFingerScrollLastY = avgY;
            VRParsecSendMouseWheel(0, static_cast<int>(dy * 5.0));
        }
        return;
    }

    UITouch *touch = [touches anyObject];
    if (!touch || !self.parsecMouseHeld || !self.parsecConnected) return;
    VRRayHit hit = [self raycastTouchPoint:[touch locationInView:self.view]];
    if (hit.node == self.parsecScreenNode)
    {
        self.cursorUv = hit.uv;
        [self pushCursorUvToParsec];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (event.allTouches.count <= touches.count)
    {
        self.isTwoFingerScrolling = NO;
        if (self.parsecMouseHeld)
        {
            self.parsecMouseHeld = NO;
            VRParsecSendMouseButton(self.heldMouseButton, 0);
        }
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;
    self.isTwoFingerScrolling = NO;
    if (self.parsecMouseHeld)
    {
        self.parsecMouseHeld = NO;
        VRParsecSendMouseButton(self.heldMouseButton, 0);
    }
}

#pragma mark - UI Button Actions & Actions

- (void)handleButtonClick:(NSString *)btnId
{
    if ([btnId isEqualToString:@"auth_email"]) { self.loginField = LoginField::Email; [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"auth_pass"]) { self.loginField = LoginField::Password; [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"auth_tfa"]) { self.loginField = LoginField::Tfa; [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"auth_signin"]) { [self startParsecSignIn]; return; }
    if ([btnId isEqualToString:@"auth_setup"]) { [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"hosts_refresh"]) { [self refreshHosts]; return; }
    if ([btnId isEqualToString:@"hosts_signout"]) { [self signOutParsec]; return; }
    if ([btnId isEqualToString:@"connect_cancel"]) { [self cancelConnect]; return; }
    if ([btnId isEqualToString:@"ipd_minus"]) { [self adjustLensSpacingBy:-0.01f]; return; }
    if ([btnId isEqualToString:@"ipd_plus"]) { [self adjustLensSpacingBy:0.01f]; return; }

    if ([btnId hasPrefix:@"host_"])
    {
        NSInteger idx = [[btnId substringFromIndex:5] integerValue];
        [self connectToHostAtIndex:idx];
        return;
    }

    if ([btnId isEqualToString:@"bar_mode"]) { [self toggleGamepadMode]; return; }
    if ([btnId isEqualToString:@"bar_sz_minus"]) { [self adjustScreenScaleBy:-0.10f]; return; }
    if ([btnId isEqualToString:@"bar_sz_plus"]) { [self adjustScreenScaleBy:0.10f]; return; }
    if ([btnId isEqualToString:@"bar_ipd_minus"]) { [self adjustLensSpacingBy:-0.01f]; return; }
    if ([btnId isEqualToString:@"bar_ipd_plus"]) { [self adjustLensSpacingBy:0.01f]; return; }
    if ([btnId isEqualToString:@"bar_lock"])
    {
        self.headLockMode = !self.headLockMode;
        [self redrawParsecBar];
        return;
    }
    if ([btnId isEqualToString:@"bar_room"])
    {
        self.passthroughOn = !self.passthroughOn;
        if (!self.passthroughOn)
            self.scene.background.contents = [UIColor blackColor];
        [self redrawParsecBar];
        return;
    }
    if ([btnId isEqualToString:@"bar_mute"])
    {
        self.muted = !self.muted;
        VRParsecSetMuted(self.muted ? 1 : 0);
        [self redrawParsecBar];
        return;
    }
    if ([btnId isEqualToString:@"bar_recenter"])
    {
        [self recenterWorkspace];
        [self redrawParsecBar];
        return;
    }
    if ([btnId isEqualToString:@"bar_disc"])
    {
        [self disconnectParsec];
        return;
    }
}

- (void)recenterWorkspace
{
    SCNMatrix4 m = self.headNode.worldTransform;
    SCNVector3 pos = SCNVector3Make(m.m41, m.m42, m.m43);
    float fx = -m.m31;
    float fz = -m.m33;
    float yaw = atan2f(-fx, -fz);
    self.cinemaRootNode.position = pos;
    self.cinemaRootNode.eulerAngles = SCNVector3Make(0, yaw, 0);
}

- (void)applyWorkspaceVisibility
{
    self.parsecScreenNode.hidden = !self.parsecConnected;
    self.parsecBarNode.hidden = !self.parsecConnected;
    self.parsecPanelNode.hidden = self.parsecConnected;
    self.parsecCursorNode.hidden = !self.parsecConnected || self.gamepadPassthroughMode;
    [self updateStereoOrFullLayout];
}

#pragma mark - Parsec Stream & Auth

- (void)updateParsecStream
{
    if (!self.parsecConnecting && !self.parsecConnected)
        return;

    int hw = 1920, hh = 1080, netFail = 0;
    int st = VRParsecGetStatus(&hw, &hh, &netFail);
    if (hw > 0 && hh > 0 && (hw != self.hostWidth || hh != self.hostHeight))
    {
        self.hostWidth = hw;
        self.hostHeight = hh;
        [self applyScreenLayoutAndScale];
    }

    if (self.parsecConnecting)
    {
        if (st == 0)
        {
            self.parsecConnecting = NO;
            self.parsecConnected = YES;
            [self applyScreenLayoutAndScale];
            [self applyWorkspaceVisibility];
            [self pushCursorUvToParsec];
            [self redrawParsecBar];
        }
        else if (st == 6 || st == 20)
        {
            NSString *msg = FormatParsecStatus(st);
            if (![self.parsecStateMessage isEqualToString:msg])
            {
                self.parsecStateMessage = msg;
                self.parsecStateIsError = NO;
                [self redrawParsecPanel];
            }
        }
        else if (st != 10)
        {
            self.parsecConnecting = NO;
            VRParsecDisconnect();
            self.parsecStateMessage = [NSString stringWithFormat:@"Connection failed (%@). Press X or A to retry.", FormatParsecStatus(st)];
            self.parsecStateIsError = YES;
            [self redrawParsecPanel];
        }
        return;
    }

    if (self.parsecConnected)
    {
        if (st != 0 && st != 10)
        {
            self.parsecConnected = NO;
            self.gamepadPassthroughMode = NO;
            VRParsecDisconnect();
            self.parsecStateMessage = [NSString stringWithFormat:@"Disconnected (%@).", FormatParsecStatus(st)];
            self.parsecStateIsError = YES;
            [self applyWorkspaceVisibility];
            [self redrawParsecPanel];
            return;
        }
        int updated0 = 0;
        id tex0 = VRParsecPollStreamTexture(0, &updated0);
        if (updated0 && tex0)
            self.parsecScreenNode.geometry.firstMaterial.diffuse.contents = tex0;
    }
}

- (void)restoreSavedSession
{
    NSString *saved = VRKeychainLoad(kKeychainSessionKey);
    if (saved.length == 0)
        return;
    NSData *data = [saved dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *dict = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    NSString *sid = dict[@"session_id"];
    if ([sid isKindOfClass:[NSString class]] && sid.length > 0)
    {
        self.sessionId = sid;
        self.showsHostList = YES;
        [self refreshHosts];
    }
}

- (void)openQuickSetupAlert
{
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Parsec & VR Box Setup"
                                                                   message:@"Sign in once; saved in iOS Keychain. Adjust VR Box Goz Araligi anytime with Xbox D-Pad Left/Right."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Parsec Email";
        tf.text = self.emailText;
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Parsec Password";
        tf.text = self.passwordText;
        tf.secureTextEntry = YES;
    }];
    if (self.requiresTfa)
    {
        [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
            tf.placeholder = @"2FA Code";
            tf.text = self.tfaText;
            tf.keyboardType = UIKeyboardTypeNumberPad;
        }];
    }
    [alert addAction:[UIAlertAction actionWithTitle:@"VR Box Goz -" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        [self adjustLensSpacingBy:-0.015f];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"VR Box Goz +" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        [self adjustLensSpacingBy:0.015f];
    }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Sign In" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        self.emailText = alert.textFields[0].text ?: @"";
        self.passwordText = alert.textFields[1].text ?: @"";
        if (alert.textFields.count > 2)
            self.tfaText = alert.textFields[2].text ?: @"";
        [self startParsecSignIn];
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)startParsecSignIn
{
    if (self.isAuthBusy)
        return;
    if (self.emailText.length == 0 || self.passwordText.length == 0)
    {
        self.parsecStateMessage = @"Tap 'Parsec Setup' in top-left corner to sign in.";
        self.parsecStateIsError = YES;
        [self redrawParsecPanel];
        return;
    }

    self.isAuthBusy = YES;
    self.parsecStateMessage = @"Signing in to Parsec...";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];

    NSDictionary *payload = @{@"email": self.emailText, @"password": self.passwordText, @"tfa": self.tfaText ?: @""};
    NSData *body = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://kessel-api.parsec.app/v1/auth"]];
    req.HTTPMethod = @"POST";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:@"parsec/150-93b Windows/11 libmatoya/4.0" forHTTPHeaderField:@"User-Agent"];
    req.HTTPBody = body;

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isAuthBusy = NO;
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (err || !data)
            {
                self.parsecStateMessage = err.localizedDescription ?: @"Could not reach Parsec.";
                self.parsecStateIsError = YES;
                [self redrawParsecPanel];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (code == 201 && [json[@"session_id"] isKindOfClass:[NSString class]])
            {
                self.sessionId = json[@"session_id"];
                self.requiresTfa = NO;
                self.tfaText = @"";
                NSString *raw = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
                if (raw) VRKeychainSave(kKeychainSessionKey, raw.UTF8String);
                self.showsHostList = YES;
                self.selectedMenuIndex = 0;
                [self refreshHosts];
                return;
            }
            if ([json[@"tfa_required"] boolValue])
            {
                self.requiresTfa = YES;
                self.parsecStateMessage = @"2FA code required. Tap Parsec Setup top-left.";
                self.parsecStateIsError = NO;
                [self redrawParsecPanel];
                return;
            }
            self.parsecStateMessage = json[@"error"] ?: [NSString stringWithFormat:@"Login failed (HTTP %ld)", (long)code];
            self.parsecStateIsError = YES;
            [self redrawParsecPanel];
        });
    }] resume];
}

- (void)refreshHosts
{
    if (self.isHostsBusy || self.sessionId.length == 0)
        return;

    self.isHostsBusy = YES;
    self.parsecStateMessage = @"Fetching your online Parsec PCs...";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://kessel-api.parsec.app/v2/hosts?mode=desktop&public=false"]];
    req.HTTPMethod = @"GET";
    [req setValue:@"application/json" forHTTPHeaderField:@"Content-Type"];
    [req setValue:[NSString stringWithFormat:@"Bearer %@", self.sessionId] forHTTPHeaderField:@"Authorization"];
    [req setValue:@"parsec/150-93b Windows/11 libmatoya/4.0" forHTTPHeaderField:@"User-Agent"];

    [[[NSURLSession sharedSession] dataTaskWithRequest:req completionHandler:^(NSData *data, NSURLResponse *resp, NSError *err) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.isHostsBusy = NO;
            NSInteger code = [(NSHTTPURLResponse *)resp statusCode];
            if (code == 401)
            {
                [self signOutParsec];
                self.parsecStateMessage = @"Session expired. Sign in via Parsec Setup.";
                self.parsecStateIsError = YES;
                [self redrawParsecPanel];
                return;
            }
            if (err || !data || code != 200)
            {
                self.parsecStateMessage = err.localizedDescription ?: [NSString stringWithFormat:@"Failed to fetch hosts (HTTP %ld)", (long)code];
                self.parsecStateIsError = YES;
                [self redrawParsecPanel];
                return;
            }
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            NSArray *list = [json[@"data"] isKindOfClass:[NSArray class]] ? json[@"data"] : @[];
            self.hosts = list;
            self.selectedMenuIndex = 0;
            if (list.count == 0)
                self.parsecStateMessage = @"No online PC found. Start Parsec on your PC, press X to Refresh.";
            else
                self.parsecStateMessage = [NSString stringWithFormat:@"Select PC (%lu online) - Press A on Xbox Controller:", (unsigned long)list.count];
            self.parsecStateIsError = NO;
            [self redrawParsecPanel];
        });
    }] resume];
}

- (void)connectToHostAtIndex:(NSInteger)idx
{
    if (idx < 0 || idx >= (NSInteger)self.hosts.count)
        return;
    NSDictionary *host = self.hosts[(NSUInteger)idx];
    NSString *peerId = host[@"peer_id"] ?: @"";
    self.connectedHostName = [host[@"name"] length] > 0 ? host[@"name"] : peerId;

    int st = VRParsecConnect(self.sessionId.UTF8String, peerId.UTF8String, 1920, 1080, 0);
    if (st != 0 && st != 20)
    {
        self.parsecStateMessage = [NSString stringWithFormat:@"Could not connect (%@).", FormatParsecStatus(st)];
        self.parsecStateIsError = YES;
        [self redrawParsecPanel];
        return;
    }
    self.parsecConnecting = YES;
    self.parsecStateMessage = [NSString stringWithFormat:@"Connecting to %@...", self.connectedHostName];
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];
}

- (void)cancelConnect
{
    self.parsecConnecting = NO;
    VRParsecDisconnect();
    self.parsecStateMessage = @"Canceled. Pick a PC or press X to Refresh.";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];
}

- (void)disconnectParsec
{
    if (self.gamepadPassthroughMode)
    {
        VRParsecSendGamepadState(0, 0, 0, 0, 0, 0, 0);
        VRParsecUnplugGamepad();
    }
    self.gamepadPassthroughMode = NO;
    self.parsecMouseHeld = NO;
    self.parsecConnected = NO;
    self.parsecConnecting = NO;
    VRParsecDisconnect();
    self.parsecStateMessage = @"Disconnected. Pick a PC to reconnect.";
    self.parsecStateIsError = NO;
    [self applyWorkspaceVisibility];
    [self redrawParsecPanel];
}

- (void)signOutParsec
{
    if (self.gamepadPassthroughMode)
    {
        VRParsecSendGamepadState(0, 0, 0, 0, 0, 0, 0);
        VRParsecUnplugGamepad();
    }
    self.gamepadPassthroughMode = NO;
    self.sessionId = @"";
    self.hosts = @[];
    self.showsHostList = NO;
    self.parsecConnected = NO;
    self.parsecConnecting = NO;
    VRKeychainDelete(kKeychainSessionKey);
    self.parsecStateMessage = @"Signed out. Tap Parsec Setup top-left.";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];
}

#pragma mark - Canvas Rendering (Parsec Panel + Cinema HUD Bar)

- (void)redrawAllPanels
{
    [self redrawParsecPanel];
    [self redrawParsecBar];
}

- (void)drawButton:(CGRect)pxRect
            canvas:(CGSize)canvasSize
          buttonId:(NSString *)btnId
             title:(NSString *)title
          selected:(BOOL)selected
       xboxFocused:(BOOL)xboxFocused
          outlined:(BOOL)outlined
            filled:(BOOL)filled
          disabled:(BOOL)disabled
           hitList:(std::vector<VRButtonHit> &)hits
{
    UIColor *bg = ColorHex(0x3B3746);
    UIColor *fg = ColorHex(0xE8DEF8);
    if (filled || selected) { bg = ColorHex(0xD0BCFF); fg = ColorHex(0x2F1665); }
    else if (outlined) { bg = ColorHex(0x25232A); fg = ColorHex(0xE6E0E9); }
    if (disabled)
    {
        bg = ColorHex(0x2C2A31, 0.55);
        fg = ColorHex(0x938F99);
    }

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:pxRect cornerRadius:MIN(14.0, pxRect.size.height * 0.42)];
    [bg setFill];
    [path fill];

    if (xboxFocused)
    {
        [ColorHex(0x5EEAD4) setStroke];
        path.lineWidth = 4.0;
        [path stroke];
    }
    else if (outlined)
    {
        [ColorHex(0x888392) setStroke];
        path.lineWidth = 1.5;
        [path stroke];
    }

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:MAX(16.0, MIN(26.0, pxRect.size.height * 0.36)) weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: ps
    };
    CGSize tSz = [title sizeWithAttributes:attrs];
    CGRect tRect = CGRectMake(pxRect.origin.x + 10, pxRect.origin.y + (pxRect.size.height - tSz.height) * 0.5, pxRect.size.width - 20, tSz.height);
    [title drawInRect:tRect withAttributes:attrs];

    CGRect uv = CGRectMake(pxRect.origin.x / canvasSize.width,
                           pxRect.origin.y / canvasSize.height,
                           pxRect.size.width / canvasSize.width,
                           pxRect.size.height / canvasSize.height);
    hits.push_back({uv, btnId, title, selected, disabled});
}

- (void)drawText:(NSString *)text rect:(CGRect)rect size:(CGFloat)size color:(UIColor *)color bold:(BOOL)bold align:(NSTextAlignment)align
{
    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = align;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:size weight:(bold ? UIFontWeightSemibold : UIFontWeightRegular)],
        NSForegroundColorAttributeName: color,
        NSParagraphStyleAttributeName: ps
    };
    [text drawInRect:rect withAttributes:attrs];
}

- (void)redrawParsecPanel
{
    _parsecPanelHits.clear();
    CGSize sz = CGSizeMake(960, 680);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    NSString *ctrlText = self.activeController
        ? [NSString stringWithFormat:@"Xbox Kolu: BAGLI (%@)", self.activeController.vendorName ?: @"Gamepad"]
        : @"Xbox Kolu: Bekleniyor (Bluetooth ile eslestir)";
    UIColor *ctrlColor = self.activeController ? ColorHex(0x80E5A3) : ColorHex(0xF6C177);

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x1D1B22, 0.96) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:34] fill];

        [self drawText:@"VR Box Parsec Cinema" rect:CGRectMake(40, 26, 520, 42) size:32 color:ColorHex(0xE6E0E9) bold:YES align:NSTextAlignmentLeft];
        [self drawText:ctrlText rect:CGRectMake(40, 72, 880, 28) size:19 color:ctrlColor bold:YES align:NSTextAlignmentLeft];
        [self drawText:self.parsecStateMessage rect:CGRectMake(40, 108, 880, 48) size:20
                 color:(self.parsecStateIsError ? ColorHex(0xF2B8B5) : ColorHex(0xCAC4D0)) bold:NO align:NSTextAlignmentLeft];

        auto idxFocus = ^BOOL(NSInteger expectedIdx) {
            return (self.selectedMenuIndex == expectedIdx);
        };

        if (self.parsecConnecting)
        {
            [self drawButton:CGRectMake(320, 300, 320, 72) canvas:sz buttonId:@"connect_cancel" title:@"Cancel Connection (B)"
                    selected:NO xboxFocused:idxFocus(0) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }
        else if (self.showsHostList)
        {
            NSInteger itemIdx = 0;
            NSUInteger count = MIN((NSUInteger)4, self.hosts.count);
            for (NSUInteger i = 0; i < count; ++i)
            {
                NSDictionary *h = self.hosts[i];
                NSString *hName = [h[@"name"] length] > 0 ? h[@"name"] : (h[@"peer_id"] ?: @"PC");
                NSString *owner = [h[@"user"] isKindOfClass:[NSDictionary class]] ? (h[@"user"][@"name"] ?: @"Host") : @"Host";
                NSString *label = [NSString stringWithFormat:@"%@  (%@)", hName, owner];
                [self drawButton:CGRectMake(44, 170 + i * 74, 872, 62) canvas:sz
                        buttonId:[NSString stringWithFormat:@"host_%lu", (unsigned long)i]
                           title:label selected:NO xboxFocused:idxFocus(itemIdx++) outlined:NO filled:(i == 0) disabled:NO hitList:_parsecPanelHits];
            }
            [self drawButton:CGRectMake(44, 486, 260, 62) canvas:sz buttonId:@"hosts_refresh" title:@"Refresh PCs (X)"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:self.isHostsBusy hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(330, 486, 190, 62) canvas:sz buttonId:@"ipd_minus"
                       title:[NSString stringWithFormat:@"Goz - (%.0f%%)", self.lensSpacingRatio * 100.0f]
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(534, 486, 176, 62) canvas:sz buttonId:@"ipd_plus" title:@"Goz +"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(726, 486, 190, 62) canvas:sz buttonId:@"hosts_signout" title:@"Sign Out"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }
        else
        {
            NSInteger itemIdx = 0;
            [self drawButton:CGRectMake(44, 180, 872, 74) canvas:sz buttonId:@"auth_setup"
                       title:@"Tap Top-Left 'Parsec Setup' on iPhone to Sign In"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:NO filled:YES disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(44, 280, 420, 68) canvas:sz buttonId:@"ipd_minus"
                       title:[NSString stringWithFormat:@"VR Box Goz Araligi - (%.0f%%)", self.lensSpacingRatio * 100.0f]
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(496, 280, 420, 68) canvas:sz buttonId:@"ipd_plus" title:@"VR Box Goz Araligi +"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }

        [self drawText:@"Xbox Kontrol: D-Pad Up/Dn: Sec | A: Baglan | X: Yenile | D-Pad L/R: VR Box Goz Birlestir | Y: Ortala"
                  rect:CGRectMake(40, 616, 880, 34) size:18 color:ColorHex(0xA9A3B5) bold:YES align:NSTextAlignmentCenter];
    }];
    self.parsecPanelNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawParsecBar
{
    _parsecBarHits.clear();
    CGSize sz = CGSizeMake(1400, 186);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];

    NSString *modeLabel = self.gamepadPassthroughMode
        ? @"MOD: XBOX OYUN KOLU (View+Menu = Fare)"
        : @"MOD: FARE / MASAUSTU (Menu = Oyun Kolu)";
    NSString *statusLine = (self.barToastText.length > 0)
        ? self.barToastText
        : [NSString stringWithFormat:@"%@ (%dx%d)  |  %@  |  Goz: %.0f%%  Boyut: %.0f%%",
           self.connectedHostName, self.hostWidth, self.hostHeight,
           (self.activeController ? @"Xbox Bagli" : @"Xbox Yok"),
           self.lensSpacingRatio * 100.0f, self.screenScale * 100.0f];
    NSString *hintLine = self.gamepadPassthroughMode
        ? @"Tam Xbox 360 Kolu PC'ye Aktariliyor!  |  View basili tut + [Menu: Fare Modu | Y: Ortala | D-Pad L/R: VR Box Goz | D-Pad U/D: Boyut]"
        : @"L-Stick: Fare | A: Sol Tik/Surukle | B: Sag Tik | X: Cift Tik | R-Stick: Kaydir | Y: Ortala | D-Pad L/R: Goz | D-Pad U/D: Boyut | LB/RB: Mesafe";

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x1D1B22, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:28] fill];

        UIColor *topColor = (self.barToastText.length > 0) ? ColorHex(0x80E5A3) : ColorHex(0xE6E0E9);
        [self drawText:statusLine rect:CGRectMake(26, 16, 1348, 30) size:22 color:topColor bold:YES align:NSTextAlignmentLeft];

        [self drawButton:CGRectMake(24, 56, 400, 58) canvas:sz buttonId:@"bar_mode" title:modeLabel
                selected:self.gamepadPassthroughMode xboxFocused:NO outlined:NO filled:YES disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(436, 56, 114, 58) canvas:sz buttonId:@"bar_ipd_minus" title:@"Goz -"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(560, 56, 114, 58) canvas:sz buttonId:@"bar_ipd_plus" title:@"Goz +"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(686, 56, 118, 58) canvas:sz buttonId:@"bar_sz_minus" title:@"Boyut -"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(814, 56, 118, 58) canvas:sz buttonId:@"bar_sz_plus" title:@"Boyut +"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(944, 56, 146, 58) canvas:sz buttonId:@"bar_lock"
                   title:(self.headLockMode ? @"Kafa Takip" : @"6DoF Sabit")
                selected:self.headLockMode xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(1102, 56, 134, 58) canvas:sz buttonId:@"bar_room"
                   title:(self.passthroughOn ? @"Kamera" : @"Siyah")
                selected:self.passthroughOn xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(1248, 56, 128, 58) canvas:sz buttonId:@"bar_disc" title:@"Kes"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];

        [self drawText:hintLine rect:CGRectMake(26, 132, 1348, 34) size:17 color:ColorHex(0xA9A3B5) bold:YES align:NSTextAlignmentCenter];
    }];
    self.parsecBarNode.geometry.firstMaterial.diffuse.contents = img;
}

@end
