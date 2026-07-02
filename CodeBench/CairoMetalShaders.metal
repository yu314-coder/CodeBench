//
// fill.metal  --  CairoMetal stencil-then-cover FILL shaders
// ============================================================================
//
// This file contains the Metal shader functions used by the stencil-then-cover
// fill (and, because strokes are expanded to fillable polygons CPU-side, by
// strokes too).  The render-pipeline-state and depth-stencil-state objects that
// *use* these functions are built ONCE in cm_device.m and fetched O(1) by
// cm_fill.m via cm_device_pipeline()/cm_device_depthstencil(); this file only
// declares the programmable stages.
//
// ----------------------------------------------------------------------------
// SHADER-NAME CONTRACT  (cm_device.m must reference these exact names)
// ----------------------------------------------------------------------------
//   cm_pipe_id                  vertex function        fragment function
//   --------------------------  ---------------------  -----------------------
//   CM_PIPE_STENCIL_NONZERO     cm_vs_stencil          cm_fs_stencil
//   CM_PIPE_STENCIL_EVENODD     cm_vs_stencil          cm_fs_stencil
//   CM_PIPE_COVER_SOLID         cm_vs_cover            cm_fs_cover_solid
//   CM_PIPE_COVER_LINEAR        cm_vs_cover            cm_fs_cover_linear
//
// The NONZERO vs EVENODD difference is ENTIRELY in the MTLDepthStencilState
// (incr/decr-wrap two-sided vs invert) — the programmable stages are identical,
// so both stencil pipelines share cm_vs_stencil + cm_fs_stencil.  Likewise the
// "test stencil then zero it" of the cover pass lives in the cover
// MTLDepthStencilState, not here.
//
// ----------------------------------------------------------------------------
// BUFFER / TEXTURE BINDING CONTRACT  (cm_fill.m must bind to these indices)
// ----------------------------------------------------------------------------
//   buffer(0)  : device const cm_vec2f*  vertices   (DEVICE-space px positions)
//   buffer(1)  : constant cm_uniforms&   uniforms   (per-draw)
//   texture(0) : 256x1 BGRA8 gradient LUT           (CM_PIPE_COVER_LINEAR only)
//
// The LUT sampler is a `constexpr sampler` declared in this file (linear / clamp
// to edge), so cm_fill.m binds NO MTLSamplerState — avoiding a per-draw or
// cached sampler object entirely.
//
// Vertices are indexed directly by vertex_id (NO MTLVertexDescriptor / stage_in)
// so cm_device.m needs no vertex layout — keeping the only cross-file coupling
// the function names above.  These binding indices are mirrored as #defines in
// cm_fill.m (CM_BUF_VERTS / CM_BUF_UNIFORMS / CM_TEX_GRAD_LUT).
//
// ----------------------------------------------------------------------------
// COORDINATE / PIXEL CONTRACT
// ----------------------------------------------------------------------------
// * The CTM is applied on the CPU at flatten time, so vertex positions arrive
//   already in DEVICE pixels.  The vertex stage only maps device px -> Metal
//   clip space via the `to_clip` uniform (which already encodes the y-flip:
//   to_clip = (2/W, -2/H, -1, +1)).  ctm_row0/row1 are carried for completeness
//   but the shipping path does not re-transform on the GPU.
// * Colour is premultiplied on OUTPUT here (rgb *= a) to match cairo's
//   premultiplied ARGB32 surface; cm_device.m configures the colour attachment
//   for PREMULTIPLIED OVER blending (srcRGB=One, dstRGB=OneMinusSrcAlpha,
//   srcA=One, dstA=OneMinusSrcAlpha).
// * No colour byte re-swap: manim pre-swaps to B,G,R,A, the LUT is baked B,G,R,A,
//   and the BGRA8Unorm target has the matching layout, so components pass
//   through unchanged.
// * Anti-aliasing is 4x MSAA on the colour+stencil attachments (configured in
//   the pipeline sampleCount + the render pass), so these stages are written
//   per-fragment and need no analytic coverage.
//
// MUST stay binary-compatible with the C structs in src/cm_internal.h:
//   cm_vec2f  { float x, y; }
//   cm_rgba   { float r, g, b, a; }
//   cm_uniforms { float ctm_row0[4]; float ctm_row1[4]; float to_clip[4];
//                 int paint_kind; float grad_axis[4]; cm_rgba solid; }
// ============================================================================

#include <metal_stdlib>
using namespace metal;

// paint_kind values (mirror cm_paint_kind in cm_internal.h): SOLID=0, LINEAR=1.
// The shader does NOT branch on paint_kind — the SOLID vs LINEAR choice is made
// by selecting cm_fs_cover_solid vs cm_fs_cover_linear via the pipeline state in
// cm_fill.m — so these values are documented here but not declared as constants.

// ---------------------------------------------------------------------------
// Shared POD types — MUST match cm_internal.h field-for-field.
// ---------------------------------------------------------------------------

/** Device-space (post-CTM) 2D position. Mirrors cm_vec2f. */
struct cm_vec2f {
    float x;
    float y;
};

/** RGBA float colour, stored NON-premultiplied. Mirrors cm_rgba. */
struct cm_rgba {
    float r;
    float g;
    float b;
    float a;
};

/**
 * Per-draw uniforms. Mirrors cm_uniforms in cm_internal.h.
 * Arrays are float[4] (not packed_float4) to match the C layout exactly:
 *   ctm_row0 = (xx, xy, x0, _)   ctm_row1 = (yx, yy, y0, _)
 *   to_clip  = (sx, sy, tx, ty)  ->  clip.xy = pos.xy * (sx,sy) + (tx,ty)
 *   grad_axis= (ax, ay, bx, by)  device-space gradient endpoints A->B
 */
struct cm_uniforms {
    float   ctm_row0[4];
    float   ctm_row1[4];
    float   to_clip[4];
    int     paint_kind;
    float   grad_axis[4];
    cm_rgba solid;
};

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/** Map a device-pixel position to Metal clip space using to_clip (y already
 *  flipped via a negative sy). z=0, w=1 for 2D. */
static inline float4 cm_to_clip(float2 device_px, constant cm_uniforms &u) {
    float2 s = float2(u.to_clip[0], u.to_clip[1]);   // (sx, sy)
    float2 t = float2(u.to_clip[2], u.to_clip[3]);   // (tx, ty)
    return float4(device_px * s + t, 0.0, 1.0);
}

// ===========================================================================
// PASS 1 — STENCIL  (write winding/parity into stencil, NO colour)
// ===========================================================================
//
// Used by CM_PIPE_STENCIL_NONZERO and CM_PIPE_STENCIL_EVENODD.  The pipeline's
// colour write mask is set to none in cm_device.m, so the fragment output is
// discarded; only the stencil op (incr/decr-wrap or invert) takes effect.
// Triangle fans for each contour are drawn here; overlap + the stencil op yield
// correct coverage for holes and self-intersection without CPU triangulation.

vertex float4
cm_vs_stencil(uint                       vid      [[vertex_id]],
              device const cm_vec2f     *verts    [[buffer(0)]],
              constant cm_uniforms      &u        [[buffer(1)]])
{
    cm_vec2f p = verts[vid];
    return cm_to_clip(float2(p.x, p.y), u);
}

// Colour is masked off by the pipeline; emit a trivial value.  Declared with
// [[color(0)]] so the function is a valid fragment stage for an attachment that
// exists (with a zero write-mask) in the stencil pipeline.
fragment float4
cm_fs_stencil(void)
{
    return float4(0.0);
}

// ===========================================================================
// PASS 2 — COVER  (test stencil, write paint; stencil self-resets to 0)
// ===========================================================================
//
// Draw the path's device-space bounding quad.  The cover MTLDepthStencilState
// tests the stencil (!=0 for nonzero, &1 for even-odd via readMask) and zeroes
// the touched samples in the SAME op, so no separate per-path stencil clear is
// needed when many paths batch into one command buffer.  MSAA resolves the
// antialiased edge from the per-sample stencil coverage.

struct CoverInOut {
    float4 position [[position]];   // clip space
    float2 dev;                     // device-space px, for gradient projection
};

vertex CoverInOut
cm_vs_cover(uint                    vid    [[vertex_id]],
            device const cm_vec2f  *verts  [[buffer(0)]],
            constant cm_uniforms   &u      [[buffer(1)]])
{
    cm_vec2f p = verts[vid];
    CoverInOut out;
    out.dev      = float2(p.x, p.y);
    out.position = cm_to_clip(out.dev, u);
    return out;
}

// ---- solid cover -----------------------------------------------------------
// Output the uniform solid colour, PREMULTIPLIED (rgb *= a) for premultiplied
// OVER blending.  Components are already in B,G,R,A order (no re-swap).
fragment float4
cm_fs_cover_solid(CoverInOut            in [[stage_in]],
                  constant cm_uniforms &u  [[buffer(1)]])
{
    float4 c = float4(u.solid.r, u.solid.g, u.solid.b, u.solid.a);
    c.rgb *= c.a;                    // premultiply
    return c;
}

// ---- linear-gradient cover -------------------------------------------------
// Project the fragment's device position onto the gradient axis A->B:
//   t = clamp( dot(p - A, B - A) / |B - A|^2 , 0, 1 )
// then sample the baked 256x1 BGRA8 LUT at t and premultiply.  The LUT is
// produced by cm_paint_gradient_lut() with the same B,G,R,A convention, so no
// re-swap; the LUT stores NON-premultiplied colour and we premultiply here so
// the blend math matches the solid path exactly.
fragment float4
cm_fs_cover_linear(CoverInOut             in       [[stage_in]],
                   constant cm_uniforms  &u        [[buffer(1)]],
                   texture2d<float>       lut      [[texture(0)]])
{
    constexpr sampler lutsamp(filter::linear,
                              mip_filter::none,
                              address::clamp_to_edge);

    float2 A = float2(u.grad_axis[0], u.grad_axis[1]);
    float2 B = float2(u.grad_axis[2], u.grad_axis[3]);
    float2 ab = B - A;
    float  denom = dot(ab, ab);

    // Degenerate axis (A == B): cairo paints the last stop everywhere; sampling
    // at t=1 (right edge of the clamped LUT) reproduces that.
    float t = (denom > 0.0) ? clamp(dot(in.dev - A, ab) / denom, 0.0, 1.0) : 1.0;

    // 1D LUT laid out along x; sample at the texel centre row (v = 0.5).
    float4 c = lut.sample(lutsamp, float2(t, 0.5));
    c.rgb *= c.a;                    // premultiply
    return c;
}
