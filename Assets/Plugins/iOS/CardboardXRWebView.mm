// Offscreen WKWebView bridge that renders web pages into a Unity Metal RenderTexture
// and forwards spatial pointer clicks, scrolls, and virtual keyboard input via DOM scripts.

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>
#include <cstdlib>
#include <cstring>
#include <string>

@interface CardboardWebHost : NSObject <WKNavigationDelegate>
@property (nonatomic, strong) WKWebView *webView;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, copy) NSString *currentUrl;
@property (nonatomic, assign) BOOL loading;
@property (nonatomic, assign) CGContextRef bitmapCtx;
@property (nonatomic, assign) uint8_t *pixelBuffer;
@end

@implementation CardboardWebHost

- (void)setupWithWidth:(int)w height:(int)h
{
    self.width = w;
    self.height = h;
    self.currentUrl = @"about:blank";
    self.loading = NO;

    size_t bufSize = static_cast<size_t>(w) * static_cast<size_t>(h) * 4;
    self.pixelBuffer = static_cast<uint8_t *>(calloc(1, bufSize));
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    // No CTM flip here: WebKit layer renders top-down into memory whose row 0 maps to Unity UV v=0 on Metal.
    self.bitmapCtx = CGBitmapContextCreate(self.pixelBuffer,
                                           static_cast<size_t>(w),
                                           static_cast<size_t>(h),
                                           8,
                                           static_cast<size_t>(w) * 4,
                                           cs,
                                           kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
    CGColorSpaceRelease(cs);

    WKWebViewConfiguration *cfg = [[WKWebViewConfiguration alloc] init];
    cfg.allowsInlineMediaPlayback = YES;
    cfg.mediaTypesRequiringUserActionForPlayback = WKAudiovisualMediaTypeNone;

    self.webView = [[WKWebView alloc] initWithFrame:CGRectMake(-4096, -4096, w, h) configuration:cfg];
    self.webView.navigationDelegate = self;
    self.webView.alpha = 0.01;
    self.webView.userInteractionEnabled = NO;
    // Desktop Safari user agent ensures web apps render full layouts in the 1280x800 virtual monitor.
    self.webView.customUserAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.6 Safari/605.1.15";

    UIWindow *hostWindow = [self activeWindow];
    if (hostWindow)
        [hostWindow addSubview:self.webView];
}

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

- (void)teardown
{
    if (self.webView)
    {
        [self.webView stopLoading];
        self.webView.navigationDelegate = nil;
        [self.webView removeFromSuperview];
        self.webView = nil;
    }
    if (self.bitmapCtx)
    {
        CGContextRelease(self.bitmapCtx);
        self.bitmapCtx = nullptr;
    }
    if (self.pixelBuffer)
    {
        free(self.pixelBuffer);
        self.pixelBuffer = nullptr;
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
    CardboardWebHost *g_webHost = nil;

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

extern "C" void CardboardXR_WebInit(int width, int height)
{
    int w = width > 64 ? width : 1280;
    int h = height > 64 ? height : 800;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_webHost)
            [g_webHost teardown];
        g_webHost = [[CardboardWebHost alloc] init];
        [g_webHost setupWithWidth:w height:h];
    });
}

extern "C" void CardboardXR_WebDestroy()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_webHost)
        {
            [g_webHost teardown];
            g_webHost = nil;
        }
    });
}

extern "C" void CardboardXR_WebLoadUrl(const char *url)
{
    if (!url)
        return;
    NSString *nsUrl = [NSString stringWithUTF8String:url];
    if (!nsUrl)
        return;
    if (![nsUrl hasPrefix:@"http://"] && ![nsUrl hasPrefix:@"https://"])
        nsUrl = [@"https://" stringByAppendingString:nsUrl];

    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_webHost || !g_webHost.webView)
            return;
        if (!g_webHost.webView.superview)
        {
            UIWindow *win = [g_webHost activeWindow];
            if (win)
                [win addSubview:g_webHost.webView];
        }
        NSURL *target = [NSURL URLWithString:nsUrl];
        if (target)
            [g_webHost.webView loadRequest:[NSURLRequest requestWithURL:target]];
    });
}

extern "C" void CardboardXR_WebGoBack()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_webHost && g_webHost.webView.canGoBack)
            [g_webHost.webView goBack];
    });
}

extern "C" void CardboardXR_WebGoForward()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_webHost && g_webHost.webView.canGoForward)
            [g_webHost.webView goForward];
    });
}

extern "C" void CardboardXR_WebReload()
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (g_webHost && g_webHost.webView)
            [g_webHost.webView reload];
    });
}

extern "C" int CardboardXR_WebUpdateTexture(void *mtlTexturePtr)
{
    if (!mtlTexturePtr || !g_webHost || !g_webHost.webView || !g_webHost.bitmapCtx || !g_webHost.pixelBuffer)
        return 0;

    id<MTLTexture> tex = (__bridge id<MTLTexture>)mtlTexturePtr;
    if (!tex)
        return 0;

    int w = g_webHost.width;
    int h = g_webHost.height;
    if (static_cast<int>(tex.width) != w || static_cast<int>(tex.height) != h)
        return 0;

    void (^renderBlock)(void) = ^{
        if (!g_webHost || !g_webHost.webView || !g_webHost.bitmapCtx)
            return;
        CGContextSaveGState(g_webHost.bitmapCtx);
        CGContextSetRGBFillColor(g_webHost.bitmapCtx, 0.12, 0.12, 0.14, 1.0);
        CGContextFillRect(g_webHost.bitmapCtx, CGRectMake(0, 0, w, h));
        [g_webHost.webView.layer renderInContext:g_webHost.bitmapCtx];
        CGContextRestoreGState(g_webHost.bitmapCtx);
    };

    if ([NSThread isMainThread])
        renderBlock();
    else
        dispatch_sync(dispatch_get_main_queue(), renderBlock);

    [tex replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(w), static_cast<NSUInteger>(h))
           mipmapLevel:0
             withBytes:g_webHost.pixelBuffer
           bytesPerRow:static_cast<NSUInteger>(w) * 4];
    return 1;
}

extern "C" void CardboardXR_WebClick(float normX, float normY)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_webHost || !g_webHost.webView)
            return;
        float px = normX * g_webHost.width;
        float py = normY * g_webHost.height;
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
        [g_webHost.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" void CardboardXR_WebScroll(float normX, float normY, float deltaY)
{
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_webHost || !g_webHost.webView)
            return;
        float px = normX * g_webHost.width;
        float py = normY * g_webHost.height;
        NSString *js = [NSString stringWithFormat:
            @"(function(){"
            "var el = document.elementFromPoint(%f, %f) || document.scrollingElement || document.documentElement;"
            "if (el && el.scrollBy) el.scrollBy(0, %f);"
            "window.scrollBy(0, %f);"
            "})();", px, py, deltaY, deltaY];
        [g_webHost.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" void CardboardXR_WebTypeKey(const char *text, int isBackspace, int isEnter)
{
    NSString *escaped = EscapeJsString(text);
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!g_webHost || !g_webHost.webView)
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
        [g_webHost.webView evaluateJavaScript:js completionHandler:nil];
    });
}

extern "C" const char *CardboardXR_WebGetUrl()
{
    if (!g_webHost || !g_webHost.currentUrl)
        return strdup("");
    return strdup([g_webHost.currentUrl UTF8String]);
}

extern "C" int CardboardXR_WebIsLoading()
{
    return (g_webHost && g_webHost.loading) ? 1 : 0;
}
