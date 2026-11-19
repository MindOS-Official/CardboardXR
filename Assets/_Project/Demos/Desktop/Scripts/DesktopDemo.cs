using System;
using System.Collections;
using System.Collections.Generic;
using CardboardXR.Hands;
using CardboardXR.UI;
using TMPro;
using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    // Spatial remote desktop and browser workspace: a 60 fps Parsec client, an offscreen
    // WebKit browser monitor, and a touchable + gaze-clickable 3D Air Keyboard. Logs [Desktop].
    public class DesktopDemo : Demo, IPinchHandler
    {
        const string KeychainSessionKey = "cardboardxr_parsec_session_v1";
        const float k_ParsecDistance = 1.45f;
        const float k_WebSideYaw = 34f;
        const float k_WebSideDistance = 1.75f;
        const float k_WebRefreshInterval = 1f / 30f;

        static readonly float[] k_MonitorScales = { 1.15f, 1.50f, 1.90f };
        static readonly string[] k_SizePresetLabels = { "Big", "Giant", "IMAX" };
        static readonly Vector3[] k_SideMonitorAngles =
        {
            new Vector3(-38f, -4f, 1.78f),
            new Vector3(66f, -4f, 1.76f),
            new Vector3(-68f, -4f, 1.76f),
            new Vector3(0f, 26f, 1.88f),
        };

        enum WorkspaceMode
        {
            ParsecAndWeb = 0,
            ParsecOnly = 1,
            WebOnly = 2,
        }

        enum InputTarget
        {
            None,
            ParsecEmail,
            ParsecPassword,
            ParsecTfa,
            WebUrl,
            ParsecHost,
            WebPage,
        }

        [SerializeField] Material m_ScreenMaterial;

        CoreServices m_Core;
        Transform m_WorkspaceRoot;
        SpatialScreenSurface m_ParsecScreen;
        SpatialScreenSurface m_WebScreen;
        readonly List<SpatialScreenSurface> m_ExtraMonitors = new();
        SpatialAirKeyboard m_Keyboard;

        RectTransform m_ControlBar;
        M3Button[] m_ModeSegments;
        M3Button m_KeyboardToggle;
        M3Button m_RightClickToggle;
        M3Button m_MuteToggle;
        M3Button m_RoomToggle;
        M3Button m_AddMonitorButton;
        M3Button m_MonitorSizeButton;

        RectTransform m_ParsecHeaderBar;
        TMP_Text m_ParsecHeaderStatus;
        M3Button m_ParsecDisconnectButton;

        RectTransform m_ParsecPanel;
        TMP_Text m_ParsecStateText;
        RectTransform m_LoginGroup;
        M3Button m_EmailFieldButton;
        M3Button m_PasswordFieldButton;
        M3Button m_TfaFieldButton;
        M3Button m_SignInButton;

        RectTransform m_HostsGroup;
        M3Button m_RefreshHostsButton;
        M3Button m_SignOutButton;
        readonly List<(M3Button item, TMP_Text supporting)> m_HostRows = new();
        readonly List<ParsecHostEntry> m_Hosts = new();

        RectTransform m_ConnectingGroup;
        TMP_Text m_ConnectingText;
        M3Button m_CancelConnectButton;

        RectTransform m_WebBar;
        M3Button m_WebUrlButton;
        TMP_Text m_WebStatusText;

        WorkspaceMode m_Mode = WorkspaceMode.ParsecAndWeb;
        InputTarget m_Focus = InputTarget.ParsecEmail;
        string m_Email = "";
        string m_Password = "";
        string m_Tfa = "";
        string m_SessionId = "";
        string m_ConnectedHostName = "";
        string m_WebUrlInput = "https://duckduckgo.com";
        bool m_IsBusy;
        bool m_RequiresTfa;
        bool m_ParsecConnecting;
        bool m_ParsecConnected;
        bool m_RightClickArmed;
        bool m_Muted;
        int m_SizePreset = 1;
        bool m_ParsecMouseDown;
        int m_HeldParsecButton = ParsecNative.MouseLeft;
        int m_LastSentPx = -1;
        int m_LastSentPy = -1;
        int m_LastParsecStatus = -999;
        float m_NextWebRefresh;
        float m_NextWebUrlSync;
        Coroutine m_AuthCoroutine;
        Coroutine m_HostsCoroutine;

        public override void OnDemoEnter(CoreServices core)
        {
            m_Core = core;
            core.Placer.ObjectPrefab = null;
            PinchRouter.Handler = this;

            m_WorkspaceRoot = new GameObject("Desktop Workspace").transform;
            m_WorkspaceRoot.SetParent(transform, false);

            BuildScreens();
            BuildControlBar();
            BuildParsecPanels();
            BuildWebBar();
            BuildKeyboard();

            ApplyScaleToMonitors();
            RecenterWorkspace();
            ApplyWorkspaceMode(WorkspaceMode.ParsecAndWeb);

            ParsecNative.Init();
            WebViewNative.Init(m_WebScreen.PixelWidth, m_WebScreen.PixelHeight);
            WebViewNative.LoadUrl(m_WebUrlInput);

            RestoreSavedSession();
            Debug.Log("[Desktop] Ready: Parsec client, WebKit browser, and 3D Air Keyboard initialized");
        }

        public override void OnDemoExit(CoreServices core)
        {
            if (m_AuthCoroutine != null)
                StopCoroutine(m_AuthCoroutine);
            if (m_HostsCoroutine != null)
                StopCoroutine(m_HostsCoroutine);

            if (ReferenceEquals(PinchRouter.Handler, this))
                PinchRouter.Clear();

            ReleaseParsecMouse();
            ParsecNative.Disconnect();
            WebViewNative.Destroy();
            Debug.Log("[Desktop] Exited and released Parsec and WebKit sessions");
        }

        void Update()
        {
            if (m_Core == null)
                return;

            UpdateParsecRuntime();
            UpdateWebRuntime();
            UpdateScreenPointer();
        }

        public bool TryBeginPinch(GameObject gazeTarget, PinchSource source)
        {
            if (gazeTarget == null)
                return false;

            var ray = ActivePointerRay();
            if (m_ParsecConnected && ReferenceEquals(gazeTarget, m_ParsecScreen.ColliderObject) &&
                m_ParsecScreen.TryRaycast(ray, out var parsecUv))
            {
                m_Focus = InputTarget.ParsecHost;
                UpdateKeyboardBanner();
                var px = SpatialScreenMath.UvToTopLeftPixel(parsecUv, m_ParsecScreen.PixelWidth, m_ParsecScreen.PixelHeight);
                ParsecNative.SendMousePosition(px.x, px.y);
                m_HeldParsecButton = m_RightClickArmed ? ParsecNative.MouseRight : ParsecNative.MouseLeft;
                ParsecNative.SendMouseButton(m_HeldParsecButton, true);
                m_ParsecMouseDown = true;

                if (m_RightClickArmed)
                {
                    m_RightClickArmed = false;
                    m_RightClickToggle.Selected = false;
                }
                return true;
            }

            if (TryRaycastAnyWebMonitor(gazeTarget, ray, out _, out var webUv))
            {
                m_Focus = InputTarget.WebPage;
                UpdateKeyboardBanner();
                var norm = SpatialScreenMath.UvToTopLeftNormalized(webUv);
                WebViewNative.Click(norm.x, norm.y);
                return true;
            }

            return false;
        }

        public void EndPinch()
        {
            ReleaseParsecMouse();
        }

        void ReleaseParsecMouse()
        {
            if (!m_ParsecMouseDown)
                return;
            ParsecNative.SendMouseButton(m_HeldParsecButton, false);
            m_ParsecMouseDown = false;
        }

        Ray ActivePointerRay() => m_Core.Gaze.RayOverride ?? new Ray(m_Core.Head.position, m_Core.Head.forward);

        void UpdateScreenPointer()
        {
            var ray = ActivePointerRay();
            var parsecHit = m_ParsecConnected && m_ParsecScreen.TryRaycast(ray, out var parsecUv);
            m_ParsecScreen.SetCursor(parsecHit, parsecUv);

            if (parsecHit)
            {
                var px = SpatialScreenMath.UvToTopLeftPixel(parsecUv, m_ParsecScreen.PixelWidth, m_ParsecScreen.PixelHeight);
                if (px.x != m_LastSentPx || px.y != m_LastSentPy)
                {
                    m_LastSentPx = px.x;
                    m_LastSentPy = px.y;
                    ParsecNative.SendMousePosition(px.x, px.y);
                }
            }

            var webHit = m_WebScreen.TryRaycast(ray, out var webUv);
            m_WebScreen.SetCursor(webHit, webUv);
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
            {
                var extra = m_ExtraMonitors[i];
                var extraHit = extra.TryRaycast(ray, out var extraUv);
                extra.SetCursor(extraHit, extraUv);
            }
        }

        void UpdateParsecRuntime()
        {
            if (!m_ParsecConnecting && !m_ParsecConnected)
                return;

            var status = ParsecNative.GetStatus(out var hostW, out var hostH, out var netFail);
            if (status != m_LastParsecStatus)
            {
                m_LastParsecStatus = status;
                Debug.Log($"[Desktop] Parsec status changed: {status} ({ParsecApiModels.FormatStatusLabel(status)})");
            }

            if (m_ParsecConnecting)
            {
                if (status == 0)
                {
                    m_ParsecConnecting = false;
                    m_ParsecConnected = true;
                    m_Focus = InputTarget.ParsecHost;
                    ShowParsecLiveView(hostW, hostH);
                    UpdateKeyboardBanner();
                }
                else if (status == 6)
                {
                    m_ConnectingText.text = $"Waiting for approval on {m_ConnectedHostName}...";
                }
                else if (status == 20)
                {
                    m_ConnectingText.text = $"Connecting to {m_ConnectedHostName}...";
                }
                else if (status != 10)
                {
                    m_ParsecConnecting = false;
                    ParsecNative.Disconnect();
                    ShowHostBrowserState(
                        $"Connection failed ({ParsecApiModels.FormatStatusLabel(status)}). Check host and retry.",
                        hasError: true);
                }
                return;
            }

            if (m_ParsecConnected)
            {
                if (status != 0 && status != 10)
                {
                    m_ParsecConnected = false;
                    ParsecNative.Disconnect();
                    ShowHostBrowserState(
                        $"Disconnected ({ParsecApiModels.FormatStatusLabel(status)}). Pick a host to reconnect.",
                        hasError: true);
                    return;
                }

                ParsecNative.RenderFrame(m_ParsecScreen.Texture, 2);
                m_ParsecHeaderStatus.text = netFail
                    ? $"{m_ConnectedHostName} (unstable network)"
                    : $"{m_ConnectedHostName} ({hostW}x{hostH})";
            }
        }

        void UpdateWebRuntime()
        {
            if (!m_WebScreen.gameObject.activeInHierarchy)
                return;

            var now = Time.unscaledTime;
            if (now >= m_NextWebRefresh)
            {
                m_NextWebRefresh = now + k_WebRefreshInterval;
                WebViewNative.UpdateTexture(m_WebScreen.Texture);
                for (var i = 0; i < m_ExtraMonitors.Count; i++)
                {
                    if (m_ExtraMonitors[i].gameObject.activeInHierarchy)
                        Graphics.Blit(m_WebScreen.Texture, m_ExtraMonitors[i].Texture);
                }
            }

            if (now >= m_NextWebUrlSync)
            {
                m_NextWebUrlSync = now + 0.5f;
                var loading = WebViewNative.IsLoading();
                var liveUrl = WebViewNative.GetUrl();
                if (!string.IsNullOrEmpty(liveUrl) && m_Focus != InputTarget.WebUrl)
                {
                    m_WebUrlInput = liveUrl;
                    m_WebUrlButton.Text = Truncate(liveUrl, 34);
                }
                m_WebStatusText.text = WebViewNative.IsSupported
                    ? (loading ? "Loading page..." : "Ready")
                    : "Editor stub (builds with WKWebView on iOS)";
            }
        }

        void BuildScreens()
        {
            var parsecGo = new GameObject("Parsec Screen");
            parsecGo.transform.SetParent(m_WorkspaceRoot, false);
            m_ParsecScreen = parsecGo.AddComponent<SpatialScreenSurface>();
            m_ParsecScreen.Initialize("Parsec", 1920, 1080, new Vector2(1.92f, 1.08f), m_ScreenMaterial);
            m_ParsecScreen.SetVisible(false);

            var webGo = new GameObject("Web Screen");
            webGo.transform.SetParent(m_WorkspaceRoot, false);
            m_WebScreen = webGo.AddComponent<SpatialScreenSurface>();
            m_WebScreen.Initialize("WebKit", 1280, 800, new Vector2(1.36f, 0.85f), m_ScreenMaterial);
        }

        void BuildControlBar()
        {
            m_ControlBar = WorldUi.Panel("Desktop Controls", m_WorkspaceRoot, new Vector2(820f, 184f), k_ParsecDistance);
            m_ModeSegments = M3.Segments("Mode", m_ControlBar, new[] { "Parsec + Web", "Parsec Only", "Web Only" },
                new Vector2(-190f, 52f), 130f, index => ApplyWorkspaceMode((WorkspaceMode)index));

            m_KeyboardToggle = M3.Button("Keyboard", m_ControlBar, "Keyboard", M3Button.Variant.Tonal,
                new Vector2(130f, 52f), ToggleKeyboard, "keyboard", 136f);
            m_KeyboardToggle.Selected = true;

            m_RightClickToggle = M3.Button("RightClick", m_ControlBar, "Right Click", M3Button.Variant.Tonal,
                new Vector2(286f, 52f), ToggleRightClick, "touch_app", 150f);

            m_MuteToggle = M3.Button("Mute", m_ControlBar, "Audio On", M3Button.Variant.Tonal,
                new Vector2(-280f, -4f), ToggleMute, "volume_up", 144f);
            M3.Button("Recenter", m_ControlBar, "Recenter", M3Button.Variant.Tonal,
                new Vector2(-118f, -4f), RecenterWorkspace, "open_with", 140f);
            M3.Button("FlipY", m_ControlBar, "Flip Y", M3Button.Variant.Tonal,
                new Vector2(40f, -4f), FlipActiveTextures, "refresh", 124f);
            m_RoomToggle = M3.Button("Room", m_ControlBar, "Passthrough", M3Button.Variant.Tonal,
                new Vector2(226f, -4f), ToggleRoom, "visibility", 174f);
            m_RoomToggle.Selected = m_Core.Passthrough != null && m_Core.Passthrough.IsOn;

            m_AddMonitorButton = M3.Button("AddMonitor", m_ControlBar, "+ Monitor (0/4)", M3Button.Variant.Filled,
                new Vector2(-190f, -60f), AddSideMonitor, "desktop_windows", 210f);
            m_MonitorSizeButton = M3.Button("MonitorSize", m_ControlBar, "Size: Giant", M3Button.Variant.Tonal,
                new Vector2(36f, -60f), CycleMonitorSize, "aspect_ratio", 190f);
            M3.Button("ClearMonitors", m_ControlBar, "Clear Side", M3Button.Variant.Outlined,
                new Vector2(246f, -60f), ClearExtraMonitors, "close", 170f);
        }

        void BuildParsecPanels()
        {
            m_ParsecHeaderBar = WorldUi.Panel("Parsec Header", m_WorkspaceRoot, new Vector2(680f, 76f), k_ParsecDistance);
            m_ParsecHeaderStatus = M3.Text("Status", m_ParsecHeaderBar, "Parsec Live", M3Theme.Type.TitleMedium,
                new Vector2(-180f, 0f), new Vector2(290f, 32f), M3Theme.OnSurface, TextAlignmentOptions.Left);
            M3.Button("ScrollUp", m_ParsecHeaderBar, "Up", M3Button.Variant.Tonal,
                new Vector2(24f, 0f), () => ParsecNative.SendMouseWheel(0, 120), width: 76f);
            M3.Button("ScrollDown", m_ParsecHeaderBar, "Down", M3Button.Variant.Tonal,
                new Vector2(108f, 0f), () => ParsecNative.SendMouseWheel(0, -120), width: 92f);
            m_ParsecDisconnectButton = M3.Button("Disconnect", m_ParsecHeaderBar, "Disconnect", M3Button.Variant.Outlined,
                new Vector2(242f, 0f), DisconnectParsec, "close", 150f);
            m_ParsecHeaderBar.gameObject.SetActive(false);

            m_ParsecPanel = WorldUi.Panel("Parsec Panel", m_WorkspaceRoot, new Vector2(540f, 440f), k_ParsecDistance);
            M3.Icon("Icon", m_ParsecPanel, "desktop_windows", 28f, new Vector2(-232f, 186f), M3Theme.Primary);
            M3.Text("Title", m_ParsecPanel, "Parsec Remote Desktop", M3Theme.Type.TitleLarge,
                new Vector2(14f, 186f), new Vector2(440f, 34f), alignment: TextAlignmentOptions.Left);
            m_ParsecStateText = M3.Text("State", m_ParsecPanel, "Sign in to list your online computers.",
                M3Theme.Type.BodyMedium, new Vector2(0f, 142f), new Vector2(488f, 40f), M3Theme.OnSurfaceVariant,
                TextAlignmentOptions.Left);

            m_LoginGroup = WorldUi.CreateGroup("LoginGroup", m_ParsecPanel);
            m_EmailFieldButton = M3.Button("Email", m_LoginGroup, "Email: Tap to type", M3Button.Variant.Outlined,
                new Vector2(0f, 76f), () => FocusField(InputTarget.ParsecEmail), "edit", 480f);
            m_PasswordFieldButton = M3.Button("Password", m_LoginGroup, "Password: Tap to type", M3Button.Variant.Outlined,
                new Vector2(0f, 10f), () => FocusField(InputTarget.ParsecPassword), "edit", 480f);
            m_TfaFieldButton = M3.Button("TFA", m_LoginGroup, "2FA Code: Optional", M3Button.Variant.Outlined,
                new Vector2(0f, -56f), () => FocusField(InputTarget.ParsecTfa), "edit", 480f);
            m_TfaFieldButton.gameObject.SetActive(false);
            m_SignInButton = M3.Button("SignIn", m_LoginGroup, "Sign In to Parsec", M3Button.Variant.Filled,
                new Vector2(0f, -142f), StartSignIn, "desktop_windows", 260f);

            m_HostsGroup = WorldUi.CreateGroup("HostsGroup", m_ParsecPanel);
            for (var i = 0; i < 4; i++)
            {
                var idx = i;
                var row = M3.ListItem($"Host_{i}", m_HostsGroup, "computer", new Vector2(0f, 76f - i * 68f), 488f,
                    () => ConnectToHostAt(idx));
                row.item.gameObject.SetActive(false);
                m_HostRows.Add(row);
            }
            m_RefreshHostsButton = M3.Button("RefreshHosts", m_HostsGroup, "Refresh Hosts", M3Button.Variant.Tonal,
                new Vector2(-118f, -176f), RefreshHosts, "refresh", 210f);
            m_SignOutButton = M3.Button("SignOut", m_HostsGroup, "Sign Out", M3Button.Variant.Outlined,
                new Vector2(126f, -176f), SignOutParsec, "close", 180f);
            m_HostsGroup.gameObject.SetActive(false);

            m_ConnectingGroup = WorldUi.CreateGroup("ConnectingGroup", m_ParsecPanel);
            m_ConnectingText = M3.Text("ConnectingStatus", m_ConnectingGroup, "Connecting...", M3Theme.Type.TitleLarge,
                new Vector2(0f, 16f), new Vector2(460f, 64f));
            m_CancelConnectButton = M3.Button("CancelConnect", m_ConnectingGroup, "Cancel", M3Button.Variant.Outlined,
                new Vector2(0f, -86f), CancelConnect, "close", 180f);
            m_ConnectingGroup.gameObject.SetActive(false);

            UpdateAuthFieldLabels();
        }

        void BuildWebBar()
        {
            m_WebBar = WorldUi.Panel("WebKit Bar", m_WorkspaceRoot, new Vector2(680f, 134f), k_WebSideDistance);
            M3.IconButton("Back", m_WebBar, "arrow_back", M3Button.Variant.Tonal, new Vector2(-300f, 30f),
                WebViewNative.GoBack, 48f);
            M3.IconButton("Forward", m_WebBar, "arrow_forward", M3Button.Variant.Tonal, new Vector2(-244f, 30f),
                WebViewNative.GoForward, 48f);
            M3.IconButton("Reload", m_WebBar, "refresh", M3Button.Variant.Tonal, new Vector2(-188f, 30f),
                WebViewNative.Reload, 48f);
            m_WebUrlButton = M3.Button("UrlField", m_WebBar, Truncate(m_WebUrlInput, 34), M3Button.Variant.Outlined,
                new Vector2(88f, 30f), () => FocusField(InputTarget.WebUrl), "search", 476f);

            M3.Button("SiteSearch", m_WebBar, "DuckDuckGo", M3Button.Variant.Tonal, new Vector2(-246f, -32f),
                () => NavigateWeb("https://duckduckgo.com"), "language", 156f);
            M3.Button("SiteYt", m_WebBar, "YouTube", M3Button.Variant.Tonal, new Vector2(-92f, -32f),
                () => NavigateWeb("https://www.youtube.com"), width: 128f);
            M3.Button("SiteGh", m_WebBar, "GitHub", M3Button.Variant.Tonal, new Vector2(36f, -32f),
                () => NavigateWeb("https://github.com"), width: 112f);
            M3.Button("WebUp", m_WebBar, "Up", M3Button.Variant.Tonal, new Vector2(150f, -32f),
                () => WebViewNative.Scroll(0.5f, 0.5f, -360f), width: 80f);
            M3.Button("WebDown", m_WebBar, "Down", M3Button.Variant.Tonal, new Vector2(246f, -32f),
                () => WebViewNative.Scroll(0.5f, 0.5f, 360f), width: 92f);
            m_WebStatusText = M3.Text("WebStatus", m_WebBar, "", M3Theme.Type.BodyMedium,
                new Vector2(0f, -72f), new Vector2(640f, 20f), M3Theme.OnSurfaceVariant);
        }

        void BuildKeyboard()
        {
            var kbGo = new GameObject("Air Keyboard Root");
            kbGo.transform.SetParent(m_WorkspaceRoot, false);
            m_Keyboard = kbGo.AddComponent<SpatialAirKeyboard>();
            m_Keyboard.Initialize(m_Core);
            m_Keyboard.KeyPressed += HandleAirKey;
            UpdateKeyboardBanner();
        }

        void ApplyWorkspaceMode(WorkspaceMode mode)
        {
            m_Mode = mode;
            for (var i = 0; i < m_ModeSegments.Length; i++)
                m_ModeSegments[i].Selected = i == (int)mode;

            var showParsec = mode != WorkspaceMode.WebOnly;
            var showWeb = mode != WorkspaceMode.ParsecOnly;

            m_ParsecScreen.SetVisible(showParsec && m_ParsecConnected);
            m_ParsecHeaderBar.gameObject.SetActive(showParsec && m_ParsecConnected);
            m_ParsecPanel.gameObject.SetActive(showParsec && !m_ParsecConnected);

            m_WebScreen.SetVisible(showWeb);
            m_WebBar.gameObject.SetActive(showWeb);
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
                m_ExtraMonitors[i].SetVisible(showWeb);
            PositionWebWorkspace(mode == WorkspaceMode.WebOnly);
        }

        void PositionWebWorkspace(bool centered)
        {
            var head = m_Core.Head;
            var flat = Vector3.ProjectOnPlane(head.forward, Vector3.up);
            var yawRot = flat.sqrMagnitude > 1e-4f ? Quaternion.LookRotation(flat.normalized) : Quaternion.identity;

            var yawDeg = centered ? 0f : k_WebSideYaw;
            var dist = centered ? k_ParsecDistance : k_WebSideDistance;
            var dir = yawRot * Quaternion.Euler(-4f, yawDeg, 0f) * Vector3.forward;
            var screenPos = head.position + dir * dist;
            var screenRot = Quaternion.LookRotation(screenPos - head.position, Vector3.up);

            m_WebScreen.transform.SetPositionAndRotation(screenPos, screenRot);
            WorldUi.PlaceInFront(m_WebBar, head, dist, 18f, yawDeg);
        }

        void RecenterWorkspace()
        {
            var head = m_Core.Head;
            var flat = Vector3.ProjectOnPlane(head.forward, Vector3.up);
            var yawRot = flat.sqrMagnitude > 1e-4f ? Quaternion.LookRotation(flat.normalized) : Quaternion.identity;

            var parsecDir = yawRot * Quaternion.Euler(-4f, 0f, 0f) * Vector3.forward;
            var parsecPos = head.position + parsecDir * k_ParsecDistance;
            var parsecRot = Quaternion.LookRotation(parsecPos - head.position, Vector3.up);
            m_ParsecScreen.transform.SetPositionAndRotation(parsecPos, parsecRot);

            WorldUi.PlaceInFront(m_ParsecPanel, head, k_ParsecDistance, 4f, 0f);
            WorldUi.PlaceInFront(m_ParsecHeaderBar, head, k_ParsecDistance, 21f, 0f);
            WorldUi.PlaceInFront(m_ControlBar, head, k_ParsecDistance, -24f, 0f);
            PositionWebWorkspace(m_Mode == WorkspaceMode.WebOnly);
            PositionExtraMonitors();
            m_Keyboard.PlaceInFront();
            Debug.Log("[Desktop] Recentered monitors, control bar, and keyboard");
        }

        void FocusField(InputTarget target)
        {
            m_Focus = target;
            UpdateAuthFieldLabels();
            UpdateKeyboardBanner();
        }

        void HandleAirKey(AirKeyEvent key)
        {
            if (m_Focus == InputTarget.ParsecHost)
            {
                SendKeyToParsec(key);
                return;
            }
            if (m_Focus == InputTarget.WebPage)
            {
                WebViewNative.TypeKey(key.Text, key.IsBackspace, key.IsEnter);
                return;
            }

            if (key.IsShiftModifier || key.IsCtrlModifier || key.IsAltModifier || key.IsWinModifier || key.IsEscape)
                return;

            if (key.IsEnter)
            {
                if (m_Focus == InputTarget.WebUrl)
                    NavigateWeb(m_WebUrlInput);
                else if (m_Focus is InputTarget.ParsecEmail or InputTarget.ParsecPassword or InputTarget.ParsecTfa)
                    StartSignIn();
                return;
            }

            if (key.IsTab && m_Focus is InputTarget.ParsecEmail or InputTarget.ParsecPassword or InputTarget.ParsecTfa)
            {
                m_Focus = m_Focus == InputTarget.ParsecEmail ? InputTarget.ParsecPassword
                    : (m_RequiresTfa && m_Focus == InputTarget.ParsecPassword ? InputTarget.ParsecTfa : InputTarget.ParsecEmail);
                UpdateAuthFieldLabels();
                UpdateKeyboardBanner();
                return;
            }

            ApplyTextEditToFocusedField(key);
        }

        void ApplyTextEditToFocusedField(AirKeyEvent key)
        {
            ref var target = ref GetFocusedFieldRef();
            if (key.IsBackspace)
            {
                if (target.Length > 0)
                    target = target.Substring(0, target.Length - 1);
            }
            else if (!string.IsNullOrEmpty(key.Text))
            {
                target += key.Text;
            }
            UpdateAuthFieldLabels();
        }

        ref string GetFocusedFieldRef()
        {
            switch (m_Focus)
            {
                case InputTarget.ParsecPassword: return ref m_Password;
                case InputTarget.ParsecTfa: return ref m_Tfa;
                case InputTarget.WebUrl: return ref m_WebUrlInput;
                default: return ref m_Email;
            }
        }

        void SendKeyToParsec(AirKeyEvent key)
        {
            if (key.IsShiftModifier)
            {
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftShift, m_Keyboard.ShiftActive);
                return;
            }
            if (key.IsCtrlModifier)
            {
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftCtrl, m_Keyboard.CtrlActive);
                return;
            }
            if (key.IsAltModifier)
            {
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftAlt, m_Keyboard.AltActive);
                return;
            }
            if (key.IsWinModifier)
            {
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftGui, m_Keyboard.WinActive);
                return;
            }

            if (key.Text.Length > 1)
            {
                for (var i = 0; i < key.Text.Length; i++)
                {
                    if (ParsecKeyMap.TryMapChar(key.Text[i], out var stroke))
                        PulseParsecKey(stroke.UsbHidCode, stroke.NeedsShift);
                }
                return;
            }

            if (key.UsbHidCode != 0)
            {
                var needsShift = key.Text.Length == 1 && ParsecKeyMap.TryMapChar(key.Text[0], out var st) && st.NeedsShift;
                PulseParsecKey(key.UsbHidCode, needsShift);
            }
        }

        void PulseParsecKey(int code, bool withShift)
        {
            if (withShift && !m_Keyboard.ShiftActive)
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftShift, true);
            ParsecNative.SendKey(code, true);
            ParsecNative.SendKey(code, false);
            if (withShift && !m_Keyboard.ShiftActive)
                ParsecNative.SendKey(ParsecKeyMap.KeyLeftShift, false);
        }

        void RestoreSavedSession()
        {
            var saved = ParsecNative.LoadSecret(KeychainSessionKey);
            if (string.IsNullOrEmpty(saved))
            {
                ShowLoginState("Enter your Parsec email and password below.", hasError: false);
                return;
            }
            try
            {
                var auth = JsonUtility.FromJson<ParsecAuthResponse>(saved);
                if (auth != null && !string.IsNullOrEmpty(auth.session_id))
                {
                    m_SessionId = auth.session_id;
                    RefreshHosts();
                    return;
                }
            }
            catch
            {
                // Corrupt saved session falls back cleanly to sign-in.
            }
            ShowLoginState("Sign in to list your online computers.", hasError: false);
        }

        void StartSignIn()
        {
            if (m_IsBusy)
                return;
            if (string.IsNullOrWhiteSpace(m_Email) || string.IsNullOrEmpty(m_Password))
            {
                ShowLoginState("Both email and password are required before signing in.", hasError: true);
                return;
            }

            m_IsBusy = true;
            m_SignInButton.Interactable = false;
            ShowLoginState("Signing in to Parsec...", hasError: false);
            m_AuthCoroutine = StartCoroutine(ParsecApiClient.Authenticate(m_Email.Trim(), m_Password, m_Tfa.Trim(), OnAuthComplete));
        }

        void OnAuthComplete(ParsecAuthResult result)
        {
            m_IsBusy = false;
            m_SignInButton.Interactable = true;

            if (result.Success && result.Session != null)
            {
                m_SessionId = result.Session.session_id;
                m_RequiresTfa = false;
                m_Tfa = "";
                ParsecNative.SaveSecret(KeychainSessionKey, JsonUtility.ToJson(result.Session));
                Debug.Log("[Desktop] Parsec sign-in succeeded");
                RefreshHosts();
                return;
            }

            if (result.RequiresTfa)
            {
                m_RequiresTfa = true;
                m_TfaFieldButton.gameObject.SetActive(true);
                FocusField(InputTarget.ParsecTfa);
                ShowLoginState("Enter the 2FA code from your authenticator app and press Sign In.", hasError: false);
                return;
            }

            ShowLoginState(result.ErrorMessage ?? "Sign-in failed. Check credentials and retry.", hasError: true);
        }

        void RefreshHosts()
        {
            if (m_IsBusy)
                return;
            m_IsBusy = true;
            m_RefreshHostsButton.Interactable = false;
            ShowHostBrowserState("Fetching your Parsec computers...", hasError: false);
            m_HostsCoroutine = StartCoroutine(ParsecApiClient.FetchHosts(m_SessionId, OnHostsFetched));
        }

        void OnHostsFetched(bool ok, bool expired, ParsecHostEntry[] hosts, string error)
        {
            m_IsBusy = false;
            m_RefreshHostsButton.Interactable = true;

            if (expired)
            {
                SignOutParsec();
                ShowLoginState("Your Parsec session expired. Sign in again.", hasError: true);
                return;
            }

            if (!ok)
            {
                ShowHostBrowserState(error ?? "Could not fetch hosts. Check Wi-Fi and press Refresh Hosts.", hasError: true);
                return;
            }

            m_Hosts.Clear();
            for (var i = 0; i < hosts.Length && m_Hosts.Count < m_HostRows.Count; i++)
                m_Hosts.Add(hosts[i]);

            for (var i = 0; i < m_HostRows.Count; i++)
            {
                var active = i < m_Hosts.Count;
                m_HostRows[i].item.gameObject.SetActive(active);
                if (!active)
                    continue;
                var host = m_Hosts[i];
                m_HostRows[i].item.Text = string.IsNullOrEmpty(host.name) ? host.peer_id : host.name;
                var owner = host.user != null ? host.user.name : "Host";
                m_HostRows[i].supporting.text = $"{owner} | {host.players} connected";
            }

            if (m_Hosts.Count == 0)
                ShowHostBrowserState("No online Parsec hosts found. Start Parsec on your PC, then press Refresh Hosts.", hasError: false);
            else
                ShowHostBrowserState($"Select a computer to connect ({m_Hosts.Count} online):", hasError: false);
        }

        void ConnectToHostAt(int index)
        {
            if (index < 0 || index >= m_Hosts.Count || m_IsBusy)
                return;
            var host = m_Hosts[index];
            m_ConnectedHostName = string.IsNullOrEmpty(host.name) ? host.peer_id : host.name;
            m_LastParsecStatus = -999;

            var status = ParsecNative.Connect(m_SessionId, host.peer_id, 1920, 1080, false);
            if (status != 0 && status != 20)
            {
                ShowHostBrowserState($"Could not start Parsec connection ({ParsecApiModels.FormatStatusLabel(status)}).", hasError: true);
                return;
            }

            m_ParsecConnecting = true;
            m_LoginGroup.gameObject.SetActive(false);
            m_HostsGroup.gameObject.SetActive(false);
            m_ConnectingGroup.gameObject.SetActive(true);
            m_ConnectingText.text = $"Connecting to {m_ConnectedHostName}...";
            m_ParsecStateText.text = "Negotiating P2P video stream";
            Debug.Log($"[Desktop] Connecting to Parsec host {m_ConnectedHostName}");
        }

        void CancelConnect()
        {
            m_ParsecConnecting = false;
            ParsecNative.Disconnect();
            ShowHostBrowserState("Connection canceled. Pick a computer or refresh hosts.", hasError: false);
        }

        void DisconnectParsec()
        {
            m_ParsecConnected = false;
            m_ParsecConnecting = false;
            ReleaseParsecMouse();
            ParsecNative.Disconnect();
            ApplyWorkspaceMode(m_Mode);
            ShowHostBrowserState("Disconnected from host.", hasError: false);
        }

        void SignOutParsec()
        {
            m_SessionId = "";
            m_Hosts.Clear();
            ParsecNative.DeleteSecret(KeychainSessionKey);
            ShowLoginState("Signed out. Enter email and password to sign in.", hasError: false);
        }

        void ShowLoginState(string statusText, bool hasError)
        {
            m_ParsecConnected = false;
            m_ParsecConnecting = false;
            m_LoginGroup.gameObject.SetActive(true);
            m_HostsGroup.gameObject.SetActive(false);
            m_ConnectingGroup.gameObject.SetActive(false);
            m_ParsecStateText.text = statusText;
            m_ParsecStateText.color = hasError ? M3Theme.Error : M3Theme.OnSurfaceVariant;
            if (m_Focus == InputTarget.ParsecHost || m_Focus == InputTarget.None)
                FocusField(InputTarget.ParsecEmail);
        }

        void ShowHostBrowserState(string statusText, bool hasError)
        {
            m_ParsecConnected = false;
            m_ParsecConnecting = false;
            m_LoginGroup.gameObject.SetActive(false);
            m_HostsGroup.gameObject.SetActive(true);
            m_ConnectingGroup.gameObject.SetActive(false);
            m_ParsecStateText.text = statusText;
            m_ParsecStateText.color = hasError ? M3Theme.Error : M3Theme.OnSurfaceVariant;
            ApplyWorkspaceMode(m_Mode);
        }

        void ShowParsecLiveView(int width, int height)
        {
            m_ParsecStateText.color = M3Theme.OnSurfaceVariant;
            m_ParsecHeaderStatus.text = $"{m_ConnectedHostName} ({width}x{height})";
            ApplyWorkspaceMode(m_Mode);
        }

        void NavigateWeb(string url)
        {
            if (string.IsNullOrWhiteSpace(url))
                return;
            var normalized = url.Trim();
            if (!normalized.StartsWith("http://", StringComparison.OrdinalIgnoreCase) &&
                !normalized.StartsWith("https://", StringComparison.OrdinalIgnoreCase))
                normalized = "https://" + normalized;

            m_WebUrlInput = normalized;
            m_WebUrlButton.Text = Truncate(normalized, 34);
            m_Focus = InputTarget.WebPage;
            UpdateKeyboardBanner();
            WebViewNative.LoadUrl(normalized);
        }

        void ToggleKeyboard()
        {
            var next = !m_Keyboard.Visible;
            m_Keyboard.SetVisible(next);
            m_KeyboardToggle.Selected = next;
        }

        void ToggleRightClick()
        {
            m_RightClickArmed = !m_RightClickArmed;
            m_RightClickToggle.Selected = m_RightClickArmed;
        }

        void ToggleMute()
        {
            m_Muted = !m_Muted;
            ParsecNative.SetMuted(m_Muted);
            m_MuteToggle.Selected = m_Muted;
            m_MuteToggle.Text = m_Muted ? "Muted" : "Audio On";
            m_MuteToggle.Icon = m_Muted ? "volume_off" : "volume_up";
        }

        void FlipActiveTextures()
        {
            m_ParsecScreen.ToggleFlipY();
            m_WebScreen.ToggleFlipY();
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
                m_ExtraMonitors[i].ToggleFlipY();
        }

        bool TryRaycastAnyWebMonitor(GameObject gazeTarget, Ray ray, out SpatialScreenSurface hitScreen, out Vector2 uv)
        {
            if (ReferenceEquals(gazeTarget, m_WebScreen.ColliderObject) && m_WebScreen.TryRaycast(ray, out uv))
            {
                hitScreen = m_WebScreen;
                return true;
            }
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
            {
                var extra = m_ExtraMonitors[i];
                if (ReferenceEquals(gazeTarget, extra.ColliderObject) && extra.TryRaycast(ray, out uv))
                {
                    hitScreen = extra;
                    return true;
                }
            }
            hitScreen = null;
            uv = Vector2.zero;
            return false;
        }

        void AddSideMonitor()
        {
            if (m_ExtraMonitors.Count >= k_SideMonitorAngles.Length)
                return;

            var idx = m_ExtraMonitors.Count;
            var go = new GameObject($"Side Monitor {idx + 1}");
            go.transform.SetParent(m_WorkspaceRoot, false);
            var surface = go.AddComponent<SpatialScreenSurface>();
            surface.Initialize($"Side_{idx + 1}", 1280, 800, new Vector2(1.36f, 0.85f), m_ScreenMaterial);
            if (m_WebScreen.FlipY)
                surface.ToggleFlipY();
            surface.SetVisible(m_Mode != WorkspaceMode.ParsecOnly);
            m_ExtraMonitors.Add(surface);

            ApplyScaleToMonitors();
            PositionExtraMonitor(idx);
            m_AddMonitorButton.Text = m_ExtraMonitors.Count >= k_SideMonitorAngles.Length
                ? $"Side Full ({m_ExtraMonitors.Count}/4)"
                : $"+ Monitor ({m_ExtraMonitors.Count}/4)";
        }

        void ClearExtraMonitors()
        {
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
                Destroy(m_ExtraMonitors[i].gameObject);
            m_ExtraMonitors.Clear();
            m_AddMonitorButton.Text = "+ Monitor (0/4)";
        }

        void CycleMonitorSize()
        {
            m_SizePreset = (m_SizePreset + 1) % k_SizePresetLabels.Length;
            m_MonitorSizeButton.Text = $"Size: {k_SizePresetLabels[m_SizePreset]}";
            ApplyScaleToMonitors();
        }

        void ApplyScaleToMonitors()
        {
            var s = Vector3.one * k_MonitorScales[m_SizePreset];
            if (m_ParsecScreen != null)
                m_ParsecScreen.transform.localScale = s;
            if (m_WebScreen != null)
                m_WebScreen.transform.localScale = s;
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
                m_ExtraMonitors[i].transform.localScale = s;
        }

        void PositionExtraMonitors()
        {
            for (var i = 0; i < m_ExtraMonitors.Count; i++)
                PositionExtraMonitor(i);
        }

        void PositionExtraMonitor(int index)
        {
            if (index < 0 || index >= m_ExtraMonitors.Count || index >= k_SideMonitorAngles.Length)
                return;
            var head = m_Core.Head;
            var flat = Vector3.ProjectOnPlane(head.forward, Vector3.up);
            var yawRot = flat.sqrMagnitude > 1e-4f ? Quaternion.LookRotation(flat.normalized) : Quaternion.identity;
            var layout = k_SideMonitorAngles[index];
            var dir = yawRot * Quaternion.Euler(-layout.y, layout.yaw, 0f) * Vector3.forward;
            var pos = head.position + dir * layout.dist;
            var rot = Quaternion.LookRotation(pos - head.position, Vector3.up);
            m_ExtraMonitors[index].transform.SetPositionAndRotation(pos, rot);
        }

        void ToggleRoom()
        {
            if (m_Core.Passthrough == null)
                return;
            m_Core.Passthrough.Toggle();
            m_RoomToggle.Selected = m_Core.Passthrough.IsOn;
        }

        void UpdateAuthFieldLabels()
        {
            m_EmailFieldButton.Text = string.IsNullOrEmpty(m_Email) ? "Email: Tap to type" : $"Email: {m_Email}";
            m_EmailFieldButton.Selected = m_Focus == InputTarget.ParsecEmail;

            var masked = new string('*', m_Password.Length);
            m_PasswordFieldButton.Text = string.IsNullOrEmpty(m_Password) ? "Password: Tap to type" : $"Password: {masked}";
            m_PasswordFieldButton.Selected = m_Focus == InputTarget.ParsecPassword;

            m_TfaFieldButton.Text = string.IsNullOrEmpty(m_Tfa) ? "2FA Code: Tap to type" : $"2FA Code: {m_Tfa}";
            m_TfaFieldButton.Selected = m_Focus == InputTarget.ParsecTfa;

            m_WebUrlButton.Text = Truncate(m_WebUrlInput, 34);
            m_WebUrlButton.Selected = m_Focus == InputTarget.WebUrl;
        }

        void UpdateKeyboardBanner()
        {
            var label = m_Focus switch
            {
                InputTarget.ParsecEmail => "Typing into: Parsec Email",
                InputTarget.ParsecPassword => "Typing into: Parsec Password",
                InputTarget.ParsecTfa => "Typing into: Parsec 2FA Code",
                InputTarget.WebUrl => "Typing into: Browser Address Bar (Enter navigates)",
                InputTarget.ParsecHost => "Typing into: Remote PC (Parsec)",
                InputTarget.WebPage => "Typing into: WebKit Page (active input)",
                _ => "Air Keyboard: Ready",
            };
            m_Keyboard.SetTargetLabel(label);
        }

        static string Truncate(string text, int max)
        {
            if (string.IsNullOrEmpty(text) || text.Length <= max)
                return text ?? "";
            return text.Substring(0, max - 3) + "...";
        }
    }
}
