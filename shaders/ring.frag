#version 440

// A card's border (see Ring.qml): the band between the card's rounded
// rectangle and the same rectangle inset by each side's width, coloured along
// the theme's gradient. Measured as a distance from both edges, so it comes
// out one even line at any width and any display scale - the shell's
// vector ring, drawn in pieces, laid a 1 px border on twice where the pieces
// met.
//
// Output is premultiplied.
//
// Rebuild ring.frag.qsb after any change (qt6-shadertools):
//   /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 \
//       -o shaders/ring.frag.qsb shaders/ring.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 size;        // the card, in its own pixels
    vec4 widths;      // top, right, bottom, left
    float radius;     // the outer corners
    vec2 from;        // gradient endpoints, in card pixels
    vec2 to;
    vec4 c0;          // up to four stops, evenly spaced, not premultiplied
    vec4 c1;
    vec4 c2;
    vec4 c3;
    float stops;      // how many of them are used, 1..4
};

// Signed distance to a rounded box centred on the origin, with a radius per
// corner (x: top-right, y: bottom-right, z: bottom-left, w: top-left).
float roundBox(vec2 p, vec2 extent, vec4 r) {
    float k = p.x > 0.0 ? (p.y > 0.0 ? r.y : r.x) : (p.y > 0.0 ? r.z : r.w);
    vec2 q = abs(p) - extent + k;
    return min(max(q.x, q.y), 0.0) + length(max(q, 0.0)) - k;
}

vec4 stopColor(float t) {
    if (stops < 1.5) return c0;
    float x = t * (stops - 1.0);
    if (x < 1.0) return mix(c0, c1, x);
    if (stops < 2.5 || x < 2.0) return mix(c1, c2, clamp(x - 1.0, 0.0, 1.0));
    return mix(c2, c3, clamp(x - 2.0, 0.0, 1.0));
}

void main() {
    vec2 p = qt_TexCoord0 * size;
    float R = min(radius, 0.5 * min(size.x, size.y));
    float outer = roundBox(p - 0.5 * size, 0.5 * size, vec4(R));

    // The inner edge: inset by each side, its corners rounded by what is left
    // of the outer radius past the wider of the two sides meeting there.
    vec2 lo = vec2(widths.w, widths.x);
    vec2 hi = size - vec2(widths.y, widths.z);
    vec2 ihalf = max(0.5 * (hi - lo), vec2(0.0));
    vec4 ir = max(vec4(R) - vec4(max(widths.x, widths.y), max(widths.y, widths.z),
                                 max(widths.z, widths.w), max(widths.w, widths.x)), 0.0);
    float inner = roundBox(p - 0.5 * (lo + hi), ihalf, ir);

    // One screen pixel of antialiasing, whatever the scale.
    float aa = max(fwidth(outer), 1e-4);
    float cover = clamp(0.5 - outer / aa, 0.0, 1.0) * clamp(0.5 + inner / aa, 0.0, 1.0);

    vec2 axis = to - from;
    float t = clamp(dot(p - from, axis) / max(dot(axis, axis), 1e-4), 0.0, 1.0);
    vec4 c = stopColor(t);
    fragColor = vec4(c.rgb * c.a, c.a) * cover * qt_Opacity;
}
