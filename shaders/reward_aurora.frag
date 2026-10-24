#version 460 core
// 奖品卡「流光」（page/festival/reward_kit.dart 的 RewardSurface；第一轮流光方向的卡，用户认可后作为奖品卡的样子）：
// 一块近黑的玻璃卡，卡头铺着缓慢流动的网格渐变（四团颜色取自种子色与它两侧相邻的色相，各自绕慢圈，位置先经噪声扭一下；同 Stripe、Linear 的 mesh gradient），
// 往下渐渐暗进卡身，留暗给文字；静态颗粒；左上一道很淡的斜向反光（随倾斜挪一点）；边上一道发丝亮线（几种颜色沿周长慢慢流，左上角带一点白色高光），
// 外面一层近光、一层远光，光从边上渗进玻璃一点。不用模糊滤镜：光晕都是到边缘距离的指数衰减。
// uMorph 是显现：卡形从中间一团光长出来（有向距离场从圆插值到圆角方），长的时候卡更亮、边更亮，长全时落回平时。坐标是画布的逻辑像素，输出是预乘颜色。
#include <flutter/runtime_effect.glsl>

precision highp float;

uniform vec2 uSize;
uniform vec4 uRect;
uniform float uRadius;
uniform float uTime;
uniform float uMorph;
uniform float uHeader;
uniform vec2 uTilt;
uniform vec3 uC0;
uniform vec3 uC1;
uniform vec3 uC2;
uniform vec3 uC3;
uniform vec3 uBody;

out vec4 fragColor;

float hash(vec2 p) {
  p = fract(p * vec2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float noise(vec2 p) {
  vec2 i = floor(p), f = fract(p);
  f = f * f * (3.0 - 2.0 * f);
  return mix(mix(hash(i), hash(i + vec2(1.0, 0.0)), f.x), mix(hash(i + vec2(0.0, 1.0)), hash(i + vec2(1.0, 1.0)), f.x), f.y);
}

float roundedBox(vec2 p, vec2 half_, float radius) {
  vec2 q = abs(p) - half_ + radius;
  return length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - radius;
}

// 卡的形（相对卡中心的坐标）：显现时从一团光长成卡。
float shape(vec2 o, vec2 half_) {
  float card = roundedBox(o, half_, uRadius);
  if (uMorph >= 1.0) return card;
  float form = smoothstep(0.25, 0.95, uMorph);
  float r = max(half_.x, half_.y) * smoothstep(0.0, 0.7, uMorph) * 0.92;
  return mix(length(o * vec2(1.0, half_.x / half_.y * 0.85 + 0.15)) - r, card, form);
}

// 四个颜色围成一圈，t 走一圈回到起点；权重取 cos 的三次方，颜色之间过渡柔和、每个颜色都有停留。
vec3 palette(float t) {
  vec4 w = pow(0.5 + 0.5 * cos(6.28318 * (t - vec4(0.0, 0.25, 0.5, 0.75))), vec4(3.0));
  return (uC0 * w.x + uC1 * w.y + uC2 * w.z + uC3 * w.w) / (w.x + w.y + w.z + w.w);
}

// 网格渐变：四团颜色各自绕慢圈，位置先经噪声扭一下（流体感）。
vec3 mesh(vec2 uv, float aspect, float t) {
  vec2 q = uv + 0.14 * (vec2(noise(uv * 2.2 + t * 0.12), noise(uv * 2.2 - t * 0.1 + 4.0)) - 0.5) + uTilt * 0.06;
  vec2 b0 = vec2(0.22 + 0.16 * sin(t * 0.31), 0.18 + 0.12 * cos(t * 0.27));
  vec2 b1 = vec2(0.80 + 0.12 * cos(t * 0.23), 0.30 + 0.16 * sin(t * 0.35));
  vec2 b2 = vec2(0.70 + 0.16 * sin(t * 0.19 + 1.0), 0.82 + 0.10 * cos(t * 0.29));
  vec2 b3 = vec2(0.20 + 0.12 * cos(t * 0.33 + 2.0), 0.72 + 0.14 * sin(t * 0.21));
  vec2 s = vec2(1.0, aspect);
  vec4 w = vec4(
    exp(-dot((q - b0) * s, (q - b0) * s) * 5.0),
    exp(-dot((q - b1) * s, (q - b1) * s) * 5.0),
    exp(-dot((q - b2) * s, (q - b2) * s) * 5.0),
    exp(-dot((q - b3) * s, (q - b3) * s) * 5.0));
  float total = w.x + w.y + w.z + w.w + 0.02;
  return (uC0 * w.x + uC1 * w.y + uC2 * w.z + uC3 * w.w) / total;
}

void main() {
  vec2 p = FlutterFragCoord().xy;
  vec2 half_ = uRect.zw * 0.5;
  vec2 offset = p - (uRect.xy + half_);
  if (uMorph <= 0.0) {
    fragColor = vec4(0.0);
    return;
  }
  float d = shape(offset, half_);
  float energy = 1.0 - smoothstep(0.55, 1.0, uMorph);
  // 沿周长的位置（按长宽归一后的角度，长边上走得不至于太快），颜色与光斑都沿它流。
  float around = atan(offset.y / half_.y, offset.x / half_.x) / 6.28318;
  vec3 edge = palette(around + uTime * (0.05 + 0.4 * energy));
  float streak = 0.5 + 0.5 * pow(0.5 + 0.5 * sin(6.28318 * (around * 2.0 - uTime * (0.16 + 0.7 * energy))), 3.0);

  vec4 color = vec4(0.0);
  float inside = 1.0 - smoothstep(-0.75, 0.75, d);
  if (d < 1.0) {
    vec2 uv = (p - uRect.xy) / uRect.zw;
    vec3 field = mesh(uv, uRect.w / uRect.z, uTime);
    // 光铺在卡头，往下渐渐暗进卡身。
    float card = (1.0 - smoothstep(0.0, uHeader * 1.5, p.y - uRect.y)) * 0.5 + 0.04;
    vec3 body = uBody + field * card * (1.0 + 0.9 * energy);
    // 边上的光渗进玻璃一点。
    body += edge * exp(d / 11.0) * (0.3 + 0.7 * energy) * streak;
    // 玻璃的反光：左上一道很淡的斜向高光（随倾斜挪一点），让它读起来是一块玻璃、不是一块色板。
    float gloss = exp(-pow((uv.x * 0.6 + uv.y - 0.3 - uTilt.x * 0.08) / 0.11, 2.0)) * (1.0 - uv.y) * 0.075;
    body += vec3(gloss);
    body += (hash(floor(p * 1.5)) - 0.5) * 0.03;
    body += (hash(p.yx * 1.37 + uSize * 0.001) - 0.5) / 255.0;
    color = vec4(body, 1.0) * inside;
  }

  // 边：一道发丝亮线（左上角带白色高光），外面一层近光、一层远光。
  float rim = exp(-abs(d) / 0.85);
  float spec = pow(max(0.0, dot(normalize(offset + 0.001), normalize(vec2(-0.5, -0.86)))), 8.0);
  vec3 rimColor = mix(edge * (0.85 + 0.6 * streak), vec3(1.0), 0.15 + 0.5 * spec);
  float outward = max(d, 0.0);
  float bloom = (exp(-outward / 5.0) * 0.32 + exp(-outward / (16.0 + 32.0 * energy)) * 0.22) * streak * step(0.0, d);
  color.rgb += rimColor * rim * (0.62 + 0.8 * energy) + edge * bloom;
  color.a = clamp(color.a + rim * 0.6 + bloom * 0.6, 0.0, 1.0);
  fragColor = color;
}
