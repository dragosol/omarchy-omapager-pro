#version 440

// Motion blur for a card leaving (see MotionTrack.qml / Smear.qml): the card's
// layer averaged over `count` copies stepped back along the last frame's
// movement, at most 2 device pixels apart. One pass, one draw - the same smear
// hyprdrive draws, without an item per copy.
//
// The effect is drawn over the card's rectangle grown by the movement
// (boxOrigin/boxSize, in the card's own pixels), so the trail can extend past
// the card. Output is premultiplied, as the layer is.
//
// Rebuild smear.frag.qsb after any change (qt6-shadertools):
//   /usr/lib/qt6/bin/qsb --glsl "100 es,120,150" --hlsl 50 --msl 12 \
//       -o shaders/smear.frag.qsb shaders/smear.frag

layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;

layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 boxOrigin;   // where the drawn rectangle starts, in card pixels
    vec2 boxSize;     // and how big it is
    vec2 itemSize;    // the card itself
    vec2 delta;       // the last frame's movement, in card pixels
    float count;      // copies, 1..32
};

layout(binding = 1) uniform sampler2D source;

void main() {
    vec2 p = boxOrigin + qt_TexCoord0 * boxSize;
    float n = max(count, 1.0);
    vec4 sum = vec4(0.0);
    for (int i = 0; i < 32; i++) {
        if (float(i) >= n) break;
        float back = n > 1.0 ? float(i) / (n - 1.0) : 0.0;
        vec2 uv = (p + delta * back) / itemSize;
        if (uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0)
            sum += texture(source, uv);
    }
    fragColor = (sum / n) * qt_Opacity;
}
