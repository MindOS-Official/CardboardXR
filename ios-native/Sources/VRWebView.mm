// Multi-instance offscreen WKWebView pool (up to 5 independent side monitors)
// returning upright UIImages for SceneKit textures and forwarding DOM clicks, scrolls, and typing.

#import "VRBridge.h"
#import <WebKit/WebKit.h>

@interface VRWebHost : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, copy) NSString *currentUrl;
@property (nonatomic, assign) BOOL loading;
@end

@implementation VRWebHost

- (UIWindow *)activeWindow
{
    for (UIScene *scene in UIApplication.sharedApplication.connectedScenes)
    {
        if (scene.activationState != UISceneActivationStateForegroundActive || ![scene isKindOfClass:[UIWindowScene class]])
            continue;
        UIWindowScene *ws = (UIWindowScene *)scene;
        for (UIWindow *win in ws.windows)
        {
            if (win.isKeyWindow)
                return win;
        }
        if (ws.windows.count > 0)
            return ws.windows.firstObject;
    }
    return nil;
}

- (void)setupWithWidth:(int)w height:(int)h initialUrl:(NSString *)url
{
    self.width = w;
    self.height = h;
    self.currentUrl = url ?: @"https://duckduckgo.com";
    self.loading = NO;

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-4096, -4096, w, h) configuration:cfg];
    self.webView.navigationDelegate = self;
    self.webView.alpha = 0.01;
    self.webView.userInteractionEnabled = NO;
    self.webView.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

    UIWindow *win = [self activeWindow];
    if (win)
        [win addSubview:self.webView];

    NSURL *nsUrl = [NSURL URLWithString:self.currentUrl];
    if (nsUrl)
        [self.webView loadRequest:[NSURLRequest requestWithURL:nsUrl]];
}

- (void)teardown
{
    if (self.webView)
    {
        [self.webView stopLoading];
        self.webView.navigationDelegate = nil;
        [self.webView removeFromSuperview];
        self.webView = nil;
    }
}

- (void)webView:(WKWebView *)webView didStartProvisionalNavigation:(WKNavigation *)navigation
{
    (void)navigation;
    self.loading = YES;
    if (webView.URL)
        self.currentUrl = webView.URL.absoluteString;
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation
{
    (void)navigation;
    self.loading = NO;
    if (webView.URL)
        self.currentUrl = webView.URL.absoluteString;
}

- (void)webView:(WKWebView *)webView didFailNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)navigation;
    (void)error;
    self.loading = NO;
    if (webView.URL)
        self.currentUrl = webView.URL.absoluteString;
}

- (void)webView:(WKWebView *)webView didFailProvisionalNavigation:(WKNavigation *)navigation withError:(NSError *)error
{
    (void)navigation;
    (void)error;
    self.loading = NO;
}

@end

namespace
{
    VRWebHost *g_webHosts[kMaxWebMonitors] = {};

    VRWebHost *HostForSlot(int slot)
    {
        if (slot < 0 || slot >= kMaxWebMonitors)
            return nil;
        return g_webHosts[slot];
    }

    NSString *EscapeJsString(const char *utf8)
    {
        if (!utf8)
            return @"";
        NSString *raw = [NSString stringWithUTF8String:utf8];
        if (!raw)
            return @"";
        raw = [raw stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
        raw = [raw stringByReplacingOccurrencesOfString:@"'" withString:@"\\'"];
        raw = [raw stringByReplacingOccurrencesOfString:@"\n" withString:@"\\n"];
        raw = [raw stringByReplacingOccurrencesOfString:@"\r" withString:@"\\r"];
        return raw;
    }
}

extern "C" void VRWebInitSlot(int slot, int width, int height, const char *initialUrl)
{
    if (slot < 0 || slot >= kMaxWebMonitors)
        return;
    int w = width > 64 ? width : 1280;
    int h = height > 64 ? height : 800;
    NSString *nsInitial = initialUrl ? [NSString stringWithUTF8String:initialUrl] : @"https://duckduckgo.com";

    dispatch_block_t block = ^{
        if (g_webHosts[slot])
            [g_webHosts[slot] teardown];
        g_webHosts[slot] = [[VRWebHost alloc] init];
        [g_webHosts[slot] setupWithWidth:w height:h initialUrl:nsInitial];
    };
    if ([NSThread isMainThread])
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

extern "C" void VRWebDestroyAll(void)
{
    dispatch_block_t block = ^{
        for (int i = 0; i < kMaxWebMonitors; ++i)
        {
            if (g_webHosts[i])
            {
                [g_webHosts[i] teardown];
                g_webHosts[i] = nil;
            }
        }
    };
    if ([NSThread isMainThread])
        block();
    else
        dispatch_async(dispatch_get_main_queue(), block);
}

extern "C" void VRWebLoadUrlSlot(int slot, const char *url)
{
    if (!url || slot < 0 || slot >= kMaxWebMonitors)
        return;
    NSString *nsUrl = [NSString stringWithUTF8String:url];
    if (!nsUrl)
        return;
    if (![nsUrl hasPrefix:@"http://"] && ![nsUrl hasPrefix:@"https://"])
        nsUrl = [@"https://" stringByAppendingString:nsUrl];

    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (!host || !host.webView)
            return;
        if (!host.webView.superview)
        {
            UIWindow *win = [host activeWindow];
            if (win)
                [win addSubview:host.webView];
        }
        NSURL *target = [NSURL URLWithString:nsUrl];
        if (target)
            [host.webView loadRequest:[NSURLRequest requestWithURL:target]];
    });
}

extern "C" void VRWebGoBackSlot(int slot)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (host && host.webView.canGoBack)
            [host.webView goBack];
    });
}

extern "C" void VRWebGoForwardSlot(int slot)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (host && host.webView.canGoForward)
            [host.webView goForward];
    });
}

extern "C" void VRWebReloadSlot(int slot)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (host && host.webView)
            [host.webView reload];
    });
}

extern "C" UIImage *VRWebSnapshotSlot(int slot)
{
    VRWebHost *host = HostForSlot(slot);
    if (!host || !host.webView)
        return nil;

    __block UIImage *img = nil;
    dispatch_block_t capture = ^{
        VRWebHost *h = HostForSlot(slot);
        if (!h || !h.webView)
            return;
        CGSize sz = CGSizeMake(h.width, h.height);
        UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat preferredFormat];
        fmt.scale = 1.0;
        fmt.opaque = YES;
        UIGraphicsImageRenderer *renderer = [[UIGraphicsImageRenderer alloc] initWithSize:sz format:fmt];
        img = [renderer imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
            [[UIColor colorWithWhite:0.12 alpha:1.0] setFill];
            [ctx fillRect:CGRectMake(0, 0, sz.width, sz.height)];
            [h.webView.layer renderInContext:ctx.CGContext];
        }];
    };

    if ([NSThread isMainThread])
        capture();
    else
        dispatch_sync(dispatch_get_main_queue(), capture);
    return img;
}

extern "C" void VRWebClickSlot(int slot, float normX, float normY)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (!host || !host.webView)
            return;
        float px = normX * host.width;
        float py = normY * host.height;
        NSString *js = [NSString stringWithFormat:
            @"(function(){"
            "var x = %f, y = %f;"
            "var el = document.elementFromPoint(x, y);"
            "if (!el) return;"
            "el.focus();"
            "['pointerdown','mousedown','pointerup','mouseup','click'].forEach(function(t){"
            "  el.dispatchEvent(new MouseEvent(t, {bubbles:true, cancelable:true, clientX:x, clientY:y, view:window}));"
            "});"
            "})();", px, py];
        [host.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" void VRWebScrollSlot(int slot, float normX, float normY, float deltaY)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (!host || !host.webView)
            return;
        float px = normX * host.width;
        float py = normY * host.height;
        NSString *js = [NSString stringWithFormat:
            @"(function(){"
            "var el = document.elementFromPoint(%f, %f) || document.scrollingElement || document.documentElement;"
            "if (el && el.scrollBy) el.scrollBy(0, %f);"
            "window.scrollBy(0, %f);"
            "})();", px, py, deltaY, deltaY];
        [host.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" void VRWebTypeKeySlot(int slot, const char *text, int isBackspace, int isEnter)
{
    NSString *escaped = EscapeJsString(text);
    dispatch_async(dispatch_get_main_queue(), ^{
        VRWebHost *host = HostForSlot(slot);
        if (!host || !host.webView)
            return;
        NSString *js = [NSString stringWithFormat:
            @"(function(){"
            "var el = document.activeElement;"
            "if (!el) return;"
            "var isText = (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.isContentEditable);"
            "if (%d) {"
            "  if (isText && el.value !== undefined && el.value.length > 0) {"
            "    var s = el.selectionStart ?? el.value.length;"
            "    var e = el.selectionEnd ?? el.value.length;"
            "    if (s !== e) { el.value = el.value.slice(0, s) + el.value.slice(e); el.selectionStart = el.selectionEnd = s; }"
            "    else if (s > 0) { el.value = el.value.slice(0, s - 1) + el.value.slice(e); el.selectionStart = el.selectionEnd = s - 1; }"
            "    el.dispatchEvent(new Event('input', {bubbles:true}));"
            "  }"
            "  return;"
            "}"
            "if (%d) {"
            "  el.dispatchEvent(new KeyboardEvent('keydown', {key:'Enter', code:'Enter', keyCode:13, which:13, bubbles:true}));"
            "  if (el.form) { if (el.form.requestSubmit) el.form.requestSubmit(); else el.form.submit(); }"
            "  return;"
            "}"
            "if (isText && '%@'.length > 0) {"
            "  var ch = '%@';"
            "  if (el.value !== undefined) {"
            "    var s = el.selectionStart ?? el.value.length;"
            "    var e = el.selectionEnd ?? el.value.length;"
            "    el.value = el.value.slice(0, s) + ch + el.value.slice(e);"
            "    el.selectionStart = el.selectionEnd = s + ch.length;"
            "    el.dispatchEvent(new Event('input', {bubbles:true}));"
            "  } else if (el.isContentEditable) {"
            "    document.execCommand('insertText', false, ch);"
            "  }"
            "}"
            "})();", isBackspace, isEnter, escaped, escaped];
        [host.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" NSString *VRWebGetUrlSlot(int slot)
{
    VRWebHost *host = HostForSlot(slot);
    return (host && host.currentUrl) ? host.currentUrl : @"";
}

extern "C" int VRWebIsLoadingSlot(int slot)
{
    VRWebHost *host = HostForSlot(slot);
    return (host && host.loading) ? 1 : 0;
}
