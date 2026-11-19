using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    public static class ParsecNative
    {
        public const int MouseLeft = 1;
        public const int MouseMiddle = 2;
        public const int MouseRight = 3;

#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern int CardboardXR_ParsecInit();
        [DllImport("__Internal")] static extern void CardboardXR_ParsecDestroy();
        [DllImport("__Internal")] static extern int CardboardXR_ParsecConnect(string sessionId, string peerId, int width, int height, int useH265);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecDisconnect();
        [DllImport("__Internal")] static extern int CardboardXR_ParsecGetStatus(out int width, out int height, out int networkFailure);
        [DllImport("__Internal")] static extern int CardboardXR_ParsecRenderFrame(IntPtr mtlTexturePtr, int timeoutMs);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecSendMousePosition(int x, int y);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecSendMouseButton(int button, int pressed);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecSendMouseWheel(int deltaX, int deltaY);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecSendKey(int usbHidKeyCode, int pressed);
        [DllImport("__Internal")] static extern void CardboardXR_ParsecSetMuted(int muted);
        [DllImport("__Internal")] static extern void CardboardXR_KeychainSave(string key, string value);
        [DllImport("__Internal")] static extern string CardboardXR_KeychainLoad(string key);
        [DllImport("__Internal")] static extern void CardboardXR_KeychainDelete(string key);

        public static bool IsSupported => true;
        public static int Init() => CardboardXR_ParsecInit();
        public static void Destroy() => CardboardXR_ParsecDestroy();
        public static int Connect(string sessionId, string peerId, int width, int height, bool useH265) =>
            CardboardXR_ParsecConnect(sessionId, peerId, width, height, useH265 ? 1 : 0);
        public static void Disconnect() => CardboardXR_ParsecDisconnect();
        public static int GetStatus(out int width, out int height, out bool networkFailure)
        {
            var status = CardboardXR_ParsecGetStatus(out width, out height, out var fail);
            networkFailure = fail != 0;
            return status;
        }
        public static bool RenderFrame(RenderTexture target, int timeoutMs = 2) =>
            target != null && CardboardXR_ParsecRenderFrame(target.GetNativeTexturePtr(), timeoutMs) != 0;
        public static void SendMousePosition(int x, int y) => CardboardXR_ParsecSendMousePosition(x, y);
        public static void SendMouseButton(int button, bool pressed) => CardboardXR_ParsecSendMouseButton(button, pressed ? 1 : 0);
        public static void SendMouseWheel(int deltaX, int deltaY) => CardboardXR_ParsecSendMouseWheel(deltaX, deltaY);
        public static void SendKey(int usbHidKeyCode, bool pressed) => CardboardXR_ParsecSendKey(usbHidKeyCode, pressed ? 1 : 0);
        public static void SetMuted(bool muted) => CardboardXR_ParsecSetMuted(muted ? 1 : 0);
        public static void SaveSecret(string key, string value) => CardboardXR_KeychainSave(key, value);
        public static string LoadSecret(string key) => CardboardXR_KeychainLoad(key);
        public static void DeleteSecret(string key) => CardboardXR_KeychainDelete(key);
#else
        public static bool IsSupported => false;
        public static int Init() => 0;
        public static void Destroy() { }
        public static int Connect(string sessionId, string peerId, int width, int height, bool useH265) => -3;
        public static void Disconnect() { }
        public static int GetStatus(out int width, out int height, out bool networkFailure)
        {
            width = 1920;
            height = 1080;
            networkFailure = false;
            return -3;
        }
        public static bool RenderFrame(RenderTexture target, int timeoutMs = 2) => false;
        public static void SendMousePosition(int x, int y) { }
        public static void SendMouseButton(int button, bool pressed) { }
        public static void SendMouseWheel(int deltaX, int deltaY) { }
        public static void SendKey(int usbHidKeyCode, bool pressed) { }
        public static void SetMuted(bool muted) { }
        public static void SaveSecret(string key, string value) => PlayerPrefs.SetString($"fallback_{key}", value ?? "");
        public static string LoadSecret(string key) => PlayerPrefs.GetString($"fallback_{key}", null);
        public static void DeleteSecret(string key) => PlayerPrefs.DeleteKey($"fallback_{key}");
#endif
    }
}
