// Dedicated 120 FPS Cardboard QR (VR BOX) Parsec Cinema app controlled by Xbox / MFi controller.
// Implements Google Cardboard asymmetric lens frustums, 40x40 polynomial radial barrel distortion
// decoded from the user's VR BOX QR profile (https://goo.gl/Dv8mJO), 120 Hz CoreMotion IMU head
// tracking with gyro prediction + ARKit 6DoF fusion, and native Parsec gamepad pass-through.

#import "VRWorkspaceViewController.h"
#import "VRBridge.h"
#import <ARKit/ARKit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreImage/CoreImage.h>
#import <CoreMotion/CoreMotion.h>
#import <GameController/GameController.h>
#import <Metal/Metal.h>
#import <SceneKit/SceneKit.h>
#include <algorithm>
#include <cmath>
#include <cstdint>
#include <vector>

namespace
{
    constexpr float kBaseScreenWidth = 1.92f;
    constexpr float kDefaultScreenScale = 1.15f;
    constexpr float kDefaultScreenDist = 1.42f;
    constexpr int kMeshResolution = 40;
    constexpr float kDefaultBorderMeters = 0.003f;
    constexpr float kMetersPerInch = 0.0254f;
    constexpr const char *kKeychainSessionKey = "cardboardxr_native_parsec_session_v1";

    NSString *const kPrefQrInterLens = @"vrbox_qr_interlens_v2";
    NSString *const kPrefScreenScale = @"vrbox_screen_scale_v2";
    NSString *const kPrefScreenDist = @"vrbox_screen_dist_v2";

    // Decoded from user's uploaded Cardboard QR code (https://goo.gl/Dv8mJO -> google.com/cardboard/cfg?p=...)
    // Vendor: "VR BOX (Measured by 'Sites in VR')", Model: "VR BOX"
    struct CardboardViewerParams
    {
        float screenToLensDistance = 0.066819f;
        float interLensDistance = 0.063000f;
        float trayToLensDistance = 0.040000f;
        int verticalAlignment = 0; // 0 = Bottom tray
        float maxFovDeg[4] = {60.029064f, 60.029064f, 60.029064f, 60.029064f}; // L, R, B, T
        float k1 = 0.26407f;
        float k2 = 0.34213f;
    };

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

    // Polynomial radial distortion p' = p (1 + K1 r^2 + K2 r^4), matching Cardboard SDK & LensDistortion.cs
    static float DistortRadius(float r, float k1, float k2)
    {
        float r2 = r * r;
        return r * (1.0f + k1 * r2 + k2 * r2 * r2);
    }

    static float DistortInverseRadius(float targetR, float k1, float k2)
    {
        if (targetR < 1e-6f)
            return 0.0f;
        float r0 = targetR * 0.5f;
        float r1 = targetR / 3.0f;
        float dr0 = targetR - DistortRadius(r0, k1, k2);
        for (int i = 0; i < 100 && fabsf(r1 - r0) > 0.0001f; ++i)
        {
            float dr1 = targetR - DistortRadius(r1, k1, k2);
            if (fabsf(dr1 - dr0) < 1e-7f)
                break;
            float r2 = r1 - dr1 * ((r1 - r0) / (dr1 - dr0));
            r0 = r1;
            r1 = r2;
            dr0 = dr1;
        }
        return r1;
    }

    static float GetEyeOffsetYMeters(const CardboardViewerParams &v, float screenH)
    {
        if (v.verticalAlignment == 0) // Bottom tray
            return v.trayToLensDistance - kDefaultBorderMeters;
        if (v.verticalAlignment == 2) // Top tray
            return screenH - v.trayToLensDistance - kDefaultBorderMeters;
        return screenH * 0.5f;
    }

    // Returns asymmetric per-eye FOV in radians as simd_float4(left, right, bottom, top).
    static simd_float4 ComputeEyeFov(int eye, const CardboardViewerParams &v, float screenW, float screenH)
    {
        float toLens = std::max(0.01f, v.screenToLensDistance);
        float outerD = (screenW - v.interLensDistance) * 0.5f;
        float innerD = v.interLensDistance * 0.5f;
        float bottomD = GetEyeOffsetYMeters(v, screenH);
        float topD = screenH - bottomD;

        float deg2rad = static_cast<float>(M_PI / 180.0);
        float outerAng = atanf(DistortRadius(outerD / toLens, v.k1, v.k2));
        float innerAng = atanf(DistortRadius(innerD / toLens, v.k1, v.k2));
        float botAng = atanf(DistortRadius(bottomD / toLens, v.k1, v.k2));
        float topAng = atanf(DistortRadius(topD / toLens, v.k1, v.k2));

        float fL = std::min(outerAng, v.maxFovDeg[0] * deg2rad);
        float fR = std::min(innerAng, v.maxFovDeg[1] * deg2rad);
        float fB = std::min(botAng, v.maxFovDeg[2] * deg2rad);
        float fT = std::min(topAng, v.maxFovDeg[3] * deg2rad);

        return (eye == 0) ? simd_make_float4(fL, fR, fB, fT) : simd_make_float4(fR, fL, fB, fT);
    }

    static CGPoint TextureUvToScreenUv(CGPoint texUv, int eye, const CardboardViewerParams &v, float screenW, float screenH, simd_float4 fov)
    {
        float toLens = std::max(0.01f, v.screenToLensDistance);
        float eyeCenterM = (eye == 0) ? ((screenW - v.interLensDistance) * 0.5f) : ((screenW + v.interLensDistance) * 0.5f);
        float scrW = screenW / toLens;
        float scrH = screenH / toLens;
        float scrOx = eyeCenterM / toLens;
        float scrOy = GetEyeOffsetYMeters(v, screenH) / toLens;

        float tanL = tanf(fov.x), tanR = tanf(fov.y), tanB = tanf(fov.z), tanT = tanf(fov.w);
        float texW = tanL + tanR;
        float texH = tanB + tanT;

        float tx = static_cast<float>(texUv.x) * texW - tanL;
        float ty = static_cast<float>(texUv.y) * texH - tanB;
        float rad = hypotf(tx, ty);
        float scale = (rad > 1e-6f) ? (DistortInverseRadius(rad, v.k1, v.k2) / rad) : 0.0f;
        float ux = tx * scale;
        float uy = ty * scale;

        return CGPointMake((ux + scrOx) / scrW, (uy + scrOy) / scrH);
    }

    static SCNMatrix4 MakeFrustumMatrix(simd_float4 fov, float nearZ, float farZ)
    {
        float l = -tanf(fov.x) * nearZ;
        float r = tanf(fov.y) * nearZ;
        float b = -tanf(fov.z) * nearZ;
        float t = tanf(fov.w) * nearZ;

        SCNMatrix4 m = SCNMatrix4Identity;
        m.m11 = (2.0f * nearZ) / (r - l);
        m.m22 = (2.0f * nearZ) / (t - b);
        m.m31 = (r + l) / (r - l);
        m.m32 = (t + b) / (t - b);
        m.m33 = -(farZ + nearZ) / (farZ - nearZ);
        m.m34 = -1.0f;
        m.m43 = -(2.0f * farZ * nearZ) / (farZ - nearZ);
        m.m44 = 0.0f;
        return m;
    }

    // Converts CoreMotion device attitude into SceneKit camera orientation matrix (R_scn_from_cam).
    static simd_quatf CoreMotionToSceneKitOrientation(CMDeviceMotion *motion, UIInterfaceOrientation orient)
    {
        CMRotationMatrix rm = motion.attitude.rotationMatrix;
        // Rows of CMRotationMatrix represent ref->dev in CoreMotion; transpose gives R_ref_from_dev (columns are dev axes in ref).
        simd_float3 colX = simd_make_float3(static_cast<float>(rm.m11), static_cast<float>(rm.m12), static_cast<float>(rm.m13));
        simd_float3 colY = simd_make_float3(static_cast<float>(rm.m21), static_cast<float>(rm.m22), static_cast<float>(rm.m23));
        simd_float3 colZ = simd_make_float3(static_cast<float>(rm.m31), static_cast<float>(rm.m32), static_cast<float>(rm.m33));
        simd_float3x3 R_ref_from_dev(colX, colY, colZ);

        // Validate against gravity vector: ref down (0,0,-1) mapped into dev by R_dev_from_ref should match motion.gravity.
        simd_float3 gravDev = simd_make_float3(static_cast<float>(motion.gravity.x),
                                              static_cast<float>(motion.gravity.y),
                                              static_cast<float>(motion.gravity.z));
        simd_float3 downTestA = simd_mul(simd_transpose(R_ref_from_dev), simd_make_float3(0.0f, 0.0f, -1.0f));
        simd_float3 downTestB = simd_mul(R_ref_from_dev, simd_make_float3(0.0f, 0.0f, -1.0f));
        if (simd_dot(downTestB, gravDev) > simd_dot(downTestA, gravDev))
            R_ref_from_dev = simd_transpose(R_ref_from_dev);

        // Screen camera axes expressed in device coordinates (LandscapeLeft vs LandscapeRight)
        simd_float3x3 R_dev_from_cam = (orient == UIInterfaceOrientationLandscapeRight)
            ? simd_float3x3(simd_make_float3(0, -1, 0), simd_make_float3(1, 0, 0), simd_make_float3(0, 0, 1))
            : simd_float3x3(simd_make_float3(0, 1, 0), simd_make_float3(-1, 0, 0), simd_make_float3(0, 0, 1));

        // SceneKit world from CoreMotion reference frame: X_scn = X_ref, Y_scn = Z_ref, Z_scn = -Y_ref
        simd_float3x3 R_scn_from_ref(simd_make_float3(1, 0, 0),
                                     simd_make_float3(0, 0, -1),
                                     simd_make_float3(0, 1, 0));

        simd_float3x3 R_scn_from_cam = simd_mul(R_scn_from_ref, simd_mul(R_ref_from_dev, R_dev_from_cam));
        simd_quatf q = simd_quaternion(R_scn_from_cam);

        // Apply 14 ms gyroscopic angular-velocity lead to minimize motion-to-photon latency at 120 Hz.
        CMRotationRate rr = motion.rotationRate;
        simd_float3 wDev = simd_make_float3(static_cast<float>(rr.x), static_cast<float>(rr.y), static_cast<float>(rr.z));
        simd_float3 wCam = simd_mul(simd_transpose(R_dev_from_cam), wDev);
        float wMag = simd_length(wCam);
        if (wMag > 1e-3f)
        {
            float predAngle = std::min(0.25f, wMag * 0.014f);
            simd_quatf dq = simd_quaternion(predAngle, wCam / wMag);
            q = simd_mul(q, dq);
        }
        return simd_normalize(q);
    }
}

@interface VRWorkspaceViewController () <ARSessionDelegate, SCNSceneRendererDelegate>
@property (nonatomic, strong) ARSession *arSession;
@property (nonatomic, strong) CMMotionManager *motionManager;
@property (nonatomic, strong) SCNView *compositorView;
@property (nonatomic, strong) SCNScene *compositorScene;
@property (nonatomic, strong) SCNNode *compositorCamNode;
@property (nonatomic, strong) SCNNode *leftDistortionNode;
@property (nonatomic, strong) SCNNode *rightDistortionNode;
@property (nonatomic, strong) SCNNode *alignmentMarkerNode;
@property (nonatomic, strong) id<MTLDevice> mtlDevice;
@property (nonatomic, strong) id<MTLCommandQueue> mtlQueue;

@property (nonatomic, strong) SCNScene *scene;
@property (nonatomic, strong) SCNNode *headNode;
@property (nonatomic, strong) SCNNode *leftEyeNode;
@property (nonatomic, strong) SCNNode *rightEyeNode;
@property (nonatomic, strong) SCNNode *centerEyeNode;
@property (nonatomic, strong) SCNNode *gazeDotNode;
@property (nonatomic, strong) SCNNode *cinemaRootNode;
@property (nonatomic, strong) SCNNode *envGroupNode;
@property (nonatomic, strong) SCNNode *screenAnchorNode;
@property (nonatomic, strong) SCNNode *parsecScreenNode;
@property (nonatomic, strong) SCNNode *parsecPanelNode;
@property (nonatomic, strong) SCNNode *parsecBarNode;
@property (nonatomic, strong) SCNNode *parsecCursorNode;

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

// VR BOX QR distortion & cinema parameters
@property (nonatomic, assign) float screenScale;
@property (nonatomic, assign) float screenDistance;
@property (nonatomic, assign) float screenMetersW;
@property (nonatomic, assign) float screenMetersH;
@property (nonatomic, assign) int envMode; // 0 = 3D VR Cyber Cinema, 1 = Pure Black, 2 = Camera Passthrough
@property (nonatomic, assign) BOOL sixDofEnabled;
@property (nonatomic, assign) BOOL headLockMode;
@property (nonatomic, assign) BOOL passthroughBusy;
@property (nonatomic, assign) CFTimeInterval nextPassthroughAt;
@property (nonatomic, assign) BOOL singleScreenTouchMode;
@property (nonatomic, assign) BOOL muted;
@property (nonatomic, assign) BOOL hasRecenteredOnce;
@property (nonatomic, assign) float yawOffsetRad;
@property (nonatomic, assign) BOOL yawInitialized;
@property (nonatomic, assign) simd_float3 arHeadOffset;
@property (nonatomic, assign) BOOL hasArPosition;
@property (nonatomic, assign) simd_float3 arHeadPos;

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
    CardboardViewerParams _viewer;
    SCNRenderer *_eyeRenderers[2];
    id<MTLTexture> _eyeColorTex[2];
    id<MTLTexture> _eyeDepthTex[2];
    int _eyeTexW;
    int _eyeTexH;
    CGSize _lastLayoutSize;
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
    self.cursorUv = CGPointMake(0.5, 0.5);
    self.lastMousePx = -1;
    self.lastMousePy = -1;
    self.heldMouseButton = 1;
    self.selectedMenuIndex = 0;

    // Initialize default VR BOX QR parameters + saved preferences
    _viewer = CardboardViewerParams{};
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    float savedIpd = [ud floatForKey:kPrefQrInterLens];
    float savedScale = [ud floatForKey:kPrefScreenScale];
    float savedDist = [ud floatForKey:kPrefScreenDist];
    if (savedIpd >= 0.050f && savedIpd <= 0.075f)
        _viewer.interLensDistance = savedIpd;
    self.screenScale = (savedScale >= 0.60f && savedScale <= 2.40f) ? savedScale : kDefaultScreenScale;
    self.screenDistance = (savedDist >= 0.85f && savedDist <= 2.60f) ? savedDist : kDefaultScreenDist;

    self.envMode = 0;      // 3D 120 FPS VR Cinema environment enabled by default
    self.sixDofEnabled = YES;
    self.headLockMode = NO;

    self.ciContext = [CIContext contextWithOptions:@{kCIContextUseSoftwareRenderer: @NO}];
    self.passthroughQueue = dispatch_queue_create("com.brenpoly.cardboardxr.passthrough", DISPATCH_QUEUE_SERIAL);

    [self setupSceneAndCardboardCompositor];
    [self buildCinemaAndEnvironment];
    [self setupOverlayButtons];
    [self setupCoreMotion120Hz];
    [self setupArSession];
    [self setupGameControllers];

    VRParsecInit();

    [self restoreSavedSession];
    [self applyScreenLayoutAndScale];
    [self applyWorkspaceVisibility];
    [self rebuildCardboardDistortionRig];
    [self redrawAllPanels];

    self.lastTickAt = CACurrentMediaTime();
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(onTick:)];
    if (@available(iOS 15.0, *))
        self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(80, 120, 120);
    [self.displayLink addToRunLoop:[NSRunLoop mainRunLoop] forMode:NSRunLoopCommonModes];
}

- (void)dealloc
{
    [self.displayLink invalidate];
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    [self.motionManager stopDeviceMotionUpdates];
    [self.arSession pause];
    self.compositorView.delegate = nil;
    VRParsecUnplugGamepad();
    VRParsecDisconnect();
}

- (void)viewDidLayoutSubviews
{
    [super viewDidLayoutSubviews];
    CGRect bounds = self.view.bounds;
    self.compositorView.frame = bounds;
    if (!CGSizeEqualToSize(bounds.size, _lastLayoutSize) && bounds.size.width > 0 && bounds.size.height > 0)
    {
        _lastLayoutSize = bounds.size;
        [self rebuildCardboardDistortionRig];
    }
}

#pragma mark - Physical Metrics & Cardboard QR Distortion Rig

- (void)updatePhysicalScreenMeters
{
    CGRect nb = [UIScreen mainScreen].nativeBounds;
    float pxW = static_cast<float>(MAX(nb.size.width, nb.size.height));
    float pxH = static_cast<float>(MIN(nb.size.width, nb.size.height));
    float scale = static_cast<float>([UIScreen mainScreen].nativeScale);
    float ppi = (scale >= 2.9f) ? ((pxW <= 2400.0f) ? 476.0f : 460.0f) : 326.0f;
    self.screenMetersW = std::max(0.08f, (pxW / ppi) * kMetersPerInch);
    self.screenMetersH = std::max(0.04f, (pxH / ppi) * kMetersPerInch);
}

- (SCNGeometry *)createDistortionGeometryForEye:(int)eye
                                         aspect:(float)screenAspect
                                            fov:(simd_float4)fov
{
    const int n = kMeshResolution;
    std::vector<SCNVector3> vertices(n * n);
    std::vector<CGPoint> texcoords(n * n);

    for (int row = 0; row < n; ++row)
    {
        float vBottomUp = static_cast<float>(row) / static_cast<float>(n - 1);
        for (int col = 0; col < n; ++col)
        {
            float u = static_cast<float>(col) / static_cast<float>(n - 1);
            CGPoint scrUv = TextureUvToScreenUv(CGPointMake(u, vBottomUp), eye, _viewer, self.screenMetersW, self.screenMetersH, fov);
            int idx = row * n + col;
            float xPos = (2.0f * static_cast<float>(scrUv.x) - 1.0f) * screenAspect;
            float yPos = 2.0f * static_cast<float>(scrUv.y) - 1.0f;
            vertices[idx] = SCNVector3Make(xPos, yPos, 0.0f);
            // Invert V because SCNRenderer writes into Metal texture top-down (row 0 = top).
            texcoords[idx] = CGPointMake(u, 1.0f - vBottomUp);
        }
    }

    std::vector<int32_t> indices((n - 1) * (n - 1) * 6);
    int t = 0;
    for (int row = 0; row < n - 1; ++row)
    {
        for (int col = 0; col < n - 1; ++col)
        {
            int idx = row * n + col;
            indices[t++] = idx;
            indices[t++] = idx + n;
            indices[t++] = idx + 1;
            indices[t++] = idx + 1;
            indices[t++] = idx + n;
            indices[t++] = idx + n + 1;
        }
    }

    SCNGeometrySource *posSrc = [SCNGeometrySource geometrySourceWithVertices:vertices.data() count:static_cast<NSInteger>(vertices.size())];
    SCNGeometrySource *uvSrc = [SCNGeometrySource geometrySourceWithTextureCoordinates:texcoords.data() count:static_cast<NSInteger>(texcoords.size())];
    NSData *idxData = [NSData dataWithBytes:indices.data() length:indices.size() * sizeof(int32_t)];
    SCNGeometryElement *elem = [SCNGeometryElement geometryElementWithData:idxData
                                                             primitiveType:SCNGeometryPrimitiveTypeTriangles
                                                            primitiveCount:static_cast<NSInteger>(indices.size() / 3)
                                                             bytesPerIndex:sizeof(int32_t)];
    return [SCNGeometry geometryWithSources:@[posSrc, uvSrc] elements:@[elem]];
}

- (void)ensureEyeRenderTargetsForWidth:(int)w height:(int)h
{
    if (_eyeTexW == w && _eyeTexH == h && _eyeColorTex[0] != nil && _eyeColorTex[1] != nil)
        return;

    _eyeTexW = w;
    _eyeTexH = h;

    for (int eye = 0; eye < 2; ++eye)
    {
        MTLTextureDescriptor *cDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
                                                                                         width:static_cast<NSUInteger>(w)
                                                                                        height:static_cast<NSUInteger>(h)
                                                                                     mipmapped:NO];
        cDesc.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
        cDesc.storageMode = MTLStorageModePrivate;
        _eyeColorTex[eye] = [self.mtlDevice newTextureWithDescriptor:cDesc];

        MTLTextureDescriptor *dDesc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatDepth32Float
                                                                                         width:static_cast<NSUInteger>(w)
                                                                                        height:static_cast<NSUInteger>(h)
                                                                                     mipmapped:NO];
        dDesc.usage = MTLTextureUsageRenderTarget;
        dDesc.storageMode = MTLStorageModePrivate;
        _eyeDepthTex[eye] = [self.mtlDevice newTextureWithDescriptor:dDesc];
    }
}

- (void)rebuildCardboardDistortionRig
{
    [self updatePhysicalScreenMeters];

    CGRect bounds = self.view.bounds;
    float viewW = std::max(1.0f, static_cast<float>(bounds.size.width));
    float viewH = std::max(1.0f, static_cast<float>(bounds.size.height));
    float screenAspect = viewW / viewH;

    CGRect nb = [UIScreen mainScreen].nativeBounds;
    int eyeW = std::max(512, static_cast<int>(MAX(nb.size.width, nb.size.height) * 0.5));
    int eyeH = std::max(512, static_cast<int>(MIN(nb.size.width, nb.size.height)));
    [self ensureEyeRenderTargetsForWidth:eyeW height:eyeH];

    simd_float4 fovL = ComputeEyeFov(0, _viewer, self.screenMetersW, self.screenMetersH);
    simd_float4 fovR = ComputeEyeFov(1, _viewer, self.screenMetersW, self.screenMetersH);
    self.leftEyeNode.camera.projectionTransform = MakeFrustumMatrix(fovL, 0.05f, 60.0f);
    self.rightEyeNode.camera.projectionTransform = MakeFrustumMatrix(fovR, 0.05f, 60.0f);

    float halfIpd = (self.envMode == 2) ? 0.0f : (_viewer.interLensDistance * 0.5f);
    self.leftEyeNode.position = SCNVector3Make(-halfIpd, 0.0f, 0.0f);
    self.rightEyeNode.position = SCNVector3Make(halfIpd, 0.0f, 0.0f);

    for (int eye = 0; eye < 2; ++eye)
    {
        SCNGeometry *geo = [self createDistortionGeometryForEye:eye aspect:screenAspect fov:(eye == 0 ? fovL : fovR)];
        SCNMaterial *mat = [SCNMaterial material];
        mat.lightingModelName = SCNLightingModelConstant;
        mat.diffuse.contents = _eyeColorTex[eye];
        mat.diffuse.wrapS = SCNWrapModeClamp;
        mat.diffuse.wrapT = SCNWrapModeClamp;
        mat.doubleSided = YES;
        mat.writesToDepthBuffer = NO;
        mat.readsFromDepthBuffer = NO;
        geo.materials = @[mat];

        SCNNode *node = (eye == 0) ? self.leftDistortionNode : self.rightDistortionNode;
        node.geometry = geo;
    }

    // Rebuild bottom Cardboard alignment marker (2 dp wide, 24 mm tall)
    float markerHNorm = std::min(0.45f, 0.024f / self.screenMetersH);
    float markerWNorm = std::max(0.002f, 2.0f / viewW);
    SCNPlane *mkPlane = [SCNPlane planeWithWidth:(markerWNorm * 2.0f * screenAspect) height:(markerHNorm * 2.0f)];
    SCNMaterial *mkMat = [SCNMaterial material];
    mkMat.lightingModelName = SCNLightingModelConstant;
    mkMat.diffuse.contents = ColorHex(0xB4B4B4, 0.85);
    mkMat.writesToDepthBuffer = NO;
    mkMat.readsFromDepthBuffer = NO;
    mkPlane.materials = @[mkMat];
    self.alignmentMarkerNode.geometry = mkPlane;
    self.alignmentMarkerNode.position = SCNVector3Make(0.0f, -1.0f + markerHNorm, 0.01f);
}

#pragma mark - SceneKit Setup & 120 FPS Compositor

- (void)setupSceneAndCardboardCompositor
{
    self.scene = [SCNScene scene];
    self.scene.background.contents = ColorHex(0x06070D);

    self.headNode = [SCNNode node];
    [self.scene.rootNode addChildNode:self.headNode];

    SCNCamera *leftCam = [SCNCamera camera];
    self.leftEyeNode = [SCNNode node];
    self.leftEyeNode.camera = leftCam;
    [self.headNode addChildNode:self.leftEyeNode];

    SCNCamera *rightCam = [SCNCamera camera];
    self.rightEyeNode = [SCNNode node];
    self.rightEyeNode.camera = rightCam;
    [self.headNode addChildNode:self.rightEyeNode];

    SCNCamera *centerCam = [SCNCamera camera];
    centerCam.zNear = 0.05;
    centerCam.zFar = 60.0;
    centerCam.fieldOfView = 72.0;
    self.centerEyeNode = [SCNNode node];
    self.centerEyeNode.camera = centerCam;
    [self.headNode addChildNode:self.centerEyeNode];

    SCNSphere *gGeo = [SCNSphere sphereWithRadius:0.009];
    SCNMaterial *gMat = [SCNMaterial material];
    gMat.lightingModelName = SCNLightingModelConstant;
    gMat.diffuse.contents = ColorHex(0x5EEAD4, 0.90);
    gMat.writesToDepthBuffer = NO;
    gGeo.materials = @[gMat];
    self.gazeDotNode = [SCNNode nodeWithGeometry:gGeo];
    self.gazeDotNode.position = SCNVector3Make(0, 0, -1.25f);
    self.gazeDotNode.renderingOrder = 30;
    [self.headNode addChildNode:self.gazeDotNode];

    // Primary full-screen 120 FPS Metal compositor SCNView
    self.compositorView = [[SCNView alloc] initWithFrame:self.view.bounds options:@{SCNPreferredRenderingAPIKey: @(SCNRenderingAPIMetal)}];
    self.compositorView.backgroundColor = [UIColor blackColor];
    self.compositorView.antialiasingMode = SCNAntialiasingModeNone;
    self.compositorView.preferredFramesPerSecond = 120;
    self.compositorView.rendersContinuously = YES;
    self.compositorView.delegate = self;
    self.compositorView.userInteractionEnabled = NO;
    [self.view addSubview:self.compositorView];

    self.mtlDevice = self.compositorView.device ?: MTLCreateSystemDefaultDevice();
    self.mtlQueue = self.compositorView.commandQueue ?: [self.mtlDevice newCommandQueue];

    for (int eye = 0; eye < 2; ++eye)
    {
        _eyeRenderers[eye] = [SCNRenderer rendererWithDevice:self.mtlDevice options:nil];
        _eyeRenderers[eye].scene = self.scene;
        _eyeRenderers[eye].pointOfView = (eye == 0) ? self.leftEyeNode : self.rightEyeNode;
    }

    self.compositorScene = [SCNScene scene];
    self.compositorScene.background.contents = [UIColor blackColor];

    SCNCamera *compCam = [SCNCamera camera];
    compCam.usesOrthographicProjection = YES;
    compCam.orthographicScale = 1.0;
    compCam.zNear = 0.01;
    compCam.zFar = 10.0;
    self.compositorCamNode = [SCNNode node];
    self.compositorCamNode.camera = compCam;
    self.compositorCamNode.position = SCNVector3Make(0, 0, 1.0);
    [self.compositorScene.rootNode addChildNode:self.compositorCamNode];

    self.leftDistortionNode = [SCNNode node];
    self.rightDistortionNode = [SCNNode node];
    self.alignmentMarkerNode = [SCNNode node];
    [self.compositorScene.rootNode addChildNode:self.leftDistortionNode];
    [self.compositorScene.rootNode addChildNode:self.rightDistortionNode];
    [self.compositorScene.rootNode addChildNode:self.alignmentMarkerNode];

    self.compositorView.scene = self.compositorScene;
    self.compositorView.pointOfView = self.compositorCamNode;
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

- (UIImage *)createCyberGridImage:(UIColor *)lineColor bgColor:(UIColor *)bgColor
{
    CGSize sz = CGSizeMake(256, 256);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];
    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        [bgColor setFill];
        [ctx fillRect:CGRectMake(0, 0, 256, 256)];
        [lineColor setFill];
        [ctx fillRect:CGRectMake(0, 0, 256, 3)];
        [ctx fillRect:CGRectMake(0, 0, 3, 256)];
    }];
}

- (void)buildCinemaAndEnvironment
{
    self.cinemaRootNode = [SCNNode node];
    [self.scene.rootNode addChildNode:self.cinemaRootNode];

    // Lightweight 120 FPS constant-shaded 3D cyber theater environment
    self.envGroupNode = [SCNNode node];
    [self.cinemaRootNode addChildNode:self.envGroupNode];

    SCNPlane *floorGeo = [SCNPlane planeWithWidth:24.0 height:24.0];
    SCNMaterial *floorMat = [SCNMaterial material];
    floorMat.lightingModelName = SCNLightingModelConstant;
    floorMat.diffuse.contents = [self createCyberGridImage:ColorHex(0x2F4670, 0.72) bgColor:ColorHex(0x06070D)];
    floorMat.diffuse.wrapS = SCNWrapModeRepeat;
    floorMat.diffuse.wrapT = SCNWrapModeRepeat;
    floorMat.diffuse.contentsTransform = SCNMatrix4MakeScale(24, 24, 1);
    floorGeo.materials = @[floorMat];
    SCNNode *floorNode = [SCNNode nodeWithGeometry:floorGeo];
    floorNode.position = SCNVector3Make(0, -1.65f, 0);
    floorNode.eulerAngles = SCNVector3Make(static_cast<float>(-M_PI_2), 0, 0);
    [self.envGroupNode addChildNode:floorNode];

    SCNPlane *ceilGeo = [SCNPlane planeWithWidth:24.0 height:24.0];
    SCNMaterial *ceilMat = [SCNMaterial material];
    ceilMat.lightingModelName = SCNLightingModelConstant;
    ceilMat.diffuse.contents = [self createCyberGridImage:ColorHex(0x262040, 0.48) bgColor:ColorHex(0x06070D)];
    ceilMat.diffuse.wrapS = SCNWrapModeRepeat;
    ceilMat.diffuse.wrapT = SCNWrapModeRepeat;
    ceilMat.diffuse.contentsTransform = SCNMatrix4MakeScale(20, 20, 1);
    ceilGeo.materials = @[ceilMat];
    SCNNode *ceilNode = [SCNNode nodeWithGeometry:ceilGeo];
    ceilNode.position = SCNVector3Make(0, 2.95f, 0);
    ceilNode.eulerAngles = SCNVector3Make(static_cast<float>(M_PI_2), 0, 0);
    [self.envGroupNode addChildNode:ceilNode];

    SCNTorus *ring1 = [SCNTorus torusWithRingRadius:5.8 pipeRadius:0.015];
    SCNMaterial *ringMat = [SCNMaterial material];
    ringMat.lightingModelName = SCNLightingModelConstant;
    ringMat.diffuse.contents = ColorHex(0x6D56A8, 0.55);
    ring1.materials = @[ringMat];
    SCNNode *ringNode = [SCNNode nodeWithGeometry:ring1];
    ringNode.position = SCNVector3Make(0, -1.60f, 0);
    [self.envGroupNode addChildNode:ringNode];

    SCNBox *pillarGeo = [SCNBox boxWithWidth:0.12 height:4.6 length:0.12 chamferRadius:0.02];
    SCNMaterial *pillarMat = [SCNMaterial material];
    pillarMat.lightingModelName = SCNLightingModelConstant;
    pillarMat.diffuse.contents = ColorHex(0x161B2E);
    pillarGeo.materials = @[pillarMat];
    for (int i = 0; i < 8; ++i)
    {
        float ang = static_cast<float>(i) * (static_cast<float>(M_PI) * 0.25f) + 0.39f;
        SCNNode *p = [SCNNode nodeWithGeometry:pillarGeo];
        p.position = SCNVector3Make(sinf(ang) * 5.6f, 0.65f, cosf(ang) * 5.6f);
        [self.envGroupNode addChildNode:p];
    }

    self.screenAnchorNode = [SCNNode node];
    self.screenAnchorNode.position = SCNVector3Make(0, 0.0f, -self.screenDistance);
    [self.cinemaRootNode addChildNode:self.screenAnchorNode];

    self.parsecScreenNode = [self makePlaneNode:@"parsec_screen" width:kBaseScreenWidth height:(kBaseScreenWidth * 9.0 / 16.0) color:ColorHex(0x0E0F14)];
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

- (void)setupOverlayButtons
{
    self.quickSetupButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.quickSetupButton.frame = CGRectMake(14, 14, 140, 32);
    self.quickSetupButton.backgroundColor = ColorHex(0x2B2930, 0.85);
    self.quickSetupButton.layer.cornerRadius = 16;
    [self.quickSetupButton setTitle:@"Parsec Setup" forState:UIControlStateNormal];
    [self.quickSetupButton setTitleColor:ColorHex(0xE6E0E9) forState:UIControlStateNormal];
    self.quickSetupButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.quickSetupButton addTarget:self action:@selector(openQuickSetupAlert) forControlEvents:UIControlEventTouchUpInside];
    self.quickSetupButton.alpha = 0.25;
    [self.view addSubview:self.quickSetupButton];

    self.viewModeButton = [UIButton buttonWithType:UIButtonTypeSystem];
    self.viewModeButton.frame = CGRectMake(162, 14, 136, 32);
    self.viewModeButton.backgroundColor = ColorHex(0x2B2930, 0.85);
    self.viewModeButton.layer.cornerRadius = 16;
    [self.viewModeButton setTitle:@"View: VR Box QR" forState:UIControlStateNormal];
    [self.viewModeButton setTitleColor:ColorHex(0xD0BCFF) forState:UIControlStateNormal];
    self.viewModeButton.titleLabel.font = [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold];
    [self.viewModeButton addTarget:self action:@selector(toggleSingleScreenTouchMode) forControlEvents:UIControlEventTouchUpInside];
    self.viewModeButton.alpha = 0.25;
    [self.view addSubview:self.viewModeButton];
}

- (void)toggleSingleScreenTouchMode
{
    self.singleScreenTouchMode = !self.singleScreenTouchMode;
    if (self.singleScreenTouchMode)
    {
        self.compositorView.scene = self.scene;
        self.compositorView.pointOfView = self.centerEyeNode;
        [self.viewModeButton setTitle:@"View: Full 2D" forState:UIControlStateNormal];
        self.quickSetupButton.alpha = 0.92;
        self.viewModeButton.alpha = 0.92;
    }
    else
    {
        self.compositorView.scene = self.compositorScene;
        self.compositorView.pointOfView = self.compositorCamNode;
        [self.viewModeButton setTitle:@"View: VR Box QR" forState:UIControlStateNormal];
        self.quickSetupButton.alpha = 0.25;
        self.viewModeButton.alpha = 0.25;
    }
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

#pragma mark - 120 Hz CoreMotion IMU & ARKit 6DoF Tracking

- (void)setupCoreMotion120Hz
{
    self.motionManager = [[CMMotionManager alloc] init];
    self.motionManager.deviceMotionUpdateInterval = 1.0 / 120.0;
    if (self.motionManager.isDeviceMotionAvailable)
    {
        [self.motionManager startDeviceMotionUpdatesUsingReferenceFrame:CMAttitudeReferenceFrameXArbitraryZVertical];
    }
}

- (void)setupArSession
{
    self.arSession = [[ARSession alloc] init];
    self.arSession.delegate = self;
    self.arSession.delegateQueue = dispatch_get_main_queue();
    [self syncArSessionState];
}

- (void)syncArSessionState
{
    BOOL needCamera = self.sixDofEnabled || (self.envMode == 2);
    if (needCamera)
    {
        ARWorldTrackingConfiguration *cfg = [[ARWorldTrackingConfiguration alloc] init];
        cfg.worldAlignment = ARWorldAlignmentGravity;
        [self.arSession runWithConfiguration:cfg];
    }
    else
    {
        [self.arSession pause];
        self.hasArPosition = NO;
    }
}

- (UIInterfaceOrientation)currentInterfaceOrientation
{
    if (self.view.window.windowScene != nil)
        return self.view.window.windowScene.interfaceOrientation;
    return UIInterfaceOrientationLandscapeLeft;
}

- (void)updateHeadPose120Hz
{
    CMDeviceMotion *motion = self.motionManager.deviceMotion;
    if (motion)
    {
        simd_quatf qImu = CoreMotionToSceneKitOrientation(motion, [self currentInterfaceOrientation]);
        if (!self.yawInitialized)
        {
            simd_float3 fwd = simd_act(qImu, simd_make_float3(0.0f, 0.0f, -1.0f));
            self.yawOffsetRad = -atan2f(fwd.x, -fwd.z);
            self.yawInitialized = YES;
        }
        simd_quatf qYaw = simd_quaternion(self.yawOffsetRad, simd_make_float3(0.0f, 1.0f, 0.0f));
        self.headNode.simdOrientation = simd_mul(qYaw, qImu);
    }

    if (self.sixDofEnabled && self.hasArPosition)
    {
        simd_float3 p = self.arHeadPos - self.arHeadOffset;
        self.headNode.position = SCNVector3Make(p.x, p.y, p.z);
    }
    else
    {
        self.headNode.position = SCNVector3Zero;
    }

    if (!self.hasRecenteredOnce && motion)
    {
        self.hasRecenteredOnce = YES;
        [self recenterWorkspace];
    }
}

- (void)session:(ARSession *)session didUpdateFrame:(ARFrame *)frame
{
    (void)session;
    if (frame.camera.trackingState == ARTrackingStateNormal)
    {
        simd_float4x4 viewMat = [frame.camera viewMatrixForOrientation:[self currentInterfaceOrientation]];
        simd_float4x4 camToWorld = simd_inverse(viewMat);
        self.arHeadPos = camToWorld.columns[3].xyz;
        self.hasArPosition = YES;
    }

    if (self.envMode == 2 && !self.passthroughBusy)
    {
        CFTimeInterval now = CACurrentMediaTime();
        if (now >= self.nextPassthroughAt)
        {
            self.nextPassthroughAt = now + (1.0 / 30.0);
            self.passthroughBusy = YES;
            CVPixelBufferRef pb = CVPixelBufferRetain(frame.capturedImage);
            UIInterfaceOrientation orient = [self currentInterfaceOrientation];
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
            if (bg && strongSelf.envMode == 2)
                strongSelf.scene.background.contents = bg;
            strongSelf.passthroughBusy = NO;
        }
    });
}

#pragma mark - 120 FPS Dual-Eye Offscreen Render + Distortion Pass

- (void)renderEyesIntoMetalTexturesAtTime:(NSTimeInterval)time
{
    if (!_eyeColorTex[0] || !_eyeColorTex[1] || !_eyeDepthTex[0] || !_eyeDepthTex[1])
        return;

    id<MTLCommandBuffer> cmdBuf = [self.mtlQueue commandBuffer];
    if (!cmdBuf)
        return;

    CGRect vp = CGRectMake(0, 0, _eyeTexW, _eyeTexH);
    for (int eye = 0; eye < 2; ++eye)
    {
        MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
        rpd.colorAttachments[0].texture = _eyeColorTex[eye];
        rpd.colorAttachments[0].loadAction = MTLLoadActionClear;
        rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
        rpd.colorAttachments[0].clearColor = (self.envMode == 0)
            ? MTLClearColorMake(0.024, 0.027, 0.051, 1.0)
            : MTLClearColorMake(0.0, 0.0, 0.0, 1.0);

        rpd.depthAttachment.texture = _eyeDepthTex[eye];
        rpd.depthAttachment.loadAction = MTLLoadActionClear;
        rpd.depthAttachment.storeAction = MTLStoreActionDontCare;
        rpd.depthAttachment.clearDepth = 1.0;

        [_eyeRenderers[eye] renderAtTime:time viewport:vp commandBuffer:cmdBuf passDescriptor:rpd];
    }
    [cmdBuf commit];
}

- (void)onTick:(CADisplayLink *)link
{
    (void)link;
    CFTimeInterval now = CACurrentMediaTime();
    float dt = static_cast<float>(std::max(0.001, std::min(0.05, now - self.lastTickAt)));
    self.lastTickAt = now;

    [self updateHeadPose120Hz];

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
        while (diff > static_cast<float>(M_PI)) diff -= 2.0f * static_cast<float>(M_PI);
        while (diff < static_cast<float>(-M_PI)) diff += 2.0f * static_cast<float>(M_PI);
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

- (void)renderer:(id<SCNSceneRenderer>)renderer willRenderScene:(SCNScene *)scene atTime:(NSTimeInterval)time
{
    (void)renderer;
    (void)scene;
    if (!self.singleScreenTouchMode)
        [self renderEyesIntoMetalTexturesAtTime:time];
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

- (void)adjustInterLensBy:(float)deltaMeters
{
    _viewer.interLensDistance = std::max(0.050f, std::min(0.075f, _viewer.interLensDistance + deltaMeters));
    [[NSUserDefaults standardUserDefaults] setFloat:_viewer.interLensDistance forKey:kPrefQrInterLens];
    [self rebuildCardboardDistortionRig];
    [self showBarToast:[NSString stringWithFormat:@"VR Box QR Goz (IPD): %.1f mm", _viewer.interLensDistance * 1000.0f]];
    [self redrawParsecBar];
    if (!self.parsecConnected)
        [self redrawParsecPanel];
}

- (void)adjustScreenScaleBy:(float)delta
{
    self.screenScale = std::max(0.60f, std::min(2.40f, self.screenScale + delta));
    [[NSUserDefaults standardUserDefaults] setFloat:self.screenScale forKey:kPrefScreenScale];
    [self applyScreenLayoutAndScale];
    [self showBarToast:[NSString stringWithFormat:@"Ekran Boyutu: %.0f%%", self.screenScale * 100.0f]];
    [self redrawParsecBar];
}

- (void)adjustScreenDistBy:(float)delta
{
    self.screenDistance = std::max(0.85f, std::min(2.60f, self.screenDistance + delta));
    [[NSUserDefaults standardUserDefaults] setFloat:self.screenDistance forKey:kPrefScreenDist];
    [self applyScreenLayoutAndScale];
    [self showBarToast:[NSString stringWithFormat:@"Ekran Mesafesi: %.2fm", self.screenDistance]];
    [self redrawParsecBar];
}

- (void)cycleEnvMode
{
    self.envMode = (self.envMode + 1) % 3;
    self.envGroupNode.hidden = (self.envMode != 0);
    if (self.envMode == 0)
        self.scene.background.contents = ColorHex(0x06070D);
    else if (self.envMode == 1)
        self.scene.background.contents = [UIColor blackColor];

    // Toggle stereo eye disparity vs MonoEyes for camera passthrough
    [self syncArSessionState];
    [self rebuildCardboardDistortionRig];
    NSString *msg = self.envMode == 0 ? @"Ortam: 3D VR 120FPS" : (self.envMode == 1 ? @"Ortam: Siyah Sinema" : @"Ortam: Kamera");
    [self showBarToast:msg];
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
                if (dpL) [self adjustInterLensBy:-0.0005f];
                if (dpR) [self adjustInterLensBy:0.0005f];
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
            [self adjustInterLensBy:(dpR ? 0.0005f : -0.0005f)];
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
        if (btnMenu && !self.prevBtnMenu)
        {
            self.prevBtnMenu = YES;
            [self toggleGamepadMode];
            return;
        }

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

        float sy = ApplyDeadzone(ry, 0.14f);
        if (sy != 0.0f && now >= self.nextNavRepeatAt)
        {
            self.nextNavRepeatAt = now + 0.035;
            VRParsecSendMouseWheel(0, static_cast<int>(sy * 110.0f));
        }

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

        if (btnB && !self.prevBtnB)
        {
            AudioServicesPlaySystemSound(1104);
            VRParsecSendMouseButton(3, 1);
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.04 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                VRParsecSendMouseButton(3, 0);
            });
        }

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

        if (btnY && !self.prevBtnY)
        {
            AudioServicesPlaySystemSound(1104);
            [self recenterWorkspace];
            [self showBarToast:@"Ekran Ortalandi"];
            [self redrawParsecBar];
        }

        if (dpL || dpR || dpU || dpD)
        {
            if (now >= self.nextComboRepeatAt)
            {
                self.nextComboRepeatAt = now + 0.09;
                if (dpL) [self adjustInterLensBy:-0.0005f];
                if (dpR) [self adjustInterLensBy:0.0005f];
                if (dpU) [self adjustScreenScaleBy:0.08f];
                if (dpD) [self adjustScreenScaleBy:-0.08f];
            }
        }

        if (btnLB && !self.prevBtnLB)
            [self adjustScreenDistBy:0.12f];
        if (btnRB && !self.prevBtnRB)
            [self adjustScreenDistBy:-0.12f];

        if (btnView && !self.prevComboToggle && now >= self.nextNavRepeatAt)
        {
            self.nextNavRepeatAt = now + 0.30;
            [self cycleEnvMode];
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

#pragma mark - Gaze & Touch Raycast

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

- (VRRayHit)raycastFlat2DTouchPoint:(CGPoint)ptInView
{
    SCNVector3 pNear = [self.compositorView unprojectPoint:SCNVector3Make(ptInView.x, ptInView.y, 0.0f)];
    SCNVector3 pFar = [self.compositorView unprojectPoint:SCNVector3Make(ptInView.x, ptInView.y, 1.0f)];
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
    VRRayHit hit = self.singleScreenTouchMode
        ? [self raycastFlat2DTouchPoint:[touch locationInView:self.view]]
        : [self raycastCenterGaze];
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
    if (!touch || !self.parsecMouseHeld || !self.parsecConnected || !self.singleScreenTouchMode) return;
    VRRayHit hit = [self raycastFlat2DTouchPoint:[touch locationInView:self.view]];
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

#pragma mark - UI Button Actions

- (void)handleButtonClick:(NSString *)btnId
{
    if ([btnId isEqualToString:@"auth_setup"]) { [self openQuickSetupAlert]; return; }
    if ([btnId isEqualToString:@"hosts_refresh"]) { [self refreshHosts]; return; }
    if ([btnId isEqualToString:@"hosts_signout"]) { [self signOutParsec]; return; }
    if ([btnId isEqualToString:@"connect_cancel"]) { [self cancelConnect]; return; }
    if ([btnId isEqualToString:@"ipd_minus"]) { [self adjustInterLensBy:-0.001f]; return; }
    if ([btnId isEqualToString:@"ipd_plus"]) { [self adjustInterLensBy:0.001f]; return; }

    if ([btnId hasPrefix:@"host_"])
    {
        NSInteger idx = [[btnId substringFromIndex:5] integerValue];
        [self connectToHostAtIndex:idx];
        return;
    }

    if ([btnId isEqualToString:@"bar_mode"]) { [self toggleGamepadMode]; return; }
    if ([btnId isEqualToString:@"bar_sz_minus"]) { [self adjustScreenScaleBy:-0.10f]; return; }
    if ([btnId isEqualToString:@"bar_sz_plus"]) { [self adjustScreenScaleBy:0.10f]; return; }
    if ([btnId isEqualToString:@"bar_ipd_minus"]) { [self adjustInterLensBy:-0.001f]; return; }
    if ([btnId isEqualToString:@"bar_ipd_plus"]) { [self adjustInterLensBy:0.001f]; return; }
    if ([btnId isEqualToString:@"bar_lock"])
    {
        self.headLockMode = !self.headLockMode;
        [self redrawParsecBar];
        return;
    }
    if ([btnId isEqualToString:@"bar_env"])
    {
        [self cycleEnvMode];
        return;
    }
    if ([btnId isEqualToString:@"bar_dof"])
    {
        self.sixDofEnabled = !self.sixDofEnabled;
        if (self.sixDofEnabled && self.hasArPosition)
            self.arHeadOffset = self.arHeadPos;
        [self syncArSessionState];
        [self showBarToast:(self.sixDofEnabled ? @"Takip: 6DoF (120Hz IMU + AR)" : @"Takip: 3DoF (Saf 120Hz IMU)")];
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
    self.gazeDotNode.hidden = self.parsecConnected;
    self.parsecCursorNode.hidden = !self.parsecConnected || self.gamepadPassthroughMode;
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
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Parsec & VR BOX QR Setup"
                                                                   message:[NSString stringWithFormat:@"QR Profile: VR BOX (IPD %.1f mm). Adjust IPD anytime with Xbox D-Pad Left/Right.", _viewer.interLensDistance * 1000.0f]
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
    [alert addAction:[UIAlertAction actionWithTitle:@"Reset VR BOX QR (63mm)" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        (void)a;
        _viewer.interLensDistance = 0.063000f;
        [[NSUserDefaults standardUserDefaults] setFloat:_viewer.interLensDistance forKey:kPrefQrInterLens];
        [self rebuildCardboardDistortionRig];
        [self redrawAllPanels];
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
        ? [NSString stringWithFormat:@"Xbox Kolu: BAGLI (%@)  |  QR: VR BOX (IPD %.1f mm)",
           self.activeController.vendorName ?: @"Gamepad", _viewer.interLensDistance * 1000.0f]
        : [NSString stringWithFormat:@"Xbox Kolu: Bekleniyor (Bluetooth ile eslestir)  |  QR: VR BOX (%.1f mm)",
           _viewer.interLensDistance * 1000.0f];
    UIColor *ctrlColor = self.activeController ? ColorHex(0x80E5A3) : ColorHex(0xF6C177);

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x1D1B22, 0.96) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:34] fill];

        [self drawText:@"VR BOX Parsec Cinema (120 FPS)" rect:CGRectMake(40, 26, 760, 42) size:32 color:ColorHex(0xE6E0E9) bold:YES align:NSTextAlignmentLeft];
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
                       title:[NSString stringWithFormat:@"IPD - (%.1fmm)", _viewer.interLensDistance * 1000.0f]
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(534, 486, 176, 62) canvas:sz buttonId:@"ipd_plus" title:@"IPD +"
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
                       title:[NSString stringWithFormat:@"VR BOX IPD - (%.1f mm)", _viewer.interLensDistance * 1000.0f]
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
            [self drawButton:CGRectMake(496, 280, 420, 68) canvas:sz buttonId:@"ipd_plus" title:@"VR BOX IPD +"
                    selected:NO xboxFocused:idxFocus(itemIdx++) outlined:YES filled:NO disabled:NO hitList:_parsecPanelHits];
        }

        [self drawText:@"Xbox Kontrol: D-Pad Up/Dn: Sec | A: Baglan | X: Yenile | D-Pad L/R: IPD (mm) | Y: Ortala"
                  rect:CGRectMake(40, 616, 880, 34) size:18 color:ColorHex(0xA9A3B5) bold:YES align:NSTextAlignmentCenter];
    }];
    self.parsecPanelNode.geometry.firstMaterial.diffuse.contents = img;
}

- (void)redrawParsecBar
{
    _parsecBarHits.clear();
    CGSize sz = CGSizeMake(1440, 186);
    UIGraphicsImageRenderer *r = [self makeUiRendererWithSize:sz];

    NSString *modeLabel = self.gamepadPassthroughMode
        ? @"MOD: XBOX KOLU (View+Menu=Fare)"
        : @"MOD: FARE (Menu=Oyun Kolu)";
    NSString *statusLine = (self.barToastText.length > 0)
        ? self.barToastText
        : [NSString stringWithFormat:@"%@ (%dx%d)  |  %@  |  QR: VR BOX %.1f mm  Boyut: %.0f%%",
           self.connectedHostName, self.hostWidth, self.hostHeight,
           (self.activeController ? @"Xbox Bagli" : @"Xbox Yok"),
           _viewer.interLensDistance * 1000.0f, self.screenScale * 100.0f];
    NSString *hintLine = self.gamepadPassthroughMode
        ? @"Tam Xbox 360 Kolu PC'ye Aktariliyor!  |  View basili tut + [Menu: Fare Modu | Y: Ortala | D-Pad L/R: IPD | D-Pad U/D: Boyut]"
        : @"L-Stick: Fare | A: Sol Tik/Surukle | B: Sag Tik | X: Cift Tik | R-Stick: Kaydir | Y: Ortala | D-Pad: IPD/Boyut | LB/RB: Mesafe";
    NSString *envLabel = self.envMode == 0 ? @"3D Ortam" : (self.envMode == 1 ? @"Siyah" : @"Kamera");

    UIImage *img = [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        (void)ctx;
        [ColorHex(0x1D1B22, 0.94) setFill];
        [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, sz.width, sz.height) cornerRadius:28] fill];

        UIColor *topColor = (self.barToastText.length > 0) ? ColorHex(0x80E5A3) : ColorHex(0xE6E0E9);
        [self drawText:statusLine rect:CGRectMake(26, 16, 1388, 30) size:22 color:topColor bold:YES align:NSTextAlignmentLeft];

        [self drawButton:CGRectMake(24, 56, 360, 58) canvas:sz buttonId:@"bar_mode" title:modeLabel
                selected:self.gamepadPassthroughMode xboxFocused:NO outlined:NO filled:YES disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(396, 56, 106, 58) canvas:sz buttonId:@"bar_ipd_minus" title:@"IPD -"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(512, 56, 106, 58) canvas:sz buttonId:@"bar_ipd_plus" title:@"IPD +"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(630, 56, 114, 58) canvas:sz buttonId:@"bar_sz_minus" title:@"Boyut -"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(754, 56, 114, 58) canvas:sz buttonId:@"bar_sz_plus" title:@"Boyut +"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(880, 56, 136, 58) canvas:sz buttonId:@"bar_env" title:envLabel
                selected:(self.envMode == 0) xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(1028, 56, 130, 58) canvas:sz buttonId:@"bar_dof"
                   title:(self.sixDofEnabled ? @"6DoF" : @"3DoF")
                selected:self.sixDofEnabled xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(1170, 56, 122, 58) canvas:sz buttonId:@"bar_recenter" title:@"Ortala"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];
        [self drawButton:CGRectMake(1304, 56, 112, 58) canvas:sz buttonId:@"bar_disc" title:@"Kes"
                selected:NO xboxFocused:NO outlined:YES filled:NO disabled:NO hitList:_parsecBarHits];

        [self drawText:hintLine rect:CGRectMake(26, 132, 1388, 34) size:17 color:ColorHex(0xA9A3B5) bold:YES align:NSTextAlignmentCenter];
    }];
    self.parsecBarNode.geometry.firstMaterial.diffuse.contents = img;
}

@end
