using System;
using System.Collections;
using System.Text;
using UnityEngine;
using UnityEngine.Networking;

namespace CardboardXR.Demos.Desktop
{
    public static class ParsecApiClient
    {
        const string AuthUrl = "https://kessel-api.parsec.app/v1/auth";
        const string HostsUrl = "https://kessel-api.parsec.app/v2/hosts?mode=desktop&public=false";
        const string UserAgent = "parsec/150-93b Windows/11 libmatoya/4.0";

        public static IEnumerator Authenticate(string email, string password, string tfa, Action<ParsecAuthResult> onComplete)
        {
            var payload = JsonUtility.ToJson(new ParsecAuthRequest
            {
                email = email ?? "",
                password = password ?? "",
                tfa = tfa ?? "",
            });

            using var req = new UnityWebRequest(AuthUrl, UnityWebRequest.kHttpVerbPOST);
            req.uploadHandler = new UploadHandlerRaw(Encoding.UTF8.GetBytes(payload));
            req.downloadHandler = new DownloadHandlerBuffer();
            req.SetRequestHeader("Content-Type", "application/json");
            req.SetRequestHeader("User-Agent", UserAgent);
            req.timeout = 15;

            yield return req.SendWebRequest();

            var body = req.downloadHandler != null ? req.downloadHandler.text : null;
            var result = ParsecApiModels.ParseAuthResponse(req.responseCode, body, req.error);
            onComplete?.Invoke(result);
        }

        public static IEnumerator FetchHosts(string sessionId, Action<bool, bool, ParsecHostEntry[], string> onComplete)
        {
            if (string.IsNullOrEmpty(sessionId))
            {
                onComplete?.Invoke(false, true, Array.Empty<ParsecHostEntry>(), "Missing session");
                yield break;
            }

            using var req = UnityWebRequest.Get(HostsUrl);
            req.SetRequestHeader("Content-Type", "application/json");
            req.SetRequestHeader("Authorization", $"Bearer {sessionId}");
            req.SetRequestHeader("User-Agent", UserAgent);
            req.timeout = 15;

            yield return req.SendWebRequest();

            var code = req.responseCode;
            var body = req.downloadHandler != null ? req.downloadHandler.text : null;
            if (code == 401)
            {
                onComplete?.Invoke(false, true, Array.Empty<ParsecHostEntry>(), "Parsec session expired");
                yield break;
            }

            if (code == 200 && ParsecApiModels.TryParseHostList(body, out var hosts))
            {
                onComplete?.Invoke(true, false, hosts, null);
                yield break;
            }

            var err = code <= 0 ? (req.error ?? "Cannot reach Parsec servers") : $"Host refresh failed (HTTP {code})";
            onComplete?.Invoke(false, false, Array.Empty<ParsecHostEntry>(), err);
        }
    }
}
