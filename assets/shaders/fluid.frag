#version 460 core
precision highp float;

#include <flutter/runtime_effect.glsl>

uniform vec2 iResolution;
uniform float iTime;
uniform vec3 iCol4;

out vec4 fragColor;

// Optimized Value Noise (much cheaper than Gradient Noise)
float cheap_hash(vec2 p) {
    return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

float fast_noise(vec2 p) {
    vec2 i = floor(p);
    vec2 f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    
    float a = cheap_hash(i);
    float b = cheap_hash(i + vec2(1.0, 0.0));
    float c = cheap_hash(i + vec2(0.0, 1.0));
    float d = cheap_hash(i + vec2(1.0, 1.0));
    
    return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

mat2 Rot(float a) {
    float s = sin(a);
    float c = cos(a);
    return mat2(c, -s, s, c);
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / iResolution.xy;
    float invAspect = iResolution.y / iResolution.x;
    
    vec2 tuv = uv - 0.5;

    // Organic movement (Simplified noise)
    float degree = fast_noise(vec2(iTime * 0.05, tuv.x * tuv.y));
    
    tuv.y *= invAspect;
    // Optimized rotation calculation
    tuv *= Rot((degree - 0.5) * 12.566 + 3.14159); // 12.566 is 720 degrees in radians
    tuv.y *= iResolution.x / iResolution.y;

    // Simple wave warp
    float speed = iTime * 1.5;
    tuv.x += sin(tuv.y * 4.0 + speed) * 0.04;
    tuv.y += sin(tuv.x * 6.0 + speed) * 0.05;
    
    // --- Palette: Mixed (col4 is theme-based) ---
    const vec3 col1 = vec3(0.322, 0.208, 0.482); // #52357B
    const vec3 col2 = vec3(0.329, 0.349, 0.675); // #5459AC
    const vec3 col3 = vec3(0.392, 0.553, 0.702); // #648DB3
    vec3 col4 = iCol4; // Dynamic secondary color from theme
    
    // Optimized animation curve (Smoothstep instead of Pow)
    float cycle = sin(iTime * 0.4);
    float t = smoothstep(-1.0, 1.0, cycle);
    
    // Palette Mixing
    vec3 colorA = mix(col1, col3, t);
    vec3 colorB = mix(col2, col4, t);
    vec3 colorC = mix(col4, col1, t);
    vec3 colorD = mix(col3, col2, t);

    // Optimized blending (Fewer step/mix calls)
    vec2 rotTuv = tuv * Rot(-0.087266); // Rotated -5 degrees
    float maskX = smoothstep(-0.4, 0.3, rotTuv.x);
    
    vec3 layer1 = mix(colorA, colorB, maskX);
    vec3 layer2 = mix(colorC, colorD, maskX);
    
    vec3 finalColor = mix(layer1, layer2, smoothstep(0.6, -0.4, tuv.y));
    
    // --- Advanced Dithering (Optimized Triangle Noise) ---
    float r1 = fract(sin(dot(fragCoord, vec2(12.9898, 78.233))) * 43758.5453);
    float r2 = fract(sin(dot(fragCoord, vec2(78.233, 12.9898))) * 43758.5453);
    finalColor += (r1 + r2 - 1.0) * (1.0 / 22.0); 

    fragColor = vec4(finalColor, 1.0);  
}