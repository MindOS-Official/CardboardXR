using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    // Pure coordinate transforms between 3D screen quad local space, Unity UVs, and top-left pixel space.
    public static class SpatialScreenMath
    {
        public static Vector2 LocalPointToUv(Vector3 localPoint)
        {
            var u = Mathf.Clamp01(localPoint.x + 0.5f);
            var v = Mathf.Clamp01(localPoint.y + 0.5f);
            return new Vector2(u, v);
        }

        public static Vector2 UvToTopLeftNormalized(Vector2 uv)
        {
            return new Vector2(Mathf.Clamp01(uv.x), Mathf.Clamp01(1f - uv.y));
        }

        public static Vector2Int UvToTopLeftPixel(Vector2 uv, int width, int height)
        {
            var w = Mathf.Max(1, width);
            var h = Mathf.Max(1, height);
            var norm = UvToTopLeftNormalized(uv);
            var px = Mathf.Clamp(Mathf.RoundToInt(norm.x * (w - 1)), 0, w - 1);
            var py = Mathf.Clamp(Mathf.RoundToInt(norm.y * (h - 1)), 0, h - 1);
            return new Vector2Int(px, py);
        }

        public static Vector3 UvToLocalPoint(Vector2 uv, float zOffset = -0.005f)
        {
            return new Vector3(Mathf.Clamp01(uv.x) - 0.5f, Mathf.Clamp01(uv.y) - 0.5f, zOffset);
        }
    }
}
