using System;
using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    [Serializable]
    public class ParsecAuthRequest
    {
        public string email;
        public string password;
        public string tfa;
    }

    [Serializable]
    public class ParsecAuthResponse
    {
        public string instance_id;
        public int user_id;
        public string session_id;
        public string host_peer_id;
        public string error;
        public bool tfa_required;
    }

    [Serializable]
    public class ParsecHostUser
    {
        public int id;
        public string name;
    }

    [Serializable]
    public class ParsecHostEntry
    {
        public ParsecHostUser user;
        public string peer_id;
        public string name;
        public string mode;
        public int players;
        public bool online;
    }

    [Serializable]
    public class ParsecHostListResponse
    {
        public ParsecHostEntry[] data;
        public bool has_more;
    }

    public readonly struct ParsecAuthResult
    {
        public readonly bool Success;
        public readonly bool RequiresTfa;
        public readonly ParsecAuthResponse Session;
        public readonly string ErrorMessage;

        public ParsecAuthResult(bool success, bool requiresTfa, ParsecAuthResponse session, string errorMessage)
        {
            Success = success;
            RequiresTfa = requiresTfa;
            Session = session;
            ErrorMessage = errorMessage;
        }
    }

    public static class ParsecApiModels
    {
        public static ParsecAuthResult ParseAuthResponse(long statusCode, string body, string transportError = null)
        {
            if (statusCode <= 0)
                return new ParsecAuthResult(false, false, null, transportError ?? "Could not reach Parsec servers");

            ParsecAuthResponse parsed = null;
            if (!string.IsNullOrEmpty(body))
            {
                try
                {
                    parsed = JsonUtility.FromJson<ParsecAuthResponse>(body);
                }
                catch
                {
                    parsed = null;
                }
            }

            if (statusCode == 201 && parsed != null && !string.IsNullOrEmpty(parsed.session_id))
                return new ParsecAuthResult(true, false, parsed, null);

            if (statusCode >= 400 && parsed != null)
            {
                if (parsed.tfa_required)
                    return new ParsecAuthResult(false, true, null, "Two-factor code required");
                if (!string.IsNullOrEmpty(parsed.error))
                    return new ParsecAuthResult(false, false, null, parsed.error);
            }

            return new ParsecAuthResult(false, false, null, $"Login failed (HTTP {statusCode})");
        }

        public static bool TryParseHostList(string body, out ParsecHostEntry[] hosts)
        {
            hosts = Array.Empty<ParsecHostEntry>();
            if (string.IsNullOrEmpty(body))
                return false;

            try
            {
                var list = JsonUtility.FromJson<ParsecHostListResponse>(body);
                if (list == null || list.data == null)
                    return true;
                hosts = list.data;
                return true;
            }
            catch
            {
                return false;
            }
        }

        public static string FormatStatusLabel(int status) => status switch
        {
            0 => "Connected",
            6 => "Waiting for host approval",
            8 => "Host declined connection",
            9 => "Connection canceled",
            11 => "Host has no free seats",
            20 => "Connecting to host",
            99 => "Host went offline",
            -3 => "Idle",
            -3008 => "Session expired",
            -6023 or -6024 or -6033 => "P2P NAT negotiation failed",
            _ => $"Status {status}",
        };
    }
}
