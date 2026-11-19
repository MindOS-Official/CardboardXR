using System;
using System.Runtime.InteropServices;
using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    public static class WebViewNative
    {
#if UNITY_IOS && !UNITY_EDITOR
        [DllImport("__Internal")] static extern void CardboardXR_WebInit(int width, int height);
        [DllImport("__Internal")] static extern void CardboardXR_WebDestroy();
        [DllImport("__Internal")] static extern void CardboardXR_WebLoadUrl(string url);
        [DllImport("__Internal")] static extern void CardboardXR_WebGoBack();
        [DllImport("__Internal")] static extern void CardboardXR_WebGoForward();
        [DllImport("__Internal")] static extern void CardboardXR_WebReload();
        [DllImport("__Internal")] static extern int CardboardXR_WebUpdateTexture(IntPtr mtlTexturePtr);
        [DllImport("__Internal")] static extern void CardboardXR_WebClick(float normX, float normY);
        [DllImport("__Internal")] static extern void CardboardXR_WebScroll(float normX, float normY, float deltaY);
        [DllImport("__Internal")] static extern void CardboardXR_WebTypeKey(string text, int isBackspace, int isEnter);
        [DllImport("__Internal")] static extern string CardboardXR_WebGetUrl();
        [DllImport("__Internal")] static extern int CardboardXR_WebIsLoading();

        public static bool IsSupported => true;
        public static void Init(int width, int height) => CardboardXR_WebInit(width, height);
        public static void Destroy() => CardboardXR_WebDestroy();
        public static void LoadUrl(string url) => CardboardXR_WebLoadUrl(url);
        public static void GoBack() => CardboardXR_WebGoBack();
        public static void GoForward() => CardboardXR_WebGoForward();
        public static void Reload() => CardboardXR_WebReload();
        public static bool UpdateTexture(RenderTexture target) =>
            target != null && CardboardXR_WebUpdateTexture(target.GetNativeTexturePtr()) != 0;
        public static void Click(float normX, float normY) => CardboardXR_WebClick(normX, normY);
        public static void Scroll(float normX, float normY, float deltaY) => CardboardXR_WebScroll(normX, normY, deltaY);
        public static void TypeKey(string text, bool isBackspace, bool isEnter) =>
            CardboardXR_WebTypeKey(text ?? "", isBackspace ? 1 : 0, isEnter ? 1 : 0);
        public static string GetUrl() => CardboardXR_WebGetUrl() ?? "";
        public static bool IsLoading() => CardboardXR_WebIsLoading() != 0;
#else
        static string s_StubUrl = "https://duckduckgo.com";
        public static bool IsSupported => false;
        public static void Init(int width, int height) { }
        public static void Destroy() { }
        public static void LoadUrl(string url) { if (!string.IsNullOrWhiteSpace(url)) s_StubUrl = url; }
        public static void GoBack() { }
        public static void GoForward() { }
        public static void Reload() { }
        public static bool UpdateTexture(RenderTexture target) => false;
        public static void Click(float normX, float normY) { }
        public static void Scroll(float normX, float normY, float deltaY) { }
        public static void TypeKey(string text, bool isBackspace, bool isEnter) { }
        public static string GetUrl() => s_StubUrl;
        public static bool IsLoading() => false;
#endif
    }
}
