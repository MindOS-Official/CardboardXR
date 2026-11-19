#if UNITY_IOS
using System.IO;
using UnityEditor;
using UnityEditor.Callbacks;
using UnityEditor.iOS.Xcode;
using UnityEditor.iOS.Xcode.Extensions;
using UnityEngine;

namespace ProjectBootstrap
{
    // Links iOS frameworks required by ParsecSDK and WKWebView and embeds ParsecSDK.framework into the app bundle.
    public static class IosNativeBuildPostprocessor
    {
        [PostProcessBuild(100)]
        public static void OnPostprocessBuild(BuildTarget target, string pathToBuiltProject)
        {
            if (target != BuildTarget.iOS)
                return;

            var pbxPath = PBXProject.GetPBXProjectPath(pathToBuiltProject);
            if (!File.Exists(pbxPath))
                return;

            var pbx = new PBXProject();
            pbx.ReadFromFile(pbxPath);

            var mainTarget = pbx.GetUnityMainTargetGuid();
            var frameworkTarget = pbx.GetUnityFrameworkTargetGuid();

            string[] systemFrameworks =
            {
                "WebKit.framework",
                "AudioToolbox.framework",
                "Metal.framework",
                "MetalKit.framework",
                "Security.framework",
                "CoreGraphics.framework",
            };

            foreach (var framework in systemFrameworks)
                pbx.AddFrameworkToProject(frameworkTarget, framework, false);

            var parsecRelPath = "Frameworks/Plugins/iOS/ParsecSDK.framework";
            if (!Directory.Exists(Path.Combine(pathToBuiltProject, parsecRelPath)))
                parsecRelPath = "Frameworks/ParsecSDK.framework";

            var parsecGuid = pbx.FindFileGuidByProjectPath(parsecRelPath);
            if (!string.IsNullOrEmpty(parsecGuid))
            {
                pbx.AddFileToEmbedFrameworks(mainTarget, parsecGuid);
                pbx.AddBuildProperty(mainTarget, "LD_RUNPATH_SEARCH_PATHS", "@executable_path/Frameworks");
            }
            else
            {
                Debug.LogWarning("[IosNativeBuildPostprocessor] ParsecSDK.framework not found in Xcode project; verify PluginImporter embed flag.");
            }

            pbx.AddBuildProperty(frameworkTarget, "LD_RUNPATH_SEARCH_PATHS", "@executable_path/Frameworks");
            pbx.WriteToFile(pbxPath);
        }
    }
}
#endif
