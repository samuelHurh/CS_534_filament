//------------------------------------------------------------------------------
// Common color operations
//------------------------------------------------------------------------------

/**
 * Computes the luminance of the specified linear RGB color using the
 * luminance coefficients from Rec. 709.
 *
 * @public-api
 */
float luminance(const vec3 linear) {
    return dot(linear, vec3(0.2126, 0.7152, 0.0722));
}

/**
 * Computes the pre-exposed intensity using the specified intensity and exposure.
 * This function exists to force highp precision on the two parameters
 */
float computePreExposedIntensity(const highp float intensity, const highp float exposure) {
    return intensity * exposure;
}

void unpremultiply(inout vec4 color) {
    color.rgb /= max(color.a, FLT_EPS);
}

/**
 * Applies a full range YCbCr to sRGB conversion and returns an RGB color.
 *
 * @public-api
 */
vec3 ycbcrToRgb(float luminance, vec2 cbcr) {
    // Taken from https://developer.apple.com/documentation/arkit/arframe/2867984-capturedimage
    const mat4 ycbcrToRgbTransform = mat4(
         1.0000,  1.0000,  1.0000,  0.0000,
         0.0000, -0.3441,  1.7720,  0.0000,
         1.4020, -0.7141,  0.0000,  0.0000,
        -0.7010,  0.5291, -0.8860,  1.0000
    );
    return (ycbcrToRgbTransform * vec4(luminance, cbcr, 1.0)).rgb;
}

//------------------------------------------------------------------------------
// Tone mapping operations
//------------------------------------------------------------------------------

/*
 * The input must be in the [0, 1] range.
 */
vec3 Inverse_Tonemap_Filmic(const vec3 x) {
    return (0.03 - 0.59 * x - sqrt(0.0009 + 1.3702 * x - 1.0127 * x * x)) / (-5.02 + 4.86 * x);
}

/**
 * Applies the inverse of the tone mapping operator to the specified HDR or LDR
 * sRGB (non-linear) color and returns a linear sRGB color. The inverse tone mapping
 * operator may be an approximation of the real inverse operation.
 *
 * @public-api
 */
vec3 inverseTonemapSRGB(vec3 color) {
    // sRGB input
    color = clamp(color, 0.0, 1.0);
    return Inverse_Tonemap_Filmic(pow(color, vec3(2.2)));
}

/**
 * Applies the inverse of the tone mapping operator to the specified HDR or LDR
 * linear RGB color and returns a linear RGB color. The inverse tone mapping operator
 * may be an approximation of the real inverse operation.
 *
 * @public-api
 */
vec3 inverseTonemap(vec3 linear) {
    // Linear input
    return Inverse_Tonemap_Filmic(clamp(linear, 0.0, 1.0));
}

//------------------------------------------------------------------------------
// Common texture operations
//------------------------------------------------------------------------------

/**
 * Decodes the specified RGBM value to linear HDR RGB.
 */
vec3 decodeRGBM(vec4 c) {
    c.rgb *= (c.a * 16.0);
    return c.rgb * c.rgb;
}

//------------------------------------------------------------------------------
// Common screen-space operations
//------------------------------------------------------------------------------

// returns the frag coord in the GL convention with (0, 0) at the bottom-left
// resolution : width, height
highp vec2 getFragCoord(const highp vec2 resolution) {
#if defined(TARGET_METAL_ENVIRONMENT) || defined(TARGET_VULKAN_ENVIRONMENT) || defined(TARGET_WEBGPU_ENVIRONMENT)
    return vec2(gl_FragCoord.x, resolution.y - gl_FragCoord.y);
#else
    return gl_FragCoord.xy;
#endif
}

//------------------------------------------------------------------------------
// Common debug
//------------------------------------------------------------------------------

vec3 heatmap(float v) {
    vec3 r = v * 2.1 - vec3(1.8, 1.14, 0.3);
    return 1.0 - r * r;
}

//------------------------------------------------------------------------------
// Preliminary fragment-discard validation (toggle via FILAMENT_VALIDATION_DROP_HALF_FRAGMENTS)
//------------------------------------------------------------------------------

#if FILAMENT_VALIDATION_DROP_HALF_FRAGMENTS
bool filamentValidationShouldDropHalfFragment() {
    // discard approximately half of all fragments.
    highp vec2 frag = floor(getFragCoord(frameUniforms.resolution.xy));
    return mod(frag.x + frag.y, 8.0) < 4.0;
}

void filamentValidationMaybeDiscardHalfFragments() {
    if (filamentValidationShouldDropHalfFragment()) {
        discard;
    }
}

vec4 filamentValidationNeighborColorFallback(const vec4 color) {
    // Extrapolate from a nearby surviving fragment along +X until the phase
    // reaches a non-discarded value.
    highp vec2 frag = floor(getFragCoord(frameUniforms.resolution.xy));
    float phase = mod(frag.x + frag.y, 8.0);
    if (phase < 4.0) {
        float dx = 4.0 - phase;
        return color + dFdx(color) * dx;
    }
    return color;
}
#else
bool filamentValidationShouldDropHalfFragment() { return false; }
void filamentValidationMaybeDiscardHalfFragments() {}
vec4 filamentValidationNeighborColorFallback(const vec4 color) { return color; }
#endif

//------------------------------------------------------------------------------
// Foveated fragment subsampling (same phase pattern as validation; dFdx fill)
//------------------------------------------------------------------------------

bool filamentFoveationShouldDropFragment() {
    if (frameUniforms.foveationEnabled < 0.5) {
        return false;
    }
    highp vec2 fragPx = getFragCoord(frameUniforms.resolution.xy);
    vec2 uv = fragPx * frameUniforms.resolution.zw;
    float dist = length(uv - frameUniforms.fovealCenter);
    if (dist <= frameUniforms.fovealRadius) {
        return false;
    }
    float ringKeep = clamp(frameUniforms.foveationTransitionKeep, 0.001, 1.0);
    float outerKeep = clamp(frameUniforms.foveationOuterKeep, 0.001, 1.0);
    float keep = (dist >= frameUniforms.peripheralRadius) ? outerKeep : ringKeep;
    float minPhase = 8.0 * (1.0 - keep);
    highp vec2 frag = floor(fragPx);
    float phase = mod(frag.x + frag.y, 8.0);
    return phase < minPhase;
}

vec4 filamentFoveationNeighborColorFallback(const vec4 color) {
    if (frameUniforms.foveationEnabled < 0.5) {
        return color;
    }
    highp vec2 fragPx = getFragCoord(frameUniforms.resolution.xy);
    vec2 uv = fragPx * frameUniforms.resolution.zw;
    float dist = length(uv - frameUniforms.fovealCenter);
    if (dist <= frameUniforms.fovealRadius) {
        return color;
    }
    float ringKeep = clamp(frameUniforms.foveationTransitionKeep, 0.001, 1.0);
    float outerKeep = clamp(frameUniforms.foveationOuterKeep, 0.001, 1.0);
    float keep = (dist >= frameUniforms.peripheralRadius) ? outerKeep : ringKeep;
    float minPhase = 8.0 * (1.0 - keep);
    highp vec2 frag = floor(fragPx);
    float phase = mod(frag.x + frag.y, 8.0);
    if (phase < minPhase) {
        float dx = minPhase - phase;
        // return color + dFdx(color) * dx;
        // prevent white artifacts at edges
        vec4 ddx = dFdx(color);
        vec4 ddy = dFdy(color);

        vec4 extrapolated = color + ddx * dx;
        vec3 localRange = abs(ddx.rgb) + abs(ddy.rgb) + vec3(1e-4);
        extrapolated.rgb = clamp(extrapolated.rgb,
                max(color.rgb - 2.0 * localRange, vec3(0.0)),
                color.rgb + 2.0 * localRange);

        float edgeStrength = max(length(ddx.rgb), length(ddy.rgb));
        float edgeBlend = smoothstep(0.2, 0.8, edgeStrength);
        return mix(extrapolated, color, edgeBlend);
    }
    return color;
}
