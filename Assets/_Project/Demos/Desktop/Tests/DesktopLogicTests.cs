using CardboardXR.Demos.Desktop;
using NUnit.Framework;
using UnityEngine;

namespace CardboardXR.Demos.Desktop.Tests
{
    public class DesktopLogicTests
    {
        [TestCase('a', 4, false)]
        [TestCase('z', 29, false)]
        [TestCase('A', 4, true)]
        [TestCase('Z', 29, true)]
        [TestCase('1', 30, false)]
        [TestCase('0', 39, false)]
        [TestCase('@', 31, true)]
        [TestCase(' ', 44, false)]
        [TestCase('/', 56, false)]
        [TestCase('?', 56, true)]
        public void CharMapsToExpectedUsbHidCode(char c, int expectedCode, bool expectedShift)
        {
            Assert.IsTrue(ParsecKeyMap.TryMapChar(c, out var stroke));
            Assert.AreEqual(expectedCode, stroke.UsbHidCode);
            Assert.AreEqual(expectedShift, stroke.NeedsShift);
        }

        [TestCase("ENTER", 40)]
        [TestCase("ESC", 41)]
        [TestCase("BKSP", 42)]
        [TestCase("TAB", 43)]
        [TestCase("SPACE", 44)]
        [TestCase("CTRL", 224)]
        [TestCase("SHIFT", 225)]
        [TestCase("ALT", 226)]
        [TestCase("WIN", 227)]
        public void NamedKeysMapCorrectly(string label, int expectedCode)
        {
            Assert.IsTrue(ParsecKeyMap.TryMapNamedKey(label, out var stroke));
            Assert.AreEqual(expectedCode, stroke.UsbHidCode);
        }

        [Test]
        public void ScreenMathMapsQuadLocalCoordinatesToTopLeftPixels()
        {
            var topLeftUv = SpatialScreenMath.LocalPointToUv(new Vector3(-0.5f, 0.5f, 0f));
            Assert.AreEqual(new Vector2(0f, 1f), topLeftUv);
            Assert.AreEqual(new Vector2Int(0, 0), SpatialScreenMath.UvToTopLeftPixel(topLeftUv, 1920, 1080));

            var bottomRightUv = SpatialScreenMath.LocalPointToUv(new Vector3(0.5f, -0.5f, 0f));
            Assert.AreEqual(new Vector2(1f, 0f), bottomRightUv);
            Assert.AreEqual(new Vector2Int(1919, 1079), SpatialScreenMath.UvToTopLeftPixel(bottomRightUv, 1920, 1080));

            var centerUv = SpatialScreenMath.LocalPointToUv(Vector3.zero);
            Assert.AreEqual(new Vector2(0.5f, 0.5f), centerUv);
            Assert.AreEqual(new Vector2(0.5f, 0.5f), SpatialScreenMath.UvToTopLeftNormalized(centerUv));
        }

        [Test]
        public void AuthParserHandlesSuccessTfaAndErrors()
        {
            var ok = ParsecApiModels.ParseAuthResponse(201, "{\"session_id\":\"abc123\",\"user_id\":42}");
            Assert.IsTrue(ok.Success);
            Assert.IsFalse(ok.RequiresTfa);
            Assert.AreEqual("abc123", ok.Session.session_id);

            var tfa = ParsecApiModels.ParseAuthResponse(401, "{\"error\":\"TFA required\",\"tfa_required\":true}");
            Assert.IsFalse(tfa.Success);
            Assert.IsTrue(tfa.RequiresTfa);

            var bad = ParsecApiModels.ParseAuthResponse(401, "{\"error\":\"Invalid password\"}");
            Assert.IsFalse(bad.Success);
            Assert.IsFalse(bad.RequiresTfa);
            Assert.AreEqual("Invalid password", bad.ErrorMessage);
        }

        [Test]
        public void HostListParserReadsEntries()
        {
            var json = "{\"data\":[{\"peer_id\":\"p1\",\"name\":\"DESKTOP-VR\",\"players\":1,\"user\":{\"id\":7,\"name\":\"ali\"}}],\"has_more\":false}";
            Assert.IsTrue(ParsecApiModels.TryParseHostList(json, out var hosts));
            Assert.AreEqual(1, hosts.Length);
            Assert.AreEqual("p1", hosts[0].peer_id);
            Assert.AreEqual("DESKTOP-VR", hosts[0].name);
            Assert.AreEqual("ali", hosts[0].user.name);
        }
    }
}
