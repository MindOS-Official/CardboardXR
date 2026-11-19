// Native iOS stereoscopic VR cockpit combining ARKit 6DoF tracking, Vision hand pinch
// tracking, SceneKit dual-eye rendering, Parsec dual-stream PC desktop, 5 giant placeable
// WebKit/PC-2 side monitors, and a 3D Air Keyboard.

#import "VRWorkspaceViewController.h"
#import "VRBridge.h"
#import <ARKit/ARKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <SceneKit/SceneKit.h>
#import <Vision/Vision.h>
#include <algorithm>
#include <cmath>
#include <vector>

namespace
{
    constexpr float kEyeSeparation = 0.063f;
    constexpr float kParsecDist = 1.35f;
    constexpr float kSideMonitorDist = 1.40f;
    constexpr float kKeyboardDist = 0.68f;
    constexpr float kKeyboardPitchDeg = -26.0f;
    constexpr CFTimeInterval kHandDwellSeconds = 0.18;
    constexpr CFTimeInterval kScreenDwellSeconds = 0.30;
    constexpr int kHandJointCount = 21;
    constexpr int kHandBoneCount = 20;
    constexpr const char *kKeychainSessionKey = "cardboardxr_native_parsec_session_v1";

    constexpr int kHandBonePairs[kHandBoneCount][2] = {
        {0, 1}, {1, 2}, {2, 3}, {3, 4},
        {0, 5}, {5, 6}, {6, 7}, {7, 8},
        {0, 9}, {9, 10}, {10, 11}, {11, 12},
        {0, 13}, {13, 14}, {14, 15}, {15, 16},
        {0, 17}, {17, 18}, {18, 19}, {19, 20},
    };

    NSArray<VNHumanHandPoseObservationJointName> *OrderedHandJointNames()
    {
        static NSArray<VNHumanHandPoseObservationJointName> *names = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            names = @[
                VNHumanHandPoseObservationJointNameWrist,
                VNHumanHandPoseObservationJointNameThumbCMC,
                VNHumanHandPoseObservationJointNameThumbMP,
                VNHumanHandPoseObservationJointNameThumbIP,
                VNHumanHandPoseObservationJointNameThumbTip,
                VNHumanHandPoseObservationJointNameIndexMCP,
                VNHumanHandPoseObservationJointNameIndexPIP,
                VNHumanHandPoseObservationJointNameIndexDIP,
                VNHumanHandPoseObservationJointNameIndexTip,
                VNHumanHandPoseObservationJointNameMiddleMCP,
                VNHumanHandPoseObservationJointNameMiddlePIP,
                VNHumanHandPoseObservationJointNameMiddleDIP,
                VNHumanHandPoseObservationJointNameMiddleTip,
                VNHumanHandPoseObservationJointNameRingMCP,
                VNHumanHandPoseObservationJointNameRingPIP,
                VNHumanHandPoseObservationJointNameRingDIP,
                VNHumanHandPoseObservationJointNameRingTip,
                VNHumanHandPoseObservationJointNameLittleMCP,
                VNHumanHandPoseObservationJointNameLittlePIP,
                VNHumanHandPoseObservationJointNameLittleDIP,
                VNHumanHandPoseObservationJointNameLittleTip,
            ];
        });
        return names;
    }

    struct VRRayHit
    {
        SCNNode *node = nil;
        CGPoint uv = CGPointZero;
        float dist = 1e9f;
        SCNVector3 worldPoint = SCNVector3Zero;
    };

    enum class InputTarget
    {
        ParsecEmail,
        ParsecPassword,
        ParsecTfa,
        WebUrl,
        ParsecHost,
        WebPage,
    };

    struct KeySpec
    {
        const char *normal;
        const char *shift;
        float units;
        int usbHid;
    };

    struct VRButtonHit
    {
        CGRect uvRect;
        NSString *buttonId;
        NSString *label;
        BOOL selected;
        BOOL disabled;
    };

    struct SideMonitorSlot
    {
        int index = 0;
        BOOL active = NO;
        BOOL useParsecStream2 = NO;
        BOOL urlEditing = NO;
        float defaultYawDeg = 0.0f;
        float defaultPitchDeg = 0.0f;
        float defaultDist = kSideMonitorDist;
        SCNNode *anchorNode = nil;
        SCNNode *screenNode = nil;
        SCNNode *barNode = nil;
        SCNNode *grabNode = nil;
        SCNNode *cursorNode = nil;
        NSString *urlText = nil;
        std::vector<VRButtonHit> barHits;
    };

    int MapCharToUsbHid(char c, BOOL *outShift)
    {
        *outShift = NO;
        if (c >= 'a' && c <= 'z') return 4 + (c - 'a');
        if (c >= 'A' && c <= 'Z') { *outShift = YES; return 4 + (c - 'A'); }
        if (c >= '1' && c <= '9') return 30 + (c - '1');
        if (c == '0') return 39;
        switch (c)
        {
            case ' ': return 44;
            case '\n': case '\r': return 40;
            case '\t': return 43;
            case '-': return 45;
            case '_': *outShift = YES; return 45;
            case '=': return 46;
            case '+': *outShift = YES; return 46;
            case '[': return 47;
            case '{': *outShift = YES; return 47;
            case ']': return 48;
            case '}': *outShift = YES; return 48;
            case '\\': return 49;
            case '|': *outShift = YES; return 49;
            case ';': return 51;
            case ':': *outShift = YES; return 51;
            case '\'': return 52;
            case '"': *outShift = YES; return 52;
            case '`': return 53;
            case '~': *outShift = YES; return 53;
            case ',': return 54;
            case '<': *outShift = YES; return 54;
            case '.': return 55;
            case '>': *outShift = YES; return 55;
            case '/': return 56;
            case '?': *outShift = YES; return 56;
            case '!': *outShift = YES; return 30;
            case '@': *outShift = YES; return 31;
            case '#': *outShift = YES; return 32;
            case '$': *outShift = YES; return 33;
            case '%': *outShift = YES; return 34;
            case '^': *outShift = YES; return 35;
            case '&': *outShift = YES; return 36;
            case '*': *outShift = YES; return 37;
            case '(': *outShift = YES; return 38;
            case ')': *outShift = YES; return 39;
            default: return 0;
        }
    }

    UIColor *ColorHex(uint32_t rgb, CGFloat alpha = 1.0)
    {
        return [UIColor colorWithRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0
                               alpha:alpha];
    }

    NSString *FormatParsecStatus(int st)
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
}

@interface VRWorkspaceViewController () <ARSessionDelegate>
@property (nonatomic, strong) ARSession *arSession;
@property (nonatomic, strong) SCNScene *scene;
@property (nonatomic, strong) SCNView *leftView;
@property (nonatomic, strong) SCNView *rightView;
@property (nonatomic, strong) SCNNode *headNode;
@property (nonatomic, strong) SCNNode *leftEyeNode;
@property (nonatomic, strong) SCNNode *rightEyeNode;
@property (nonatomic, strong) SCNNode *workspaceRoot;
@property (nonatomic, strong) SCNNode *floorNode;

@property (nonatomic, strong) SCNNode *mainAnchorNode;
@property (nonatomic, strong) SCNNode *parsecScreenNode;
@property (nonatomic, strong) SCNNode *parsecPanelNode;
@property (nonatomic, strong) SCNNode *parsecBarNode;
@property (nonatomic, strong) SCNNode *dockNode;
@property (nonatomic, strong) SCNNode *keyboardNode;
@property (nonatomic, strong) SCNNode *parsecCursorNode;
@property (nonatomic, strong) SCNNode *palmMenuNode;
@property (nonatomic, strong) SCNNode *mainGrabNode;
@property (nonatomic, strong) SCNNode *keyboardGrabNode;
@property (nonatomic, strong) SCNNode *dockGrabNode;
@property (nonatomic, strong) SCNNode *hoverHighlightNode;
@property (nonatomic, strong) SCNNode *handRayNode;
@property (nonatomic, strong) SCNMaterial *indexTipMat;

@property (nonatomic, strong) UIView *leftReticle;
@property (nonatomic, strong) UIView *rightReticle;
@property (nonatomic, strong) UIButton *quickSetupButton;
@property (nonatomic, strong) UIButton *viewModeButton;
@property (nonatomic, strong) CADisplayLink *displayLink;
@property (nonatomic, strong) CIContext *ciContext;
@property (nonatomic, strong) dispatch_queue_t visionQueue;
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

@property (nonatomic, assign) InputTarget inputTarget;
@property (nonatomic, assign) int activeSideSlot;
@property (nonatomic, assign) int screenSizePreset; // 0 = Big (1.15x), 1 = Giant (1.50x), 2 = IMAX (1.90x)
@property (nonatomic, assign) int movingMonitorIndex; // -2 = none, -1 = main PC, 0..4 = side slot
@property (nonatomic, assign) BOOL passthroughOn;
@property (nonatomic, assign) BOOL singleScreenTouchMode;
@property (nonatomic, assign) BOOL keyboardVisible;
@property (nonatomic, assign) BOOL rightClickArmed;
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, assign) BOOL shiftOn;
@property (nonatomic, assign) BOOL ctrlOn;
@property (nonatomic, assign) BOOL altOn;
@property (nonatomic, assign) BOOL winOn;
@property (nonatomic, assign) BOOL handAimEnabled;

@property (nonatomic, copy) NSString *hoveredNodeKey;
@property (nonatomic, copy) NSString *hoveredButtonId;
@property (nonatomic, copy) NSString *flashedButtonId;
@property (nonatomic, copy) NSString *dwellButtonId;
@property (nonatomic, assign) CFTimeInterval dwellStartAt;
@property (nonatomic, assign) BOOL dwellFiredForHover;
@property (nonatomic, assign) CFTimeInterval flashUntil;
@property (nonatomic, assign) CFTimeInterval nextWebSnapshotAt;
@property (nonatomic, assign) CFTimeInterval nextPassthroughAt;
@property (nonatomic, assign) CFTimeInterval nextVisionAt;
@property (nonatomic, assign) CFTimeInterval lastPinchClickAt;

@property (nonatomic, assign) BOOL passthroughBusy;
@property (nonatomic, assign) BOOL visionBusy;
@property (nonatomic, assign) BOOL handTracked;
@property (nonatomic, assign) BOOL pinchClosed;
@property (nonatomic, assign) BOOL fingerPoking;
@property (nonatomic, assign) BOOL fingerPokePending;
@property (nonatomic, assign) CGPoint smoothedHandAim;
@property (nonatomic, assign) int screenDwellPx;
@property (nonatomic, assign) int screenDwellPy;
@property (nonatomic, assign) CFTimeInterval screenDwellStartAt;
@property (nonatomic, assign) BOOL screenDwellFired;
@property (nonatomic, copy) NSString *screenDwellNodeName;
@property (nonatomic, assign) BOOL parsecMouseHeld;
@property (nonatomic, assign) int heldParsecButton;
@property (nonatomic, assign) BOOL isTwoFingerScrolling;
@property (nonatomic, assign) CGFloat twoFingerScrollLastY;
@property (nonatomic, assign) int lastMousePx;
@property (nonatomic, assign) int lastMousePy;
@property (nonatomic, assign) BOOL hasRecenteredOnce;
@property (nonatomic, assign) int lastFocusedTargetIndex;
@property (nonatomic, assign) BOOL palmOpenNow;
@property (nonatomic, assign) CFTimeInterval palmFacingSince;
@property (nonatomic, assign) CFTimeInterval palmMenuVisibleUntil;
@property (nonatomic, assign) float grabBaseDistance;
@property (nonatomic, assign) float grabInitialHandDepth;
@property (nonatomic, assign) CFTimeInterval grabStartedAt;
@property (nonatomic, assign) SCNVector3 grabSteadyPos;
@property (nonatomic, assign) CFTimeInterval grabSteadySince;
@property (nonatomic, assign) BOOL grabHasMovedSignificantly;
@end

@implementation VRWorkspaceViewController
{
    std::vector<VRButtonHit> _parsecPanelHits;
    std::vector<VRButtonHit> _parsecBarHits;
    std::vector<VRButtonHit> _dockHits;
    std::vector<VRButtonHit> _keyboardHits;
    std::vector<VRButtonHit> _palmMenuHits;
    SideMonitorSlot _sideSlots[kMaxWebMonitors];
    SCNNode *_handJointNodes[kHandJointCount];
    SCNNode *_handBoneNodes[kHandBoneCount];
    SCNVector3 _targetHandJoints[kHandJointCount];
    SCNVector3 _currentHandJoints[kHandJointCount];
    float _targetHandDepth;
    float _restingHandDepth;
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
    self.parsecStateMessage = @"Sign in with your Parsec account or tap Parsec Setup.";
    self.inputTarget = InputTarget::ParsecEmail;
    self.activeSideSlot = 0;
    self.screenSizePreset = 1; // Default to Giant monitors.
    self.movingMonitorIndex = -2;
    self.passthroughOn = YES; // GPU Metal passthrough active at startup so user sees their room.
    self.handAimEnabled = YES; // Visible 3D hand + fingertip poke/dwell enabled at startup.
    self.singleScreenTouchMode = NO;
    self.keyboardVisible = YES;
    self.hosts = @[];
    self.hostWidth = 1920;
    self.hostHeight = 1080;
    self.lastFocusedTargetIndex = -1;
    self.grabBaseDistance = kParsecDist;
    self.heldParsecButton = 1;
    self.lastMousePx = -1;
    self.lastMousePy = -1;

    self.ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    self.visionQueue = dispatch_queue_create("com.brenpoly.cardboardxr.vision", DISPATCH_QUEUE_SERIAL);
    self.passthroughQueue = dispatch_queue_create("com.brenpoly.cardboardxr.passthrough", DISPATCH_QUEUE_SERIAL);

    [self setupSceneAndStereoViews];
    [self buildWorkspaceNodes];
    [self setupGestureAndOverlay];
    [self setupArSession];

    VRParsecInit();

    [self restoreSavedSession];
    [self applyMonitorSizes];
    [self applyWorkspaceVisibility];
    [self redrawAllUiPanels];

    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
    if (@available(iOS 15.0, *))
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    [self updateStereoOrFullLayout];
}

- (void)updateStereoOrFullLayout
{
    CGRect bounds = self.view.bounds;
    if (self.singleScreenTouchMode)
    {
        self.leftView.frame = bounds;
        self.rightView.hidden = YES;
        self.rightView.rendersContinuously = NO;
        self.leftReticle.hidden = YES;
        self.rightReticle.hidden = YES;
        return;
    }

    self.rightView.hidden = NO;
    self.rightView.rendersContinuously = YES;
    self.leftReticle.hidden = NO;
    self.rightReticle.hidden = NO;

    CGFloat halfW = bounds.size.width * 0.5;
    self.leftView.frame = CGRectMake(0, 0, halfW - 1.0, bounds.size.height);
    self.rightView.frame = CGRectMake(halfW + 1.0, 0, halfW - 1.0, bounds.size.height);

    CGFloat rSize = 10.0;
    self.leftReticle.center = CGPointMake(halfW * 0.5, bounds.size.height * 0.5);
    self.leftReticle.bounds = CGRectMake(0, 0, rSize, rSize);
    self.rightReticle.center = CGPointMake(halfW + halfW * 0.5, bounds.size.height * 0.5);
    self.rightReticle.bounds = CGRectMake(0, 0, rSize, rSize);
}

- (void)dealloc
{
    [self.displayLink invalidate];
    [self.arSession pause];
    VRParsecDisconnect();
    VRWebDestroyAll();
}

- (void)setupSceneAndStereoViews
{
    self.scene = [SCNScene scene];
    self.scene.background.contents = ColorHex(0x141218);

    self.headNode = [SCNNode node];
    [self.scene.rootNode addChildNode:self.headNode];

    SCNCamera *leftCam = [SCNCamera camera];
    leftCam.zNear = 0.05;
    leftCam.zFar = 60.0;
    leftCam.fieldOfView = 76.0;
    self.leftEyeNode = [SCNNode node];
    self.leftEyeNode.camera = leftCam;
    self.leftEyeNode.position = SCNVector3Make(-kEyeSeparation * 0.5f, 0, 0);
    [self.headNode addChildNode:self.leftEyeNode];

    SCNCamera *rightCam = [SCNCamera camera];
    rightCam.zNear = 0.05;
    rightCam.zFar = 60.0;
    rightCam.fieldOfView = 76.0;
    self.rightEyeNode = [SCNNode node];
    self.rightEyeNode.camera = rightCam;
    self.rightEyeNode.position = SCNVector3Make(kEyeSeparation * 0.5f, 0, 0);
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

- (UIImage *)createFloorGridImage
{
    CGSize sz = CGSizeMake(256, 256);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [ColorHex(0x0E1018) setFill];
        [ctx fillRect:CGRectMake(0, 0, 256, 256)];
        [ColorHex(0x374B6E) setFill];
        [ctx fillRect:CGRectMake(0, 0, 256, 4)];
        [ctx fillRect:CGRectMake(0, 0, 4, 256)];
    }];
}

- (void)buildWorkspaceNodes
{
    self.workspaceRoot = [SCNNode node];
    [self.scene.rootNode addChildNode:self.workspaceRoot];

    SCNPlane *floorGeo = [SCNPlane planeWithWidth:16.0 height:16.0];
    SCNMaterial *floorMat = [SCNMaterial material];
    floorMat.lightingModelName = SCNLightingModelConstant;
    floorMat.diffuse.contents = [self createFloorGridImage];
    floorMat.diffuse.wrapS = SCNWrapModeRepeat;
    floorMat.diffuse.wrapT = SCNWrapModeRepeat;
    floorMat.diffuse.contentsTransform = SCNMatrix4MakeScale(16, 16, 1);
    floorGeo.materials = @[floorMat];
    self.floorNode = [SCNNode nodeWithGeometry:floorGeo];
    self.floorNode.position = SCNVector3Make(0, -1.6f, 0);
    self.floorNode.eulerAngles = SCNVector3Make(-M_PI_2, 0, 0);
    self.floorNode.hidden = self.passthroughOn;
    [self.workspaceRoot addChildNode:self.floorNode];

    self.mainAnchorNode = [SCNNode node];
    self.mainAnchorNode.position = SCNVector3Make(0, 0.42f, -kParsecDist);
    self.mainAnchorNode.eulerAngles = SCNVector3Make(4.0f * M_PI / 180.0f, 0, 0);
    [self.workspaceRoot addChildNode:self.mainAnchorNode];

    self.parsecScreenNode = [self makePlaneNode:@"parsec_screen" width:2.20 height:1.24 color:ColorHex(0x18171D)];
    [self.mainAnchorNode addChildNode:self.parsecScreenNode];

    self.parsecPanelNode = [self makePlaneNode:@"parsec_panel" width:1.28 height:0.84 color:ColorHex(0x211F26)];
    [self.mainAnchorNode addChildNode:self.parsecPanelNode];

    self.parsecBarNode = [self makePlaneNode:@"parsec_bar" width:1.60 height:0.16 color:ColorHex(0x211F26)];
    self.parsecBarNode.position = SCNVector3Make(0, 0.72f, 0.01f);
    [self.mainAnchorNode addChildNode:self.parsecBarNode];

    self.mainGrabNode = [self makePlaneNode:@"grab_main" width:0.76 height:0.09 color:ColorHex(0x4A4458)];
    self.mainGrabNode.position = SCNVector3Make(0, -0.69f, 0.01f);
    [self.mainAnchorNode addChildNode:self.mainGrabNode];

    self.keyboardNode = [self makePlaneNode:@"keyboard" width:0.84 height:0.35 color:ColorHex(0x211F26)];
    self.keyboardNode.position = SCNVector3Make(0, -0.48f, -kKeyboardDist);
    self.keyboardNode.eulerAngles = SCNVector3Make(kKeyboardPitchDeg * M_PI / 180.0f, 0, 0);
    [self.workspaceRoot addChildNode:self.keyboardNode];

    self.keyboardGrabNode = [self makePlaneNode:@"grab_kb" width:0.42 height:0.055 color:ColorHex(0x4A4458)];
    self.keyboardGrabNode.position = SCNVector3Make(0, 0.21f, 0.005f);
    [self.keyboardNode addChildNode:self.keyboardGrabNode];

    self.dockNode = [self makePlaneNode:@"dock" width:1.20 height:0.18 color:ColorHex(0x211F26)];
    self.dockNode.position = SCNVector3Make(0, -0.78f, -0.62f);
    self.dockNode.eulerAngles = SCNVector3Make(-34.0f * M_PI / 180.0f, 0, 0);
    [self.workspaceRoot addChildNode:self.dockNode];

    self.dockGrabNode = [self makePlaneNode:@"grab_dock" width:0.42 height:0.05 color:ColorHex(0x4A4458)];
    self.dockGrabNode.position = SCNVector3Make(0, 0.125f, 0.005f);
    [self.dockNode addChildNode:self.dockGrabNode];

    self.palmMenuNode = [self makePlaneNode:@"palm_menu" width:0.42 height:0.26 color:ColorHex(0x211F26)];
    self.palmMenuNode.renderingOrder = 30;
    self.palmMenuNode.hidden = YES;
    [self.headNode addChildNode:self.palmMenuNode];

    SCNPlane *hoverPlane = [SCNPlane planeWithWidth:1.0 height:1.0];
    hoverPlane.cornerRadius = 0.08;
    SCNMaterial *hoverMat = [SCNMaterial material];
    hoverMat.lightingModelName = SCNLightingModelConstant;
    hoverMat.diffuse.contents = ColorHex(0xD0BCFF, 0.28);
    hoverMat.writesToDepthBuffer = NO;
    hoverPlane.materials = @[hoverMat];
    self.hoverHighlightNode = [SCNNode nodeWithGeometry:hoverPlane];
    self.hoverHighlightNode.renderingOrder = 10;
    self.hoverHighlightNode.hidden = YES;

    SCNSphere *cGeo = [SCNSphere sphereWithRadius:0.014];
    SCNMaterial *cMat = [SCNMaterial material];
    cMat.lightingModelName = SCNLightingModelConstant;
    cMat.diffuse.contents = ColorHex(0xD0BCFF);
    cGeo.materials = @[cMat];
    self.parsecCursorNode = [SCNNode nodeWithGeometry:cGeo];
    self.parsecCursorNode.hidden = YES;
    [self.parsecScreenNode addChildNode:self.parsecCursorNode];

    struct SlotDefaults { float yawDeg; float pitchDeg; float dist; BOOL startOn; const char *url; };
    const SlotDefaults defs[kMaxWebMonitors] = {
        {-54.0f,  4.0f, 1.40f, NO, "https://www.youtube.com"},
        { 54.0f,  4.0f, 1.40f, NO, "https://duckduckgo.com"},
        {  0.0f, 34.0f, 1.44f, NO, "https://discord.com/app"},
        {-96.0f,  4.0f, 1.40f, NO, "https://chatgpt.com"},
        { 96.0f,  4.0f, 1.40f, NO, "https://github.com"},
    };

    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        SideMonitorSlot &slot = _sideSlots[i];
        slot.index = i;
        slot.active = defs[i].startOn;
        slot.useParsecStream2 = NO;
        slot.defaultYawDeg = defs[i].yawDeg;
        slot.defaultPitchDeg = defs[i].pitchDeg;
        slot.defaultDist = defs[i].dist;
        slot.urlText = [NSString stringWithUTF8String:defs[i].url];

        slot.anchorNode = [SCNNode node];
        [self.workspaceRoot addChildNode:slot.anchorNode];

        slot.screenNode = [self makePlaneNode:[NSString stringWithFormat:@"side_screen_%d", i]
                                        width:1.80 height:1.08 color:ColorHex(0x18171D)];
        [slot.anchorNode addChildNode:slot.screenNode];

        slot.barNode = [self makePlaneNode:[NSString stringWithFormat:@"side_bar_%d", i]
                                     width:1.80 height:0.24 color:ColorHex(0x211F26)];
        slot.barNode.position = SCNVector3Make(0, 0.68f, 0.01f);
        [slot.anchorNode addChildNode:slot.barNode];

        slot.grabNode = [self makePlaneNode:[NSString stringWithFormat:@"grab_side_%d", i]
                                      width:0.64 height:0.08 color:ColorHex(0x4A4458)];
        slot.grabNode.position = SCNVector3Make(0, -0.61f, 0.01f);
        [slot.anchorNode addChildNode:slot.grabNode];

        slot.cursorNode = [SCNNode nodeWithGeometry:cGeo];
        slot.cursorNode.hidden = YES;
        [slot.screenNode addChildNode:slot.cursorNode];

        [self resetSideSlotPose:i];
    }

    SCNSphere *jointGeo = [SCNSphere sphereWithRadius:0.0065];
    SCNMaterial *jointMat = [SCNMaterial material];
    jointMat.lightingModelName = SCNLightingModelConstant;
    jointMat.diffuse.contents = ColorHex(0xD0BCFF, 0.92);
    jointGeo.materials = @[jointMat];

    SCNSphere *tipGeo = [SCNSphere sphereWithRadius:0.011];
    self.indexTipMat = [SCNMaterial material];
    self.indexTipMat.lightingModelName = SCNLightingModelConstant;
    self.indexTipMat.diffuse.contents = ColorHex(0x5EEAD4, 0.96);
    tipGeo.materials = @[self.indexTipMat];

    for (int i = 0; i < kHandJointCount; ++i)
    {
        SCNNode *jn = [SCNNode nodeWithGeometry:(i == 8 ? tipGeo : jointGeo)];
        jn.hidden = YES;
        jn.renderingOrder = 25;
        [self.headNode addChildNode:jn];
        _handJointNodes[i] = jn;
        _targetHandJoints[i] = SCNVector3Zero;
        _currentHandJoints[i] = SCNVector3Zero;
    }

    SCNCylinder *boneGeo = [SCNCylinder cylinderWithRadius:0.0032 height:1.0];
    SCNMaterial *boneMat = [SCNMaterial material];
    boneMat.lightingModelName = SCNLightingModelConstant;
    boneMat.diffuse.contents = ColorHex(0xE8DEF8, 0.78);
    boneGeo.materials = @[boneMat];

    for (int b = 0; b < kHandBoneCount; ++b)
    {
        SCNNode *bn = [SCNNode nodeWithGeometry:boneGeo];
        bn.hidden = YES;
        bn.renderingOrder = 24;
        [self.headNode addChildNode:bn];
        _handBoneNodes[b] = bn;
    }

    SCNCylinder *rayGeo = [SCNCylinder cylinderWithRadius:0.0022 height:1.0];
    SCNMaterial *rayMat = [SCNMaterial material];
    rayMat.lightingModelName = SCNLightingModelConstant;
    rayMat.diffuse.contents = ColorHex(0x5EEAD4, 0.55);
    rayMat.writesToDepthBuffer = NO;
    rayGeo.materials = @[rayMat];
    self.handRayNode = [SCNNode nodeWithGeometry:rayGeo];
    self.handRayNode.hidden = YES;
    self.handRayNode.renderingOrder = 23;
    [self.headNode addChildNode:self.handRayNode];
}

- (void)resetSideSlotPose:(int)i
{
    if (i < 0 || i >= kMaxWebMonitors) return;
    SideMonitorSlot &slot = _sideSlots[i];
    float yaw = slot.defaultYawDeg * M_PI / 180.0f;
    float pitch = slot.defaultPitchDeg * M_PI / 180.0f;
    float cosP = cosf(pitch);
    float x = -sinf(yaw) * cosP * slot.defaultDist;
    float y = 0.42f + sinf(pitch) * slot.defaultDist;
    float z = -cosf(yaw) * cosP * slot.defaultDist;
    slot.anchorNode.position = SCNVector3Make(x, y, z);
    slot.anchorNode.eulerAngles = SCNVector3Make(-pitch, yaw, 0);
}

- (float)currentMonitorScale
{
    if (self.screenSizePreset == 0) return 1.05f;
    if (self.screenSizePreset == 1) return 1.30f;
    return 1.60f;
}

- (void)applyMonitorSizes
{
    float s = [self currentMonitorScale];
    self.mainAnchorNode.scale = SCNVector3Make(s, s, 1.0f);
    for (int i = 0; i < kMaxWebMonitors; ++i)
        _sideSlots[i].anchorNode.scale = SCNVector3Make(s, s, 1.0f);
}

- (void)setupGestureAndOverlay
{
    self.leftReticle = [[UIView alloc] init];
    self.leftReticle.userInteractionEnabled = NO;
    self.leftReticle.layer.cornerRadius = 5.0;
    self.leftReticle.layer.borderWidth = 1.8;
    self.leftReticle.layer.borderColor = [UIColor whiteColor].CGColor;
    self.leftReticle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    [self.view addSubview:self.leftReticle];

    self.rightReticle = [[UIView alloc] init];
    self.rightReticle.userInteractionEnabled = NO;
    self.rightReticle.layer.cornerRadius = 5.0;
    self.rightReticle.layer.borderWidth = 1.8;
    self.rightReticle.layer.borderColor = [UIColor whiteColor].CGColor;
    self.rightReticle.backgroundColor = [UIColor colorWithWhite:1.0 alpha:0.25];
    [self.view addSubview:self.rightReticle];

    self.quickSetupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.quickSetupButton.frame = CGRectMake(18, 16, 124, 34);
    self.quickSetupButton.backgroundColor = ColorHex(0x211F26, 0.88);
    self.quickSetupButton.layer.cornerRadius = 17.0;
    [self.quickSetupButton setTitle:@"Parsec Setup" forState:UIControlStateNormal];
    [self.quickSetupButton setTitleColor:ColorHex(0xD0BCFF) forState:UIControlStateNormal];
    self.quickSetupButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.quickSetupButton addTarget:self action:@selector(openQuickSetupAlert) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.quickSetupButton];

    self.viewModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.viewModeButton.frame = CGRectMake(150, 16, 138, 34);
    self.viewModeButton.backgroundColor = ColorHex(0x211F26, 0.88);
    self.viewModeButton.layer.cornerRadius = 17.0;
    [self.viewModeButton setTitle:@"View: VR Split" forState:UIControlStateNormal];
    [self.viewModeButton setTitleColor:ColorHex(0xD0BCFF) forState:UIControlStateNormal];
    self.viewModeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.viewModeButton addTarget:self action:@selector(toggleSingleScreenTouchMode) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:self.viewModeButton];
}

- (void)toggleSingleScreenTouchMode
{
    self.singleScreenTouchMode = !self.singleScreenTouchMode;
    [self.viewModeButton setTitle:(self.singleScreenTouchMode ? @"View: Full Touch" : @"View: VR Split") forState:UIControlStateNormal];
    [self updateStereoOrFullLayout];
}

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

    CFTimeInterval now = CACurrentMediaTime();
    if (self.passthroughOn && !self.passthroughBusy && now >= self.nextPassthroughAt)
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

    if (self.handAimEnabled && !self.visionBusy && now >= self.nextVisionAt)
    {
        self.nextVisionAt = now + (1.0 / 20.0);
        self.visionBusy = YES;
        CVPixelBufferRef pb = CVPixelBufferRetain(frame.capturedImage);
        CGImagePropertyOrientation cgOrient = (orient == UIInterfaceOrientationLandscapeLeft)
            ? kCGImagePropertyOrientationDown
            : kCGImagePropertyOrientationUp;

        __weak VRWorkspaceViewController *weakSelf = self;
        dispatch_async(self.visionQueue, ^{
            VRWorkspaceViewController *strongSelf = weakSelf;
            if (strongSelf)
                [strongSelf processHandPoseOnBuffer:pb orientation:cgOrient];
            CVPixelBufferRelease(pb);
        });
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

- (void)processHandPoseOnBuffer:(CVPixelBufferRef)pixelBuffer orientation:(CGImagePropertyOrientation)orient
{
    VNDetectHumanHandPoseRequest *req = [[VNDetectHumanHandPoseRequest alloc] init];
    req.maximumHandCount = 1;
    VNImageRequestHandler *handler = [[VNImageRequestHandler alloc] initWithCVPixelBuffer:pixelBuffer orientation:orient options:@{}];
    NSError *err = nil;
    BOOL ok = [handler performRequests:@[req] error:&err];
    VNHumanHandPoseObservation *obs = ok ? req.results.firstObject : nil;

    BOOL tracked = NO;
    BOOL palmOpen = NO;
    CGPoint aimNorm = CGPointMake(0.5, 0.5);
    float estDepth = 0.45f;
    std::vector<SCNVector3> parsedJoints(kHandJointCount, SCNVector3Zero);

    if (obs)
    {
        NSArray<VNHumanHandPoseObservationJointName> *names = OrderedHandJointNames();
        float ptX[kHandJointCount] = {};
        float ptY[kHandJointCount] = {};
        BOOL valid[kHandJointCount] = {};

        for (int i = 0; i < kHandJointCount; ++i)
        {
            VNRecognizedPoint *jp = [obs recognizedPointForJointName:names[i] error:nil];
            if (jp && jp.confidence > 0.25f)
            {
                ptX[i] = static_cast<float>(jp.location.x);
                ptY[i] = static_cast<float>(jp.location.y);
                valid[i] = YES;
            }
        }

        if (valid[0] && valid[8])
        {
            tracked = YES;
            aimNorm = CGPointMake(ptX[8], ptY[8]);
            for (int i = 1; i < kHandJointCount; ++i)
            {
                if (!valid[i])
                {
                    int fallback = (i <= 4 || i == 5 || i == 9 || i == 13 || i == 17) ? 0 : (i - 1);
                    ptX[i] = valid[fallback] ? ptX[fallback] : ptX[0];
                    ptY[i] = valid[fallback] ? ptY[fallback] : ptY[0];
                }
            }

            float p9x = valid[9] ? ptX[9] : ptX[5];
            float p9y = valid[9] ? ptY[9] : ptY[5];
            float palmSpan = hypotf((p9x - ptX[0]) * 1.55f, (p9y - ptY[0]));
            float knuckSpan = (valid[5] && valid[17]) ? hypotf((ptX[17] - ptX[5]) * 1.55f, (ptY[17] - ptY[5])) : palmSpan;
            float palmNorm = std::max(0.045f, std::max(palmSpan, knuckSpan));
            estDepth = std::max(0.22f, std::min(0.75f, 0.105f / palmNorm));

            if (valid[5] && valid[17] && valid[12] && valid[16] && valid[20])
            {
                float ix = ptX[5] - ptX[0], iy = ptY[5] - ptY[0];
                float px = ptX[17] - ptX[0], py = ptY[17] - ptY[0];
                float il = hypotf(ix, iy), pl = hypotf(px, py);
                float facingSin = (il > 1e-4f && pl > 1e-4f) ? fabsf(ix * py - iy * px) / (il * pl) : 0.0f;

                float dMid = hypotf(ptX[12] - ptX[0], ptY[12] - ptY[0]);
                float dRing = hypotf(ptX[16] - ptX[0], ptY[16] - ptY[0]);
                float dPink = hypotf(ptX[20] - ptX[0], ptY[20] - ptY[0]);
                float dIdx = hypotf(ptX[8] - ptX[0], ptY[8] - ptY[0]);
                float baseSpan = std::max(0.03f, hypotf(p9x - ptX[0], p9y - ptY[0]));
                float openRatio = ((dIdx + dMid + dRing + dPink) * 0.25f) / baseSpan;
                palmOpen = (facingSin >= 0.30f && openRatio >= 1.45f);
            }

            for (int i = 0; i < kHandJointCount; ++i)
            {
                float nx = (ptX[i] - 0.5f) * 2.0f;
                float ny = (ptY[i] - 0.5f) * 2.0f;
                float zJ = estDepth;
                if (i >= 5 && i <= 8)
                    zJ -= 0.008f * static_cast<float>(i - 5);
                parsedJoints[i] = SCNVector3Make(nx * 0.68f * zJ, ny * 0.42f * zJ, -zJ);
            }
        }
    }

    __weak VRWorkspaceViewController *weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWorkspaceViewController *strongSelf = weakSelf;
        if (!strongSelf)
            return;

        CFTimeInterval now = CACurrentMediaTime();
        strongSelf.handTracked = tracked;
        strongSelf.palmOpenNow = palmOpen;

        if (tracked)
        {
            strongSelf.smoothedHandAim = CGPointMake(strongSelf.smoothedHandAim.x * 0.55 + aimNorm.x * 0.45,
                                                     strongSelf.smoothedHandAim.y * 0.55 + aimNorm.y * 0.45);
            for (int i = 0; i < kHandJointCount; ++i)
                strongSelf->_targetHandJoints[i] = parsedJoints[i];
            strongSelf->_targetHandDepth = estDepth;

            if (strongSelf->_restingHandDepth <= 0.01f)
                strongSelf->_restingHandDepth = estDepth;

            if (palmOpen)
            {
                if (strongSelf.palmFacingSince <= 0.0)
                    strongSelf.palmFacingSince = now;
                else if ((now - strongSelf.palmFacingSince) >= 0.22)
                    strongSelf.palmMenuVisibleUntil = now + 4.5;
            }
            else
            {
                strongSelf.palmFacingSince = 0.0;
            }

            BOOL nearKeyboard = NO;
            if (strongSelf.keyboardVisible && !palmOpen)
            {
                SCNVector3 tipLocal = strongSelf->_targetHandJoints[8];
                simd_float4 tipWorld = simd_mul(strongSelf.headNode.simdWorldTransform,
                                                simd_make_float4(tipLocal.x, tipLocal.y, tipLocal.z, 1.0f));
                simd_float4 kbPt = simd_mul(simd_inverse(strongSelf.keyboardNode.simdWorldTransform), tipWorld);
                SCNPlane *kbGeo = (SCNPlane *)strongSelf.keyboardNode.geometry;
                if (fabsf(kbPt.z) <= 0.055f &&
                    fabsf(kbPt.x) <= kbGeo.width * 0.52f &&
                    fabsf(kbPt.y) <= kbGeo.height * 0.52f)
                {
                    nearKeyboard = YES;
                }
            }

            float pokeThresh = strongSelf.fingerPoking ? 0.016f : 0.025f;
            BOOL pokeNow = !palmOpen && (((strongSelf->_restingHandDepth - estDepth) >= pokeThresh) || nearKeyboard);
            if (!pokeNow)
                strongSelf->_restingHandDepth = strongSelf->_restingHandDepth * 0.90f + estDepth * 0.10f;

            if (pokeNow && !strongSelf.fingerPoking)
            {
                strongSelf.fingerPoking = YES;
                strongSelf.fingerPokePending = YES;
            }
            else if (!pokeNow && strongSelf.fingerPoking)
            {
                strongSelf.fingerPoking = NO;
                [strongSelf handlePrimaryActionUp];
            }
        }
        else
        {
            strongSelf->_restingHandDepth = 0.0f;
            strongSelf.palmFacingSince = 0.0;
            if (strongSelf.fingerPoking)
            {
                strongSelf.fingerPoking = NO;
                [strongSelf handlePrimaryActionUp];
            }
        }
        strongSelf.visionBusy = NO;
    });
}

- (void)hideHandSkeleton
{
    for (int i = 0; i < kHandJointCount; ++i)
        _handJointNodes[i].hidden = YES;
    for (int b = 0; b < kHandBoneCount; ++b)
        _handBoneNodes[b].hidden = YES;
    self.handRayNode.hidden = YES;
}

- (void)updateHandSkeletonWithHitDist:(float)hitDist hasHit:(BOOL)hasHit
{
    if (!self.handAimEnabled || !self.handTracked)
    {
        [self hideHandSkeleton];
        return;
    }

    float alpha = 0.42f;
    for (int i = 0; i < kHandJointCount; ++i)
    {
        SCNVector3 cur = _currentHandJoints[i];
        SCNVector3 tgt = _targetHandJoints[i];
        SCNVector3 next = SCNVector3Make(cur.x + (tgt.x - cur.x) * alpha,
                                         cur.y + (tgt.y - cur.y) * alpha,
                                         cur.z + (tgt.z - cur.z) * alpha);
        _currentHandJoints[i] = next;
        _handJointNodes[i].position = next;
        _handJointNodes[i].hidden = NO;
    }

    self.indexTipMat.diffuse.contents = (self.fingerPoking || self.parsecMouseHeld)
        ? ColorHex(0x4ADE80, 0.98)
        : ColorHex(0x5EEAD4, 0.96);

    const simd_float3 up = simd_make_float3(0.0f, 1.0f, 0.0f);
    for (int b = 0; b < kHandBoneCount; ++b)
    {
        SCNVector3 pA = _currentHandJoints[kHandBonePairs[b][0]];
        SCNVector3 pB = _currentHandJoints[kHandBonePairs[b][1]];
        float dx = pB.x - pA.x;
        float dy = pB.y - pA.y;
        float dz = pB.z - pA.z;
        float len = sqrtf(dx * dx + dy * dy + dz * dz);
        SCNNode *bone = _handBoneNodes[b];
        if (len < 1e-4f)
        {
            bone.hidden = YES;
            continue;
        }
        bone.hidden = NO;
        bone.position = SCNVector3Make((pA.x + pB.x) * 0.5f, (pA.y + pB.y) * 0.5f, (pA.z + pB.z) * 0.5f);
        bone.scale = SCNVector3Make(1.0f, len, 1.0f);
        simd_float3 dir = simd_make_float3(dx / len, dy / len, dz / len);
        float d = simd_dot(up, dir);
        if (d < -0.9995f)
            bone.simdOrientation = simd_quaternion(static_cast<float>(M_PI), simd_make_float3(1.0f, 0.0f, 0.0f));
        else
            bone.simdOrientation = simd_quaternion(up, dir);
    }

    if (hasHit)
    {
        SCNVector3 tip = _currentHandJoints[8];
        float rx = tip.x;
        float ry = tip.y + 0.05f;
        float rz = tip.z;
        float rlen = sqrtf(rx * rx + ry * ry + rz * rz);
        if (rlen > 1e-4f)
        {
            simd_float3 rdir = simd_make_float3(rx / rlen, ry / rlen, rz / rlen);
            float rayLen = std::max(0.08f, std::min(2.5f, hitDist - rlen));
            self.handRayNode.hidden = NO;
            self.handRayNode.position = SCNVector3Make(tip.x + rdir.x * rayLen * 0.5f,
                                                       tip.y + rdir.y * rayLen * 0.5f,
                                                       tip.z + rdir.z * rayLen * 0.5f);
            self.handRayNode.scale = SCNVector3Make(1.0f, rayLen, 1.0f);
            float d = simd_dot(up, rdir);
            if (d < -0.9995f)
                self.handRayNode.simdOrientation = simd_quaternion(static_cast<float>(M_PI), simd_make_float3(1.0f, 0.0f, 0.0f));
            else
                self.handRayNode.simdOrientation = simd_quaternion(up, rdir);
        }
        else
        {
            self.handRayNode.hidden = YES;
        }
    }
    else
    {
        self.handRayNode.hidden = YES;
    }
}

- (SCNNode *)anchorNodeForGrabIndex:(int)idx
{
    if (idx == -1) return self.mainAnchorNode;
    if (idx >= 0 && idx < kMaxWebMonitors) return _sideSlots[idx].anchorNode;
    if (idx == 10) return self.keyboardNode;
    if (idx == 11) return self.dockNode;
    return nil;
}

- (void)startGrabForIndex:(int)idx
{
    if (self.movingMonitorIndex == idx)
    {
        [self finishGrabAtCurrentPose];
        return;
    }

    SCNNode *anchor = [self anchorNodeForGrabIndex:idx];
    if (!anchor)
        return;

    CFTimeInterval now = CACurrentMediaTime();
    SCNVector3 rayOrigin = SCNVector3Zero, rayDir = SCNVector3Make(0, 0, -1);
    [self computeActiveRayOrigin:&rayOrigin dir:&rayDir];
    SCNVector3 aw = [anchor convertPosition:SCNVector3Zero toNode:self.scene.rootNode];
    float dist = sqrtf((aw.x - rayOrigin.x) * (aw.x - rayOrigin.x) +
                       (aw.y - rayOrigin.y) * (aw.y - rayOrigin.y) +
                       (aw.z - rayOrigin.z) * (aw.z - rayOrigin.z));

    self.movingMonitorIndex = idx;
    self.grabBaseDistance = std::max(0.50f, std::min(2.40f, dist));
    self.grabInitialHandDepth = _targetHandDepth > 0.05f ? _targetHandDepth : 0.44f;
    self.grabStartedAt = now;
    self.grabSteadyPos = anchor.position;
    self.grabSteadySince = now;
    self.grabHasMovedSignificantly = NO;

    AudioServicesPlaySystemSound(1104);
    [self redrawGrabBars];
    [self redrawDockPanel];
    [self redrawPalmMenuPanel];
    if (idx >= 0 && idx < kMaxWebMonitors)
        [self redrawSideBar:idx];
}

- (void)finishGrabAtCurrentPose
{
    int prevIdx = self.movingMonitorIndex;
    self.movingMonitorIndex = -2;
    self.grabHasMovedSignificantly = NO;
    AudioServicesPlaySystemSound(1104);
    [self redrawGrabBars];
    [self redrawDockPanel];
    [self redrawPalmMenuPanel];
    if (prevIdx >= 0 && prevIdx < kMaxWebMonitors)
        [self redrawSideBar:prevIdx];
}

- (void)updateLiveGrabbedTargetAtTime:(CFTimeInterval)now
{
    int idx = self.movingMonitorIndex;
    SCNNode *anchor = [self anchorNodeForGrabIndex:idx];
    if (!anchor)
    {
        self.movingMonitorIndex = -2;
        return;
    }

    SCNVector3 origin = SCNVector3Zero, dir = SCNVector3Make(0, 0, -1);
    [self computeActiveRayOrigin:&origin dir:&dir];
    float depthDelta = self.handTracked ? (self.grabInitialHandDepth - _targetHandDepth) : 0.0f;
    float targetDist = std::max(0.45f, std::min(2.60f, self.grabBaseDistance + depthDelta * 2.2f));

    SCNVector3 worldTarget = SCNVector3Make(origin.x + dir.x * targetDist,
                                            origin.y + dir.y * targetDist,
                                            origin.z + dir.z * targetDist);
    SCNVector3 localTarget = [self.workspaceRoot convertPosition:worldTarget fromNode:self.scene.rootNode];
    SCNVector3 curPos = anchor.position;
    SCNVector3 nextPos = SCNVector3Make(curPos.x + (localTarget.x - curPos.x) * 0.28f,
                                        curPos.y + (localTarget.y - curPos.y) * 0.28f,
                                        curPos.z + (localTarget.z - curPos.z) * 0.28f);
    anchor.position = nextPos;

    SCNVector3 headLocal = [self.workspaceRoot convertPosition:[self.headNode convertPosition:SCNVector3Zero toNode:self.scene.rootNode]
                                                      fromNode:self.scene.rootNode];
    float dx = headLocal.x - nextPos.x;
    float dy = headLocal.y - nextPos.y;
    float dz = headLocal.z - nextPos.z;
    float yaw = atan2f(dx, dz);
    float horiz = sqrtf(dx * dx + dz * dz);
    float pitch = -atan2f(dy, MAX(0.1f, horiz));
    if (idx == 10)
        pitch = std::max(-0.90f, std::min(0.20f, pitch - 0.36f));
    else if (idx == 11)
        pitch = std::max(-0.95f, std::min(0.20f, pitch - 0.44f));
    anchor.eulerAngles = SCNVector3Make(pitch, yaw, 0);

    float moveDelta = sqrtf((nextPos.x - self.grabSteadyPos.x) * (nextPos.x - self.grabSteadyPos.x) +
                            (nextPos.y - self.grabSteadyPos.y) * (nextPos.y - self.grabSteadyPos.y) +
                            (nextPos.z - self.grabSteadyPos.z) * (nextPos.z - self.grabSteadyPos.z));
    if (moveDelta > 0.025f)
    {
        self.grabSteadyPos = nextPos;
        self.grabSteadySince = now;
        self.grabHasMovedSignificantly = YES;
    }
    else if (self.grabHasMovedSignificantly && (now - self.grabStartedAt) >= 1.1 && (now - self.grabSteadySince) >= 0.70)
    {
        [self finishGrabAtCurrentPose];
    }
}

- (void)updatePalmMenuAtTime:(CFTimeInterval)now
{
    BOOL show = self.handAimEnabled && (now < self.palmMenuVisibleUntil);
    if (!show)
    {
        self.palmMenuNode.hidden = YES;
        return;
    }

    if (self.palmMenuNode.hidden)
    {
        self.palmMenuNode.hidden = NO;
        [self redrawPalmMenuPanel];
    }

    if (self.handTracked)
    {
        SCNVector3 palm = _currentHandJoints[9];
        float offX = (palm.x < 0.0f) ? 0.22f : -0.22f;
        float tx = std::max(-0.22f, std::min(0.22f, palm.x + offX));
        float ty = std::max(-0.14f, std::min(0.16f, palm.y + 0.08f));
        float tz = std::max(-0.48f, std::min(-0.34f, palm.z));
        SCNVector3 cur = self.palmMenuNode.position;
        if (hypot(cur.x, cur.y) < 0.001f && cur.z == 0.0f)
            self.palmMenuNode.position = SCNVector3Make(tx, ty, tz);
        else
            self.palmMenuNode.position = SCNVector3Make(cur.x + (tx - cur.x) * 0.25f,
                                                        cur.y + (ty - cur.y) * 0.25f,
                                                        cur.z + (tz - cur.z) * 0.25f);
    }
}

- (void)onTick:(CADisplayLink *)link
{
    (void)link;
    CFTimeInterval now = CACurrentMediaTime();

    [self updatePalmMenuAtTime:now];
    if (self.movingMonitorIndex != -2)
        [self updateLiveGrabbedTargetAtTime:now];
    [self updatePointerHoverAndCursor];
    [self updateParsecStream];
    [self updateSideStreams:now];

    if (self.flashedButtonId != nil && now >= self.flashUntil)
    {
        self.flashedButtonId = nil;
        [self redrawKeyboardPanel];
        [self redrawDockPanel];
        if (!self.palmMenuNode.hidden)
            [self redrawPalmMenuPanel];
    }

    UIColor *reticleColor = (self.movingMonitorIndex != -2)
        ? ColorHex(0x80E5A3)
        : (self.handTracked ? ColorHex(0x5EEAD4) : [UIColor whiteColor]);
    self.leftReticle.layer.borderColor = reticleColor.CGColor;
    self.rightReticle.layer.borderColor = reticleColor.CGColor;
    CGFloat scale = (self.hoveredButtonId != nil || self.movingMonitorIndex != -2) ? 1.45 : 1.0;
    self.leftReticle.transform = CGAffineTransformMakeScale(scale, scale);
    self.rightReticle.transform = CGAffineTransformMakeScale(scale, scale);
}

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
    float halfW = static_cast<float>(pl.width * 0.5);
    float halfH = static_cast<float>(pl.height * 0.5);
    if (fabsf(hx) > halfW || fabsf(hy) > halfH)
        return;

    simd_float4 hw = simd_mul(wt, simd_make_float4(hx, hy, 0.0f, 1.0f));
    float dx = hw.x - origin.x;
    float dy = hw.y - origin.y;
    float dz = hw.z - origin.z;
    float dist = sqrtf(dx * dx + dy * dy + dz * dz);
    if (dist < best.dist)
    {
        float u = std::max(0.0f, std::min(1.0f, hx / std::max(1e-4f, static_cast<float>(pl.width)) + 0.5f));
        float v = std::max(0.0f, std::min(1.0f, 0.5f - hy / std::max(1e-4f, static_cast<float>(pl.height))));
        best.node = node;
        best.uv = CGPointMake(u, v);
        best.dist = dist;
        best.worldPoint = SCNVector3Make(hw.x, hw.y, hw.z);
    }
}

- (VRRayHit)analyticRaycastOrigin:(SCNVector3)origin dir:(SCNVector3)dir
{
    VRRayHit best;
    simd_float3 o = simd_make_float3(origin.x, origin.y, origin.z);
    simd_float3 d = simd_make_float3(dir.x, dir.y, dir.z);

    [self testPlaneNode:self.palmMenuNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.keyboardGrabNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.keyboardNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.dockGrabNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.dockNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.mainGrabNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.parsecBarNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.parsecPanelNode rayOrigin:o rayDir:d bestHit:best];
    [self testPlaneNode:self.parsecScreenNode rayOrigin:o rayDir:d bestHit:best];
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        [self testPlaneNode:_sideSlots[i].grabNode rayOrigin:o rayDir:d bestHit:best];
        [self testPlaneNode:_sideSlots[i].barNode rayOrigin:o rayDir:d bestHit:best];
        [self testPlaneNode:_sideSlots[i].screenNode rayOrigin:o rayDir:d bestHit:best];
    }
    return best;
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
    SCNVector3 dir = SCNVector3Make(dx / len, dy / len, dz / len);
    return [self analyticRaycastOrigin:pNear dir:dir];
}

- (void)computeActiveRayOrigin:(SCNVector3 *)outOrigin dir:(SCNVector3 *)outDir
{
    simd_float4x4 hm = self.headNode.simdWorldTransform;
    SCNVector3 localOrigin = SCNVector3Zero;
    SCNVector3 localDir = SCNVector3Make(0, 0, -1.0f);
    if (self.handAimEnabled && self.handTracked)
    {
        SCNVector3 tip = _currentHandJoints[8];
        localOrigin = SCNVector3Make(0.0f, -0.05f, 0.0f);
        float dx = tip.x - localOrigin.x;
        float dy = tip.y - localOrigin.y;
        float dz = tip.z - localOrigin.z;
        float len = sqrtf(dx * dx + dy * dy + dz * dz);
        if (len > 1e-4f)
            localDir = SCNVector3Make(dx / len, dy / len, dz / len);
    }

    simd_float4 wo = simd_mul(hm, simd_make_float4(localOrigin.x, localOrigin.y, localOrigin.z, 1.0f));
    simd_float4 wd = simd_mul(hm, simd_make_float4(localDir.x, localDir.y, localDir.z, 0.0f));
    float wlen = sqrtf(wd.x * wd.x + wd.y * wd.y + wd.z * wd.z);
    if (wlen > 1e-5f)
    {
        wd.x /= wlen;
        wd.y /= wlen;
        wd.z /= wlen;
    }

    SCNVector3 origin = SCNVector3Make(wo.x, wo.y, wo.z);
    SCNVector3 dir = SCNVector3Make(wd.x, wd.y, wd.z);
    if (outOrigin) *outOrigin = origin;
    if (outDir) *outDir = dir;
}

- (VRRayHit)raycastCenterGaze:(SCNVector3 *)outOrigin dir:(SCNVector3 *)outDir
{
    SCNVector3 origin = SCNVector3Zero, dir = SCNVector3Make(0, 0, -1);
    [self computeActiveRayOrigin:&origin dir:&dir];
    if (outOrigin) *outOrigin = origin;
    if (outDir) *outDir = dir;
    return [self analyticRaycastOrigin:origin dir:dir];
}

- (const VRButtonHit *)buttonHitAtUv:(CGPoint)uv inList:(const std::vector<VRButtonHit> &)list
{
    for (const auto &b : list)
    {
        if (!b.disabled && CGRectContainsPoint(b.uvRect, uv))
            return &b;
    }
    return nullptr;
}

- (NSString *)buttonAtUv:(CGPoint)uv inList:(const std::vector<VRButtonHit> &)list
{
    const VRButtonHit *b = [self buttonHitAtUv:uv inList:list];
    return b ? b->buttonId : nil;
}

- (int)sideSlotIndexForNode:(SCNNode *)node isBar:(BOOL *)outIsBar
{
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        if (node == _sideSlots[i].screenNode) { if (outIsBar) *outIsBar = NO; return i; }
        if (node == _sideSlots[i].barNode) { if (outIsBar) *outIsBar = YES; return i; }
    }
    return -1;
}

- (void)applyHoverOverlayToNode:(SCNNode *)panelNode buttonHit:(const VRButtonHit *)btnHit
{
    if (!panelNode || !btnHit)
    {
        self.hoverHighlightNode.hidden = YES;
        return;
    }
    SCNPlane *pl = (SCNPlane *)panelNode.geometry;
    CGRect uvr = btnHit->uvRect;
    float uCenter = static_cast<float>(uvr.origin.x + uvr.size.width * 0.5);
    float vCenter = static_cast<float>(uvr.origin.y + uvr.size.height * 0.5);
    float bw = static_cast<float>(uvr.size.width * pl.width);
    float bh = static_cast<float>(uvr.size.height * pl.height);
    if (self.hoverHighlightNode.parentNode != panelNode)
        [panelNode addChildNode:self.hoverHighlightNode];
    self.hoverHighlightNode.position = SCNVector3Make((uCenter - 0.5f) * static_cast<float>(pl.width),
                                                      (0.5f - vCenter) * static_cast<float>(pl.height),
                                                      0.004f);
    self.hoverHighlightNode.scale = SCNVector3Make(bw, bh, 1.0f);
    self.hoverHighlightNode.hidden = NO;
}

- (int)grabTargetIndexForGrabNode:(SCNNode *)node
{
    if (!node) return -2;
    if (node == self.mainGrabNode) return -1;
    if (node == self.keyboardGrabNode) return 10;
    if (node == self.dockGrabNode) return 11;
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        if (node == _sideSlots[i].grabNode)
            return i;
    }
    return -2;
}

- (void)updatePointerHoverAndCursor
{
    VRRayHit hit = [self raycastCenterGaze:nil dir:nil];
    [self updateHandSkeletonWithHitDist:hit.dist hasHit:(hit.node != nil)];

    if (self.fingerPokePending)
    {
        self.fingerPokePending = NO;
        [self handleRayHitDown:hit fromDirectTouch:NO];
    }

    if (self.parsecMouseHeld)
    {
        if (hit.node == self.parsecScreenNode && self.parsecConnected)
        {
            int maxW = std::max(1, self.hostWidth - 1);
            int maxH = std::max(1, self.hostHeight - 1);
            int px = static_cast<int>(hit.uv.x * maxW);
            int py = static_cast<int>(hit.uv.y * maxH);
            if (px != self.lastMousePx || py != self.lastMousePy)
            {
                self.lastMousePx = px;
                self.lastMousePy = py;
                VRParsecSendStreamMousePosition(0, px, py);
            }
            self.parsecCursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
            self.parsecCursorNode.position = SCNVector3Make((hit.uv.x - 0.5) * pl.width, (0.5 - hit.uv.y) * pl.height, 0.01f);
        }
        return;
    }

    NSString *newNode = hit.node ? hit.node.name : nil;
    NSString *newBtn = nil;
    const VRButtonHit *btnHit = nullptr;
    VRButtonHit fullGrabHit{CGRectMake(0, 0, 1, 1), nil, nil, NO, NO};

    self.parsecCursorNode.hidden = YES;
    for (int i = 0; i < kMaxWebMonitors; ++i)
        _sideSlots[i].cursorNode.hidden = YES;

    CFTimeInterval now = CACurrentMediaTime();
    BOOL onInteractiveScreen = NO;

    if (hit.node)
    {
        CGPoint uv = hit.uv;
        BOOL isSideBar = NO;
        int sideIdx = [self sideSlotIndexForNode:hit.node isBar:&isSideBar];
        int grabIdx = [self grabTargetIndexForGrabNode:hit.node];
        int maxW = std::max(1, self.hostWidth - 1);
        int maxH = std::max(1, self.hostHeight - 1);

        if (hit.node == self.parsecScreenNode || hit.node == self.parsecPanelNode || hit.node == self.parsecBarNode || hit.node == self.mainGrabNode)
            self.lastFocusedTargetIndex = -1;
        else if (sideIdx >= 0)
            self.lastFocusedTargetIndex = sideIdx;
        else if (grabIdx != -2)
            self.lastFocusedTargetIndex = grabIdx;
        else if (hit.node == self.keyboardNode)
            self.lastFocusedTargetIndex = 10;
        else if (hit.node == self.dockNode)
            self.lastFocusedTargetIndex = 11;

        if (grabIdx != -2 && self.movingMonitorIndex == -2)
        {
            fullGrabHit.buttonId = [NSString stringWithFormat:@"__grab_%d", grabIdx];
            btnHit = &fullGrabHit;
        }
        else if (hit.node == self.palmMenuNode)
        {
            self.palmMenuVisibleUntil = now + 4.5;
            btnHit = [self buttonHitAtUv:uv inList:_palmMenuHits];
        }
        else if (hit.node == self.parsecScreenNode && self.parsecConnected)
        {
            onInteractiveScreen = YES;
            self.parsecCursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
            self.parsecCursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
            int px = static_cast<int>(uv.x * maxW);
            int py = static_cast<int>(uv.y * maxH);
            if (!self.singleScreenTouchMode && (px != self.lastMousePx || py != self.lastMousePy))
            {
                self.lastMousePx = px;
                self.lastMousePy = py;
                VRParsecSendStreamMousePosition(0, px, py);
            }
            if (self.handAimEnabled && self.handTracked && self.movingMonitorIndex == -2)
            {
                if (![self.screenDwellNodeName isEqualToString:@"parsec_screen"] ||
                    abs(px - self.screenDwellPx) > 18 || abs(py - self.screenDwellPy) > 18)
                {
                    self.screenDwellNodeName = @"parsec_screen";
                    self.screenDwellPx = px;
                    self.screenDwellPy = py;
                    self.screenDwellStartAt = now;
                    self.screenDwellFired = NO;
                }
                else if (!self.screenDwellFired && (now - self.screenDwellStartAt) >= kScreenDwellSeconds)
                {
                    self.screenDwellFired = YES;
                    AudioServicesPlaySystemSound(1104);
                    int btn = self.rightClickArmed ? 3 : 1;
                    VRParsecSendMouseButton(btn, 1);
                    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                        VRParsecSendMouseButton(btn, 0);
                    });
                    if (self.rightClickArmed)
                    {
                        self.rightClickArmed = NO;
                        [self redrawDockPanel];
                    }
                }
            }
        }
        else if (sideIdx >= 0 && !isSideBar)
        {
            onInteractiveScreen = YES;
            SideMonitorSlot &slot = _sideSlots[sideIdx];
            slot.cursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)slot.screenNode.geometry;
            slot.cursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
            int px = static_cast<int>(uv.x * maxW);
            int py = static_cast<int>(uv.y * maxH);
            if (slot.useParsecStream2 && self.parsecConnected && !self.singleScreenTouchMode)
                VRParsecSendStreamMousePosition(1, px, py);
            if (self.handAimEnabled && self.handTracked && self.movingMonitorIndex == -2)
            {
                NSString *sName = hit.node.name;
                if (![self.screenDwellNodeName isEqualToString:sName] ||
                    abs(px - self.screenDwellPx) > 18 || abs(py - self.screenDwellPy) > 18)
                {
                    self.screenDwellNodeName = sName;
                    self.screenDwellPx = px;
                    self.screenDwellPy = py;
                    self.screenDwellStartAt = now;
                    self.screenDwellFired = NO;
                }
                else if (!self.screenDwellFired && (now - self.screenDwellStartAt) >= kScreenDwellSeconds)
                {
                    self.screenDwellFired = YES;
                    AudioServicesPlaySystemSound(1104);
                    if (slot.useParsecStream2 && self.parsecConnected)
                    {
                        int btn = self.rightClickArmed ? 3 : 1;
                        VRParsecSendMouseButton(btn, 1);
                        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.05 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                            VRParsecSendMouseButton(btn, 0);
                        });
                    }
                    else
                    {
                        VRWebClickSlot(sideIdx, static_cast<float>(uv.x), static_cast<float>(uv.y));
                    }
                }
            }
        }
        else if (sideIdx >= 0 && isSideBar)
            btnHit = [self buttonHitAtUv:uv inList:_sideSlots[sideIdx].barHits];
        else if (hit.node == self.parsecPanelNode)
            btnHit = [self buttonHitAtUv:uv inList:_parsecPanelHits];
        else if (hit.node == self.parsecBarNode)
            btnHit = [self buttonHitAtUv:uv inList:_parsecBarHits];
        else if (hit.node == self.dockNode)
            btnHit = [self buttonHitAtUv:uv inList:_dockHits];
        else if (hit.node == self.keyboardNode)
            btnHit = [self buttonHitAtUv:uv inList:_keyboardHits];

        if (btnHit)
            newBtn = btnHit->buttonId;
    }

    if (!onInteractiveScreen)
    {
        self.screenDwellNodeName = nil;
        self.screenDwellFired = NO;
    }

    BOOL btnSame = (newBtn == self.dwellButtonId || [newBtn isEqualToString:self.dwellButtonId]);
    if (!btnSame)
    {
        self.dwellButtonId = newBtn;
        self.dwellStartAt = now;
        self.dwellFiredForHover = NO;
    }
    else if (self.handAimEnabled && self.handTracked && newBtn != nil && !self.dwellFiredForHover &&
             (now - self.dwellStartAt) >= kHandDwellSeconds)
    {
        self.dwellFiredForHover = YES;
        if ([newBtn hasPrefix:@"__grab_"])
        {
            [self startGrabForIndex:[[newBtn substringFromIndex:7] intValue]];
        }
        else
        {
            AudioServicesPlaySystemSound(1104);
            self.flashedButtonId = newBtn;
            self.flashUntil = now + 0.10;
            [self handleButtonClick:newBtn];
            [self redrawPanelForNodeName:hit.node.name];
        }
    }

    self.hoveredNodeKey = newNode;
    self.hoveredButtonId = newBtn;
    [self applyHoverOverlayToNode:hit.node buttonHit:btnHit];
}

- (CGPoint)averageTouchPointInSet:(NSSet<UITouch *> *)touches
{
    CGFloat sx = 0.0, sy = 0.0;
    NSUInteger count = touches.count;
    for (UITouch *t in touches)
    {
        CGPoint p = [t locationInView:self.view];
        sx += p.x;
        sy += p.y;
    }
    if (count == 0)
        return CGPointZero;
    return CGPointMake(sx / count, sy / count);
}

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSSet<UITouch *> *all = event.allTouches;
    if (all.count >= 2)
    {
        CGPoint avg = [self averageTouchPointInSet:all];
        self.isTwoFingerScrolling = YES;
        self.twoFingerScrollLastY = avg.y;
        [self handlePrimaryActionUp];
        return;
    }

    UITouch *touch = [touches anyObject];
    if (!touch)
        return;
    CGPoint pt = [touch locationInView:self.view];
    VRRayHit hit = [self raycastTouchPoint:pt];
    if (!hit.node && !self.singleScreenTouchMode)
        hit = [self raycastCenterGaze:nil dir:nil];
    [self handleRayHitDown:hit fromDirectTouch:YES];
}

- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    NSSet<UITouch *> *all = event.allTouches;
    if (self.isTwoFingerScrolling && all.count >= 2)
    {
        CGPoint avg = [self averageTouchPointInSet:all];
        CGFloat dy = avg.y - self.twoFingerScrollLastY;
        if (fabs(dy) >= 2.0)
        {
            self.twoFingerScrollLastY = avg.y;
            VRRayHit hit = [self raycastTouchPoint:avg];
            BOOL isSideBar = NO;
            int sideIdx = hit.node ? [self sideSlotIndexForNode:hit.node isBar:&isSideBar] : -1;
            if (self.parsecConnected && (hit.node == self.parsecScreenNode || self.inputTarget == InputTarget::ParsecHost || (sideIdx >= 0 && _sideSlots[sideIdx].useParsecStream2)))
                VRParsecSendMouseWheel(0, static_cast<int>(dy * 5.0));
            else if (sideIdx >= 0 && !isSideBar)
                VRWebScrollSlot(sideIdx, 0.5f, 0.5f, static_cast<float>(-dy * 4.0));
        }
        return;
    }

    UITouch *touch = [touches anyObject];
    if (!touch)
        return;
    CGPoint pt = [touch locationInView:self.view];
    VRRayHit hit = [self raycastTouchPoint:pt];
    if (!hit.node)
        return;

    CGPoint uv = hit.uv;
    BOOL isSideBar = NO;
    int sideIdx = [self sideSlotIndexForNode:hit.node isBar:&isSideBar];
    int maxW = std::max(1, self.hostWidth - 1);
    int maxH = std::max(1, self.hostHeight - 1);

    if (self.parsecMouseHeld)
    {
        if (hit.node == self.parsecScreenNode && self.parsecConnected)
        {
            int px = static_cast<int>(uv.x * maxW);
            int py = static_cast<int>(uv.y * maxH);
            self.lastMousePx = px;
            self.lastMousePy = py;
            VRParsecSendStreamMousePosition(0, px, py);
            self.parsecCursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
            self.parsecCursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
        }
        else if (sideIdx >= 0 && !isSideBar && _sideSlots[sideIdx].useParsecStream2 && self.parsecConnected)
        {
            int px = static_cast<int>(uv.x * maxW);
            int py = static_cast<int>(uv.y * maxH);
            VRParsecSendStreamMousePosition(1, px, py);
        }
        return;
    }

    if (hit.node == self.keyboardNode)
    {
        const VRButtonHit *btn = [self buttonHitAtUv:uv inList:_keyboardHits];
        self.hoveredNodeKey = hit.node.name;
        self.hoveredButtonId = btn ? btn->buttonId : nil;
        [self applyHoverOverlayToNode:hit.node buttonHit:btn];
    }
}

- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    if (event.allTouches.count <= touches.count)
    {
        self.isTwoFingerScrolling = NO;
        [self handlePrimaryActionUp];
    }
}

- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event
{
    (void)touches;
    (void)event;
    self.isTwoFingerScrolling = NO;
    [self handlePrimaryActionUp];
}

- (void)handleRayHitDown:(VRRayHit)hit fromDirectTouch:(BOOL)isDirectTouch
{
    CFTimeInterval now = CACurrentMediaTime();
    if (!isDirectTouch)
    {
        if (now - self.lastPinchClickAt < 0.16)
            return;
        self.lastPinchClickAt = now;
    }

    if (self.movingMonitorIndex != -2)
    {
        [self finishGrabAtCurrentPose];
        return;
    }

    if (!hit.node)
        return;

    int grabIdx = [self grabTargetIndexForGrabNode:hit.node];
    if (grabIdx != -2)
    {
        [self startGrabForIndex:grabIdx];
        return;
    }

    CGPoint uv = hit.uv;
    int maxW = std::max(1, self.hostWidth - 1);
    int maxH = std::max(1, self.hostHeight - 1);

    if (hit.node == self.palmMenuNode)
    {
        self.palmMenuVisibleUntil = now + 4.5;
        NSString *btnId = [self buttonAtUv:uv inList:_palmMenuHits];
        if (btnId)
        {
            AudioServicesPlaySystemSound(1104);
            self.flashedButtonId = btnId;
            self.flashUntil = now + 0.09;
            [self handleButtonClick:btnId];
            [self redrawPalmMenuPanel];
        }
        return;
    }

    if (hit.node == self.parsecScreenNode && self.parsecConnected)
    {
        self.inputTarget = InputTarget::ParsecHost;
        int px = static_cast<int>(uv.x * maxW);
        int py = static_cast<int>(uv.y * maxH);
        self.lastMousePx = px;
        self.lastMousePy = py;
        VRParsecSendStreamMousePosition(0, px, py);
        int btn = self.rightClickArmed ? 3 : 1;
        self.heldParsecButton = btn;
        VRParsecSendMouseButton(btn, 1);
        self.parsecMouseHeld = YES;
        self.parsecCursorNode.hidden = NO;
        SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
        self.parsecCursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
        if (self.rightClickArmed)
        {
            self.rightClickArmed = NO;
            [self redrawDockPanel];
        }
        [self redrawKeyboardPanel];
        return;
    }

    BOOL isSideBar = NO;
    int sideIdx = [self sideSlotIndexForNode:hit.node isBar:&isSideBar];
    if (sideIdx >= 0 && !isSideBar)
    {
        self.activeSideSlot = sideIdx;
        SideMonitorSlot &slot = _sideSlots[sideIdx];
        if (slot.useParsecStream2 && self.parsecConnected)
        {
            self.inputTarget = InputTarget::ParsecHost;
            int px = static_cast<int>(uv.x * maxW);
            int py = static_cast<int>(uv.y * maxH);
            VRParsecSendStreamMousePosition(1, px, py);
            int btn = self.rightClickArmed ? 3 : 1;
            self.heldParsecButton = btn;
            VRParsecSendMouseButton(btn, 1);
            self.parsecMouseHeld = YES;
            if (self.rightClickArmed)
            {
                self.rightClickArmed = NO;
                [self redrawDockPanel];
            }
        }
        else
        {
            self.inputTarget = InputTarget::WebPage;
            VRWebClickSlot(sideIdx, static_cast<float>(uv.x), static_cast<float>(uv.y));
        }
        [self redrawKeyboardPanel];
        return;
    }

    NSString *btnId = nil;
    if (sideIdx >= 0 && isSideBar) btnId = [self buttonAtUv:uv inList:_sideSlots[sideIdx].barHits];
    else if (hit.node == self.parsecPanelNode) btnId = [self buttonAtUv:uv inList:_parsecPanelHits];
    else if (hit.node == self.parsecBarNode) btnId = [self buttonAtUv:uv inList:_parsecBarHits];
    else if (hit.node == self.dockNode) btnId = [self buttonAtUv:uv inList:_dockHits];
    else if (hit.node == self.keyboardNode) btnId = [self buttonAtUv:uv inList:_keyboardHits];

    if (btnId)
    {
        AudioServicesPlaySystemSound(1104);
        self.flashedButtonId = btnId;
        self.flashUntil = now + 0.09;
        [self handleButtonClick:btnId];
        [self redrawPanelForNodeName:hit.node.name];
    }
}

- (void)handlePrimaryActionUp
{
    if (self.parsecMouseHeld)
    {
        self.parsecMouseHeld = NO;
        VRParsecSendMouseButton(self.heldParsecButton, 0);
    }
}

- (void)handleButtonClick:(NSString *)btnId
{
    if ([btnId isEqualToString:@"auth_email"]) { self.inputTarget = InputTarget::ParsecEmail; [self redrawParsecPanel]; [self redrawKeyboardPanel]; return; }
    if ([btnId isEqualToString:@"auth_pass"]) { self.inputTarget = InputTarget::ParsecPassword; [self redrawParsecPanel]; [self redrawKeyboardPanel]; return; }
    if ([btnId isEqualToString:@"auth_tfa"]) { self.inputTarget = InputTarget::ParsecTfa; [self redrawParsecPanel]; [self redrawKeyboardPanel]; return; }
    if ([btnId isEqualToString:@"auth_signin"]) { [self startParsecSignIn]; return; }
    if ([btnId isEqualToString:@"auth_setup"]) { [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"hosts_refresh"]) { [self refreshHosts]; return; }
    if ([btnId isEqualToString:@"hosts_signout"]) { [self signOutParsec]; return; }
    if ([btnId isEqualToString:@"connect_cancel"]) { [self cancelConnect]; return; }
    if ([btnId hasPrefix:@"host_"])
    {
        NSInteger idx = [[btnId substringFromIndex:5] integerValue];
        [self connectToHostAtIndex:idx];
        return;
    }

    if ([btnId isEqualToString:@"pbar_up"]) { VRParsecSendMouseWheel(0, 120); return; }
    if ([btnId isEqualToString:@"pbar_down"]) { VRParsecSendMouseWheel(0, -120); return; }
    if ([btnId isEqualToString:@"pbar_disc"]) { [self disconnectParsec]; return; }

    if ([btnId hasPrefix:@"sbar_"])
    {
        NSArray<NSString *> *parts = [btnId componentsSeparatedByString:@"_"];
        if (parts.count == 3)
        {
            int slotIdx = [parts[1] intValue];
            NSString *act = parts[2];
            if (slotIdx >= 0 && slotIdx < kMaxWebMonitors)
            {
                self.activeSideSlot = slotIdx;
                SideMonitorSlot &slot = _sideSlots[slotIdx];
                if ([act isEqualToString:@"src"])
                {
                    slot.useParsecStream2 = !slot.useParsecStream2;
                    [self syncSecondParsecStream];
                    [self redrawSideBar:slotIdx];
                }
                else if ([act isEqualToString:@"back"]) { VRWebGoBackSlot(slotIdx); }
                else if ([act isEqualToString:@"fwd"]) { VRWebGoForwardSlot(slotIdx); }
                else if ([act isEqualToString:@"reload"]) { VRWebReloadSlot(slotIdx); }
                else if ([act isEqualToString:@"url"]) { self.inputTarget = InputTarget::WebUrl; [self redrawSideBar:slotIdx]; [self redrawKeyboardPanel]; }
                else if ([act isEqualToString:@"yt"]) { [self navigateSideSlot:slotIdx url:@"https://www.youtube.com"]; }
                else if ([act isEqualToString:@"dc"]) { [self navigateSideSlot:slotIdx url:@"https://discord.com/app"]; }
                else if ([act isEqualToString:@"ai"]) { [self navigateSideSlot:slotIdx url:@"https://chatgpt.com"]; }
                else if ([act isEqualToString:@"up"]) { VRWebScrollSlot(slotIdx, 0.5f, 0.5f, -360.0f); }
                else if ([act isEqualToString:@"dn"]) { VRWebScrollSlot(slotIdx, 0.5f, 0.5f, 360.0f); }
                else if ([act isEqualToString:@"move"])
                {
                    [self startGrabForIndex:slotIdx];
                }
                else if ([act isEqualToString:@"close"])
                {
                    slot.active = NO;
                    slot.useParsecStream2 = NO;
                    [self syncSecondParsecStream];
                    [self applyWorkspaceVisibility];
                    [self redrawDockPanel];
                }
            }
        }
        return;
    }

    if ([btnId isEqualToString:@"dock_addmon"] || [btnId isEqualToString:@"palm_addmon"])
    {
        for (int i = 0; i < kMaxWebMonitors; ++i)
        {
            if (!_sideSlots[i].active)
            {
                _sideSlots[i].active = YES;
                VRWebInitSlot(i, 1280, 800, _sideSlots[i].urlText.UTF8String);
                [self resetSideSlotPose:i];
                [self applyWorkspaceVisibility];
                [self redrawSideBar:i];
                [self redrawDockPanel];
                [self redrawPalmMenuPanel];
                break;
            }
        }
        return;
    }
    if ([btnId isEqualToString:@"dock_size"] || [btnId isEqualToString:@"palm_size"])
    {
        self.screenSizePreset = (self.screenSizePreset + 1) % 3;
        [self applyMonitorSizes];
        [self redrawDockPanel];
        [self redrawPalmMenuPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_movepc"])
    {
        [self startGrabForIndex:-1];
        return;
    }
    if ([btnId isEqualToString:@"palm_grab"])
    {
        int target = (self.lastFocusedTargetIndex >= -1) ? self.lastFocusedTargetIndex : -1;
        [self startGrabForIndex:target];
        self.palmMenuVisibleUntil = 0.0;
        self.palmMenuNode.hidden = YES;
        return;
    }
    if ([btnId isEqualToString:@"palm_kb"])
    {
        self.keyboardVisible = YES;
        SCNVector3 origin = SCNVector3Zero, dir = SCNVector3Make(0, 0, -1);
        [self computeActiveRayOrigin:&origin dir:&dir];
        SCNVector3 wt = SCNVector3Make(origin.x + dir.x * 0.65f, origin.y - 0.34f, origin.z + dir.z * 0.65f);
        SCNVector3 lt = [self.workspaceRoot convertPosition:wt fromNode:self.scene.rootNode];
        self.keyboardNode.position = lt;
        SCNVector3 hl = [self.workspaceRoot convertPosition:[self.headNode convertPosition:SCNVector3Zero toNode:self.scene.rootNode]
                                                   fromNode:self.scene.rootNode];
        float yaw = atan2f(hl.x - lt.x, hl.z - lt.z);
        self.keyboardNode.eulerAngles = SCNVector3Make(kKeyboardPitchDeg * M_PI / 180.0f, yaw, 0);
        [self applyWorkspaceVisibility];
        [self redrawDockPanel];
        return;
    }
    if ([btnId isEqualToString:@"palm_close"])
    {
        self.palmMenuVisibleUntil = 0.0;
        self.palmMenuNode.hidden = YES;
        return;
    }
    if ([btnId isEqualToString:@"dock_kb"]) { self.keyboardVisible = !self.keyboardVisible; [self applyWorkspaceVisibility]; [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_rclick"]) { self.rightClickArmed = !self.rightClickArmed; [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_mute"]) { self.muted = !self.muted; VRParsecSetMuted(self.muted ? 1 : 0); [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_handaim"])
    {
        self.handAimEnabled = !self.handAimEnabled;
        if (!self.handAimEnabled)
        {
            self.handTracked = NO;
            self.fingerPoking = NO;
            self.palmMenuVisibleUntil = 0.0;
            self.palmMenuNode.hidden = YES;
            [self hideHandSkeleton];
        }
        [self redrawDockPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_recenter"] || [btnId isEqualToString:@"palm_recenter"])
    {
        self.movingMonitorIndex = -2;
        self.mainAnchorNode.position = SCNVector3Make(0, 0.42f, -kParsecDist);
        self.mainAnchorNode.eulerAngles = SCNVector3Make(4.0f * M_PI / 180.0f, 0, 0);
        self.keyboardNode.position = SCNVector3Make(0, -0.48f, -kKeyboardDist);
        self.keyboardNode.eulerAngles = SCNVector3Make(kKeyboardPitchDeg * M_PI / 180.0f, 0, 0);
        self.dockNode.position = SCNVector3Make(0, -0.78f, -0.62f);
        self.dockNode.eulerAngles = SCNVector3Make(-34.0f * M_PI / 180.0f, 0, 0);
        for (int i = 0; i < kMaxWebMonitors; ++i)
            [self resetSideSlotPose:i];
        [self recenterWorkspace];
        [self redrawGrabBars];
        [self redrawDockPanel];
        [self redrawPalmMenuPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_room"] || [btnId isEqualToString:@"palm_room"])
    {
        self.passthroughOn = !self.passthroughOn;
        self.floorNode.hidden = self.passthroughOn;
        if (!self.passthroughOn)
            self.scene.background.contents = ColorHex(0x141218);
        [self redrawDockPanel];
        [self redrawPalmMenuPanel];
        return;
    }

    if ([btnId hasPrefix:@"kb_"])
    {
        [self handleKeyboardButton:[btnId substringFromIndex:3]];
    }
}

- (void)syncSecondParsecStream
{
    BOOL need2 = NO;
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        if (_sideSlots[i].active && _sideSlots[i].useParsecStream2)
            need2 = YES;
    }
    VRParsecSetSecondStreamEnabled(need2 ? 1 : 0);
}

- (void)handleKeyboardButton:(NSString *)keyName
{
    if ([keyName isEqualToString:@"SHIFT"]) { self.shiftOn = !self.shiftOn; if (self.inputTarget == InputTarget::ParsecHost) VRParsecSendKey(225, self.shiftOn); [self redrawKeyboardPanel]; return; }
    if ([keyName isEqualToString:@"CTRL"]) { self.ctrlOn = !self.ctrlOn; if (self.inputTarget == InputTarget::ParsecHost) VRParsecSendKey(224, self.ctrlOn); [self redrawKeyboardPanel]; return; }
    if ([keyName isEqualToString:@"ALT"]) { self.altOn = !self.altOn; if (self.inputTarget == InputTarget::ParsecHost) VRParsecSendKey(226, self.altOn); [self redrawKeyboardPanel]; return; }
    if ([keyName isEqualToString:@"WIN"]) { self.winOn = !self.winOn; if (self.inputTarget == InputTarget::ParsecHost) VRParsecSendKey(227, self.winOn); [self redrawKeyboardPanel]; return; }

    BOOL isBksp = [keyName isEqualToString:@"BKSP"];
    BOOL isEnter = [keyName isEqualToString:@"ENTER"];
    BOOL isSpace = [keyName isEqualToString:@"SPACE"];
    BOOL isTab = [keyName isEqualToString:@"TAB"];
    BOOL isEsc = [keyName isEqualToString:@"ESC"];
    NSString *text = isSpace ? @" " : keyName;
    if (isBksp || isEnter || isTab || isEsc ||
        [keyName isEqualToString:@"DEL"] || [keyName isEqualToString:@"UP"] ||
        [keyName isEqualToString:@"DOWN"] || [keyName isEqualToString:@"LEFT"] || [keyName isEqualToString:@"RIGHT"])
        text = @"";

    if (self.inputTarget == InputTarget::ParsecHost)
    {
        int code = 0;
        if (isEnter) code = 40;
        else if (isEsc) code = 41;
        else if (isBksp) code = 42;
        else if (isTab) code = 43;
        else if (isSpace) code = 44;
        else if ([keyName isEqualToString:@"DEL"]) code = 76;
        else if ([keyName isEqualToString:@"RIGHT"]) code = 79;
        else if ([keyName isEqualToString:@"LEFT"]) code = 80;
        else if ([keyName isEqualToString:@"DOWN"]) code = 81;
        else if ([keyName isEqualToString:@"UP"]) code = 82;

        if (code != 0)
        {
            VRParsecSendKey(code, 1);
            VRParsecSendKey(code, 0);
        }
        else if (text.length > 0)
        {
            const char *utf8 = text.UTF8String;
            for (size_t i = 0; utf8 && utf8[i] != '\0'; ++i)
            {
                BOOL needsShift = NO;
                int chCode = MapCharToUsbHid(utf8[i], &needsShift);
                if (chCode != 0)
                {
                    if (needsShift && !self.shiftOn) VRParsecSendKey(225, 1);
                    VRParsecSendKey(chCode, 1);
                    VRParsecSendKey(chCode, 0);
                    if (needsShift && !self.shiftOn) VRParsecSendKey(225, 0);
                }
            }
        }
    }
    else if (self.inputTarget == InputTarget::WebPage)
    {
        VRWebTypeKeySlot(self.activeSideSlot, text.UTF8String, isBksp ? 1 : 0, isEnter ? 1 : 0);
    }
    else
    {
        if (isEnter)
        {
            if (self.inputTarget == InputTarget::WebUrl) [self navigateSideSlot:self.activeSideSlot url:_sideSlots[self.activeSideSlot].urlText];
            else [self startParsecSignIn];
        }
        else if (isTab)
        {
            if (self.inputTarget == InputTarget::ParsecEmail) self.inputTarget = InputTarget::ParsecPassword;
            else if (self.inputTarget == InputTarget::ParsecPassword && self.requiresTfa) self.inputTarget = InputTarget::ParsecTfa;
            else if (self.inputTarget != InputTarget::WebUrl) self.inputTarget = InputTarget::ParsecEmail;
            [self redrawParsecPanel];
        }
        else
        {
            NSString *cur = @"";
            if (self.inputTarget == InputTarget::ParsecEmail) cur = self.emailText;
            else if (self.inputTarget == InputTarget::ParsecPassword) cur = self.passwordText;
            else if (self.inputTarget == InputTarget::ParsecTfa) cur = self.tfaText;
            else if (self.inputTarget == InputTarget::WebUrl) cur = _sideSlots[self.activeSideSlot].urlText;

            if (isBksp)
                cur = cur.length > 0 ? [cur substringToIndex:cur.length - 1] : @"";
            else
                cur = [cur stringByAppendingString:text];

            if (self.inputTarget == InputTarget::ParsecEmail) self.emailText = cur;
            else if (self.inputTarget == InputTarget::ParsecPassword) self.passwordText = cur;
            else if (self.inputTarget == InputTarget::ParsecTfa) self.tfaText = cur;
            else if (self.inputTarget == InputTarget::WebUrl)
            {
                _sideSlots[self.activeSideSlot].urlText = cur;
                [self redrawSideBar:self.activeSideSlot];
            }

            [self redrawParsecPanel];
        }
    }

    if (self.shiftOn)
    {
        self.shiftOn = NO;
        if (self.inputTarget == InputTarget::ParsecHost)
            VRParsecSendKey(225, 0);
        [self redrawKeyboardPanel];
    }
}

- (void)recenterWorkspace
{
    SCNMatrix4 m = self.headNode.worldTransform;
    SCNVector3 pos = SCNVector3Make(m.m41, m.m42, m.m43);
    float fx = -m.m31;
    float fz = -m.m33;
    float yaw = atan2f(-fx, -fz);
    self.workspaceRoot.position = pos;
    self.workspaceRoot.eulerAngles = SCNVector3Make(0, yaw, 0);
}

- (void)applyWorkspaceVisibility
{
    self.parsecScreenNode.hidden = !self.parsecConnected;
    self.parsecBarNode.hidden = !self.parsecConnected;
    self.parsecPanelNode.hidden = self.parsecConnected;
    self.mainGrabNode.position = SCNVector3Make(0, self.parsecConnected ? -0.69f : -0.50f, 0.01f);

    for (int i = 0; i < kMaxWebMonitors; ++i)
        _sideSlots[i].anchorNode.hidden = !_sideSlots[i].active;

    self.keyboardNode.hidden = !self.keyboardVisible;
}

- (void)updateParsecStream
{
    if (!self.parsecConnecting && !self.parsecConnected)
        return;

    int hw = 1920, hh = 1080, netFail = 0;
    int st = VRParsecGetStatus(&hw, &hh, &netFail);
    if (hw > 0 && hh > 0)
    {
        self.hostWidth = hw;
        self.hostHeight = hh;
    }

    if (self.parsecConnecting)
    {
        if (st == 0)
        {
            self.parsecConnecting = NO;
            self.parsecConnected = YES;
            self.inputTarget = InputTarget::ParsecHost;
            [self syncSecondParsecStream];
            [self applyWorkspaceVisibility];
            [self redrawParsecBarWithWidth:hw height:hh netFail:netFail != 0];
            [self redrawKeyboardPanel];
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
            self.parsecStateMessage = [NSString stringWithFormat:@"Connection failed (%@). Retry or check host.", FormatParsecStatus(st)];
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

        int updated1 = 0;
        id tex1 = nil;
        BOOL checked1 = NO;
        for (int i = 0; i < kMaxWebMonitors; ++i)
        {
            if (_sideSlots[i].active && _sideSlots[i].useParsecStream2)
            {
                if (!checked1)
                {
                    tex1 = VRParsecPollStreamTexture(1, &updated1);
                    checked1 = YES;
                }
                if (updated1 && tex1)
                    _sideSlots[i].screenNode.geometry.firstMaterial.diffuse.contents = tex1;
            }
        }
    }
}

- (void)updateSideStreams:(CFTimeInterval)now
{
    if (now < self.nextWebSnapshotAt)
        return;
    self.nextWebSnapshotAt = now + (1.0 / 18.0);

    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        SideMonitorSlot &slot = _sideSlots[i];
        if (!slot.active || slot.useParsecStream2)
            continue;
        UIImage *snap = VRWebSnapshotSlot(i);
        if (snap)
            slot.screenNode.geometry.firstMaterial.diffuse.contents = snap;
        NSString *liveUrl = VRWebGetUrlSlot(i);
        if (liveUrl.length > 0 && !(self.inputTarget == InputTarget::WebUrl && self.activeSideSlot == i))
        {
            if (![slot.urlText isEqualToString:liveUrl])
            {
                slot.urlText = liveUrl;
                [self redrawSideBar:i];
            }
        }
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Parsec Sign In"
                                                                   message:@"Sign in once; your session is stored in iOS Keychain."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Email";
        tf.text = self.emailText;
        tf.keyboardType = UIKeyboardTypeEmailAddress;
        tf.autocapitalizationType = UITextAutocapitalizationTypeNone;
    }];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *tf) {
        tf.placeholder = @"Password";
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
        self.parsecStateMessage = @"Both email and password are required.";
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
                [self refreshHosts];
                return;
            }
            if ([json[@"tfa_required"] boolValue])
            {
                self.requiresTfa = YES;
                self.inputTarget = InputTarget::ParsecTfa;
                self.parsecStateMessage = @"Enter 2FA code from your authenticator app.";
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
    self.parsecStateMessage = @"Fetching your online Parsec computers...";
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
                self.parsecStateMessage = @"Session expired. Please sign in again.";
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
            if (list.count == 0)
                self.parsecStateMessage = @"No online hosts found. Start Parsec on your PC, then Refresh.";
            else
                self.parsecStateMessage = [NSString stringWithFormat:@"Select a computer (%lu online):", (unsigned long)list.count];
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
    self.parsecStateMessage = @"Connection canceled. Pick a host or Refresh.";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];
}

- (void)disconnectParsec
{
    self.parsecConnected = NO;
    self.parsecConnecting = NO;
    VRParsecDisconnect();
    self.parsecStateMessage = @"Disconnected. Pick a host to reconnect.";
    self.parsecStateIsError = NO;
    [self applyWorkspaceVisibility];
    [self redrawParsecPanel];
}

- (void)signOutParsec
{
    self.sessionId = @"";
    self.hosts = @[];
    self.showsHostList = NO;
    self.parsecConnected = NO;
    self.parsecConnecting = NO;
    VRKeychainDelete(kKeychainSessionKey);
    self.parsecStateMessage = @"Signed out. Enter email and password.";
    self.parsecStateIsError = NO;
    [self redrawParsecPanel];
}

- (void)navigateSideSlot:(int)slotIdx url:(NSString *)url
{
    if (slotIdx < 0 || slotIdx >= kMaxWebMonitors) return;
    NSString *trimmed = [url stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if (trimmed.length == 0)
        return;
    if (![trimmed hasPrefix:@"http://"] && ![trimmed hasPrefix:@"https://"])
        trimmed = [@"https://" stringByAppendingString:trimmed];
    _sideSlots[slotIdx].urlText = trimmed;
    self.activeSideSlot = slotIdx;
    self.inputTarget = InputTarget::WebPage;
    VRWebLoadUrlSlot(slotIdx, trimmed.UTF8String);
    [self redrawSideBar:slotIdx];
    [self redrawKeyboardPanel];
}

#pragma mark - Material 3 Canvas Renderers

- (void)redrawAllUiPanels
{
    [self redrawParsecPanel];
    [self redrawParsecBarWithWidth:1920 height:1080 netFail:NO];
    for (int i = 0; i < kMaxWebMonitors; ++i)
        [self redrawSideBar:i];
    [self redrawDockPanel];
    [self redrawKeyboardPanel];
    [self redrawGrabBars];
    [self redrawPalmMenuPanel];
}

- (void)redrawPanelForNodeName:(NSString *)name
{
    if (!name) return;
    if ([name isEqualToString:@"parsec_panel"]) [self redrawParsecPanel];
    else if ([name isEqualToString:@"parsec_bar"]) [self redrawParsecBarWithWidth:1920 height:1080 netFail:NO];
    else if ([name isEqualToString:@"dock"]) [self redrawDockPanel];
    else if ([name isEqualToString:@"keyboard"]) [self redrawKeyboardPanel];
    else if ([name isEqualToString:@"palm_menu"]) [self redrawPalmMenuPanel];
    else if ([name hasPrefix:@"side_bar_"]) [self redrawSideBar:[[name substringFromIndex:9] intValue]];
}

- (UIImage *)createGrabHandleImage:(NSString *)label active:(BOOL)active width:(CGFloat)w height:(CGFloat)h
{
    CGSize sz = CGSizeMake(w, h);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        UIColor *bg = active ? ColorHex(0x80E5A3, 0.96) : ColorHex(0x332F3D, 0.92);
        UIColor *fg = active ? ColorHex(0x0D2818) : ColorHex(0xD0BCFF);
        [bg setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, sz.width - 4, sz.height - 4) cornerRadius:sz.height * 0.45] fill];
        [fg setStroke];
        UIBezierPath *border = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, sz.width - 4, sz.height - 4) cornerRadius:sz.height * 0.45];
        border.lineWidth = 2.5;
        [border stroke];
        [self drawText:label rect:CGRectMake(10, (sz.height - 24) * 0.5, sz.width - 20, 24) size:19 color:fg bold:YES align:NSTextAlignmentCenter];
    }];
}

- (void)redrawGrabBars
{
    self.mainGrabNode.geometry.firstMaterial.diffuse.contents =
        [self createGrabHandleImage:(self.movingMonitorIndex == -1 ? @"Drop Main Screen" : @"Grab & Move 6DoF")
                             active:(self.movingMonitorIndex == -1) width:420 height:52];
    self.keyboardGrabNode.geometry.firstMaterial.diffuse.contents =
        [self createGrabHandleImage:(self.movingMonitorIndex == 10 ? @"Drop Keyboard" : @"Move Keyboard")
                             active:(self.movingMonitorIndex == 10) width:340 height:46];
    self.dockGrabNode.geometry.firstMaterial.diffuse.contents =
        [self createGrabHandleImage:(self.movingMonitorIndex == 11 ? @"Drop Controls" : @"Move Controls")
                             active:(self.movingMonitorIndex == 11) width:340 height:44];
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        _sideSlots[i].grabNode.geometry.firstMaterial.diffuse.contents =
            [self createGrabHandleImage:(self.movingMonitorIndex == i ? @"Drop Monitor" : @"Grab & Move 6DoF")
                                 active:(self.movingMonitorIndex == i) width:380 height:48];
    }
}

- (void)redrawPalmMenuPanel
{
    _palmMenuHits.clear();
    CGSize sz = CGSizeMake(640, 400);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    NSString *sizeLabel = self.screenSizePreset == 0 ? @"Size: Big" : (self.screenSizePreset == 1 ? @"Size: Giant" : @"Size: IMAX");
    BOOL grabbing = (self.movingMonitorIndex != -2);

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x1D1B22, 0.96) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:32] fill];
        [ColorHex(0xD0BCFF, 0.6) setStroke];
        UIBezierPath *ring = [UIBezierPath bezierPathWithRoundedRect:CGRectMake(2, 2, sz.width - 4, sz.height - 4) cornerRadius:32];
        ring.lineWidth = 3.0;
        [ring stroke];

        [self drawText:@"Hand Menu (6DoF)" rect:CGRectMake(26, 20, 490, 38) size:26 color:ColorHex(0xE6E0E9) bold:YES align:NSTextAlignmentLeft];
        [self drawButton:CGRectMake(544, 16, 72, 50) canvas:sz buttonId:@"palm_close" title:@"X" selected:NO outlined:YES filled:NO disabled:NO hitList:_palmMenuHits];

        [self drawButton:CGRectMake(24, 86, 286, 84) canvas:sz buttonId:@"palm_addmon" title:@"+ Add Monitor"
                selected:NO outlined:NO filled:YES disabled:NO hitList:_palmMenuHits];
        [self drawButton:CGRectMake(330, 86, 286, 84) canvas:sz buttonId:@"palm_grab"
                   title:(grabbing ? @"Drop Window" : @"Grab Window")
                selected:grabbing outlined:NO filled:NO disabled:NO hitList:_palmMenuHits];

        [self drawButton:CGRectMake(24, 190, 286, 84) canvas:sz buttonId:@"palm_kb" title:@"Keyboard Here"
                selected:NO outlined:NO filled:NO disabled:NO hitList:_palmMenuHits];
        [self drawButton:CGRectMake(330, 190, 286, 84) canvas:sz buttonId:@"palm_recenter" title:@"Recenter 6DoF"
                selected:NO outlined:YES filled:NO disabled:NO hitList:_palmMenuHits];

        [self drawButton:CGRectMake(24, 294, 286, 84) canvas:sz buttonId:@"palm_size" title:sizeLabel
                selected:(self.screenSizePreset > 0) outlined:NO filled:NO disabled:NO hitList:_palmMenuHits];
        [self drawButton:CGRectMake(330, 294, 286, 84) canvas:sz buttonId:@"palm_room"
                   title:(self.passthroughOn ? @"Passthrough: ON" : @"VR Grid Mode")
                selected:self.passthroughOn outlined:NO filled:NO disabled:NO hitList:_palmMenuHits];
    }];
    self.palmMenuNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)drawButton:(CGRect)pxRect
            canvas:(CGSize)canvasSize
          buttonId:(NSString *)btnId
             title:(NSString *)title
          selected:(BOOL)selected
          outlined:(BOOL)outlined
            filled:(BOOL)filled
          disabled:(BOOL)disabled
           hitList:(std::vector<VRButtonHit> &)hits
{
    BOOL flashed = [self.flashedButtonId isEqualToString:btnId] && CACurrentMediaTime() < self.flashUntil;

    UIColor *bg = ColorHex(0x4A4458);
    UIColor *fg = ColorHex(0xE8DEF8);
    if (flashed || filled || selected) { bg = ColorHex(0xD0BCFF); fg = ColorHex(0x381E72); }
    else if (outlined) { bg = ColorHex(0x2B2930); fg = ColorHex(0xE6E0E9); }
    if (disabled)
    {
        bg = ColorHex(0x36343B, 0.5);
        fg = ColorHex(0x938F99);
    }

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:pxRect cornerRadius:MIN(14.0, pxRect.size.height * 0.45)];
    [bg setFill];
    [path fill];
    if (outlined)
    {
        [ColorHex(0x938F99) setStroke];
        path.lineWidth = 1.5;
        [path stroke];
    }

    NSMutableParagraphStyle *ps = [[NSMutableParagraphStyle alloc] init];
    ps.alignment = NSTextAlignmentCenter;
    ps.lineBreakMode = NSLineBreakByTruncatingTail;
    NSDictionary *attrs = @{
        NSFontAttributeName: [UIFont systemFontOfSize:MAX(16.0, MIN(28.0, pxRect.size.height * 0.36)) weight:UIFontWeightSemibold],
        NSForegroundColorAttributeName: fg,
        NSParagraphStyleAttributeName: ps
    };
    CGSize tSz = [title sizeWithAttributes:attrs];
    CGRect tRect = CGRectMake(pxRect.origin.x + 8, pxRect.origin.y + (pxRect.size.height - tSz.height) * 0.5, pxRect.size.width - 16, tSz.height);
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
    CGSize sz = CGSizeMake(920, 660);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.96) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:36] fill];

        [self drawText:@"Parsec Remote Desktop" rect:CGRectMake(40, 30, 840, 42) size:32 color:ColorHex(0xE6E0E9) bold:YES align:NSTextAlignmentLeft];
        [self drawText:self.parsecStateMessage rect:CGRectMake(40, 80, 840, 56) size:21
                 color:(self.parsecStateIsError ? ColorHex(0xF2B8B5) : ColorHex(0xCAC4D0)) bold:NO align:NSTextAlignmentLeft];

        if (self.parsecConnecting)
        {
            [self drawButton:CGRectMake(310, 320, 300, 68) canvas:sz buttonId:@"connect_cancel" title:@"Cancel Connection"
                    selected:NO outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }
        else if (self.showsHostList)
        {
            NSUInteger count = MIN((NSUInteger)5, self.hosts.count);
            for (NSUInteger i = 0; i < count; ++i)
            {
                NSDictionary *h = self.hosts[i];
                NSString *hName = [h[@"name"] length] > 0 ? h[@"name"] : (h[@"peer_id"] ?: @"Host");
                NSString *owner = [h[@"user"] isKindOfClass:[NSDictionary class]] ? (h[@"user"][@"name"] ?: @"PC") : @"PC";
                NSString *label = [NSString stringWithFormat:@"%@  (%@)", hName, owner];
                [self drawButton:CGRectMake(48, 156 + i * 74, 824, 62) canvas:sz
                        buttonId:[NSString stringWithFormat:@"host_%lu", (unsigned long)i]
                           title:label selected:NO outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            }
            [self drawButton:CGRectMake(48, 560, 260, 64) canvas:sz buttonId:@"hosts_refresh" title:@"Refresh Hosts"
                    selected:NO outlined:NO filled:NO disabled:self.isHostsBusy hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(640, 560, 232, 64) canvas:sz buttonId:@"hosts_signout" title:@"Sign Out"
                    selected:NO outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }
        else
        {
            NSString *emailLabel = self.emailText.length > 0 ? [NSString stringWithFormat:@"Email: %@", self.emailText] : @"Email: Tap to type with Air Keyboard";
            NSString *stars = [@"" stringByPaddingToLength:self.passwordText.length withString:@"*" startingAtIndex:0];
            NSString *passLabel = self.passwordText.length > 0 ? [NSString stringWithFormat:@"Password: %@", stars] : @"Password: Tap to type with Air Keyboard";

            [self drawButton:CGRectMake(48, 168, 824, 68) canvas:sz buttonId:@"auth_email" title:emailLabel
                    selected:(self.inputTarget == InputTarget::ParsecEmail) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(48, 256, 824, 68) canvas:sz buttonId:@"auth_pass" title:passLabel
                    selected:(self.inputTarget == InputTarget::ParsecPassword) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            if (self.requiresTfa)
            {
                NSString *tfaLabel = self.tfaText.length > 0 ? [NSString stringWithFormat:@"2FA: %@", self.tfaText] : @"2FA Code: Tap to type";
                [self drawButton:CGRectMake(48, 344, 824, 68) canvas:sz buttonId:@"auth_tfa" title:tfaLabel
                        selected:(self.inputTarget == InputTarget::ParsecTfa) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            }
            [self drawButton:CGRectMake(48, 458, 420, 72) canvas:sz buttonId:@"auth_signin" title:(self.isAuthBusy ? @"Signing In..." : @"Sign In to Parsec")
                    selected:NO outlined:NO filled:YES disabled:self.isAuthBusy hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(510, 458, 362, 72) canvas:sz buttonId:@"auth_setup" title:@"iPhone Keyboard Popup"
                    selected:NO outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }
    }];
    self.parsecPanelNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawParsecBarWithWidth:(int)w height:(int)h netFail:(BOOL)netFail
{
    _parsecBarHits.clear();
    CGSize sz = CGSizeMake(1000, 120);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:28] fill];
        NSString *status = netFail
            ? [NSString stringWithFormat:@"%@ (weak link)", self.connectedHostName]
            : [NSString stringWithFormat:@"%@ (%dx%d)", self.connectedHostName, w, h];
        [self drawText:status rect:CGRectMake(28, 38, 410, 44) size:24 color:ColorHex(0xE6E0E9) bold:YES align:NSTextAlignmentLeft];
        [self drawButton:CGRectMake(460, 26, 120, 68) canvas:sz buttonId:@"pbar_up" title:@"Up" selected:NO outlined:NO filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(594, 26, 136, 68) canvas:sz buttonId:@"pbar_down" title:@"Down" selected:NO outlined:NO filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(746, 26, 226, 68) canvas:sz buttonId:@"pbar_disc" title:@"Disconnect" selected:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
    }];
    self.parsecBarNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawSideBar:(int)slotIdx
{
    if (slotIdx < 0 || slotIdx >= kMaxWebMonitors) return;
    SideMonitorSlot &slot = _sideSlots[slotIdx];
    slot.barHits.clear();

    CGSize sz = CGSizeMake(1060, 174);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:28] fill];

        NSString *p = [NSString stringWithFormat:@"sbar_%d_", slotIdx];
        [self drawButton:CGRectMake(18, 16, 152, 64) canvas:sz buttonId:[p stringByAppendingString:@"src"]
                   title:(slot.useParsecStream2 ? @"Src: PC-2" : @"Src: Web")
                selected:slot.useParsecStream2 outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(180, 16, 66, 64) canvas:sz buttonId:[p stringByAppendingString:@"back"] title:@"<" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(254, 16, 66, 64) canvas:sz buttonId:[p stringByAppendingString:@"fwd"] title:@">" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(328, 16, 94, 64) canvas:sz buttonId:[p stringByAppendingString:@"reload"] title:@"Reload" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(432, 16, 540, 64) canvas:sz buttonId:[p stringByAppendingString:@"url"] title:slot.urlText
                selected:(self.inputTarget == InputTarget::WebUrl && self.activeSideSlot == slotIdx) outlined:YES filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(982, 16, 60, 64) canvas:sz buttonId:[p stringByAppendingString:@"close"] title:@"X" selected:NO outlined:YES filled:NO disabled:NO hitList:slot.barHits];

        [self drawButton:CGRectMake(18, 94, 160, 64) canvas:sz buttonId:[p stringByAppendingString:@"yt"] title:@"YouTube" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(190, 94, 150, 64) canvas:sz buttonId:[p stringByAppendingString:@"dc"] title:@"Discord" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(352, 94, 150, 64) canvas:sz buttonId:[p stringByAppendingString:@"ai"] title:@"ChatGPT" selected:NO outlined:NO filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(518, 94, 134, 64) canvas:sz buttonId:[p stringByAppendingString:@"up"] title:@"Scroll Up" selected:NO outlined:YES filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(664, 94, 144, 64) canvas:sz buttonId:[p stringByAppendingString:@"dn"] title:@"Scroll Dn" selected:NO outlined:YES filled:NO disabled:NO hitList:slot.barHits];
        [self drawButton:CGRectMake(824, 94, 218, 64) canvas:sz buttonId:[p stringByAppendingString:@"move"]
                   title:(self.movingMonitorIndex == slotIdx ? @"Drop Here" : @"Move Monitor")
                selected:(self.movingMonitorIndex == slotIdx) outlined:NO filled:NO disabled:NO hitList:slot.barHits];
    }];
    slot.barNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawDockPanel
{
    _dockHits.clear();
    int activeCount = 0;
    for (int i = 0; i < kMaxWebMonitors; ++i) if (_sideSlots[i].active) activeCount++;

    NSString *sizeTitle = self.screenSizePreset == 0 ? @"Size: Big" : (self.screenSizePreset == 1 ? @"Size: Giant" : @"Size: IMAX");

    CGSize sz = CGSizeMake(1220, 186);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:28] fill];

        [self drawButton:CGRectMake(20, 20, 250, 66) canvas:sz buttonId:@"dock_addmon"
                   title:(activeCount < kMaxWebMonitors ? [NSString stringWithFormat:@"+ Add Monitor (%d/%d)", activeCount, kMaxWebMonitors] : @"Max Monitors (5/5)")
                selected:NO outlined:NO filled:(activeCount < kMaxWebMonitors) disabled:(activeCount >= kMaxWebMonitors) hitList:_dockHits];
        [self drawButton:CGRectMake(284, 20, 210, 66) canvas:sz buttonId:@"dock_size" title:sizeTitle
                selected:(self.screenSizePreset > 0) outlined:NO filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(508, 20, 224, 66) canvas:sz buttonId:@"dock_movepc"
                   title:(self.movingMonitorIndex == -1 ? @"Drop Here" : @"Move Main PC")
                selected:(self.movingMonitorIndex == -1) outlined:NO filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(746, 20, 220, 66) canvas:sz buttonId:@"dock_kb" title:@"Air Keyboard"
                selected:self.keyboardVisible outlined:NO filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(980, 20, 220, 66) canvas:sz buttonId:@"dock_rclick" title:(self.rightClickArmed ? @"Right Click: ON" : @"Right Click")
                selected:self.rightClickArmed outlined:NO filled:NO disabled:NO hitList:_dockHits];

        [self drawButton:CGRectMake(20, 102, 220, 66) canvas:sz buttonId:@"dock_mute" title:(self.muted ? @"Audio: Muted" : @"Audio: On")
                selected:self.muted outlined:NO filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(254, 102, 254, 66) canvas:sz buttonId:@"dock_handaim" title:(self.handAimEnabled ? @"Aim: Hand Ray" : @"Aim: Head Gaze")
                selected:self.handAimEnabled outlined:NO filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(522, 102, 260, 66) canvas:sz buttonId:@"dock_recenter" title:@"Recenter Cockpit"
                selected:NO outlined:YES filled:NO disabled:NO hitList:_dockHits];
        [self drawButton:CGRectMake(796, 102, 404, 66) canvas:sz buttonId:@"dock_room" title:(self.passthroughOn ? @"Room: Passthrough" : @"Room: VR Grid")
                selected:self.passthroughOn outlined:NO filled:NO disabled:NO hitList:_dockHits];
    }];
    self.dockNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawKeyboardPanel
{
    _keyboardHits.clear();
    CGSize sz = CGSizeMake(1280, 560);

    static const KeySpec r0[] = {
        {"ESC","ESC",1.1f,41},{"1","!",1,30},{"2","@",1,31},{"3","#",1,32},{"4","$",1,33},
        {"5","%",1,34},{"6","^",1,35},{"7","&",1,36},{"8","*",1,37},{"9","(",1,38},
        {"0",")",1,39},{"-","_",1,45},{"=","+",1,46},{"BKSP","BKSP",1.5f,42}
    };
    static const KeySpec r1[] = {
        {"TAB","TAB",1.3f,43},{"q","Q",1,20},{"w","W",1,26},{"e","E",1,8},{"r","R",1,21},
        {"t","T",1,23},{"y","Y",1,28},{"u","U",1,24},{"i","I",1,12},{"o","O",1,18},
        {"p","P",1,19},{"[","{",1,47},{"]","}",1,48},{"\\","|",1.3f,49}
    };
    static const KeySpec r2[] = {
        {"SHIFT","SHIFT",1.6f,225},{"a","A",1,4},{"s","S",1,22},{"d","D",1,7},{"f","F",1,9},
        {"g","G",1,10},{"h","H",1,11},{"j","J",1,13},{"k","K",1,14},{"l","L",1,15},
        {";",":",1,51},{"'","\"",1,52},{"ENTER","ENTER",2.0f,40}
    };
    static const KeySpec r3[] = {
        {"CTRL","CTRL",1.3f,224},{"z","Z",1,29},{"x","X",1,27},{"c","C",1,6},{"v","V",1,25},
        {"b","B",1,5},{"n","N",1,17},{"m","M",1,16},{",","<",1,54},{".",">",1,55},
        {"/","?",1,56},{"UP","UP",1.2f,82},{"DEL","DEL",1.1f,76}
    };
    static const KeySpec r4[] = {
        {"ALT","ALT",1.2f,226},{"WIN","WIN",1.2f,227},{".com",".com",1.4f,0},{"https://","https://",1.7f,0},
        {"SPACE","SPACE",4.2f,44},{"LEFT","LEFT",1.1f,80},{"DOWN","DOWN",1.1f,81},{"RIGHT","RIGHT",1.1f,79}
    };

    static const KeySpec *const rows[] = {r0, r1, r2, r3, r4};
    static const int counts[] = {14, 14, 13, 13, 8};

    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:30] fill];

        NSString *targetStr = @"Target: Parsec Email";
        if (self.inputTarget == InputTarget::ParsecPassword) targetStr = @"Target: Parsec Password";
        else if (self.inputTarget == InputTarget::ParsecTfa) targetStr = @"Target: Parsec 2FA Code";
        else if (self.inputTarget == InputTarget::WebUrl) targetStr = [NSString stringWithFormat:@"Target: Side Monitor %d URL (Enter opens)", self.activeSideSlot + 1];
        else if (self.inputTarget == InputTarget::ParsecHost) targetStr = @"Target: Remote PC (Parsec Live)";
        else if (self.inputTarget == InputTarget::WebPage) targetStr = [NSString stringWithFormat:@"Target: Side Monitor %d Web Input", self.activeSideSlot + 1];
        [self drawText:targetStr rect:CGRectMake(24, 14, sz.width - 48, 34) size:22 color:ColorHex(0xD0BCFF) bold:YES align:NSTextAlignmentCenter];

        CGFloat usableW = sz.width - 36.0;
        CGFloat gap = 8.0;
        CGFloat rowH = 84.0;
        CGFloat rowStep = 98.0;
        CGFloat startY = 58.0;

        for (int row = 0; row < 5; ++row)
        {
            float totalUnits = 0.0f;
            for (int i = 0; i < counts[row]; ++i) totalUnits += rows[row][i].units;
            CGFloat unitW = (usableW - gap * (counts[row] - 1)) / totalUnits;
            CGFloat x = 20.0;
            CGFloat y = startY + row * rowStep;

            for (int i = 0; i < counts[row]; ++i)
            {
                const KeySpec &k = rows[row][i];
                CGFloat kw = k.units * unitW;
                NSString *norm = [NSString stringWithUTF8String:k.normal];
                NSString *shft = [NSString stringWithUTF8String:k.shift];
                NSString *cap = self.shiftOn ? shft : norm;
                BOOL modOn = ([norm isEqualToString:@"SHIFT"] && self.shiftOn) ||
                             ([norm isEqualToString:@"CTRL"] && self.ctrlOn) ||
                             ([norm isEqualToString:@"ALT"] && self.altOn) ||
                             ([norm isEqualToString:@"WIN"] && self.winOn);

                [self drawButton:CGRectMake(x, y, kw, rowH) canvas:sz
                        buttonId:[NSString stringWithFormat:@"kb_%@", norm]
                           title:cap selected:modOn outlined:NO filled:NO disabled:NO hitList:_keyboardHits];
                x += kw + gap;
            }
        }
    }];
    self.keyboardNode.geometry.firstMaterial.diffuse.contents = img;
}

@end
