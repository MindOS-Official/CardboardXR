// Native iOS Parsec client bridge for Unity Metal RenderTextures, AudioQueue PCM output,
// and Keychain credential persistence.

#import <AudioToolbox/AudioToolbox.h>
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <Security/Security.h>
#include <atomic>
#include <cstring>
#include <mutex>
#include <string>
#include <vector>
#include "ParsecSDK.framework/Headers/parsec.h"

namespace
{
    constexpr int kNumAudioBuf = 16;
    constexpr UInt32 kAudioBufBytes = 4096;
    constexpr UInt32 kSilenceBufBytes = 4096;
    constexpr UInt32 kFakeSize = 0;
    constexpr int kLowestNumBuffer = 3;

    struct RecycleChain
    {
        AudioQueueBufferRef *curt;
        RecycleChain *next;
    };

    struct AudioContext
    {
        AudioQueueRef q;
        AudioQueueBufferRef audioBuf[kNumAudioBuf];
        AudioQueueBufferRef silenceBuf;
        char *mem[kNumAudioBuf * 2];
        int loc[kNumAudioBuf];
        RecycleChain *rc;
        std::atomic<RecycleChain *> first{nullptr};
        std::atomic<RecycleChain *> lastToQueue{nullptr};
        std::atomic<int32_t> failNum{0};
        std::atomic<int32_t> inUse{0};
        std::atomic<unsigned int> silenceInQueue{0};
        std::atomic<unsigned int> silenceOutQueue{0};
        std::mutex clearLock;
    };

    std::atomic<bool> g_audioMuted{false};
    std::atomic<bool> g_audioHeld{false};
    std::atomic<bool> g_audioStarted{false};
    std::atomic<int> g_lastAudioBuf{0};

    inline UInt32 BufferSizeLoad(AudioQueueBufferRef buffer)
    {
        return __atomic_load_n(&buffer->mAudioDataByteSize, __ATOMIC_ACQUIRE);
    }

    inline void BufferSizeStore(AudioQueueBufferRef buffer, UInt32 size)
    {
        __atomic_store_n(&buffer->mAudioDataByteSize, size, __ATOMIC_RELEASE);
    }

    void AudioQueueCallback(void *opaque, AudioQueueRef queue, AudioQueueBufferRef buffer)
    {
        AudioContext *ctx = static_cast<AudioContext *>(opaque);
        if (!ctx)
            return;

        if (ctx->inUse.load() > 0)
            ctx->inUse.fetch_sub(static_cast<int32_t>(BufferSizeLoad(buffer)));

        if (buffer != ctx->silenceBuf)
        {
            BufferSizeStore(buffer, kFakeSize);
            g_lastAudioBuf.store(*static_cast<int *>(buffer->mUserData));
        }
        else
        {
            ctx->silenceOutQueue.fetch_add(1);
        }

        if (g_audioMuted.load())
            return;

        RecycleChain *firstNode = ctx->first.load();
        int deltaBuf = *static_cast<int *>((*firstNode->curt)->mUserData) - g_lastAudioBuf.load() - 1;
        if (deltaBuf < 0)
            deltaBuf += kNumAudioBuf;

        RecycleChain *lastNode = ctx->lastToQueue.load();
        while (lastNode->next != firstNode)
        {
            AudioQueueEnqueueBuffer(ctx->q, *lastNode->next->curt, 0, nullptr);
            lastNode = lastNode->next;
            ctx->lastToQueue.store(lastNode);
        }

        int silencePending = static_cast<int>(ctx->silenceInQueue.load() - ctx->silenceOutQueue.load());
        if (silencePending < 0)
        {
            ctx->silenceOutQueue.store(ctx->silenceInQueue.load());
            silencePending = 0;
        }
        if (deltaBuf + silencePending < kLowestNumBuffer)
        {
            int numAdd = kLowestNumBuffer - deltaBuf - silencePending;
            for (int i = 0; i < numAdd; ++i)
                AudioQueueEnqueueBuffer(ctx->q, ctx->silenceBuf, 0, nullptr);
            ctx->silenceInQueue.fetch_add(static_cast<unsigned int>(numAdd));
        }
    }

    AudioContext *AudioInit()
    {
        AudioContext *ctx = new AudioContext();
        std::memset(ctx->mem, 0, sizeof(ctx->mem));
        AudioStreamBasicDescription fmt{};
        fmt.mSampleRate = 48000;
        fmt.mFormatID = kAudioFormatLinearPCM;
        fmt.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
        fmt.mFramesPerPacket = 1;
        fmt.mChannelsPerFrame = 2;
        fmt.mBitsPerChannel = 16;
        fmt.mBytesPerPacket = 4;
        fmt.mBytesPerFrame = 4;

        AudioQueueNewOutput(&fmt, AudioQueueCallback, ctx, nullptr, nullptr, 0, &ctx->q);

        ctx->rc = reinterpret_cast<RecycleChain *>(&ctx->mem[0]);
        ctx->first.store(ctx->rc);
        RecycleChain *traverse = ctx->rc;
        for (int32_t x = 0; x < kNumAudioBuf; ++x)
        {
            AudioQueueAllocateBuffer(ctx->q, kAudioBufBytes, &ctx->audioBuf[x]);
            ctx->audioBuf[x]->mAudioDataByteSize = kFakeSize;
            ctx->loc[x] = x;
            ctx->audioBuf[x]->mUserData = &ctx->loc[x];
            traverse->curt = &ctx->audioBuf[x];
            if (x != kNumAudioBuf - 1)
            {
                traverse->next = reinterpret_cast<RecycleChain *>(&ctx->mem[2 * (x + 1)]);
                traverse = traverse->next;
            }
            else
            {
                traverse->next = ctx->rc;
            }
        }

        g_audioStarted.store(false);
        g_audioHeld.store(false);
        AudioQueueAllocateBuffer(ctx->q, kSilenceBufBytes, &ctx->silenceBuf);
        std::memset(ctx->silenceBuf->mAudioData, 0, kSilenceBufBytes);
        ctx->silenceBuf->mAudioDataByteSize = kSilenceBufBytes;
        ctx->silenceBuf->mUserData = nullptr;
        return ctx;
    }

    void AudioClear(AudioContext *ctx)
    {
        if (!ctx)
            return;
        std::lock_guard<std::mutex> lock(ctx->clearLock);
        if (ctx->q)
            AudioQueueStop(ctx->q, true);
        for (int32_t x = 0; x < kNumAudioBuf; ++x)
            BufferSizeStore(ctx->audioBuf[x], kFakeSize);
        g_audioStarted.store(false);
        ctx->inUse.store(0);
        ctx->failNum.store(0);
        ctx->silenceInQueue.store(0);
        ctx->silenceOutQueue.store(0);
    }

    void AudioDestroy(AudioContext **ctxPtr)
    {
        if (!ctxPtr || !*ctxPtr)
            return;
        AudioContext *ctx = *ctxPtr;
        AudioClear(ctx);
        for (int32_t x = 0; x < kNumAudioBuf; ++x)
        {
            if (ctx->audioBuf[x])
                AudioQueueFreeBuffer(ctx->q, ctx->audioBuf[x]);
        }
        if (ctx->silenceBuf)
            AudioQueueFreeBuffer(ctx->q, ctx->silenceBuf);
        if (ctx->q)
            AudioQueueDispose(ctx->q, true);
        delete ctx;
        *ctxPtr = nullptr;
    }

    void AudioCallback(const int16_t *pcm, uint32_t frames, void *opaque)
    {
        if (frames == 0 || !opaque || g_audioMuted.load() || g_audioHeld.load())
            return;

        AudioContext *ctx = static_cast<AudioContext *>(opaque);
        RecycleChain *firstNode = ctx->first.load();
        AudioQueueBufferRef *idle = firstNode->curt;
        if (BufferSizeLoad(*idle) != kFakeSize)
        {
            if (ctx->failNum.fetch_add(1) > 10)
                AudioClear(ctx);
            return;
        }

        // Clamp incoming host chunks to the fixed 4096-byte AudioQueue allocation after link stalls.
        uint32_t bytes = frames * 4;
        if (bytes > kAudioBufBytes)
            bytes = kAudioBufBytes;
        std::memcpy((*idle)->mAudioData, pcm, bytes);
        BufferSizeStore(*idle, bytes);

        if (!g_audioStarted.load())
        {
            ctx->lastToQueue.store(firstNode);
            AudioQueueEnqueueBuffer(ctx->q, *idle, 0, nullptr);
        }

        ctx->failNum.store(0);
        ctx->first.store(firstNode->next);
        int32_t currentUse = ctx->inUse.fetch_add(static_cast<int32_t>(frames)) + static_cast<int32_t>(frames);
        if (currentUse > 1000 && !g_audioStarted.load())
        {
            AudioQueueStart(ctx->q, nullptr);
            g_audioStarted.store(true);
        }
    }

    static NSString *const kNv12ShaderSource = @R"(
#include <metal_stdlib>
using namespace metal;
struct VOut {
    float4 pos [[position]];
    float2 uv;
};
vertex VOut vs_parsec(uint vid [[vertex_id]]) {
    float2 p = float2(float(vid & 1), float(vid >> 1));
    VOut o;
    // Flip Y relative to Metal top-left origin so Unity RenderTexture UVs read upright on a Quad.
    o.pos = float4(p.x * 2.0 - 1.0, p.y * 2.0 - 1.0, 0.0, 1.0);
    o.uv = p;
    return o;
}
fragment float4 fs_parsec(VOut in [[stage_in]],
                          texture2d<float> yt [[texture(0)]],
                          texture2d<float> ct [[texture(1)]],
                          sampler s [[sampler(0)]]) {
    float y = (yt.sample(s, in.uv).r - 0.0625) * 1.164;
    float2 c = ct.sample(s, in.uv).rg - 0.5;
    float r = y + 1.793 * c.y;
    float g = y - 0.213 * c.x - 0.533 * c.y;
    float b = y + 2.112 * c.x;
    return float4(saturate(float3(r, g, b)), 1.0);
}
)";

    struct MetalState
    {
        id<MTLDevice> device = nil;
        id<MTLCommandQueue> queue = nil;
        id<MTLRenderPipelineState> pipeline = nil;
        id<MTLSamplerState> sampler = nil;
        MTLPixelFormat targetFormat = MTLPixelFormatInvalid;
        id<MTLTexture> yTex = nil;
        id<MTLTexture> uvTex = nil;
        uint32_t texWidth = 0;
        uint32_t texHeight = 0;
        bool hasFrame = false;
    };

    std::mutex g_parsecMutex;
    Parsec *g_parsec = nullptr;
    AudioContext *g_audio = nullptr;
    MetalState g_metal;
    std::atomic<int> g_pollGeneration{0};
    std::atomic<int> g_hostWidth{1920};
    std::atomic<int> g_hostHeight{1080};
    std::atomic<int> g_clientWidth{1920};
    std::atomic<int> g_clientHeight{1080};

    void ParsecLogHandler(ParsecLogLevel level, const char *msg, void *opaque)
    {
        (void)opaque;
        if (msg)
            NSLog(@"[ParsecSDK:%@] %s", level == LOG_DEBUG ? @"D" : @"I", msg);
    }

    bool EnsureMetalPipeline(id<MTLTexture> target)
    {
        if (!target)
            return false;
        id<MTLDevice> dev = target.device;
        MTLPixelFormat fmt = target.pixelFormat;
        if (g_metal.device == dev && g_metal.pipeline != nil && g_metal.targetFormat == fmt)
            return true;

        g_metal.device = dev;
        g_metal.queue = [dev newCommandQueue];
        g_metal.targetFormat = fmt;
        g_metal.pipeline = nil;

        NSError *err = nil;
        id<MTLLibrary> lib = [dev newLibraryWithSource:kNv12ShaderSource options:nil error:&err];
        if (!lib)
        {
            NSLog(@"[CardboardXRParsec] Metal library compile error: %@", err);
            return false;
        }

        MTLRenderPipelineDescriptor *desc = [[MTLRenderPipelineDescriptor alloc] init];
        desc.vertexFunction = [lib newFunctionWithName:@"vs_parsec"];
        desc.fragmentFunction = [lib newFunctionWithName:@"fs_parsec"];
        desc.colorAttachments[0].pixelFormat = fmt;
        g_metal.pipeline = [dev newRenderPipelineStateWithDescriptor:desc error:&err];
        if (!g_metal.pipeline)
        {
            NSLog(@"[CardboardXRParsec] Metal pipeline error: %@", err);
            return false;
        }

        MTLSamplerDescriptor *sd = [[MTLSamplerDescriptor alloc] init];
        sd.minFilter = MTLSamplerMinFilterLinear;
        sd.magFilter = MTLSamplerMagFilterLinear;
        g_metal.sampler = [dev newSamplerStateWithDescriptor:sd];
        return g_metal.queue != nil && g_metal.sampler != nil;
    }

    void EnsurePlaneTextures(uint32_t w, uint32_t h)
    {
        if (g_metal.yTex && g_metal.uvTex && g_metal.texWidth == w && g_metal.texHeight == h)
            return;

        MTLTextureDescriptor *yd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR8Unorm
                                                                                      width:w
                                                                                     height:h
                                                                                  mipmapped:NO];
        MTLTextureDescriptor *cd = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatRG8Unorm
                                                                                      width:(w + 1) / 2
                                                                                     height:(h + 1) / 2
                                                                                  mipmapped:NO];
        yd.usage = MTLTextureUsageShaderRead;
        cd.usage = MTLTextureUsageShaderRead;
        g_metal.yTex = [g_metal.device newTextureWithDescriptor:yd];
        g_metal.uvTex = [g_metal.device newTextureWithDescriptor:cd];
        g_metal.texWidth = w;
        g_metal.texHeight = h;
    }

    void FrameUploadCallback(const ParsecFrame *frame, const void *image, void *opaque)
    {
        (void)opaque;
        if (!frame || !image || !g_metal.device)
            return;

        uint32_t w = frame->width;
        uint32_t h = frame->height;
        uint32_t stride = frame->fullWidth;
        uint32_t rows = frame->fullHeight;
        if (frame->format != FORMAT_NV12 || w == 0 || h == 0 || stride < 2 * ((w + 1) / 2) || rows < h)
            return;
        if (frame->size < stride * rows + stride * ((h + 1) / 2))
            return;

        EnsurePlaneTextures(w, h);
        if (!g_metal.yTex || !g_metal.uvTex)
            return;

        const uint8_t *bytes = static_cast<const uint8_t *>(image);
        [g_metal.yTex replaceRegion:MTLRegionMake2D(0, 0, w, h)
                        mipmapLevel:0
                          withBytes:bytes
                        bytesPerRow:stride];
        [g_metal.uvTex replaceRegion:MTLRegionMake2D(0, 0, (w + 1) / 2, (h + 1) / 2)
                         mipmapLevel:0
                           withBytes:bytes + (stride * rows)
                         bytesPerRow:stride];
        g_metal.hasFrame = true;
        g_hostWidth.store(static_cast<int>(w));
        g_hostHeight.store(static_cast<int>(h));
    }

    void StartBackgroundThreads(int generation)
    {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            while (g_pollGeneration.load() == generation)
            {
                Parsec *ps = nullptr;
                AudioContext *au = nullptr;
                {
                    std::lock_guard<std::mutex> lock(g_parsecMutex);
                    ps = g_parsec;
                    au = g_audio;
                }
                if (!ps || !au)
                    break;
                if (ParsecClientPollAudio(ps, AudioCallback, 16, au) == PARSEC_NOT_RUNNING)
                    usleep(30000);
            }
        });

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_DEFAULT, 0), ^{
            while (g_pollGeneration.load() == generation)
            {
                Parsec *ps = nullptr;
                {
                    std::lock_guard<std::mutex> lock(g_parsecMutex);
                    ps = g_parsec;
                }
                if (!ps)
                    break;
                ParsecClientEvent ev{};
                if (ParsecClientPollEvents(ps, 16, &ev))
                {
                    uint32_t bufKey = 0;
                    if (ev.type == CLIENT_EVENT_CURSOR && ev.cursor.cursor.imageUpdate)
                        bufKey = ev.cursor.key;
                    else if (ev.type == CLIENT_EVENT_USER_DATA)
                        bufKey = ev.userData.key;

                    if (bufKey != 0)
                    {
                        void *buf = ParsecGetBuffer(ps, bufKey);
                        if (buf)
                            ParsecFree(buf);
                    }
                }
                else
                {
                    usleep(10000);
                }
            }
        });
    }
}

extern "C" int CardboardXR_ParsecInit()
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
        return PARSEC_OK;

    ParsecSetLogCallback(ParsecLogHandler, nullptr);
    g_audio = AudioInit();
    const char *reserved = "{\"ssHost\":\"kessel-ws.parsec.app\"}";
    ParsecStatus status = ParsecInit(PARSEC_VER, nullptr, reserved, &g_parsec);
    if (status != PARSEC_OK)
    {
        AudioDestroy(&g_audio);
        g_parsec = nullptr;
    }
    return static_cast<int>(status);
}

extern "C" void CardboardXR_ParsecDestroy()
{
    g_pollGeneration.fetch_add(1);
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
    {
        ParsecClientDisconnect(g_parsec);
        ParsecDestroy(g_parsec);
        g_parsec = nullptr;
    }
    AudioDestroy(&g_audio);
    g_metal.yTex = nil;
    g_metal.uvTex = nil;
    g_metal.hasFrame = false;
}

extern "C" int CardboardXR_ParsecConnect(const char *sessionId, const char *peerId, int width, int height, int useH265)
{
    if (!sessionId || !peerId)
        return ERR_DEFAULT;

    int initStatus = CardboardXR_ParsecInit();
    if (initStatus != PARSEC_OK)
        return initStatus;

    std::lock_guard<std::mutex> lock(g_parsecMutex);
    ParsecClientConfig cfg = PARSEC_CLIENT_DEFAULTS;
    cfg.video[0].decoderIndex = 1;
    cfg.video[0].resolutionX = width;
    cfg.video[0].resolutionY = height;
    cfg.video[0].decoderH265 = useH265 != 0;
    cfg.video[1].decoderIndex = 1;
    cfg.video[1].resolutionX = width;
    cfg.video[1].resolutionY = height;
    cfg.video[1].decoderH265 = useH265 != 0;
    cfg.mediaContainer = CONTAINER_PARSEC;
    cfg.protocol = PROTO_MODE_BUD;
    cfg.pngCursor = false;

    g_clientWidth.store(width > 0 ? width : 1920);
    g_clientHeight.store(height > 0 ? height : 1080);
    g_metal.hasFrame = false;

    ParsecStatus status = ParsecClientConnect(g_parsec, &cfg, sessionId, peerId);
    if (status == PARSEC_OK || status == PARSEC_CONNECTING)
    {
        ParsecClientSetDimensions(g_parsec, DEFAULT_STREAM, static_cast<uint32_t>(g_clientWidth.load()),
                                  static_cast<uint32_t>(g_clientHeight.load()), 1.0f);
        int gen = g_pollGeneration.fetch_add(1) + 1;
        StartBackgroundThreads(gen);
    }
    return static_cast<int>(status);
}

extern "C" void CardboardXR_ParsecDisconnect()
{
    g_pollGeneration.fetch_add(1);
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
    {
        ParsecMessage rel{};
        rel.type = MESSAGE_RELEASE;
        ParsecClientSendMessage(g_parsec, &rel);
        ParsecClientDisconnect(g_parsec);
    }
    AudioClear(g_audio);
    g_metal.hasFrame = false;
}

extern "C" int CardboardXR_ParsecGetStatus(int *outWidth, int *outHeight, int *outNetworkFailure)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return PARSEC_NOT_RUNNING;

    ParsecClientStatus pcs{};
    ParsecStatus st = ParsecClientGetStatus(g_parsec, &pcs);
    if (pcs.decoder[0].width > 0 && pcs.decoder[0].height > 0)
    {
        g_hostWidth.store(static_cast<int>(pcs.decoder[0].width));
        g_hostHeight.store(static_cast<int>(pcs.decoder[0].height));
    }
    if (outWidth)
        *outWidth = g_hostWidth.load();
    if (outHeight)
        *outHeight = g_hostHeight.load();
    if (outNetworkFailure)
        *outNetworkFailure = pcs.networkFailure ? 1 : 0;
    return static_cast<int>(st);
}

extern "C" int CardboardXR_ParsecRenderFrame(void *mtlTexturePtr, int timeoutMs)
{
    if (!mtlTexturePtr)
        return 0;

    Parsec *ps = nullptr;
    {
        std::lock_guard<std::mutex> lock(g_parsecMutex);
        ps = g_parsec;
    }
    if (!ps)
        return 0;

    id<MTLTexture> target = (__bridge id<MTLTexture>)mtlTexturePtr;
    if (!EnsureMetalPipeline(target))
        return 0;

    ParsecStatus pollStatus = ParsecClientPollFrame(ps, DEFAULT_STREAM, FrameUploadCallback,
                                                    static_cast<uint32_t>(timeoutMs > 0 ? timeoutMs : 1), nullptr);
    if (!g_metal.hasFrame || !g_metal.yTex || !g_metal.uvTex)
        return 0;

    MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
    rpd.colorAttachments[0].texture = target;
    rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
    rpd.colorAttachments[0].storeAction = MTLStoreActionStore;

    id<MTLCommandBuffer> cb = [g_metal.queue commandBuffer];
    id<MTLRenderCommandEncoder> enc = [cb renderCommandEncoderWithDescriptor:rpd];
    [enc setRenderPipelineState:g_metal.pipeline];
    [enc setFragmentTexture:g_metal.yTex atIndex:0];
    [enc setFragmentTexture:g_metal.uvTex atIndex:1];
    [enc setFragmentSamplerState:g_metal.sampler atIndex:0];
    [enc drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
    [enc endEncoding];
    [cb commit];
    [cb waitUntilCompleted];
    return (pollStatus == PARSEC_OK || g_metal.hasFrame) ? 1 : 0;
}

extern "C" void CardboardXR_ParsecSendMousePosition(int x, int y)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_MOUSE_MOTION;
    msg.mouseMotion.x = x;
    msg.mouseMotion.y = y;
    msg.mouseMotion.relative = false;
    msg.mouseMotion.stream = DEFAULT_STREAM;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void CardboardXR_ParsecSendMouseButton(int button, int pressed)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_MOUSE_BUTTON;
    msg.mouseButton.button = static_cast<ParsecMouseButton>(button);
    msg.mouseButton.pressed = pressed != 0;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void CardboardXR_ParsecSendMouseWheel(int deltaX, int deltaY)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_MOUSE_WHEEL;
    msg.mouseWheel.x = deltaX;
    msg.mouseWheel.y = deltaY;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void CardboardXR_ParsecSendKey(int usbHidKeyCode, int pressed)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_KEYBOARD;
    msg.keyboard.code = static_cast<ParsecKeycode>(usbHidKeyCode);
    msg.keyboard.mod = MOD_NONE;
    msg.keyboard.pressed = pressed != 0;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void CardboardXR_ParsecSetMuted(int muted)
{
    bool m = muted != 0;
    g_audioMuted.store(m);
    if (m && g_audio)
        AudioClear(g_audio);
}

extern "C" void CardboardXR_KeychainSave(const char *key, const char *value)
{
    if (!key || !value)
        return;
    NSString *nsKey = [NSString stringWithUTF8String:key];
    NSData *data = [[NSString stringWithUTF8String:value] dataUsingEncoding:NSUTF8StringEncoding];
    NSDictionary *delQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: nsKey
    };
    SecItemDelete((__bridge CFDictionaryRef)delQuery);
    NSDictionary *addQuery = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: nsKey,
        (__bridge id)kSecValueData: data,
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    SecItemAdd((__bridge CFDictionaryRef)addQuery, nullptr);
}

extern "C" const char *CardboardXR_KeychainLoad(const char *key)
{
    if (!key)
        return nullptr;
    NSString *nsKey = [NSString stringWithUTF8String:key];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: nsKey,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result)
        return nullptr;
    NSData *data = (__bridge_transfer NSData *)result;
    NSString *str = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (!str)
        return nullptr;
    return strdup([str UTF8String]);
}

extern "C" void CardboardXR_KeychainDelete(const char *key)
{
    if (!key)
        return;
    NSString *nsKey = [NSString stringWithUTF8String:key];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: nsKey
    };
    SecItemDelete((__bridge CFDictionaryRef)query);
}
