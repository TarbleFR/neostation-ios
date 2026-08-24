#version 460 core
#include <flutter/runtime_effect.glsl>

uniform vec2 uCanvasSize;
uniform vec2 uTextureSize;
uniform float uFit; // 0: fill, 1: contain, 2: cover
uniform sampler2D uTexture;
out vec4 fragColor;

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / uCanvasSize;
    
    if (uFit > 0.5) {
        float canvasAspect = uCanvasSize.x / uCanvasSize.y;
        float textureAspect = uTextureSize.x / uTextureSize.y;
        
        if (uFit < 1.5) { // contain
            if (canvasAspect > textureAspect) {
                float s = textureAspect / canvasAspect;
                uv.x = (uv.x - 0.5) / s + 0.5;
            } else {
                float s = canvasAspect / textureAspect;
                uv.y = (uv.y - 0.5) / s + 0.5;
            }
            if (uv.x < 0.0 || uv.x > 1.0 || uv.y < 0.0 || uv.y > 1.0) {
                fragColor = vec4(0.0, 0.0, 0.0, 0.0);
                return;
            }
        } else { // cover
            if (canvasAspect > textureAspect) {
                float s = canvasAspect / textureAspect;
                uv.y = (uv.y - 0.5) / s + 0.5;
            } else {
                float s = textureAspect / canvasAspect;
                uv.x = (uv.x - 0.5) / s + 0.5;
            }
        }
    }
    
    // Direct sampling from the current composed frame
    fragColor = texture(uTexture, uv);
}
