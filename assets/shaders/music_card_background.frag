#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uSize;
uniform float uTime;
uniform vec4 uTint;
uniform vec2 uCoverSize;
uniform vec2 uDiskSize;
uniform sampler2D uCover;
uniform sampler2D uDisk;

out vec4 fragColor;

vec2 rotate2d(vec2 p, float a) {
    float s = sin(a);
    float c = cos(a);
    return vec2(p.x * c - p.y * s, p.x * s + p.y * c);
}

vec2 containUv(vec2 localUv, vec2 boxSize, vec2 texSize) {
    float boxAspect = boxSize.x / max(boxSize.y, 0.0001);
    float texAspect = texSize.x / max(texSize.y, 0.0001);

    if (texAspect > boxAspect) {
        float usedHeight = boxAspect / texAspect;
        float y = (localUv.y - (1.0 - usedHeight) * 0.5) / max(usedHeight, 0.0001);
        return vec2(localUv.x, y);
    }

    float usedWidth = texAspect / boxAspect;
    float x = (localUv.x - (1.0 - usedWidth) * 0.5) / max(usedWidth, 0.0001);
    return vec2(x, localUv.y);
}

vec2 coverUv(vec2 localUv, vec2 boxSize, vec2 texSize) {
    float boxAspect = boxSize.x / max(boxSize.y, 0.0001);
    float texAspect = texSize.x / max(texSize.y, 0.0001);

    if (texAspect > boxAspect) {
        float usedWidth = boxAspect / texAspect;
        float x = (localUv.x - (1.0 - usedWidth) * 0.5) / max(usedWidth, 0.0001);
        return vec2(x, localUv.y);
    }

    float usedHeight = texAspect / boxAspect;
    float y = (localUv.y - (1.0 - usedHeight) * 0.5) / max(usedHeight, 0.0001);
    return vec2(localUv.x, y);
}

vec4 sampleContainDisk(vec2 localUv, vec2 boxSize, vec2 texSize) {
    vec2 uv = containUv(localUv, boxSize, texSize);
    float valid = step(0.0, uv.x) * step(0.0, uv.y) * step(uv.x, 1.0) * step(uv.y, 1.0);
    return texture(uDisk, clamp(uv, vec2(0.0), vec2(1.0))) * valid;
}

void main() {
    vec2 fragPx = FlutterFragCoord().xy;
    vec2 uv = fragPx / uSize;

    // Cover as full-card background (cover fit, no stretching).
    vec2 bgUv = coverUv(uv, vec2(1.0, 1.0), uCoverSize);
    vec3 bgColor = texture(uCover, clamp(bgUv, vec2(0.0), vec2(1.0))).rgb;

    // Disk moved down: only top half visible from the bottom edge.
    vec2 diskCenter = vec2(0.5, 0.65) * uSize;
    float diskRadius = uSize.y * 0.35;
    vec2 diskUv = (fragPx - diskCenter) / max(diskRadius, 0.0001);
    float edge = 2.0 / max(diskRadius, 1.0);
    float diskCircle = 1.0 - smoothstep(1.0, 1.0 + edge, length(diskUv));
    vec2 rotated = rotate2d(diskUv, -uTime * 6.2) * 0.5 + vec2(0.5);
    vec4 disk = sampleContainDisk(rotated, vec2(1.0, 1.0), uDiskSize);

    float diskAlpha = disk.a * diskCircle;
    vec3 diskColor = mix(disk.rgb, disk.rgb * uTint.rgb, 0.12);
    vec3 finalColor = mix(bgColor, diskColor, diskAlpha);

    fragColor = vec4(finalColor, 1.0);
}
