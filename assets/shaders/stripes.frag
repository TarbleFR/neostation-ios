#version 460 core
#include <flutter/runtime_effect.glsl>

#define PI 3.14159265359

uniform vec2 uResolution;
uniform float uTime;
uniform float uTiles;
uniform float uDirection;
uniform float uWarpScale;
uniform float uWarpTiling;
uniform vec3 uColor1;
uniform vec3 uColor2;

out vec4 fragColor;

vec2 rotatePoint(vec2 pt, vec2 center, float angle) {
    float sinAngle = sin(angle);
    float cosAngle = cos(angle);
    pt -= center;
    vec2 r = vec2(
        pt.x * cosAngle - pt.y * sinAngle,
        pt.x * sinAngle + pt.y * cosAngle
    );
    r += center;
    return r;
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uResolution.xy;
    
    // Rotate the UV coordinates based on direction
    vec2 uv2 = rotatePoint(uv, vec2(0.5, 0.5), uDirection * 2.0 * PI);
    
    // Apply warp and movement
    uv2.x += sin(uv2.y * uWarpTiling * PI * 2.0) * uWarpScale + uTime;
    
    // Robust anti-aliased stripes using sine
    // This ensures smooth transitions regardless of wrap-around
    float aa = 0.05; // Smoothing amount
    float stripes = sin(uv2.x * uTiles * PI * 2.0);
    float st = smoothstep(-aa, aa, stripes);
    
    // Mix colors
    vec3 color = mix(uColor1, uColor2, st);
    
    fragColor = vec4(color, 1.0);
}
