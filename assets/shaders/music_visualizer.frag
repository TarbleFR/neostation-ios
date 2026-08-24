#version 460 core
precision mediump float;

#include <flutter/runtime_effect.glsl>

uniform vec2 iResolution;
uniform float iTime;
uniform float iVolume;
uniform vec4 iPrimaryColor;
uniform vec4 iSecondaryColor;
uniform vec4 iBackgroundColor;
uniform vec4 iTertiaryColor;
uniform float iIsPlaying;

// 31 Frequencies (starting at index 21)
uniform float iFreq0, iFreq1, iFreq2, iFreq3, iFreq4, iFreq5, iFreq6, iFreq7, iFreq8, iFreq9, iFreq10, iFreq11, iFreq12, iFreq13, iFreq14, iFreq15, iFreq16, iFreq17, iFreq18, iFreq19, iFreq20, iFreq21, iFreq22, iFreq23, iFreq24, iFreq25, iFreq26, iFreq27, iFreq28, iFreq29, iFreq30;
// 31 Peaks (starting at index 52)
uniform float iPeak0, iPeak1, iPeak2, iPeak3, iPeak4, iPeak5, iPeak6, iPeak7, iPeak8, iPeak9, iPeak10, iPeak11, iPeak12, iPeak13, iPeak14, iPeak15, iPeak16, iPeak17, iPeak18, iPeak19, iPeak20, iPeak21, iPeak22, iPeak23, iPeak24, iPeak25, iPeak26, iPeak27, iPeak28, iPeak29, iPeak30;

out vec4 fragColor;

float getFreq(int idx) {
    if (idx < 16) {
        if (idx < 8) {
            if (idx == 0) return iFreq0; if (idx == 1) return iFreq1; if (idx == 2) return iFreq2; if (idx == 3) return iFreq3;
            if (idx == 4) return iFreq4; if (idx == 5) return iFreq5; if (idx == 6) return iFreq6; return iFreq7;
        } else {
            if (idx == 8) return iFreq8; if (idx == 9) return iFreq9; if (idx == 10) return iFreq10; if (idx == 11) return iFreq11;
            if (idx == 12) return iFreq12; if (idx == 13) return iFreq13; if (idx == 14) return iFreq14; return iFreq15;
        }
    } else {
        if (idx < 24) {
            if (idx == 16) return iFreq16; if (idx == 17) return iFreq17; if (idx == 18) return iFreq18; if (idx == 19) return iFreq19;
            if (idx == 20) return iFreq20; if (idx == 21) return iFreq21; if (idx == 22) return iFreq22; return iFreq23;
        } else {
            if (idx == 24) return iFreq24; if (idx == 25) return iFreq25; if (idx == 26) return iFreq26; if (idx == 27) return iFreq27;
            if (idx == 28) return iFreq28; if (idx == 29) return iFreq29; return iFreq30;
        }
    }
}

float getPeak(int idx) {
    if (idx < 16) {
        if (idx < 8) {
            if (idx == 0) return iPeak0; if (idx == 1) return iPeak1; if (idx == 2) return iPeak2; if (idx == 3) return iPeak3;
            if (idx == 4) return iPeak4; if (idx == 5) return iPeak5; if (idx == 6) return iPeak6; return iPeak7;
        } else {
            if (idx == 8) return iPeak8; if (idx == 9) return iPeak9; if (idx == 10) return iPeak10; if (idx == 11) return iPeak11;
            if (idx == 12) return iPeak12; if (idx == 13) return iPeak13; if (idx == 14) return iPeak14; return iPeak15;
        }
    } else {
        if (idx < 24) {
            if (idx == 16) return iPeak16; if (idx == 17) return iPeak17; if (idx == 18) return iPeak18; if (idx == 19) return iPeak19;
            if (idx == 20) return iPeak20; if (idx == 21) return iPeak21; if (idx == 22) return iPeak22; return iPeak23;
        } else {
            if (idx == 24) return iPeak24; if (idx == 25) return iPeak25; if (idx == 26) return iPeak26; if (idx == 27) return iPeak27;
            if (idx == 28) return iPeak28; if (idx == 29) return iPeak29; return iPeak30;
        }
    }
}

void main() {
    vec2 fragCoord = FlutterFragCoord().xy;
    vec2 uv = fragCoord / iResolution.xy;
    
    // Centered and mirrored Y coordination (0.0 at center, 1.0 at top/bottom)
    float mirroredY = abs(uv.y - 0.5) * 2.0;
    
    vec3 col = iBackgroundColor.rgb;
    
    const float totalBands = 31.0;
    float barWidth = 1.0 / totalBands;
    
    float barIdx = floor(uv.x * totalBands);
    float barCenter = (barIdx + 0.5) * barWidth;
    int freqIdx = int(barIdx);
    
    float f = getFreq(freqIdx) * iIsPlaying;
    float peak = getPeak(freqIdx) * iIsPlaying;
    
    // Minimal height when playing
    if (iIsPlaying > 0.5 && f < 0.02) f = 0.02;
    
    // Segmented LED look (symmetric)
    float segments = 26.0;
    float segmentY = floor(mirroredY * segments) / segments;
    float isGap = step(0.4, fract(mirroredY * segments));
    
    float barX = abs(uv.x - barCenter);
    // Slightly narrower bars for better separation look
    bool inBar = barX < barWidth * 0.38 && mirroredY < f;
    
    float alpha = iBackgroundColor.a;
    
    if (inBar && isGap > 0.5) {
        // Use primary and secondary color gradient from center outwards
        col = mix(iPrimaryColor.rgb, iSecondaryColor.rgb, segmentY);
        alpha = mix(iPrimaryColor.a, iSecondaryColor.a, segmentY);
    }
    
    // Falling peak indicator (reflected)
    float peakDist = abs(mirroredY - peak);
    if (peakDist < 0.005 && barX < barWidth * 0.4 && peak > 0.02) {
        col = iTertiaryColor.rgb;
        alpha = iTertiaryColor.a;
    }

    fragColor = vec4(col, alpha);
}
