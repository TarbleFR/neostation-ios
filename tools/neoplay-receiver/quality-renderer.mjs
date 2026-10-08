// Optional GPU display sharpening. Never modifies the original H.264/PCM packets,
// decoding timestamps or the trusted 2D canvas renderer.
export const QUALITY_PRESETS = Object.freeze({
  original: Object.freeze({ strength: 0, label: 'original' }),
  enhanced: Object.freeze({ strength: 0.28, label: 'enhanced' }),
  crisp: Object.freeze({ strength: 0.47, label: 'crisp' }),
});

export function qualityPreset(value) {
  return Object.hasOwn(QUALITY_PRESETS, value) ? value : 'enhanced';
}
export function qualityScale(sourceWidth, sourceHeight, stageWidth, dpr = 1, stageHeight = Infinity) {
  if (![sourceWidth, sourceHeight].every(v => Number.isFinite(v) && v > 0)) return {width:2,height:2};
  const source = Math.max(2, Math.floor(sourceWidth));
  const density = Number.isFinite(dpr) ? Math.min(2, Math.max(1, dpr)) : 1;
  const fitted = Number.isFinite(stageHeight) && stageHeight > 0 ? Math.min(stageWidth, stageHeight * sourceWidth / sourceHeight) : stageWidth;
  const demand = Number.isFinite(fitted) && fitted > 0 ? Math.ceil(fitted * density) : source;
  // Do not invent detail beyond the captured pixels: output can be supersampled
  // for a 4K display, but never expands a picture by more than 2x.
  const width = Math.max(source, Math.min(source * 2, Math.min(3840, demand)));
  return { width, height: Math.max(2, Math.round(width * sourceHeight / sourceWidth)) };
}

export const RENDER_MODES = Object.freeze(['auto', 'native', 'qhd', 'uhd']);
export function resolutionMode(value) {
  return RENDER_MODES.includes(value) ? value : 'auto';
}
// A GPU OUTPUT target, never a claim that the iPhone captured these pixels.
// Wider iPhone sources preserve their aspect ratio inside QHD/UHD bounds.
export function resolutionScale(sourceWidth, sourceHeight, mode, stageWidth, dpr = 1, stageHeight = Infinity, gpuMaximum = 3840) {
  if (![sourceWidth, sourceHeight].every(v => Number.isFinite(v) && v > 0)) return {width:2,height:2};
  const sourceW = Math.max(2, Math.floor(sourceWidth));
  const sourceH = Math.max(2, Math.floor(sourceHeight));
  const maximum = Number.isFinite(gpuMaximum) ? Math.max(2, Math.min(3840, Math.floor(gpuMaximum))) : 3840;
  const selected = resolutionMode(mode);
  if (selected === 'native' && sourceW <= maximum && sourceH <= maximum) return {width:sourceW,height:sourceH};
  let bounds;
  if (selected === 'qhd') bounds = {width:2560,height:1440};
  else if (selected === 'uhd') bounds = {width:3840,height:2160};
  else bounds = qualityScale(sourceW, sourceH, stageWidth, dpr, stageHeight);
  const factor = Math.min(bounds.width / sourceW, bounds.height / sourceH, maximum / sourceW, maximum / sourceH);
  const even = value => Math.max(2, Math.min(Math.floor(maximum / 2) * 2, Math.round(value / 2) * 2));
  return { width:even(sourceW * factor), height:even(sourceH * factor) };
}

// Avoid trading playback cadence for UHD supersampling. Observe actual frame
// drops and GPU submission cost. The H.264 sender/PCM audio remain untouched.
export class RenderBudget {
  constructor() { this.reset(); }
  reset() { this.steps = 0; this.last = null; this.lastBad = -Infinity; }
  effective(requested) {
    const mode = resolutionMode(requested);
    if (mode === 'uhd') return this.steps >= 2 ? 'native' : this.steps === 1 ? 'qhd' : 'uhd';
    if (mode === 'qhd') return this.steps > 0 ? 'native' : 'qhd';
    return mode;
  }
  sample({at, decoded, droppedLate, renderMs = 0, visible = true}) {
    if (![at, decoded, droppedLate].every(Number.isFinite)) return false;
    const current = {at, decoded, droppedLate};
    if (!visible || !this.last) { this.last = current; return false; }
    if (at - this.last.at < 3000) return false;
    const frames = decoded - this.last.decoded;
    const lost = Math.max(0, droppedLate - this.last.droppedLate);
    this.last = current;
    if (frames < 24) return false; // paused game/hidden window
    if (lost > Math.max(3, frames * 0.07) || renderMs > 13) {
      this.lastBad = at;
      if (this.steps < 2) { this.steps++; return true; }
      return false;
    }
    if (this.steps > 0 && at - this.lastBad >= 20000) {
      this.steps--; this.lastBad = at; return true;
    }
    return false;
  }
}

const vertexShader = `#version 300 es
in vec2 a_vertex;
out vec2 v_uv;
void main() {
  v_uv = a_vertex * 0.5 + 0.5;
  gl_Position = vec4(a_vertex, 0., 1.);
}`;
const fragmentShader = `#version 300 es
precision highp float;
in vec2 v_uv;
out vec4 outputColor;
uniform sampler2D u_frame;
uniform vec2 u_texel;
uniform float u_strength;
void main() {
  vec4 original = texture(u_frame, v_uv);
  vec3 neighbors = texture(u_frame, v_uv + vec2(-u_texel.x, 0.)).rgb
                 + texture(u_frame, v_uv + vec2(u_texel.x, 0.)).rgb
                 + texture(u_frame, v_uv + vec2(0., -u_texel.y)).rgb
                 + texture(u_frame, v_uv + vec2(0., u_texel.y)).rgb;
  // Conservative five-tap unsharp mask, preserving the frame cadence.
  outputColor = vec4(clamp(original.rgb + u_strength * (original.rgb - neighbors * 0.25), 0., 1.), original.a);
}`;

export function createQualityRenderer(canvas, stage) {
  if (!canvas || typeof canvas.getContext !== 'function') return null;
  let gl;
  try { gl = canvas.getContext('webgl2', { alpha:false, depth:false, antialias:false, preserveDrawingBuffer:false, desynchronized:true, failIfMajorPerformanceCaveat:true }); }
  catch { return null; }
  if (!gl) return null;
  const compile = (type, source) => {
    const shader = gl.createShader(type);
    gl.shaderSource(shader, source); gl.compileShader(shader);
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) {
      const error = gl.getShaderInfoLog(shader);
      gl.deleteShader(shader); throw new Error(error || 'sharpen shader failed');
    }
    return shader;
  };
  let program, texture, buffer, position, texel, strength;
  try {
    const vert = compile(gl.VERTEX_SHADER, vertexShader), frag = compile(gl.FRAGMENT_SHADER, fragmentShader);
    program = gl.createProgram();
    gl.attachShader(program, vert); gl.attachShader(program, frag); gl.linkProgram(program);
    gl.deleteShader(vert); gl.deleteShader(frag);
    if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program));
    position = gl.getAttribLocation(program, 'a_vertex');
    texel = gl.getUniformLocation(program, 'u_texel');
    strength = gl.getUniformLocation(program, 'u_strength');
    texture = gl.createTexture(); buffer = gl.createBuffer();
    gl.bindBuffer(gl.ARRAY_BUFFER, buffer);
    gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,1,-1,-1,1,-1,1,1,-1,1,1]), gl.STATIC_DRAW);
    gl.useProgram(program);
    gl.enableVertexAttribArray(position);
    gl.vertexAttribPointer(position, 2, gl.FLOAT, false, 0, 0);
    gl.activeTexture(gl.TEXTURE0);
    gl.bindTexture(gl.TEXTURE_2D, texture);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MIN_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_MAG_FILTER, gl.LINEAR);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_S, gl.CLAMP_TO_EDGE);
    gl.texParameteri(gl.TEXTURE_2D, gl.TEXTURE_WRAP_T, gl.CLAMP_TO_EDGE);
    gl.uniform1i(gl.getUniformLocation(program, 'u_frame'), 0);
    gl.pixelStorei(gl.UNPACK_FLIP_Y_WEBGL, true);
  } catch {
    if (program) gl.deleteProgram(program);
    return null;
  }
  let broken = false;
  const lost = event => { event.preventDefault?.(); broken = true; };
  canvas.addEventListener?.('webglcontextlost', lost, {passive:false});

  return {
    draw(frame, preset, mode = 'auto') {
      if (broken || gl.isContextLost() || !frame || !QUALITY_PRESETS[preset]) return false;
      try {
        const bounds = stage?.getBoundingClientRect?.();
        const stageWidth = bounds?.width || frame.displayWidth;
        const dpr = typeof devicePixelRatio === 'number' ? devicePixelRatio : 1;
        const gpuMaximum = Math.min(3840, gl.getParameter(gl.MAX_TEXTURE_SIZE) || 3840, gl.getParameter(gl.MAX_RENDERBUFFER_SIZE) || 3840);
        const dims = resolutionScale(frame.displayWidth, frame.displayHeight, mode, stageWidth, dpr, bounds?.height, gpuMaximum);
        if (canvas.width !== dims.width || canvas.height !== dims.height) {
          canvas.width = dims.width; canvas.height = dims.height;
        }
        gl.viewport(0, 0, canvas.width, canvas.height);
        gl.bindTexture(gl.TEXTURE_2D, texture);
        gl.texImage2D(gl.TEXTURE_2D, 0, gl.RGBA, gl.RGBA, gl.UNSIGNED_BYTE, frame);
        // WebGL reports failed texture imports through getError, not an
        // exception. Keep the 2D fallback visible instead of a black canvas.
        if (gl.getError() !== gl.NO_ERROR) { broken = true; return false; }
        gl.uniform2f(texel, 1 / frame.displayWidth, 1 / frame.displayHeight);
        gl.uniform1f(strength, QUALITY_PRESETS[preset].strength);
        gl.drawArrays(gl.TRIANGLES, 0, 6);
        return true;
      } catch {
        broken = true;
        return false;
      }
    },
    get available() { return !broken; },
    close() {
      broken = true;
      canvas.removeEventListener?.('webglcontextlost', lost);
      gl.deleteTexture(texture); gl.deleteBuffer(buffer); gl.deleteProgram(program);
    }
  };
}
