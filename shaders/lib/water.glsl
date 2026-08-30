#ifndef FOXY_WATER_GLSL
#define FOXY_WATER_GLSL

#include "/lib/settings.glsl"
#include "/lib/math.glsl"

#if !defined(FOXY_EXTERNAL_PIPELINE_BINDINGS)
uniform sampler2D noisetex;
uniform sampler2D waterCausticV5Atlas;
#endif

const vec3 FOXY_WATER_ABSORPTION_RATIO = vec3(0.390, 0.120, 0.060);
const vec3 FOXY_WATER_SCATTERING_RATIO = vec3(0.010);
const float WATER_IOR = 1.333;

vec3 WaterExtinction(const in float fogStrength) {
	float density = mix(0.72, 1.18, Saturate(fogStrength)) * FOXY_WATER_DENSITY;
	vec3 absorption = FOXY_WATER_ABSORPTION_RATIO * density;
	vec3 scattering = FOXY_WATER_SCATTERING_RATIO * density;
	return absorption + scattering;
}

vec3 WaterTransmittance(const in float waterDepth, const in float fogStrength) {
	return exp(-WaterExtinction(fogStrength) * max(waterDepth, 0.0));
}

vec3 WaterScatterColor(const in vec3 skyAmbient, const in vec3 sunColor, const in float sunAmount, const in float skyLight, const in float rainStrength) {
	vec3 clearScatter = vec3(0.022, 0.070, 0.080);
	vec3 rainScatter = vec3(0.045, 0.060, 0.060);
	vec3 waterScatter = mix(clearScatter, rainScatter, Saturate(rainStrength));
	vec3 lumaWeight = vec3(0.2126, 0.7152, 0.0722);
	vec3 skyTint = skyAmbient / max(dot(skyAmbient, lumaWeight), 0.08);
	vec3 sunTint = sunColor / max(dot(sunColor, lumaWeight), 0.16);
	vec3 illuminant = mix(skyTint, sunTint, Saturate(sunAmount) * 0.28);
	float lightLevel = 0.14 + skyLight * 0.50 + Saturate(sunAmount) * 0.14;
	return waterScatter * illuminant * lightLevel
		* mix(0.75, 1.20, Saturate(FOXY_WATER_DENSITY * 0.55))
		* FOXY_WATER_SCATTER_BRIGHTNESS;
}

float WaterCriticalCosine() {
	float inverseIor = 1.0 / WATER_IOR;
	return sqrt(max(1.0 - inverseIor * inverseIor, 0.0));
}

float WaterSnellWindowTransmission(const in float NoV) {
	float criticalCosine = WaterCriticalCosine();
	return smoothstep(criticalCosine - 0.012, criticalCosine + 0.012, Saturate(NoV));
}

float WaterGgxSunLobe(
	const in float NoH,
	const in float NoV,
	const in float NoL,
	const in float slope,
	const in float fresnel
) {
	float alpha = max(slope, 0.004);
	float alphaSquared = alpha * alpha;
	float distributionDenominator = NoH * NoH * (alphaSquared - 1.0) + 1.0;
	float distribution = alphaSquared / max(PI * distributionDenominator * distributionDenominator, 1.0e-6);
	float geometryK = alpha * 0.5;
	float visibilityV = NoV / max(NoV * (1.0 - geometryK) + geometryK, 1.0e-5);
	float visibilityL = NoL / max(NoL * (1.0 - geometryK) + geometryK, 1.0e-5);
	return fresnel * distribution * visibilityV * visibilityL / max(4.0 * NoV, 0.08);
}

vec3 WaterSunGlint(
	const in vec3 normalView,
	const in vec3 viewDir,
	const in vec3 sunView,
	const in vec3 sunLightColor,
	const in float sunShadow,
	const in float skyLight,
	const in float solarVisibility,
	const in float rainStrength,
	const in float waveHeight,
	const in float normalAaReduction,
	const in vec3 worldPos,
	const in float frameTimeCounter
) {
	float NoV = max(dot(normalView, viewDir), 0.0);
	float NoL = max(dot(normalView, sunView), 0.0);
	float directVisibility = sunShadow * skyLight * solarVisibility;
	if (min(min(NoV, NoL), directVisibility) <= 0.001) {
		return vec3(0.0);
	}

	vec3 halfVectorUnnormalized = viewDir + sunView;
	float halfLengthSquared = dot(halfVectorUnnormalized, halfVectorUnnormalized);
	if (halfLengthSquared <= 1.0e-6) {
		return vec3(0.0);
	}
	vec3 halfVector = halfVectorUnnormalized * inversesqrt(halfLengthSquared);
	float NoH = max(dot(normalView, halfVector), 0.0);
	float VoH = max(dot(viewDir, halfVector), 0.0);
	float oneMinusVoH = 1.0 - VoH;
	float oneMinusVoH2 = oneMinusVoH * oneMinusVoH;
	float fresnel = 0.020 + 0.980 * oneMinusVoH2 * oneMinusVoH2 * oneMinusVoH;
	float aa = Saturate(normalAaReduction);

	float angularFloor = max(tan(max(FOXY_PBR_LIGHT_ANGULAR_RADIUS, 0.0)), 0.002);
	float slope = max(mix(0.008, 0.038, aa), angularFloor);
	float lobe = min(WaterGgxSunLobe(NoH, NoV, NoL, slope, fresnel), 28.0);
	float alignedLobe = max(lobe - mix(0.26, 0.46, aa), 0.0);
	float crest = mix(0.80, 1.20, Saturate(waveHeight * 1.65 + 0.50));
	float sparkle = min(alignedLobe * 16.0 * NoL * crest, 192.0);
	float weather = mix(1.0, 0.42, Saturate(rainStrength));
	return max(sunLightColor, vec3(0.0)) * sparkle * directVisibility * weather * FOXY_WATER_SUN_GLINT;
}

vec2 WaterRotate(const in vec2 p, const in float a) {
	float c = cos(a);
	float s = sin(a);
	return vec2(c * p.x - s * p.y, s * p.x + c * p.y);
}

float WaterTime(const in float frameTimeCounter) {
	return frameTimeCounter * FOXY_WATER_WAVE_SPEED * 1.65;
}

float WaterSpectrumTextureWave(const in vec2 p, const in vec2 scale, const in float angle, const in vec2 scroll, const in float t, const in float crestBias) {
	vec2 q = WaterRotate(p, angle) / scale + scroll * t;
	float n = texture2D(noisetex, q).b;
	float soft = n * 2.0 - 1.0;
	float ridge = 1.0 - abs(n * 2.0 - 1.0);
	float crest = pow(Saturate(ridge), crestBias) * 2.0 - 1.0;
	return mix(soft, crest, 0.34);
}

float WaterSpectrumHeightRaw(const in vec2 position, const in float frameTimeCounter, const in float midLevel, const in float fineLevel) {
	float t = WaterTime(frameTimeCounter) * 0.58;
	float spectrumScale = max(FOXY_WATER_SPECTRUM_SCALE, 0.01);
	vec2 scaledPosition = position / spectrumScale;
	vec2 broadWarp = texture2D(noisetex, scaledPosition / 210.0 + vec2(t * 0.0018, -t * 0.0011)).rg - vec2(0.5);
	vec2 p = scaledPosition + broadWarp * (5.6 + midLevel * 2.4) * FOXY_WATER_SPECTRUM_WARP;
	if (max(midLevel, fineLevel) > 0.001) {
		vec2 midWarp = texture2D(noisetex, WaterRotate(scaledPosition, -0.61) / 76.0 + vec2(-t * 0.0032, t * 0.0020)).ba - vec2(0.5);
		p += midWarp * (0.7 + fineLevel * 1.4) * FOXY_WATER_SPECTRUM_WARP;
	}

	float largePatch = smoothstep(0.18, 0.92, texture2D(noisetex, scaledPosition / 520.0 + vec2(t * 0.0008, -t * 0.0006)).r);
	float midPatch = smoothstep(0.12, 0.86, texture2D(noisetex, WaterRotate(scaledPosition, 0.37) / 180.0 + vec2(-t * 0.0017, t * 0.0012)).g);
	float spectrumPatch = mix(0.72, 1.18, largePatch * 0.65 + midPatch * 0.35);

	float height = 0.0;
	float largeHeight = FOXY_WATER_SPECTRUM_LARGE_HEIGHT;
	float largeScale = FOXY_WATER_SPECTRUM_LARGE_SCALE;
	height += WaterSpectrumTextureWave(p, vec2(220.0, 76.0) * largeScale,  0.23, vec2( 0.0015, -0.0009), t, 1.12) * (0.62 * largeHeight);
	height += WaterSpectrumTextureWave(p, vec2(142.0, 96.0) * largeScale, -0.84, vec2(-0.0010,  0.0013), t, 1.08) * (0.40 * largeHeight);
	height += WaterSpectrumTextureWave(p, vec2( 88.0, 42.0) * largeScale,  1.46, vec2( 0.0020,  0.0010), t, 1.18) * (0.28 * largeHeight);

	float mid = smoothstep(0.04, 0.72, midLevel);
	if (mid > 0.001) {
		float midHeight = FOXY_WATER_SPECTRUM_MID_HEIGHT;
		float midScale = FOXY_WATER_SPECTRUM_MID_SCALE;
		height += WaterSpectrumTextureWave(p, vec2(54.0, 20.0) * midScale, -0.28, vec2( 0.0045, -0.0028), t, 1.34) * (0.28 * mid * midHeight);
		height += WaterSpectrumTextureWave(p, vec2(38.0, 29.0) * midScale,  0.96, vec2(-0.0032,  0.0041), t, 1.28) * (0.22 * mid * midHeight);
		height += WaterSpectrumTextureWave(p, vec2(28.0, 61.0) * midScale, -1.37, vec2( 0.0028,  0.0050), t, 1.22) * (0.16 * mid * midHeight);
		height += WaterSpectrumTextureWave(p, vec2(21.0, 12.0) * midScale,  2.08, vec2(-0.0056, -0.0024), t, 1.42) * (0.11 * mid * midHeight);
	}

	float fine = smoothstep(0.10, 0.86, fineLevel);
	if (fine > 0.001) {
		float fineHeight = FOXY_WATER_SPECTRUM_FINE_HEIGHT * FOXY_WATER_SPECTRUM_NORMAL_DETAIL;
		float fineScale = FOXY_WATER_SPECTRUM_FINE_SCALE;
		height += WaterSpectrumTextureWave(p, vec2(12.0, 5.0) * fineScale,  0.54, vec2( 0.0100, -0.0120), t, 1.62) * (0.030 * fine * fineHeight);
		height += WaterSpectrumTextureWave(p, vec2( 8.4, 9.8) * fineScale, -1.11, vec2(-0.0130,  0.0080), t, 1.56) * (0.022 * fine * fineHeight);
		height += WaterSpectrumTextureWave(p, vec2( 6.2, 3.6) * fineScale,  1.82, vec2( 0.0150,  0.0110), t, 1.72) * (0.016 * fine * fineHeight);
		height += WaterSpectrumTextureWave(p, vec2( 4.4, 7.4) * fineScale, -2.39, vec2(-0.0160, -0.0130), t, 1.68) * (0.011 * fine * fineHeight);
	}

	float lowBias = texture2D(noisetex, scaledPosition / 690.0 + vec2(-t * 0.0005, t * 0.0004)).a * 2.0 - 1.0;
	return (height * spectrumPatch + lowBias * (0.10 * largeHeight)) * 1.05;
}

void WaterSpectrumField(const in vec2 position, const in float frameTimeCounter, const in float midLevel, const in float fineLevel, out float height, out vec2 slope) {
	float detail = Saturate(midLevel * 0.45 + fineLevel);
	float delta = mix(0.82, 0.18, detail);
	height = WaterSpectrumHeightRaw(position, frameTimeCounter, midLevel, fineLevel);
	float hx = WaterSpectrumHeightRaw(position + vec2(delta, 0.0), frameTimeCounter, midLevel, fineLevel);
	float hz = WaterSpectrumHeightRaw(position + vec2(0.0, delta), frameTimeCounter, midLevel, fineLevel);
	slope = vec2(hx - height, hz - height) / delta;
}

float WaterSpectrumHeightAt(const in vec2 position, const in float frameTimeCounter, const in bool detail) {
	return WaterSpectrumHeightRaw(position, frameTimeCounter, detail ? 0.92 : 0.0, detail ? 0.72 : 0.0);
}

float WaterV5AtlasFrame(const in vec2 uv, const in float frameIndex) {
	float tileX = mod(frameIndex, 8.0);
	float tileY = floor(frameIndex * 0.125);
	const float atlasTilePixelSize = 464.0;
	const float atlasGutterPixels = 8.0;
	const float atlasContentPixels = 448.0;
	vec2 localUv = (vec2(atlasGutterPixels + 0.5) + fract(uv) * (atlasContentPixels - 1.0)) / atlasTilePixelSize;
	vec2 atlasUv = (localUv + vec2(tileX, tileY)) * vec2(0.125);
	return texture2D(waterCausticV5Atlas, atlasUv).r;
}

float WaterV5AtlasCaustic(const in vec2 uv, const in float frameTimeCounter) {
	const float atlasFrameCount = 64.0;
	const float atlasPlaybackFps = 12.0;
	float phase = mod(frameTimeCounter * atlasPlaybackFps, atlasFrameCount);
	float frame0 = floor(phase);
	float frame1 = mod(frame0 + 1.0, atlasFrameCount);
	float blendWeight = fract(phase);
	float a = WaterV5AtlasFrame(uv, frame0);
	float b = WaterV5AtlasFrame(uv, frame1);
	return mix(a, b, blendWeight);
}

float WaterSpectrumCaustics(const in vec3 worldPos, const in vec3 sunWorldDir, const in float frameTimeCounter, const in float waterDepth, const in float projectionDepth) {
	float sunLift = smoothstep(0.045, 0.38, sunWorldDir.y);
	float depth = max(waterDepth, 0.0);
	float depthFade = exp(-depth * 0.020) * (1.0 - smoothstep(72.0, 162.0, depth));
	if (sunLift * depthFade <= 0.0001) {
		return 1.0;
	}

	float projection = max(projectionDepth, 0.0) / max(abs(sunWorldDir.y), 0.12);
	float spectrumScale = max(FOXY_WATER_SPECTRUM_SCALE, 0.01);
	vec2 lightProjected = (worldPos.xz + sunWorldDir.xz * projection) / spectrumScale;

	vec2 causticUv = lightProjected / 4.75 + vec2(0.5);
	float field = WaterV5AtlasCaustic(causticUv, frameTimeCounter);

	field = smoothstep(0.085, 0.265, field);
	float intensity = mix(1.40, 2.80, Saturate(FOXY_WATER_WAVE_STRENGTH));
	float caustic = 1.0 + field * intensity * sunLift * depthFade;
	return clamp(caustic, 1.0, 4.35);
}

float WaterCaustics(const in vec3 worldPos, const in vec3 sunWorldDir, const in float frameTimeCounter, const in float waterDepth, const in float projectionDepth) {
#if FOXY_WATER_CAUSTICS == 1 && FOXY_WATER_SPECTRUM_WAVES == 1
	return WaterSpectrumCaustics(worldPos, sunWorldDir, frameTimeCounter, waterDepth, projectionDepth);
#else
	return 1.0;
#endif
}

float WaterLargeHeight(const in vec2 p, const in float frameTimeCounter) {
#if FOXY_WATER_SPECTRUM_WAVES == 1
	float anchoredHeight = WaterSpectrumHeightAt(p, frameTimeCounter, false);
	anchoredHeight -= FOXY_WATER_SPECTRUM_VERTEX_ANCHOR * FOXY_WATER_SPECTRUM_LARGE_HEIGHT * 0.62;
	return anchoredHeight * FOXY_WATER_WAVE_STRENGTH * FOXY_WATER_SPECTRUM_VERTEX_HEIGHT * 1.85;
#else
	return 0.0;
#endif
}

float WaterDetailHeightShared(const in vec2 p, const in float frameTimeCounter) {
#if FOXY_WATER_SPECTRUM_WAVES == 1
	return WaterSpectrumHeightAt(p, frameTimeCounter, true);
#else
	return 0.0;
#endif
}

void WaterNormalAaFactors(
	const in mat4 gbufferModelView,
	const in vec3 baseNormalView,
	const in vec3 worldPos,
	const in vec3 cameraPosition,
	const in float worldFootprint,
	out float midKeep,
	out float fineKeep,
	out float normalKeep,
	out float reduction
) {
	float strength = Saturate(FOXY_WATER_NORMAL_AA_STRENGTH);
	vec3 viewDirView = normalize(mat3(gbufferModelView) * (cameraPosition - worldPos));
	float flatNoV = abs(dot(normalize(baseNormalView), viewDirView));
	float grazingTarget = mix(0.12, 1.0, smoothstep(0.025, 0.16, flatNoV));

	float footprint = max(worldFootprint, 0.0);
	float spectrumScale = max(FOXY_WATER_SPECTRUM_SCALE, 0.01);
	float fineWavelength = max(4.4 * FOXY_WATER_SPECTRUM_FINE_SCALE * spectrumScale, 0.25);
	float midWavelength = max(21.0 * FOXY_WATER_SPECTRUM_MID_SCALE * spectrumScale, 0.50);
	float fineTarget = 1.0 - smoothstep(fineWavelength * 0.12, fineWavelength * 0.55, footprint);
	float midTarget = 1.0 - smoothstep(midWavelength * 0.12, midWavelength * 0.55, footprint);
	float footprintNormalTarget = mix(0.20, 1.0, 1.0 - smoothstep(1.25, 12.0, footprint));

	midKeep = mix(1.0, midTarget, strength);
	fineKeep = mix(1.0, fineTarget, strength);
	normalKeep = mix(1.0, min(grazingTarget, footprintNormalTarget), strength);
	float bandReduction = 1.0 - (midKeep * 0.40 + fineKeep * 0.60);
	reduction = Saturate(max(1.0 - normalKeep, bandReduction * 0.55));
}

vec2 WaterSurfaceCoordPlayer(
	const in vec3 baseNormalPlayer,
	const in vec3 worldPos
) {

	if (abs(baseNormalPlayer.y) < 0.25) {
		vec3 sideTangent = normalize(cross(vec3(0.0, 1.0, 0.0), baseNormalPlayer));
		return vec2(dot(worldPos, sideTangent), worldPos.y);
	}
	return worldPos.xz;
}

vec3 WaterDetailNormalPlayer(
	const in vec3 baseNormalPlayer,
	const in vec3 worldPos,
	const in vec3 cameraPosition,
	const in float frameTimeCounter,
	const in float midFootprintKeep,
	const in float fineFootprintKeep
) {
#if FOXY_WATER_SPECTRUM_WAVES == 1
	vec3 geometricNormal = normalize(baseNormalPlayer);
	vec2 p = WaterSurfaceCoordPlayer(geometricNormal, worldPos);
	float viewDistance = length(worldPos - cameraPosition);
	float midLevel = (1.0 - smoothstep(128.0, 380.0, viewDistance)) * midFootprintKeep;
	float fineLevel = (1.0 - smoothstep(16.0, 92.0, viewDistance)) * fineFootprintKeep;
	float spectrumHeight;
	vec2 spectrumSlope;
	WaterSpectrumField(p, frameTimeCounter, midLevel, fineLevel, spectrumHeight, spectrumSlope);
	float nearDetail = max(midLevel * 0.82, fineLevel * 0.58);
	float farUpright = mix(0.78, 0.56, nearDetail);
	vec2 waveSlope = spectrumSlope * (1.18 / max(farUpright, 0.20));

	if (abs(geometricNormal.y) < 0.25) {
		vec3 sideTangent = normalize(cross(vec3(0.0, 1.0, 0.0), geometricNormal));
		return normalize(
			geometricNormal
			- sideTangent * waveSlope.x
			- vec3(0.0, 1.0, 0.0) * waveSlope.y
		);
	}

float facingSign = mix(-1.0, 1.0, step(0.0, geometricNormal.y));
	vec3 upwardNormal = geometricNormal * facingSign;
	vec2 geometricSlope = -upwardNormal.xz / max(upwardNormal.y, 0.10);
	vec2 combinedSlope = geometricSlope + waveSlope;
	return normalize(vec3(-combinedSlope.x, 1.0, -combinedSlope.y)) * facingSign;
#else
	return normalize(baseNormalPlayer);
#endif
}

vec3 WaterDetailNormalViewShared(
	const in mat4 gbufferModelView,
	const in vec3 baseNormalView,
	const in vec3 worldPos,
	const in vec3 cameraPosition,
	const in float frameTimeCounter,
	const in float worldFootprint,
	out float aaReduction
) {
		float midKeep;
		float fineKeep;
		float normalKeep;
		WaterNormalAaFactors(gbufferModelView, baseNormalView, worldPos, cameraPosition, worldFootprint, midKeep, fineKeep, normalKeep, aaReduction);
		vec3 baseNormalPlayer = normalize(transpose(mat3(gbufferModelView)) * baseNormalView);
		vec3 detailPlayer = WaterDetailNormalPlayer(baseNormalPlayer, worldPos, cameraPosition, frameTimeCounter, midKeep, fineKeep);
		vec3 detailView = normalize(mat3(gbufferModelView) * detailPlayer);
		float detailInfluence = Saturate(FOXY_WATER_WAVE_STRENGTH * 1.02) * normalKeep;
		return normalize(mix(baseNormalView, detailView, detailInfluence));
}

#endif
