/**
 * Rauch-Wisps als Punktwolke.
 *
 * Bewusst kein Volumen-Rendering: ein paar hundert additiv gemischte,
 * weich auslaufende Punkte, die langsam aufsteigen und seitlich pendeln,
 * lesen bei dieser Bildgröße als Rauch — und kosten fast nichts.
 */
export const smokeVertexShader = /* glsl */ `
  uniform float uTime;
  uniform float uSize;
  uniform float uPixelRatio;
  uniform float uSpread;

  attribute float aSeed;
  attribute float aScale;
  attribute float aSpeed;

  varying float vAlpha;
  varying float vSeed;

  void main() {
    vec3 pos = position;

    // Aufsteigen mit Umbruch: jeder Punkt startet zeitversetzt neu unten.
    float life = fract(uTime * aSpeed * 0.06 + aSeed);
    pos.y += life * uSpread;

    // Seitliches Pendeln, das mit der Höhe breiter wird.
    float sway = life * 0.6 + 0.15;
    pos.x += sin(uTime * 0.35 * aSpeed + aSeed * 24.0) * 0.16 * sway;
    pos.z += cos(uTime * 0.28 * aSpeed + aSeed * 17.0) * 0.16 * sway;

    vec4 mvPosition = modelViewMatrix * vec4(pos, 1.0);
    gl_Position = projectionMatrix * mvPosition;

    // Größe perspektivisch korrekt, Retina-Dichte eingerechnet.
    gl_PointSize = uSize * aScale * uPixelRatio * (1.0 / -mvPosition.z);

    // Unten einblenden, oben ausblenden — nichts erscheint oder endet hart.
    vAlpha = smoothstep(0.0, 0.18, life) * (1.0 - smoothstep(0.45, 1.0, life));
    vSeed = aSeed;
  }
`

export const smokeFragmentShader = /* glsl */ `
  precision mediump float;

  uniform vec3 uColor;
  uniform float uOpacity;

  varying float vAlpha;
  varying float vSeed;

  void main() {
    // Weiche runde Maske statt Textur — spart einen Request.
    vec2 uv = gl_PointCoord - 0.5;
    float dist = length(uv);
    float mask = 1.0 - smoothstep(0.12, 0.5, dist);
    mask *= mask;

    float alpha = mask * vAlpha * uOpacity;
    if (alpha < 0.002) discard;

    // Leichte Farbstreuung, damit die Wolke nicht flach wirkt.
    vec3 color = mix(uColor, uColor * 1.35, fract(vSeed * 7.0));
    gl_FragColor = vec4(color, alpha);
  }
`
