// ParsecSDK dual-stream native client, AudioQueue stereo PCM output, NV12 frame converter, and Keychain helpers.

#import "VRBridge.h"
#import <Accelerate/Accelerate.h>
#import <AudioToolbox/AudioToolbox.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Metal/Metal.h>
#import <Security/Security.h>
#include <algorithm>
#include <atomic>
#include <cstring>
#include <mutex>
#include <vector>
#include <ParsecSDK/parsec.h>

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
        (void)queue;
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

    inline uint8_t ClampByte(int v)
    {
        return static_cast<uint8_t>(v < 0 ? 0 : (v > 255 ? 255 : v));
    }

    struct FrameBufferState
    {
        std::mutex mutex;
        std::vector<uint8_t> stagingBgra;
        std::vector<uint8_t> bgra;
        id<MTLTexture> textures[2] = {nil, nil};
        int texW = 0;
        int texH = 0;
        int writeIdx = 0;
        int readyIdx = -1;
        int width = 0;
        int height = 0;
        bool updated = false;
    };

    std::mutex g_parsecMutex;
    Parsec *g_parsec = nullptr;
    AudioContext *g_audio = nullptr;
    FrameBufferState g_frames[kMaxParsecStreams];
    std::atomic<int> g_pollGeneration{0};
    std::atomic<int> g_activeWorkers{0};
    std::atomic<bool> g_secondStreamEnabled{false};
    std::atomic<int> g_lastStatus{PARSEC_NOT_RUNNING};
    std::atomic<int> g_netFailure{0};
    std::atomic<int> g_hostWidth{1920};
    std::atomic<int> g_hostHeight{1080};

    id<MTLDevice> GetMetalDevice()
    {
        static id<MTLDevice> dev = nil;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            dev = MTLCreateSystemDefaultDevice();
        });
        return dev;
    }

    const vImage_YpCbCrToARGB *GetBt601Info()
    {
        static vImage_YpCbCrToARGB info;
        static dispatch_once_t once;
        dispatch_once(&once, ^{
            vImage_YpCbCrPixelRange range = {16, 128, 235, 240, 255, 0, 255, 0};
            vImageConvert_YpCbCrToARGB_GenerateConversion(
                kvImage_YpCbCrToARGBMatrix_ITU_R_601_4,
                &range,
                &info,
                kvImage420Yp8_CbCr8,
                kvImageARGB8888,
                kvImageNoFlags);
        });
        return &info;
    }

    void ParsecLogHandler(ParsecLogLevel level, const char *msg, void *opaque)
    {
        (void)opaque;
        if (msg)
            NSLog(@"[ParsecSDK:%@] %s", level == LOG_DEBUG ? @"D" : @"I", msg);
    }

    void UploadFrameToTexture(FrameBufferState *slot, int w, int h)
    {
        id<MTLDevice> dev = GetMetalDevice();
        if (!dev)
            return;

        if (slot->texW != w || slot->texH != h || !slot->textures[0] || !slot->textures[1])
        {
            MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                                                                            width:static_cast<NSUInteger>(w)
                                                                                           height:static_cast<NSUInteger>(h)
                                                                                        mipmapped:NO];
            desc.usage = MTLTextureUsageShaderRead;
            desc.storageMode = MTLStorageModeShared;
            id<MTLTexture> t0 = [dev newTextureWithDescriptor:desc];
            id<MTLTexture> t1 = [dev newTextureWithDescriptor:desc];
            std::lock_guard<std::mutex> lock(slot->mutex);
            slot->textures[0] = t0;
            slot->textures[1] = t1;
            slot->texW = w;
            slot->texH = h;
            slot->readyIdx = -1;
            slot->writeIdx = 0;
        }

        int idx = 0;
        id<MTLTexture> targetTex = nil;
        {
            std::lock_guard<std::mutex> lock(slot->mutex);
            idx = (slot->readyIdx == 0) ? 1 : 0;
            targetTex = slot->textures[idx];
        }
        if (!targetTex)
            return;

        [targetTex replaceRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(w), static_cast<NSUInteger>(h))
                     mipmapLevel:0
                       withBytes:slot->stagingBgra.data()
                     bytesPerRow:static_cast<NSUInteger>(w) * 4];

        std::lock_guard<std::mutex> lock(slot->mutex);
        slot->width = w;
        slot->height = h;
        slot->readyIdx = idx;
        slot->writeIdx = 1 - idx;
        slot->updated = true;
    }

    void FrameUploadCallback(const ParsecFrame *frame, const void *image, void *opaque)
    {
        FrameBufferState *slot = static_cast<FrameBufferState *>(opaque);
        if (!frame || !image || !slot)
            return;

        int w = static_cast<int>(frame->width);
        int h = static_cast<int>(frame->height);
        int stride = static_cast<int>(frame->fullWidth);
        int rows = static_cast<int>(frame->fullHeight);
        if (w <= 0 || h <= 0 || stride < w || rows < h)
            return;

        const uint8_t *src = static_cast<const uint8_t *>(image);
        slot->stagingBgra.resize(static_cast<size_t>(w) * static_cast<size_t>(h) * 4);
        bool converted = false;

        if (frame->format == FORMAT_NV12 &&
            frame->size >= static_cast<uint32_t>(stride * rows + stride * ((h + 1) / 2)))
        {
            const uint8_t *yPlane = src;
            const uint8_t *uvPlane = src + (stride * rows);

            vImage_Buffer srcYp = {const_cast<uint8_t *>(yPlane), static_cast<vImagePixelCount>(h), static_cast<vImagePixelCount>(w), static_cast<size_t>(stride)};
            vImage_Buffer srcCbCr = {const_cast<uint8_t *>(uvPlane), static_cast<vImagePixelCount>((h + 1) / 2), static_cast<vImagePixelCount>((w + 1) / 2), static_cast<size_t>(stride)};
            vImage_Buffer dstBgra = {slot->stagingBgra.data(), static_cast<vImagePixelCount>(h), static_cast<vImagePixelCount>(w), static_cast<size_t>(w) * 4};
            const uint8_t permuteMap[4] = {3, 2, 1, 0};
            vImage_Error err = vImageConvert_420Yp8_CbCr8ToARGB8888(&srcYp, &srcCbCr, &dstBgra, GetBt601Info(), permuteMap, 255, kvImageNoFlags);
            if (err == kvImageNoError)
            {
                converted = true;
            }
            else
            {
                uint8_t *dst = slot->stagingBgra.data();
                for (int y = 0; y < h; ++y)
                {
                    const uint8_t *yRow = yPlane + (y * stride);
                    const uint8_t *uvRow = uvPlane + ((y >> 1) * stride);
                    uint8_t *outRow = dst + (y * w * 4);
                    for (int x = 0; x < w; ++x)
                    {
                        int c = static_cast<int>(yRow[x]) - 16;
                        int uvIdx = (x & ~1);
                        int d = static_cast<int>(uvRow[uvIdx]) - 128;
                        int e = static_cast<int>(uvRow[uvIdx + 1]) - 128;
                        int y298 = 298 * c;
                        int o = x * 4;
                        outRow[o + 0] = ClampByte((y298 + 516 * d + 128) >> 8);
                        outRow[o + 1] = ClampByte((y298 - 100 * d - 208 * e + 128) >> 8);
                        outRow[o + 2] = ClampByte((y298 + 409 * e + 128) >> 8);
                        outRow[o + 3] = 255;
                    }
                }
                converted = true;
            }
        }
        else if (frame->format == FORMAT_BGRA && frame->size >= static_cast<uint32_t>(stride * h * 4))
        {
            for (int y = 0; y < h; ++y)
                std::memcpy(slot->stagingBgra.data() + y * w * 4, src + y * stride * 4, static_cast<size_t>(w) * 4);
            converted = true;
        }

        if (!converted)
            return;

        if (slot == &g_frames[0])
        {
            g_hostWidth.store(w);
            g_hostHeight.store(h);
        }

        UploadFrameToTexture(slot, w, h);
    }

    void StartBackgroundThreads(int generation)
    {
        g_activeWorkers.fetch_add(3);

        dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
            while (g_pollGeneration.load() == generation)
            {
                Parsec *ps = nullptr;
                {
                    std::lock_guard<std::mutex> lock(g_parsecMutex);
                    ps = g_parsec;
                }
                if (!ps)
                    break;
                ParsecStatus st = ParsecClientPollFrame(ps, 0, FrameUploadCallback, 4, &g_frames[0]);
                if (st == PARSEC_OK || st < 0)
                    g_lastStatus.store(static_cast<int>(st));
                if (g_secondStreamEnabled.load())
                    ParsecClientPollFrame(ps, 1, FrameUploadCallback, 1, &g_frames[1]);
                if (st == PARSEC_NOT_RUNNING)
                    usleep(16000);
            }
            g_activeWorkers.fetch_sub(1);
        });

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
            g_activeWorkers.fetch_sub(1);
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

                ParsecClientStatus pcs{};
                ParsecStatus cst = ParsecClientGetStatus(ps, &pcs);
                g_lastStatus.store(static_cast<int>(cst));
                if (pcs.decoder[0].width > 0 && pcs.decoder[0].height > 0)
                {
                    g_hostWidth.store(static_cast<int>(pcs.decoder[0].width));
                    g_hostHeight.store(static_cast<int>(pcs.decoder[0].height));
                }
                g_netFailure.store(pcs.networkFailure ? 1 : 0);

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
            g_activeWorkers.fetch_sub(1);
        });
    }
}

extern "C" int VRParsecInit(void)
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

extern "C" void VRParsecDestroy(void)
{
    g_pollGeneration.fetch_add(1);
    g_secondStreamEnabled.store(false);
    for (int i = 0; i < 40 && g_activeWorkers.load() > 0; ++i)
        usleep(5000);
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
    {
        ParsecClientDisconnect(g_parsec);
        ParsecDestroy(g_parsec);
        g_parsec = nullptr;
    }
    AudioDestroy(&g_audio);
}

extern "C" int VRParsecConnect(const char *sessionId, const char *peerId, int width, int height, int useH265)
{
    if (!sessionId || !peerId)
        return ERR_DEFAULT;

    int initStatus = VRParsecInit();
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

    ParsecStatus status = ParsecClientConnect(g_parsec, &cfg, sessionId, peerId);
    g_lastStatus.store(static_cast<int>(status));
    g_netFailure.store(0);
    if (status == PARSEC_OK || status == PARSEC_CONNECTING)
    {
        int cw = width > 0 ? width : 1920;
        int ch = height > 0 ? height : 1080;
        ParsecClientSetDimensions(g_parsec, 0, static_cast<uint32_t>(cw), static_cast<uint32_t>(ch), 1.0f);
        ParsecClientSetDimensions(g_parsec, 1, static_cast<uint32_t>(cw), static_cast<uint32_t>(ch), 1.0f);
        int gen = g_pollGeneration.fetch_add(1) + 1;
        StartBackgroundThreads(gen);
    }
    return static_cast<int>(status);
}

extern "C" void VRParsecDisconnect(void)
{
    g_pollGeneration.fetch_add(1);
    g_secondStreamEnabled.store(false);
    g_lastStatus.store(PARSEC_NOT_RUNNING);
    g_netFailure.store(0);
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
    {
        ParsecMessage rel{};
        rel.type = MESSAGE_RELEASE;
        ParsecClientSendMessage(g_parsec, &rel);
        ParsecClientDisconnect(g_parsec);
    }
    AudioClear(g_audio);
    for (int i = 0; i < kMaxParsecStreams; ++i)
    {
        std::lock_guard<std::mutex> flock(g_frames[i].mutex);
        g_frames[i].updated = false;
        g_frames[i].readyIdx = -1;
    }
}

extern "C" int VRParsecGetStatus(int *outWidth, int *outHeight, int *outNetworkFailure)
{
    if (outWidth)
        *outWidth = g_hostWidth.load();
    if (outHeight)
        *outHeight = g_hostHeight.load();
    if (outNetworkFailure)
        *outNetworkFailure = g_netFailure.load();
    return g_lastStatus.load();
}

extern "C" void VRParsecSetSecondStreamEnabled(int enabled)
{
    g_secondStreamEnabled.store(enabled != 0);
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (g_parsec)
        ParsecClientEnableStream(g_parsec, 1, enabled != 0);
}

extern "C" id VRParsecPollStreamTexture(int streamIndex, int *outUpdated)
{
    if (outUpdated)
        *outUpdated = 0;
    if (streamIndex < 0 || streamIndex >= kMaxParsecStreams)
        return nil;

    FrameBufferState *slot = &g_frames[streamIndex];
    std::lock_guard<std::mutex> flock(slot->mutex);
    if (slot->readyIdx < 0)
        return nil;
    if (slot->updated)
    {
        slot->updated = false;
        if (outUpdated)
            *outUpdated = 1;
    }
    return slot->textures[slot->readyIdx];
}

extern "C" UIImage *VRParsecPollStreamImage(int streamIndex, int timeoutMs)
{
    (void)timeoutMs;
    if (streamIndex < 0 || streamIndex >= kMaxParsecStreams)
        return nil;

    FrameBufferState *slot = &g_frames[streamIndex];
    std::lock_guard<std::mutex> flock(slot->mutex);
    if (!slot->updated || slot->readyIdx < 0 || slot->width <= 0 || slot->height <= 0)
        return nil;

    id<MTLTexture> tex = slot->textures[slot->readyIdx];
    if (!tex)
        return nil;

    slot->updated = false;
    slot->bgra.resize(static_cast<size_t>(slot->width) * static_cast<size_t>(slot->height) * 4);
    [tex getBytes:slot->bgra.data()
      bytesPerRow:static_cast<NSUInteger>(slot->width) * 4
       fromRegion:MTLRegionMake2D(0, 0, static_cast<NSUInteger>(slot->width), static_cast<NSUInteger>(slot->height))
      mipmapLevel:0];

    NSData *data = [NSData dataWithBytes:slot->bgra.data() length:slot->bgra.size()];
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)data);
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGImageRef cgImg = CGImageCreate(static_cast<size_t>(slot->width),
                                     static_cast<size_t>(slot->height),
                                     8,
                                     32,
                                     static_cast<size_t>(slot->width) * 4,
                                     cs,
                                     kCGBitmapByteOrder32Little | kCGImageAlphaNoneSkipFirst,
                                     provider,
                                     nullptr,
                                     true,
                                     kCGRenderingIntentDefault);
    UIImage *result = cgImg ? [UIImage imageWithCGImage:cgImg] : nil;
    if (cgImg)
        CGImageRelease(cgImg);
    CGColorSpaceRelease(cs);
    CGDataProviderRelease(provider);
    return result;
}

extern "C" void VRParsecSendStreamMousePosition(int streamIndex, int x, int y)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_MOUSE_MOTION;
    msg.mouseMotion.x = x;
    msg.mouseMotion.y = y;
    msg.mouseMotion.relative = false;
    msg.mouseMotion.scaleRelative = false;
    msg.mouseMotion.stream = static_cast<uint8_t>(streamIndex >= 0 && streamIndex < kMaxParsecStreams ? streamIndex : 0);
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void VRParsecSendRelativeMouse(int dx, int dy)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_MOUSE_MOTION;
    msg.mouseMotion.x = dx;
    msg.mouseMotion.y = dy;
    msg.mouseMotion.relative = true;
    msg.mouseMotion.scaleRelative = false;
    msg.mouseMotion.stream = 0;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void VRParsecSendMouseButton(int button, int pressed)
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

extern "C" void VRParsecSendMouseWheel(int deltaX, int deltaY)
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

extern "C" void VRParsecSendKey(int usbHidKeyCode, int pressed)
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

extern "C" void VRParsecSendGamepadState(uint16_t buttons,
                                         int16_t thumbLX,
                                         int16_t thumbLY,
                                         int16_t thumbRX,
                                         int16_t thumbRY,
                                         uint8_t leftTrigger,
                                         uint8_t rightTrigger)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_GAMEPAD_STATE;
    msg.gamepadState.id = 0;
    msg.gamepadState.buttons = buttons;
    msg.gamepadState.thumbLX = thumbLX;
    msg.gamepadState.thumbLY = thumbLY;
    msg.gamepadState.thumbRX = thumbRX;
    msg.gamepadState.thumbRY = thumbRY;
    msg.gamepadState.leftTrigger = leftTrigger;
    msg.gamepadState.rightTrigger = rightTrigger;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void VRParsecUnplugGamepad(void)
{
    std::lock_guard<std::mutex> lock(g_parsecMutex);
    if (!g_parsec)
        return;
    ParsecMessage msg{};
    msg.type = MESSAGE_GAMEPAD_UNPLUG;
    msg.gamepadUnplug.id = 0;
    ParsecClientSendMessage(g_parsec, &msg);
}

extern "C" void VRParsecSetMuted(int muted)
{
    bool m = muted != 0;
    g_audioMuted.store(m);
    if (m && g_audio)
        AudioClear(g_audio);
}

extern "C" void VRKeychainSave(const char *key, const char *value)
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

extern "C" NSString *VRKeychainLoad(const char *key)
{
    if (!key)
        return nil;
    NSString *nsKey = [NSString stringWithUTF8String:key];
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrAccount: nsKey,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = nullptr;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess || !result)
        return nil;
    NSData *data = (__bridge_transfer NSData *)result;
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
}

extern "C" void VRKeychainDelete(const char *key)
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
