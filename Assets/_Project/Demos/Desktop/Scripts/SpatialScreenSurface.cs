using System;
using UnityEngine;

namespace CardboardXR.Demos.Desktop
{
    // A 3D virtual display quad with a RenderTexture, subtle bezel, collider, and cursor dot.
    public class SpatialScreenSurface : MonoBehaviour
    {
        GameObject m_Quad;
        GameObject m_Frame;
        BoxCollider m_Collider;
        Material m_ScreenMaterial;
        Material m_FrameMaterial;
        Material m_CursorMaterial;
        Transform m_CursorDot;
        RenderTexture m_Texture;
        bool m_FlipY;

        public GameObject ColliderObject => m_Quad;
        public RenderTexture Texture => m_Texture;
        public int PixelWidth { get; private set; }
        public int PixelHeight { get; private set; }
        public bool FlipY => m_FlipY;

        public event Action<Vector2> ClickedUv;

        public void Initialize(string label, int widthPx, int heightPx, Vector2 metersSize, Material templateMaterial)
        {
            PixelWidth = Mathf.Max(64, widthPx);
            PixelHeight = Mathf.Max(64, heightPx);

            m_Texture = new RenderTexture(PixelWidth, PixelHeight, 0, RenderTextureFormat.BGRA32)
            {
                name = $"{label} RT",
                filterMode = FilterMode.Bilinear,
                wrapMode = TextureWrapMode.Clamp,
            };
            m_Texture.Create();

            var shader = templateMaterial != null ? templateMaterial.shader : Shader.Find("Universal Render Pipeline/Unlit");
            m_ScreenMaterial = new Material(shader) { name = $"{label} Mat", color = Color.white };
            m_ScreenMaterial.mainTexture = m_Texture;
            ApplyFlip();

            m_FrameMaterial = new Material(shader) { name = $"{label} Frame", color = new Color(0.11f, 0.12f, 0.15f, 1f) };
            m_CursorMaterial = new Material(shader) { name = $"{label} Cursor", color = new Color(0.82f, 0.74f, 1f, 1f) };

            m_Frame = GameObject.CreatePrimitive(PrimitiveType.Quad);
            m_Frame.name = $"{label} Frame";
            Destroy(m_Frame.GetComponent<Collider>());
            m_Frame.transform.SetParent(transform, false);
            m_Frame.transform.localPosition = new Vector3(0f, 0f, 0.008f);
            m_Frame.transform.localScale = new Vector3(metersSize.x + 0.05f, metersSize.y + 0.05f, 1f);
            var frameRenderer = m_Frame.GetComponent<MeshRenderer>();
            frameRenderer.sharedMaterial = m_FrameMaterial;
            frameRenderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;

            m_Quad = GameObject.CreatePrimitive(PrimitiveType.Quad);
            m_Quad.name = $"{label} Surface";
            m_Quad.transform.SetParent(transform, false);
            m_Quad.transform.localScale = new Vector3(metersSize.x, metersSize.y, 1f);
            Destroy(m_Quad.GetComponent<MeshCollider>());
            m_Collider = m_Quad.AddComponent<BoxCollider>();
            m_Collider.size = new Vector3(1f, 1f, 0.02f);

            var quadRenderer = m_Quad.GetComponent<MeshRenderer>();
            quadRenderer.sharedMaterial = m_ScreenMaterial;
            quadRenderer.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;

            var dot = GameObject.CreatePrimitive(PrimitiveType.Sphere);
            dot.name = $"{label} Cursor";
            Destroy(dot.GetComponent<Collider>());
            dot.transform.SetParent(m_Quad.transform, false);
            dot.transform.localScale = new Vector3(0.012f / Mathf.Max(0.1f, metersSize.x), 0.012f / Mathf.Max(0.1f, metersSize.y), 0.004f);
            dot.GetComponent<MeshRenderer>().sharedMaterial = m_CursorMaterial;
            m_CursorDot = dot.transform;
            m_CursorDot.gameObject.SetActive(false);
        }

        public void SetVisible(bool visible) => gameObject.SetActive(visible);

        public void ToggleFlipY()
        {
            m_FlipY = !m_FlipY;
            ApplyFlip();
        }

        public bool TryRaycast(Ray ray, out Vector2 uv)
        {
            uv = Vector2.zero;
            if (!gameObject.activeInHierarchy || m_Collider == null)
                return false;

            if (!m_Collider.Raycast(ray, out var hit, 12f))
                return false;

            var localPoint = m_Quad.transform.InverseTransformPoint(hit.point);
            uv = SpatialScreenMath.LocalPointToUv(localPoint);
            if (m_FlipY)
                uv.y = 1f - uv.y;
            return true;
        }

        public void SetCursor(bool visible, Vector2 uv)
        {
            if (m_CursorDot == null)
                return;
            m_CursorDot.gameObject.SetActive(visible);
            if (!visible)
                return;

            var displayUv = m_FlipY ? new Vector2(uv.x, 1f - uv.y) : uv;
            m_CursorDot.localPosition = SpatialScreenMath.UvToLocalPoint(displayUv, -0.01f);
        }

        public void NotifyClick(Vector2 uv) => ClickedUv?.Invoke(uv);

        void ApplyFlip()
        {
            if (m_ScreenMaterial == null)
                return;
            m_ScreenMaterial.mainTextureScale = new Vector2(1f, m_FlipY ? -1f : 1f);
            m_ScreenMaterial.mainTextureOffset = new Vector2(0f, m_FlipY ? 1f : 0f);
        }

        void OnDestroy()
        {
            if (m_Texture != null)
            {
                m_Texture.Release();
                Destroy(m_Texture);
            }
            if (m_ScreenMaterial != null)
                Destroy(m_ScreenMaterial);
            if (m_FrameMaterial != null)
                Destroy(m_FrameMaterial);
            if (m_CursorMaterial != null)
                Destroy(m_CursorMaterial);
        }
    }
}
