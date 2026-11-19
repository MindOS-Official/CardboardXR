// Native iOS stereoscopic VR cockpit combining ARKit 6DoF tracking, Vision hand pinch
// tracking, SceneKit dual-eye rendering, Parsec dual-stream PC desktop, 5 giant placeable
// WebKit/PC-2 side monitors, and a 3D Air Keyboard.

#import "VRWorkspaceViewController.h"
#import "VRBridge.h"
#import <ARKit/ARKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <SceneKit/SceneKit.h>
#import <Vision/Vision.h>
#include <algorithm>
#include <cmath>
#include <vector>

namespace
{
    constexpr float kEyeSeparation = 0.063f;
    constexpr float kParsecDist = 1.42f;
    constexpr float kSideMonitorDist = 1.46f;
    constexpr float kKeyboardDist = 1.08f;
    constexpr float kKeyboardPitchDeg = -18.0f;
    constexpr CFTimeInterval kHandDwellSeconds = 0.26;
    constexpr const char *kKeychainSessionKey = "cardboardxr_native_parsec_session_v1";

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
@property (nonatomic, assign) CGPoint smoothedHandAim;
@property (nonatomic, assign) BOOL parsecMouseHeld;
@property (nonatomic, assign) int heldParsecButton;
@property (nonatomic, assign) BOOL isTwoFingerScrolling;
@property (nonatomic, assign) CGFloat twoFingerScrollLastY;
@property (nonatomic, assign) int lastMousePx;
@property (nonatomic, assign) int lastMousePy;
@property (nonatomic, assign) BOOL hasRecenteredOnce;
@end

@implementation VRWorkspaceViewController
{
    std::vector<VRButtonHit> _parsecPanelHits;
    std::vector<VRButtonHit> _parsecBarHits;
    std::vector<VRButtonHit> _dockHits;
    std::vector<VRButtonHit> _keyboardHits;
    SideMonitorSlot _sideSlots[kMaxWebMonitors];
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
    self.passthroughOn = NO; // Off by default for zero camera readback lag.
    self.singleScreenTouchMode = NO;
    self.keyboardVisible = YES;
    self.hosts = @[];
    self.hostWidth = 1920;
    self.hostHeight = 1080;
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

- (UIImage *)createFloorGridImage
{
    CGSize sz = CGSizeMake(256, 256);
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
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
    self.mainAnchorNode.position = SCNVector3Make(0, 0.14f, -kParsecDist);
    [self.workspaceRoot addChildNode:self.mainAnchorNode];

    self.parsecScreenNode = [self makePlaneNode:@"parsec_screen" width:2.40 height:1.35 color:ColorHex(0x18171D)];
    [self.mainAnchorNode addChildNode:self.parsecScreenNode];

    self.parsecPanelNode = [self makePlaneNode:@"parsec_panel" width:1.88 height:1.24 color:ColorHex(0x211F26)];
    [self.mainAnchorNode addChildNode:self.parsecPanelNode];

    self.parsecBarNode = [self makePlaneNode:@"parsec_bar" width:2.10 height:0.22 color:ColorHex(0x211F26)];
    self.parsecBarNode.position = SCNVector3Make(0, 0.80f, 0.01f);
    [self.mainAnchorNode addChildNode:self.parsecBarNode];

    self.dockNode = [self makePlaneNode:@"dock" width:1.96 height:0.28 color:ColorHex(0x211F26)];
    self.dockNode.position = SCNVector3Make(0, -0.96f, -1.12f);
    [self.workspaceRoot addChildNode:self.dockNode];

    self.keyboardNode = [self makePlaneNode:@"keyboard" width:1.58 height:0.68 color:ColorHex(0x211F26)];
    self.keyboardNode.position = SCNVector3Make(0, -0.44f, -kKeyboardDist);
    self.keyboardNode.eulerAngles = SCNVector3Make(kKeyboardPitchDeg * M_PI / 180.0f, 0, 0);
    [self.workspaceRoot addChildNode:self.keyboardNode];

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
        {-58.0f,  0.0f, 1.46f, NO, "https://www.youtube.com"},
        { 58.0f,  0.0f, 1.46f, NO, "https://duckduckgo.com"},
        {  0.0f, 34.0f, 1.50f, NO, "https://discord.com/app"},
        {-104.0f, 0.0f, 1.46f, NO, "https://chatgpt.com"},
        { 104.0f, 0.0f, 1.46f, NO, "https://github.com"},
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
                                        width:1.92 height:1.15 color:ColorHex(0x18171D)];
        [slot.anchorNode addChildNode:slot.screenNode];

        slot.barNode = [self makePlaneNode:[NSString stringWithFormat:@"side_bar_%d", i]
                                     width:1.92 height:0.28 color:ColorHex(0x211F26)];
        slot.barNode.position = SCNVector3Make(0, 0.73f, 0.01f);
        [slot.anchorNode addChildNode:slot.barNode];

        slot.cursorNode = [SCNNode nodeWithGeometry:cGeo];
        slot.cursorNode.hidden = YES;
        [slot.screenNode addChildNode:slot.cursorNode];

        [self resetSideSlotPose:i];
    }
}

- (void)resetSideSlotPose:(int)i
{
    if (i < 0 || i >= kMaxWebMonitors) return;
    SideMonitorSlot &slot = _sideSlots[i];
    float yaw = slot.defaultYawDeg * M_PI / 180.0f;
    float pitch = slot.defaultPitchDeg * M_PI / 180.0f;
    float cosP = cosf(pitch);
    float x = -sinf(yaw) * cosP * slot.defaultDist;
    float y = 0.14f + sinf(pitch) * slot.defaultDist;
    float z = -cosf(yaw) * cosP * slot.defaultDist;
    slot.anchorNode.position = SCNVector3Make(x, y, z);
    slot.anchorNode.eulerAngles = SCNVector3Make(-pitch, yaw, 0);
}

- (float)currentMonitorScale
{
    if (self.screenSizePreset == 0) return 1.15f;
    if (self.screenSizePreset == 1) return 1.50f;
    return 1.90f;
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
        self.nextPassthroughAt = now + (1.0 / 15.0);
        self.passthroughBusy = YES;
        CVPixelBufferRef pb = CVPixelBufferRetain(frame.capturedImage);
        dispatch_async(self.passthroughQueue, ^{
            [self updatePassthroughBackground:pb orientation:orient];
            CVPixelBufferRelease(pb);
        });
    }

    if (self.handAimEnabled && !self.visionBusy && now >= self.nextVisionAt)
    {
        self.nextVisionAt = now + (1.0 / 12.0);
        self.visionBusy = YES;
        CVPixelBufferRef pb = CVPixelBufferRetain(frame.capturedImage);
        CGImagePropertyOrientation cgOrient = (orient == UIInterfaceOrientationLandscapeLeft)
            ? kCGImagePropertyOrientationDown
            : kCGImagePropertyOrientationUp;

        dispatch_async(self.visionQueue, ^{
            [self processHandPoseOnBuffer:pb orientation:cgOrient];
            CVPixelBufferRelease(pb);
        });
    }
}

- (void)updatePassthroughBackground:(CVPixelBufferRef)pixelBuffer orientation:(UIInterfaceOrientation)orient
{
    if (!pixelBuffer)
    {
        dispatch_async(dispatch_get_main_queue(), ^{ self.passthroughBusy = NO; });
        return;
    }

    CIImage *ci = [CIImage imageWithCVPixelBuffer:pixelBuffer];
    CGImagePropertyOrientation cgOrient = (orient == UIInterfaceOrientationLandscapeLeft)
        ? kCGImagePropertyOrientationDown
        : kCGImagePropertyOrientationUp;
    ci = [ci imageByApplyingOrientation:cgOrient];
    ci = [ci imageByApplyingTransform:CGAffineTransformMakeScale(0.35, 0.35)];
    CGRect extent = ci.extent;
    UIImage *bg = nil;
    if (extent.size.width > 0 && extent.size.height > 0)
    {
        CGImageRef cg = [self.ciContext createCGImage:ci fromRect:extent];
        if (cg)
        {
            bg = [UIImage imageWithCGImage:cg];
            CGImageRelease(cg);
        }
    }
    dispatch_async(dispatch_get_main_queue(), ^{
        if (bg && self.passthroughOn)
            self.scene.background.contents = bg;
        self.passthroughBusy = NO;
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
    CGPoint aimNorm = CGPointMake(0.5, 0.5);

    if (obs)
    {
        VNRecognizedPoint *idx = [obs recognizedPointForJointName:VNHumanHandPoseObservationJointNameIndexTip error:nil];
        if (idx && idx.confidence > 0.35f)
        {
            tracked = YES;
            aimNorm = idx.location;
        }
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        self.handTracked = tracked;
        if (tracked)
        {
            self.smoothedHandAim = CGPointMake(self.smoothedHandAim.x * 0.55 + aimNorm.x * 0.45,
                                               self.smoothedHandAim.y * 0.55 + aimNorm.y * 0.45);
        }
        self.visionBusy = NO;
    });
}

- (void)onTick:(CADisplayLink *)link
{
    (void)link;
    CFTimeInterval now = CACurrentMediaTime();

    [self updatePointerHoverAndCursor];
    [self updateParsecStream];
    [self updateSideStreams:now];

    if (self.flashedButtonId != nil && now >= self.flashUntil)
    {
        self.flashedButtonId = nil;
        [self redrawKeyboardPanel];
        [self redrawDockPanel];
    }

    UIColor *reticleColor = (self.movingMonitorIndex >= -1)
        ? ColorHex(0x80E5A3)
        : (self.handTracked ? ColorHex(0xD0BCFF) : [UIColor whiteColor]);
    self.leftReticle.layer.borderColor = reticleColor.CGColor;
    self.rightReticle.layer.borderColor = reticleColor.CGColor;
    CGFloat scale = (self.hoveredButtonId != nil || self.movingMonitorIndex >= -1) ? 1.45 : 1.0;
    self.leftReticle.transform = CGAffineTransformMakeScale(scale, scale);
    self.rightReticle.transform = CGAffineTransformMakeScale(scale, scale);
}

- (SCNHitTestResult *)firstInteractiveHitFromResults:(NSArray<SCNHitTestResult *> *)hits
{
    for (SCNHitTestResult *res in hits)
    {
        if (res.node == self.floorNode || res.node == self.parsecCursorNode)
            continue;
        BOOL isCursor = NO;
        for (int i = 0; i < kMaxWebMonitors; ++i)
        {
            if (res.node == _sideSlots[i].cursorNode) { isCursor = YES; break; }
        }
        if (isCursor)
            continue;
        if (!res.node.hidden && res.node.name.length > 0)
            return res;
    }
    return nil;
}

- (SCNHitTestResult *)raycastTouchPoint:(CGPoint)ptInView
{
    SCNView *targetView = (self.singleScreenTouchMode || ptInView.x <= self.view.bounds.size.width * 0.5)
        ? self.leftView
        : self.rightView;
    CGPoint localPt = [targetView convertPoint:ptInView fromView:self.view];
    NSArray<SCNHitTestResult *> *hits = [targetView hitTest:localPt options:@{
        SCNHitTestSortResultsKey: @YES,
        SCNHitTestBackFaceCullingKey: @NO
    }];
    return [self firstInteractiveHitFromResults:hits];
}

- (SCNHitTestResult *)raycastCenterGaze:(SCNVector3 *)outOrigin dir:(SCNVector3 *)outDir
{
    SCNMatrix4 m = self.headNode.worldTransform;
    SCNVector3 origin = SCNVector3Make(m.m41, m.m42, m.m43);
    float dx = self.handAimEnabled && self.handTracked ? static_cast<float>((self.smoothedHandAim.x - 0.5) * 0.45) : 0.0f;
    float dy = self.handAimEnabled && self.handTracked ? static_cast<float>((self.smoothedHandAim.y - 0.5) * 0.35) : 0.0f;
    SCNVector3 localDir = SCNVector3Make(dx, dy, -1.0f);
    SCNVector3 worldDir = SCNVector3Make(
        m.m11 * localDir.x + m.m21 * localDir.y + m.m31 * localDir.z,
        m.m12 * localDir.x + m.m22 * localDir.y + m.m32 * localDir.z,
        m.m13 * localDir.x + m.m23 * localDir.y + m.m33 * localDir.z);
    float len = sqrtf(worldDir.x * worldDir.x + worldDir.y * worldDir.y + worldDir.z * worldDir.z);
    if (len > 1e-5f)
    {
        worldDir.x /= len;
        worldDir.y /= len;
        worldDir.z /= len;
    }
    if (outOrigin) *outOrigin = origin;
    if (outDir) *outDir = worldDir;

    SCNVector3 end = SCNVector3Make(origin.x + worldDir.x * 14.0f,
                                    origin.y + worldDir.y * 14.0f,
                                    origin.z + worldDir.z * 14.0f);
    NSArray<SCNHitTestResult *> *hits = [self.scene.rootNode hitTestWithSegmentFromPoint:origin toPoint:end options:@{
        SCNHitTestSortResultsKey: @YES,
        SCNHitTestBackFaceCullingKey: @NO
    }];
    return [self firstInteractiveHitFromResults:hits];
}

- (CGPoint)topLeftUvForHit:(SCNHitTestResult *)hit
{
    SCNPlane *plane = (SCNPlane *)hit.node.geometry;
    CGFloat w = plane.width > 0 ? plane.width : 1.0;
    CGFloat h = plane.height > 0 ? plane.height : 1.0;
    float u = static_cast<float>(hit.localCoordinates.x / w + 0.5);
    float v = static_cast<float>(0.5 - hit.localCoordinates.y / h);
    u = std::max(0.0f, std::min(1.0f, u));
    v = std::max(0.0f, std::min(1.0f, v));
    return CGPointMake(u, v);
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

- (int)sideSlotIndexForNode:(SCNNode *)node isBar:(BOOL *)outIsBar
{
    for (int i = 0; i < kMaxWebMonitors; ++i)
    {
        if (node == _sideSlots[i].screenNode) { if (outIsBar) *outIsBar = NO; return i; }
        if (node == _sideSlots[i].barNode) { if (outIsBar) *outIsBar = YES; return i; }
    }
    return -1;
}

- (void)updatePointerHoverAndCursor
{
    if (self.parsecMouseHeld)
        return;

    SCNHitTestResult *hit = [self raycastCenterGaze:nil dir:nil];
    NSString *newNode = hit ? hit.node.name : nil;
    NSString *newBtn = nil;

    self.parsecCursorNode.hidden = YES;
    for (int i = 0; i < kMaxWebMonitors; ++i)
        _sideSlots[i].cursorNode.hidden = YES;

    if (hit)
    {
        CGPoint uv = [self topLeftUvForHit:hit];
        BOOL isSideBar = NO;
        int sideIdx = [self sideSlotIndexForNode:hit.node isBar:&isSideBar];
        int maxW = std::max(1, self.hostWidth - 1);
        int maxH = std::max(1, self.hostHeight - 1);

        if (hit.node == self.parsecScreenNode && self.parsecConnected)
        {
            self.parsecCursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)self.parsecScreenNode.geometry;
            self.parsecCursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
            if (!self.singleScreenTouchMode)
            {
                int px = static_cast<int>(uv.x * maxW);
                int py = static_cast<int>(uv.y * maxH);
                if (px != self.lastMousePx || py != self.lastMousePy)
                {
                    self.lastMousePx = px;
                    self.lastMousePy = py;
                    VRParsecSendStreamMousePosition(0, px, py);
                }
            }
        }
        else if (sideIdx >= 0 && !isSideBar)
        {
            SideMonitorSlot &slot = _sideSlots[sideIdx];
            slot.cursorNode.hidden = NO;
            SCNPlane *pl = (SCNPlane *)slot.screenNode.geometry;
            slot.cursorNode.position = SCNVector3Make((uv.x - 0.5) * pl.width, (0.5 - uv.y) * pl.height, 0.01f);
            if (slot.useParsecStream2 && self.parsecConnected && !self.singleScreenTouchMode)
            {
                int px = static_cast<int>(uv.x * maxW);
                int py = static_cast<int>(uv.y * maxH);
                VRParsecSendStreamMousePosition(1, px, py);
            }
        }
        else if (sideIdx >= 0 && isSideBar)
            newBtn = [self buttonAtUv:uv inList:_sideSlots[sideIdx].barHits];
        else if (hit.node == self.parsecPanelNode)
            newBtn = [self buttonAtUv:uv inList:_parsecPanelHits];
        else if (hit.node == self.parsecBarNode)
            newBtn = [self buttonAtUv:uv inList:_parsecBarHits];
        else if (hit.node == self.dockNode)
            newBtn = [self buttonAtUv:uv inList:_dockHits];
        else if (hit.node == self.keyboardNode)
            newBtn = [self buttonAtUv:uv inList:_keyboardHits];
    }

    CFTimeInterval now = CACurrentMediaTime();
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
        AudioServicesPlaySystemSound(1104);
        self.flashedButtonId = newBtn;
        self.flashUntil = now + 0.10;
        [self handleButtonClick:newBtn];
    }

    BOOL changed = !((self.hoveredNodeKey == newNode || [self.hoveredNodeKey isEqualToString:newNode]) &&
                     (self.hoveredButtonId == newBtn || [self.hoveredButtonId isEqualToString:newBtn]));
    if (changed)
    {
        NSString *oldNode = self.hoveredNodeKey;
        self.hoveredNodeKey = newNode;
        self.hoveredButtonId = newBtn;
        [self redrawPanelForNodeName:oldNode];
        [self redrawPanelForNodeName:newNode];
    }
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
    SCNHitTestResult *hit = [self raycastTouchPoint:pt];
    if (!hit && !self.singleScreenTouchMode)
        hit = [self raycastCenterGaze:nil dir:nil];
    [self handleHitDown:hit fromDirectTouch:YES];
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
            SCNHitTestResult *hit = [self raycastTouchPoint:avg];
            BOOL isSideBar = NO;
            int sideIdx = hit ? [self sideSlotIndexForNode:hit.node isBar:&isSideBar] : -1;
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
    SCNHitTestResult *hit = [self raycastTouchPoint:pt];
    if (!hit)
        return;

    CGPoint uv = [self topLeftUvForHit:hit];
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
        NSString *btn = [self buttonAtUv:uv inList:_keyboardHits];
        if (![self.hoveredButtonId isEqualToString:btn])
        {
            self.hoveredNodeKey = hit.node.name;
            self.hoveredButtonId = btn;
            [self redrawKeyboardPanel];
        }
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

- (void)placeMovingMonitorAtGaze
{
    SCNVector3 origin = SCNVector3Zero, dir = SCNVector3Make(0, 0, -1);
    [self raycastCenterGaze:&origin dir:&dir];

    int idx = self.movingMonitorIndex;
    float dist = (idx == -1) ? kParsecDist : kSideMonitorDist;
    SCNVector3 worldTarget = SCNVector3Make(origin.x + dir.x * dist,
                                            origin.y + dir.y * dist,
                                            origin.z + dir.z * dist);
    SCNVector3 localTarget = [self.workspaceRoot convertPosition:worldTarget fromNode:self.scene.rootNode];
    SCNNode *anchor = (idx == -1) ? self.mainAnchorNode : _sideSlots[idx].anchorNode;
    anchor.position = localTarget;

    SCNVector3 headLocal = [self.workspaceRoot convertPosition:origin fromNode:self.scene.rootNode];
    float dx = headLocal.x - localTarget.x;
    float dy = headLocal.y - localTarget.y;
    float dz = headLocal.z - localTarget.z;
    float yaw = atan2f(dx, dz);
    float horiz = sqrtf(dx * dx + dz * dz);
    float pitch = -atan2f(dy, MAX(0.1f, horiz));
    anchor.eulerAngles = SCNVector3Make(pitch, yaw, 0);

    self.movingMonitorIndex = -2;
    [self redrawDockPanel];
    if (idx >= 0) [self redrawSideBar:idx];
}

- (void)handleHitDown:(SCNHitTestResult *)hit fromDirectTouch:(BOOL)isDirectTouch
{
    CFTimeInterval now = CACurrentMediaTime();
    if (!isDirectTouch)
    {
        if (now - self.lastPinchClickAt < 0.22)
            return;
        self.lastPinchClickAt = now;
    }

    if (self.movingMonitorIndex >= -1)
    {
        AudioServicesPlaySystemSound(1104);
        [self placeMovingMonitorAtGaze];
        return;
    }

    if (!hit)
        return;

    CGPoint uv = [self topLeftUvForHit:hit];
    int maxW = std::max(1, self.hostWidth - 1);
    int maxH = std::max(1, self.hostHeight - 1);

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
                    self.movingMonitorIndex = (self.movingMonitorIndex == slotIdx) ? -2 : slotIdx;
                    [self redrawSideBar:slotIdx];
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

    if ([btnId isEqualToString:@"dock_addmon"])
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
                break;
            }
        }
        return;
    }
    if ([btnId isEqualToString:@"dock_size"])
    {
        self.screenSizePreset = (self.screenSizePreset + 1) % 3;
        [self applyMonitorSizes];
        [self redrawDockPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_movepc"])
    {
        self.movingMonitorIndex = (self.movingMonitorIndex == -1) ? -2 : -1;
        [self redrawDockPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_kb"]) { self.keyboardVisible = !self.keyboardVisible; [self applyWorkspaceVisibility]; [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_rclick"]) { self.rightClickArmed = !self.rightClickArmed; [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_mute"]) { self.muted = !self.muted; VRParsecSetMuted(self.muted ? 1 : 0); [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_handaim"]) { self.handAimEnabled = !self.handAimEnabled; [self redrawDockPanel]; return; }
    if ([btnId isEqualToString:@"dock_recenter"])
    {
        self.mainAnchorNode.position = SCNVector3Make(0, 0.14f, -kParsecDist);
        self.mainAnchorNode.eulerAngles = SCNVector3Zero;
        for (int i = 0; i < kMaxWebMonitors; ++i)
            [self resetSideSlotPose:i];
        [self recenterWorkspace];
        [self redrawDockPanel];
        return;
    }
    if ([btnId isEqualToString:@"dock_room"])
    {
        self.passthroughOn = !self.passthroughOn;
        self.floorNode.hidden = self.passthroughOn;
        if (!self.passthroughOn)
            self.scene.background.contents = ColorHex(0x141218);
        [self redrawDockPanel];
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
}

- (void)redrawPanelForNodeName:(NSString *)name
{
    if (!name) return;
    if ([name isEqualToString:@"parsec_panel"]) [self redrawParsecPanel];
    else if ([name isEqualToString:@"parsec_bar"]) [self redrawParsecBarWithWidth:1920 height:1080 netFail:NO];
    else if ([name isEqualToString:@"dock"]) [self redrawDockPanel];
    else if ([name isEqualToString:@"keyboard"]) [self redrawKeyboardPanel];
    else if ([name hasPrefix:@"side_bar_"]) [self redrawSideBar:[[name substringFromIndex:9] intValue]];
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
    BOOL hovered = [self.hoveredButtonId isEqualToString:btnId];
    BOOL flashed = [self.flashedButtonId isEqualToString:btnId] && CACurrentMediaTime() < self.flashUntil;

    UIColor *bg = ColorHex(0x4A4458);
    UIColor *fg = ColorHex(0xE8DEF8);
    if (flashed || filled || selected) { bg = ColorHex(0xD0BCFF); fg = ColorHex(0x381E72); }
    else if (outlined) { bg = ColorHex(0x2B2930); fg = ColorHex(0xE6E0E9); }
    if (hovered && !flashed)
        bg = [bg colorWithAlphaComponent:0.86];
    if (disabled)
    {
        bg = ColorHex(0x36343B, 0.5);
        fg = ColorHex(0x938F99);
    }

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:pxRect cornerRadius:MIN(14.0, pxRect.size.height * 0.45)];
    [bg setFill];
    [path fill];
    if (outlined || hovered)
    {
        [(hovered ? ColorHex(0xD0BCFF) : ColorHex(0x938F99)) setStroke];
        path.lineWidth = hovered ? 3.0 : 1.5;
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
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
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
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
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
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
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
                   title:(self.movingMonitorIndex == slotIdx ? @"Look & Pinch" : @"Move Monitor")
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
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
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
                   title:(self.movingMonitorIndex == -1 ? @"Look & Pinch" : @"Move Main PC")
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
    CGSize sz = CGSizeMake(1440, 680);

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

    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:sz];
    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x211F26, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:34] fill];

        NSString *targetStr = @"Target: Parsec Email";
        if (self.inputTarget == InputTarget::ParsecPassword) targetStr = @"Target: Parsec Password";
        else if (self.inputTarget == InputTarget::ParsecTfa) targetStr = @"Target: Parsec 2FA Code";
        else if (self.inputTarget == InputTarget::WebUrl) targetStr = [NSString stringWithFormat:@"Target: Side Monitor %d URL (Enter opens)", self.activeSideSlot + 1];
        else if (self.inputTarget == InputTarget::ParsecHost) targetStr = @"Target: Remote PC (Parsec Live)";
        else if (self.inputTarget == InputTarget::WebPage) targetStr = [NSString stringWithFormat:@"Target: Side Monitor %d Web Input", self.activeSideSlot + 1];
        [self drawText:targetStr rect:CGRectMake(28, 16, sz.width - 56, 38) size:25 color:ColorHex(0xD0BCFF) bold:YES align:NSTextAlignmentCenter];

        CGFloat usableW = sz.width - 40.0;
        CGFloat gap = 10.0;
        CGFloat rowH = 104.0;
        CGFloat rowStep = 118.0;
        CGFloat startY = 66.0;

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
