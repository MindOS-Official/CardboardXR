using System;
using System.Collections.Generic;
using CardboardXR.Hands;
using CardboardXR.Interaction;
using CardboardXR.UI;
using TMPro;
using UnityEngine;
using UnityEngine.UI;

namespace CardboardXR.Demos.Desktop
{
    public readonly struct AirKeyEvent
    {
        public readonly string Label;
        public readonly string Text;
        public readonly bool IsBackspace;
        public readonly bool IsEnter;
        public readonly bool IsSpace;
        public readonly bool IsTab;
        public readonly bool IsEscape;
        public readonly bool IsShiftModifier;
        public readonly bool IsCtrlModifier;
        public readonly bool IsAltModifier;
        public readonly bool IsWinModifier;
        public readonly int UsbHidCode;

        public AirKeyEvent(
            string label,
            string text,
            int usbHidCode,
            bool isBackspace = false,
            bool isEnter = false,
            bool isSpace = false,
            bool isTab = false,
            bool isEscape = false,
            bool isShiftModifier = false,
            bool isCtrlModifier = false,
            bool isAltModifier = false,
            bool isWinModifier = false)
        {
            Label = label;
            Text = text;
            UsbHidCode = usbHidCode;
            IsBackspace = isBackspace;
            IsEnter = isEnter;
            IsSpace = isSpace;
            IsTab = isTab;
            IsEscape = isEscape;
            IsShiftModifier = isShiftModifier;
            IsCtrlModifier = isCtrlModifier;
            IsAltModifier = isAltModifier;
            IsWinModifier = isWinModifier;
        }
    }

    // 3D Material keyboard panel operable by both Gaze+Pinch and direct 3D fingertip touch.
    public class SpatialAirKeyboard : MonoBehaviour
    {
        const float k_Distance = 0.72f;
        const float k_PitchDegrees = -28f;
        const float k_PanelWidth = 650f;
        const float k_PanelHeight = 308f;
        const float k_TouchFrontDp = -26f;
        const float k_TouchDepthDp = 34f;
        const float k_KeyCooldown = 0.28f;

        sealed class KeyWidget
        {
            public RectTransform Rect;
            public Image Background;
            public TMP_Text Caption;
            public string NormalLabel;
            public string ShiftLabel;
            public string NormalText;
            public string ShiftText;
            public int UsbHidCode;
            public bool IsModifier;
            public string ModifierKind;
            public float FlashUntil;
            public float NextTouchAllowedAt;
        }

        static readonly (string normal, string shift, float units)[] s_Row0 =
        {
            ("ESC", "ESC", 1.1f), ("1", "!", 1f), ("2", "@", 1f), ("3", "#", 1f), ("4", "$", 1f),
            ("5", "%", 1f), ("6", "^", 1f), ("7", "&", 1f), ("8", "*", 1f), ("9", "(", 1f),
            ("0", ")", 1f), ("-", "_", 1f), ("=", "+", 1f), ("BKSP", "BKSP", 1.5f),
        };

        static readonly (string normal, string shift, float units)[] s_Row1 =
        {
            ("TAB", "TAB", 1.3f), ("q", "Q", 1f), ("w", "W", 1f), ("e", "E", 1f), ("r", "R", 1f),
            ("t", "T", 1f), ("y", "Y", 1f), ("u", "U", 1f), ("i", "I", 1f), ("o", "O", 1f),
            ("p", "P", 1f), ("[", "{", 1f), ("]", "}", 1f), ("\\", "|", 1.3f),
        };

        static readonly (string normal, string shift, float units)[] s_Row2 =
        {
            ("SHIFT", "SHIFT", 1.6f), ("a", "A", 1f), ("s", "S", 1f), ("d", "D", 1f), ("f", "F", 1f),
            ("g", "G", 1f), ("h", "H", 1f), ("j", "J", 1f), ("k", "K", 1f), ("l", "L", 1f),
            (";", ":", 1f), ("'", "\"", 1f), ("ENTER", "ENTER", 2.0f),
        };

        static readonly (string normal, string shift, float units)[] s_Row3 =
        {
            ("CTRL", "CTRL", 1.3f), ("z", "Z", 1f), ("x", "X", 1f), ("c", "C", 1f), ("v", "V", 1f),
            ("b", "B", 1f), ("n", "N", 1f), ("m", "M", 1f), (",", "<", 1f), (".", ">", 1f),
            ("/", "?", 1f), ("UP", "UP", 1.2f), ("DEL", "DEL", 1.1f),
        };

        static readonly (string normal, string shift, float units)[] s_Row4 =
        {
            ("ALT", "ALT", 1.2f), ("WIN", "WIN", 1.2f), (".com", ".com", 1.3f), ("https://", "https://", 1.6f),
            ("SPACE", "SPACE", 4.4f), ("LEFT", "LEFT", 1.1f), ("DOWN", "DOWN", 1.1f), ("RIGHT", "RIGHT", 1.1f),
        };

        readonly List<KeyWidget> m_Keys = new();
        RectTransform m_Panel;
        TMP_Text m_TargetBanner;
        AudioSource m_Audio;
        AudioClip m_ClickClip;
        CoreServices m_Core;
        bool m_Shift;
        bool m_Ctrl;
        bool m_Alt;
        bool m_Win;
        bool m_HadTipInTouchZone;
        float m_LastTipZ;

        public event Action<AirKeyEvent> KeyPressed;

        public bool ShiftActive => m_Shift;
        public bool CtrlActive => m_Ctrl;
        public bool AltActive => m_Alt;
        public bool WinActive => m_Win;
        public bool Visible => m_Panel != null && m_Panel.gameObject.activeSelf;

        public void Initialize(CoreServices core)
        {
            m_Core = core;
            m_Audio = gameObject.AddComponent<AudioSource>();
            m_Audio.playOnAwake = false;
            m_ClickClip = CreateClickClip();
            BuildKeyboard();
            PlaceInFront();
        }

        public void SetVisible(bool visible)
        {
            if (m_Panel != null)
                m_Panel.gameObject.SetActive(visible);
        }

        public void SetTargetLabel(string text)
        {
            if (m_TargetBanner != null)
                m_TargetBanner.text = text;
        }

        public void PlaceInFront()
        {
            if (m_Panel == null || m_Core == null)
                return;
            WorldUi.PlaceInFront(m_Panel, m_Core.Head, k_Distance, k_PitchDegrees, 0f);
        }

        void Update()
        {
            if (!Visible || m_Core == null)
                return;

            var now = Time.unscaledTime;
            UpdateKeyVisuals(now);
            PollDirectFingertipTouch(now);
        }

        void BuildKeyboard()
        {
            m_Panel = WorldUi.Panel("Air Keyboard", transform, new Vector2(k_PanelWidth, k_PanelHeight), k_Distance,
                M3Theme.WithAlpha(M3Theme.SurfaceContainer, 0.92f));
            m_TargetBanner = M3.Text("Target", m_Panel, "Air Keyboard: Ready", M3Theme.Type.BodyMedium,
                new Vector2(0f, k_PanelHeight / 2f - 20f), new Vector2(k_PanelWidth - 36f, 24f), M3Theme.OnSurfaceVariant);

            var rows = new[] { s_Row0, s_Row1, s_Row2, s_Row3, s_Row4 };
            const float topY = 104f;
            const float rowStep = 50f;
            const float keyHeight = 44f;
            const float gap = 4f;
            const float usableWidth = k_PanelWidth - 24f;

            for (var r = 0; r < rows.Length; r++)
            {
                var row = rows[r];
                var totalUnits = 0f;
                for (var i = 0; i < row.Length; i++)
                    totalUnits += row[i].units;

                var unitWidth = (usableWidth - gap * (row.Length - 1)) / totalUnits;
                var cursorX = -usableWidth / 2f;
                var y = topY - r * rowStep;

                for (var i = 0; i < row.Length; i++)
                {
                    var spec = row[i];
                    var w = spec.units * unitWidth;
                    var centerX = cursorX + w / 2f;
                    cursorX += w + gap;
                    CreateKeyWidget(spec.normal, spec.shift, new Vector2(centerX, y), new Vector2(w, keyHeight));
                }
            }
            RefreshKeyLabels();
        }

        void CreateKeyWidget(string normal, string shift, Vector2 position, Vector2 size)
        {
            var go = new GameObject($"Key_{normal}", typeof(RectTransform));
            go.transform.SetParent(m_Panel, false);
            var rect = (RectTransform)go.transform;
            rect.anchoredPosition = position;
            rect.sizeDelta = size;

            var bg = go.AddComponent<Image>();
            bg.color = M3Theme.SurfaceContainerHighest;
            bg.raycastTarget = true;
            M3Shapes.Apply(bg, M3Theme.k_ShapeCard);

            var stateImage = M3.Surface("State", rect, Vector2.zero, size, Color.clear, M3Theme.k_ShapeCard);
            var button = go.AddComponent<Button>();
            button.transition = Selectable.Transition.None;
            button.targetGraphic = bg;
            var state = go.AddComponent<M3StateLayer>();
            state.Initialize(stateImage, button, M3Theme.OnSurface);

            var label = M3.Text("Label", rect, normal, M3Theme.Type.LabelLarge, Vector2.zero, size - new Vector2(4f, 4f));
            label.textWrappingMode = TextWrappingModes.NoWrap;

            var isMod = normal is "SHIFT" or "CTRL" or "ALT" or "WIN";
            ParsecKeyMap.TryMapNamedKey(normal, out var mapped);

            var widget = new KeyWidget
            {
                Rect = rect,
                Background = bg,
                Caption = label,
                NormalLabel = normal,
                ShiftLabel = shift,
                NormalText = normal,
                ShiftText = shift,
                UsbHidCode = mapped.UsbHidCode,
                IsModifier = isMod,
                ModifierKind = isMod ? normal : null,
            };

            button.onClick.AddListener(() => TriggerKey(widget));
            m_Keys.Add(widget);
        }

        void PollDirectFingertipTouch(float now)
        {
            var tracker = m_Core.HandTracker;
            if (tracker == null || !tracker.isActiveAndEnabled || !tracker.IsTracking)
            {
                m_HadTipInTouchZone = false;
                return;
            }

            var tipWorld = tracker.Joints[HandGeometry.IndexTip];
            var local = m_Panel.InverseTransformPoint(tipWorld);
            var inPlaneBounds = Mathf.Abs(local.x) <= k_PanelWidth * 0.52f && Mathf.Abs(local.y) <= k_PanelHeight * 0.52f;
            if (!inPlaneBounds)
            {
                m_HadTipInTouchZone = false;
                return;
            }

            var inTouch = local.z >= k_TouchFrontDp && local.z <= k_TouchDepthDp;
            var entered = inTouch && (!m_HadTipInTouchZone || m_LastTipZ < k_TouchFrontDp);
            m_HadTipInTouchZone = inTouch;
            m_LastTipZ = local.z;

            if (!entered)
                return;

            var point2D = new Vector2(local.x, local.y);
            for (var i = 0; i < m_Keys.Count; i++)
            {
                var key = m_Keys[i];
                var center = key.Rect.anchoredPosition;
                var half = key.Rect.sizeDelta * 0.5f;
                if (Mathf.Abs(point2D.x - center.x) <= half.x && Mathf.Abs(point2D.y - center.y) <= half.y)
                {
                    if (now >= key.NextTouchAllowedAt)
                    {
                        key.NextTouchAllowedAt = now + k_KeyCooldown;
                        TriggerKey(key);
                    }
                    return;
                }
            }
        }

        void TriggerKey(KeyWidget key)
        {
            key.FlashUntil = Time.unscaledTime + 0.14f;
            if (m_Audio != null && m_ClickClip != null)
                m_Audio.PlayOneShot(m_ClickClip, 0.35f);

            if (key.IsModifier)
            {
                ToggleModifier(key.ModifierKind);
                RefreshKeyLabels();
                KeyPressed?.Invoke(new AirKeyEvent(
                    key.NormalLabel,
                    "",
                    key.UsbHidCode,
                    isShiftModifier: key.ModifierKind == "SHIFT",
                    isCtrlModifier: key.ModifierKind == "CTRL",
                    isAltModifier: key.ModifierKind == "ALT",
                    isWinModifier: key.ModifierKind == "WIN"));
                return;
            }

            var isBksp = key.NormalLabel == "BKSP";
            var isEnter = key.NormalLabel == "ENTER";
            var isSpace = key.NormalLabel == "SPACE";
            var isTab = key.NormalLabel == "TAB";
            var isEsc = key.NormalLabel == "ESC";
            var rawText = isSpace ? " " : (m_Shift ? key.ShiftText : key.NormalText);
            if (isBksp || isEnter || isTab || isEsc || key.NormalLabel is "DEL" or "UP" or "DOWN" or "LEFT" or "RIGHT")
                rawText = "";

            var code = key.UsbHidCode;
            if (code == 0 && rawText.Length == 1 && ParsecKeyMap.TryMapChar(rawText[0], out var stroke))
                code = stroke.UsbHidCode;

            KeyPressed?.Invoke(new AirKeyEvent(
                key.NormalLabel,
                rawText,
                code,
                isBackspace: isBksp,
                isEnter: isEnter,
                isSpace: isSpace,
                isTab: isTab,
                isEscape: isEsc));

            if (m_Shift && key.NormalLabel != "SHIFT")
            {
                m_Shift = false;
                RefreshKeyLabels();
            }
        }

        void ToggleModifier(string kind)
        {
            switch (kind)
            {
                case "SHIFT":
                    m_Shift = !m_Shift;
                    break;
                case "CTRL":
                    m_Ctrl = !m_Ctrl;
                    break;
                case "ALT":
                    m_Alt = !m_Alt;
                    break;
                case "WIN":
                    m_Win = !m_Win;
                    break;
            }
        }

        void RefreshKeyLabels()
        {
            for (var i = 0; i < m_Keys.Count; i++)
            {
                var key = m_Keys[i];
                if (!key.IsModifier)
                    key.Caption.text = m_Shift ? key.ShiftLabel : key.NormalLabel;
            }
        }

        void UpdateKeyVisuals(float now)
        {
            for (var i = 0; i < m_Keys.Count; i++)
            {
                var key = m_Keys[i];
                var activeMod = key.ModifierKind switch
                {
                    "SHIFT" => m_Shift,
                    "CTRL" => m_Ctrl,
                    "ALT" => m_Alt,
                    "WIN" => m_Win,
                    _ => false,
                };
                var flashed = now < key.FlashUntil;
                key.Background.color = flashed || activeMod ? M3Theme.Primary : M3Theme.SurfaceContainerHighest;
                key.Caption.color = flashed || activeMod ? M3Theme.OnPrimary : M3Theme.OnSurface;
            }
        }

        static AudioClip CreateClickClip()
        {
            const int rate = 44100;
            const float seconds = 0.035f;
            var samples = new float[(int)(rate * seconds)];
            for (var i = 0; i < samples.Length; i++)
            {
                var t = i / (float)samples.Length;
                var env = (1f - t) * (1f - t);
                samples[i] = Mathf.Sin(t * 24f * Mathf.PI) * env * 0.5f;
            }
            var clip = AudioClip.Create("KeyClick", samples.Length, 1, rate, false);
            clip.SetData(samples, 0);
            return clip;
        }
    }
}
