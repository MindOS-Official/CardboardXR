using System.Collections.Generic;

namespace CardboardXR.Demos.Desktop
{
    public readonly struct ParsecKeyStroke
    {
        public readonly int UsbHidCode;
        public readonly bool NeedsShift;

        public ParsecKeyStroke(int usbHidCode, bool needsShift)
        {
            UsbHidCode = usbHidCode;
            NeedsShift = needsShift;
        }
    }

    // Translates text characters and key labels to USB HID usage codes expected by ParsecSDK.
    public static class ParsecKeyMap
    {
        public const int KeyEnter = 40;
        public const int KeyEscape = 41;
        public const int KeyBackspace = 42;
        public const int KeyTab = 43;
        public const int KeySpace = 44;
        public const int KeyDelete = 76;
        public const int KeyRight = 79;
        public const int KeyLeft = 80;
        public const int KeyDown = 81;
        public const int KeyUp = 82;
        public const int KeyLeftCtrl = 224;
        public const int KeyLeftShift = 225;
        public const int KeyLeftAlt = 226;
        public const int KeyLeftGui = 227;

        static readonly Dictionary<string, int> s_NamedKeys = new(System.StringComparer.OrdinalIgnoreCase)
        {
            ["ENTER"] = KeyEnter,
            ["RETURN"] = KeyEnter,
            ["ESC"] = KeyEscape,
            ["ESCAPE"] = KeyEscape,
            ["BKSP"] = KeyBackspace,
            ["BACKSPACE"] = KeyBackspace,
            ["TAB"] = KeyTab,
            ["SPACE"] = KeySpace,
            ["DEL"] = KeyDelete,
            ["DELETE"] = KeyDelete,
            ["RIGHT"] = KeyRight,
            ["LEFT"] = KeyLeft,
            ["DOWN"] = KeyDown,
            ["UP"] = KeyUp,
            ["CTRL"] = KeyLeftCtrl,
            ["SHIFT"] = KeyLeftShift,
            ["ALT"] = KeyLeftAlt,
            ["WIN"] = KeyLeftGui,
            ["CMD"] = KeyLeftGui,
        };

        static readonly Dictionary<char, ParsecKeyStroke> s_SymbolMap = new()
        {
            ['-'] = new ParsecKeyStroke(45, false),
            ['_'] = new ParsecKeyStroke(45, true),
            ['='] = new ParsecKeyStroke(46, false),
            ['+'] = new ParsecKeyStroke(46, true),
            ['['] = new ParsecKeyStroke(47, false),
            ['{'] = new ParsecKeyStroke(47, true),
            [']'] = new ParsecKeyStroke(48, false),
            ['}'] = new ParsecKeyStroke(48, true),
            ['\\'] = new ParsecKeyStroke(49, false),
            ['|'] = new ParsecKeyStroke(49, true),
            [';'] = new ParsecKeyStroke(51, false),
            [':'] = new ParsecKeyStroke(51, true),
            ['\''] = new ParsecKeyStroke(52, false),
            ['"'] = new ParsecKeyStroke(52, true),
            ['`'] = new ParsecKeyStroke(53, false),
            ['~'] = new ParsecKeyStroke(53, true),
            [','] = new ParsecKeyStroke(54, false),
            ['<'] = new ParsecKeyStroke(54, true),
            ['.'] = new ParsecKeyStroke(55, false),
            ['>'] = new ParsecKeyStroke(55, true),
            ['/'] = new ParsecKeyStroke(56, false),
            ['?'] = new ParsecKeyStroke(56, true),
            ['!'] = new ParsecKeyStroke(30, true),
            ['@'] = new ParsecKeyStroke(31, true),
            ['#'] = new ParsecKeyStroke(32, true),
            ['$'] = new ParsecKeyStroke(33, true),
            ['%'] = new ParsecKeyStroke(34, true),
            ['^'] = new ParsecKeyStroke(35, true),
            ['&'] = new ParsecKeyStroke(36, true),
            ['*'] = new ParsecKeyStroke(37, true),
            ['('] = new ParsecKeyStroke(38, true),
            [')'] = new ParsecKeyStroke(39, true),
        };

        public static bool TryMapChar(char c, out ParsecKeyStroke stroke)
        {
            if (c >= 'a' && c <= 'z')
            {
                stroke = new ParsecKeyStroke(4 + (c - 'a'), false);
                return true;
            }
            if (c >= 'A' && c <= 'Z')
            {
                stroke = new ParsecKeyStroke(4 + (c - 'A'), true);
                return true;
            }
            if (c >= '1' && c <= '9')
            {
                stroke = new ParsecKeyStroke(30 + (c - '1'), false);
                return true;
            }
            if (c == '0')
            {
                stroke = new ParsecKeyStroke(39, false);
                return true;
            }
            if (c == ' ')
            {
                stroke = new ParsecKeyStroke(KeySpace, false);
                return true;
            }
            if (c == '\n' || c == '\r')
            {
                stroke = new ParsecKeyStroke(KeyEnter, false);
                return true;
            }
            if (c == '\t')
            {
                stroke = new ParsecKeyStroke(KeyTab, false);
                return true;
            }
            return s_SymbolMap.TryGetValue(c, out stroke);
        }

        public static bool TryMapNamedKey(string keyLabel, out ParsecKeyStroke stroke)
        {
            if (string.IsNullOrEmpty(keyLabel))
            {
                stroke = default;
                return false;
            }
            if (s_NamedKeys.TryGetValue(keyLabel.Trim(), out var code))
            {
                stroke = new ParsecKeyStroke(code, false);
                return true;
            }
            if (keyLabel.Length == 1)
                return TryMapChar(keyLabel[0], out stroke);

            stroke = default;
            return false;
        }
    }
}
