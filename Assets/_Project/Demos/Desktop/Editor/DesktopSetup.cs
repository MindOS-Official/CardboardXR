using CardboardXR.Demos;
using CardboardXR.Demos.Desktop;
using UnityEditor;
using UnityEngine;

namespace ProjectBootstrap
{
    // Spatial Desktop: Parsec remote PC stream, WebKit browser monitor, and 3D Air Keyboard.
    class DesktopSetup : DemoSetup
    {
        public override string Name => "Desktop";
        public override int Order => 60;

        public override DemoCatalog.Entry Entry => new()
        {
            Id = "desktop",
            Title = "Desktop",
            Description = "Stream your Windows or Mac desktop over Parsec alongside a WebKit browser and 3D Air Keyboard.",
            Tagline = "Remote PC with Parsec, WebKit browser, and air keyboard",
            Icon = "desktop_windows",
            Tint = new Color(0.20f, 0.45f, 0.72f),
            Requirements = new DemoRequirements { SixDof = Need.On, Passthrough = Need.On, Hands = Need.On },
        };

        public override void BuildScene(string folder)
        {
            var environment = DemoAssets.Environment();
            var grid = StereoBuilder.SaveAsset(DemoAssets.CreateGridTexture(), $"{folder}/Grid.asset");
            var floorMat = StereoBuilder.CreateMaterial("Desktop Floor", DemoAssets.Unlit, new Color(0.75f, 0.85f, 1f),
                grid, DemoAssets.RoomSize / 1f, folder);
            DemoAssets.Floor(environment.transform, floorMat, DemoAssets.RoomSize);

            var screenMaterial = StereoBuilder.CreateMaterial("Desktop Screen", DemoAssets.Unlit, Color.white, null, 1f, folder);

            var demo = new GameObject("Desktop Demo").AddComponent<DesktopDemo>();
            var serialized = new SerializedObject(demo);
            serialized.FindProperty("m_ScreenMaterial").objectReferenceValue = screenMaterial;
            serialized.ApplyModifiedPropertiesWithoutUndo();
        }
    }
}
