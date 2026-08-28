#include "/lib/settings.glsl"
#include "/lib/math.glsl"
#include "/lib/lighting.glsl"
#include "/lib/celestial.glsl"
#include "/lib/first_person_depth.glsl"

#define FinalOutput gl_FragColor

#if FOXY_POST_RESOLVE_ACTIVE == 0
	#define FOXY_FINAL_SCENE_FROM_COMPOSED 1
uniform sampler2D colortex11;
uniform sampler2D colortex14;
uniform sampler2D colortex0;
#else
	#define FOXY_FINAL_SCENE_FROM_COMPOSED 0
uniform sampler2D colortex0;
#endif
uniform sampler2D colortex1;
uniform sampler2D colortex5;
uniform sampler2D colortex6;
uniform sampler2D colortex7;
uniform sampler2D colortex8;
uniform sampler2D colortex9;
uniform sampler2D depthtex0;
#if FOXY_DOF == 1 && FOXY_DOF_AUTO_FOCUS == 1
uniform float centerDepthSmooth;
#endif
#include "/lib/contracts/endpoint.glsl"
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 sunPosition;
uniform vec3 moonPosition;
uniform vec3 upPosition;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float viewWidth;
uniform float viewHeight;
uniform float frameTime;
uniform float far;
uniform float rainStrength;
uniform float waterEnteredAltitude;
uniform ivec2 eyeBrightnessSmooth;
uniform int isEyeInWater;
uniform int frameCounter;
varying vec2 texcoord;
varying float finalVertexExposure;
varying float presentationSunAltitude;
varying vec3 vertexSunLightColor;
varying vec3 vertexMoonLightColor;
varying vec3 vertexSkyAmbientColor;
varying vec3 vertexSunView;
varying vec3 vertexMoonView;
varying vec3 vertexUpView;
varying float vertexSunAltitude;
varying float vertexMoonAltitude;
#include "/lib/sr.glsl"

#define FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG
#include "/lib/contracts/images.glsl"

#if FOXY_IRRADIANCE_CACHE_ACTIVE == 1
#include "/lib/voxel/irradiance_cache.glsl"
#endif

vec2 FinalSceneUv(const in vec2 uv) {
	return SrPresentationUv(uv);
}

vec3 FinalCurrentSceneEncodedSample(const in vec2 uv) {
	#if FOXY_FINAL_SCENE_FROM_COMPOSED == 1
		vec2 sceneUv = FinalSceneUv(uv);
		vec3 presentationColor = texture2D(colortex11, sceneUv).rgb;
		vec2 currentResourceUv = SrSceneSampleUv(sceneUv);
		#if FOXY_VOLUMETRIC_LIGHT == 1
			vec3 temporalCurrent = texture2D(colortex0, currentResourceUv).rgb;
		#else
			vec3 temporalCurrent = texture2D(colortex14, currentResourceUv).rgb;
		#endif
		return presentationColor;
	#else
		return texture2D(colortex0, FinalSceneUv(uv)).rgb;
	#endif
}

vec2 FinalScenePixelCenter(const in vec2 uv) {
	return SrPixelCenter(uv);
}

vec3 BloomBufferSample(const in vec2 uv, const in vec2 offset) {
	vec2 sampleUv = clamp(uv + offset, vec2(0.0), vec2(1.0));
	#if FOXY_TAAU_ACTIVE == 1
		return max(texture2D(colortex1, sampleUv).rgb, vec3(0.0));
	#else
		return max(texture2D(colortex1, SrPresentationUv(sampleUv)).rgb, vec3(0.0));
	#endif
}

vec4 VolumeBufferSample(const in vec2 uv) {
	vec4 v = DecodeVolumeBuffer(texture2D(colortex6, SrSceneSampleUv(uv)));
	return vec4(max(v.rgb, vec3(0.0)), Saturate(v.a));
}

vec3 FinalDecodeSkyLutColor(const in vec3 c) {
	return DecodeBufferColor(c);
}

vec3 FinalBloom(const in vec2 uv, const in vec2 px) {
	vec2 bloomPx = px * 4.0;
	vec2 bilinearOffset = bloomPx * 0.40;
	vec3 bloom = BloomBufferSample(uv, vec2( bilinearOffset.x,  bilinearOffset.y));
	bloom += BloomBufferSample(uv, vec2(-bilinearOffset.x,  bilinearOffset.y));
	bloom += BloomBufferSample(uv, vec2( bilinearOffset.x, -bilinearOffset.y));
	bloom += BloomBufferSample(uv, vec2(-bilinearOffset.x, -bilinearOffset.y));
	bloom *= 0.25;
	float luma = Luma(bloom);
	float compressed = luma / (1.0 + luma * 0.28);
	bloom *= compressed / max(luma, 1.0e-4);
	return bloom;
}

vec3 FinalDither(const in vec3 color, const in float noisePattern) {
	float luma = Luma(color);
	float shadowWeight = 1.0 - smoothstep(0.08, 0.48, luma);
	float noise = noisePattern - 0.5;
	return color + vec3(noise * (1.0 / 255.0) * mix(0.75, 1.18, shadowWeight));
}

float FinalWaterHgPhase(const in float mu, const in float g) {
	float gg = g * g;
	return (1.0 - gg) / max(4.0 * PI * pow(1.0 + gg - 2.0 * g * mu, 1.5), 1.0e-4);
}

vec3 FinalWaterExtinction(const in float fogStrength) {
	vec3 absorptionRatio = vec3(0.390, 0.120, 0.060);
	vec3 scatteringRatio = vec3(0.010);
	float density = mix(0.72, 1.18, Saturate(fogStrength)) * FOXY_WATER_DENSITY;
	return (absorptionRatio + scatteringRatio) * density;
}

vec3 FinalWaterScatterColor(const in vec3 skyAmbient, const in vec3 sunColor, const in float sunAmount, const in float skyLight, const in float rainStrength) {
	vec3 clearScatter = vec3(0.022, 0.070, 0.080);
	vec3 rainScatter = vec3(0.045, 0.060, 0.060);
	vec3 waterScatter = mix(clearScatter, rainScatter, Saturate(rainStrength));
	vec3 lumaWeight = vec3(0.2126, 0.7152, 0.0722);
	vec3 skyTint = skyAmbient / max(dot(skyAmbient, lumaWeight), 0.08);
	vec3 sunTint = sunColor / max(dot(sunColor, lumaWeight), 0.16);
	vec3 illuminant = mix(skyTint, sunTint, Saturate(sunAmount) * 0.28);
	float lightLevel = 0.14 + skyLight * 0.50 + Saturate(sunAmount) * 0.14;
	return waterScatter * illuminant * lightLevel * mix(0.75, 1.20, Saturate(FOXY_WATER_DENSITY * 0.55));
}

float SafeDivisorFinal(const in float x) {
	if (abs(x) < 1.0e-6) {
		return x < 0.0 ? -1.0e-6 : 1.0e-6;
	}
	return x;
}

vec3 FinalViewPosFromDepth(const in vec2 uv, const in float depth) {
	vec4 clip = vec4(uv * 2.0 - 1.0, depth * 2.0 - 1.0, 1.0);
	vec4 view = gbufferProjectionInverse * clip;
	return view.xyz / SafeDivisorFinal(view.w);
}

vec2 FinalProjectPreviousUv(const in Endpoint endpoint, const in vec3 viewPos) {
	vec4 player = gbufferModelViewInverse * vec4(viewPos, 1.0);
	player.xyz /= SafeDivisorFinal(player.w);
	player.xyz += cameraPosition - previousCameraPosition;
	vec4 previousView = gbufferPreviousModelView * vec4(player.xyz, 1.0);
	vec4 previousClip = EndpointPreviousClip(endpoint, previousView, gbufferPreviousProjection);
	return previousClip.xy / SafeDivisorFinal(previousClip.w) * 0.5 + 0.5;
}

vec2 FinalMotionVector(
	const in vec2 uv,
	const in float depthRaw,
	const in Endpoint endpoint
) {
	float endpointValid = 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, endpoint.rayDistance);
	if (endpointValid > 0.5) {
		vec3 endpointViewPos = EndpointViewPosition(
			endpoint,
			uv,
			depthRaw,
			gbufferProjectionInverse
		);
		vec2 previousUv = FinalProjectPreviousUv(endpoint, endpointViewPos);
		if (previousUv.x > 0.001 && previousUv.x < 0.999 && previousUv.y > 0.001 && previousUv.y < 0.999) {
			return uv - previousUv;
		}
	}
	if (depthRaw >= 0.99999) {
		return vec2(0.0);
	}
	vec3 viewPos = FinalViewPosFromDepth(uv, depthRaw);
	vec2 previousUv = FinalProjectPreviousUv(EndpointSky(), viewPos);
	return uv - previousUv;
}

vec3 FinalApplyWhiteBalance(const in vec3 color) {
	#if FOXY_WHITE_BALANCE == 6500
		return color;
	#else
		vec3 d65 = ColorTemperatureToRgb(6500.0);
		vec3 sourceWhite = max(ColorTemperatureToRgb(float(FOXY_WHITE_BALANCE)), vec3(0.04));
		vec3 balanced = color * (d65 / sourceWhite);
		return max(balanced, vec3(0.0));
	#endif
}

vec3 FinalApplyColorGrade(const in vec3 color) {
	float amount = Saturate(FOXY_COLOR_GRADING);
	float luma = Luma(color);
	float shadow = 1.0 - smoothstep(0.045, 0.340, luma);
	float highlight = smoothstep(0.360, 0.920, luma);
	vec3 graded = color;
	graded *= mix(vec3(1.0), vec3(0.965, 0.992, 1.045), shadow * amount);
	graded *= mix(vec3(1.0), vec3(1.040, 1.010, 0.965), highlight * amount);
	float preContrastLuma = Luma(graded);
	float contrastScale = mix(1.0, 1.045, amount);
	float pivotContrastLuma = max(0.18 + (preContrastLuma - 0.18) * contrastScale, 0.0);
	float contrastWeight = smoothstep(0.012, 0.22, preContrastLuma);
	float protectedContrastLuma = mix(preContrastLuma, pivotContrastLuma, contrastWeight);
	graded *= protectedContrastLuma / max(preContrastLuma, 1.0e-6);
	float gradedLuma = Luma(graded);
	float chromaWeight = smoothstep(0.025, 0.22, gradedLuma);
	graded = mix(vec3(gradedLuma), graded, mix(1.0, 1.035, amount * chromaWeight));
	return max(graded, vec3(0.0));
}

float FinalVignette(const in vec2 uv) {
	vec2 p = uv * (vec2(1.0) - uv);
	float shape = pow(Saturate(p.x * p.y * 16.0), 0.35);
	return mix(1.0, shape, Saturate(FOXY_VIGNETTE));
}

vec3 FinalMotionBlur(
	const in vec2 uv,
	const in float depthRaw,
	const in vec3 centerColor,
	const in Endpoint motionEndpoint,
	const in float shutterPattern
) {
	if (FOXY_MOTION_BLUR <= 0.0001) {
		return centerColor;
	}
	if (FirstPersonDepthMask(depthRaw) > 0.5) {
		return centerColor;
	}
	float motionSurface = 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, motionEndpoint.rayDistance);
	if (depthRaw >= 0.99999 && motionSurface < 0.5) {
		return centerColor;
	}
	vec2 velocity = FinalMotionVector(uv, depthRaw, motionEndpoint);
	float velocityPx = length(velocity / SrFullPixelSize());
	float motionActivation = smoothstep(0.35, 2.0, velocityPx);
	if (motionActivation <= 0.005) {
		return centerColor;
	}
	float blurAmount = clamp(FOXY_MOTION_BLUR, 0.0, 3.0);
	vec2 shutterVelocityPx = velocity / SrFullPixelSize();
	shutterVelocityPx *= blurAmount * 0.5 * motionActivation;
	float shutterLengthPx = length(shutterVelocityPx);
	shutterVelocityPx *= min(1.0, 32.0 / max(shutterLengthPx, 1.0e-4));
	velocity = shutterVelocityPx * SrFullPixelSize();
	float effectiveVelocityPx = min(shutterLengthPx, 32.0);
	if (effectiveVelocityPx <= 0.35) {
		return centerColor;
	}
	float blurCoverage = smoothstep(0.35, 1.50, effectiveVelocityPx);
	vec2 edge = SrFullPixelSize() * 2.0;
	// Complementary phases preserve unit weight and zero centroid.
	int shutterPhase = (int(floor(shutterPattern * 4.0)) + (frameCounter & 3)) & 3;
	const vec4 innerTaps = vec4(0.30, 0.42, 0.54, 0.66);
	const vec4 outerTaps = vec4(0.97553404, 0.93019711, 0.86606389, 0.77850284);
	float innerTap = innerTaps[shutterPhase];
	float outerTap = outerTaps[shutterPhase];
	const float pairWeight = 0.16;
	const float centerWeight = 0.36;
	vec3 color = centerColor * centerWeight;
	color += DecodeSceneColor(FinalCurrentSceneEncodedSample(clamp(uv - velocity * outerTap, edge, vec2(1.0) - edge))) * pairWeight;
	color += DecodeSceneColor(FinalCurrentSceneEncodedSample(clamp(uv - velocity * innerTap, edge, vec2(1.0) - edge))) * pairWeight;
	color += DecodeSceneColor(FinalCurrentSceneEncodedSample(clamp(uv + velocity * innerTap, edge, vec2(1.0) - edge))) * pairWeight;
	color += DecodeSceneColor(FinalCurrentSceneEncodedSample(clamp(uv + velocity * outerTap, edge, vec2(1.0) - edge))) * pairWeight;
	return max(mix(centerColor, color, blurCoverage), vec3(0.0));
}

#if FOXY_DOF == 1
	#if FOXY_DOF_QUALITY == 0
		#define FOXY_DOF_BOKEH_SAMPLES 32
		#define FOXY_DOF_HEXAGONAL_APERTURE 0
	#elif FOXY_DOF_QUALITY == 1
		#define FOXY_DOF_BOKEH_SAMPLES 60
		#define FOXY_DOF_HEXAGONAL_APERTURE 1
	#elif FOXY_DOF_QUALITY == 2
		#define FOXY_DOF_BOKEH_SAMPLES 64
		#define FOXY_DOF_HEXAGONAL_APERTURE 0
	#elif FOXY_DOF_QUALITY == 3
		#define FOXY_DOF_BOKEH_SAMPLES 96
		#define FOXY_DOF_HEXAGONAL_APERTURE 0
	#else
		#define FOXY_DOF_BOKEH_SAMPLES 128
		#define FOXY_DOF_HEXAGONAL_APERTURE 0
	#endif

float FinalDofFocusDistance() {
	#if FOXY_DOF_AUTO_FOCUS == 1
		// Sky focus uses the far plane; geometry retains smoothed focus.
		float centerRawDepth = texture2D(
			depthtex0,
			SrSceneSampleUv(vec2(0.5))
		).r;
		if (centerRawDepth >= 0.99999) {
			return max(far, 0.25);
		}
		float focusDepth = clamp(centerDepthSmooth, 1.0e-6, 0.99999);
		return max(length(FinalViewPosFromDepth(vec2(0.5), focusDepth)), 0.25);
	#endif
	return max(FOXY_DOF_FOCUS_DISTANCE, 0.25);
}

vec3 FinalDofEncodedSampleLod(const in vec2 uv, const in float lodLevel) {
	#if FOXY_FINAL_SCENE_FROM_COMPOSED == 1
		return texture2DLod(colortex11, FinalSceneUv(uv), lodLevel).rgb;
	#else
		return texture2DLod(colortex0, FinalSceneUv(uv), lodLevel).rgb;
	#endif
}

float FinalDofSignedCoc(
	const in float distanceToCamera,
	const in float focusDistance
) {
	// Signed thin-lens circle of confusion in screen pixels.
	float focalLength = min(0.35, focusDistance * 0.20);
	float focusSeparation = max(focusDistance - focalLength, 0.05);
	float lens = FOXY_DOF_APERTURE * focusDistance * 1.70;
	return lens * focalLength * (distanceToCamera - focusDistance) /
		max(distanceToCamera * focusSeparation, 0.05);
}

vec3 FinalDepthOfField(const in vec2 uv, const in float depthRaw, const in vec3 centerColor) {
	float focusDistance = FinalDofFocusDistance();
	float centerDistance = depthRaw >= 0.99999
		? far
		: length(FinalViewPosFromDepth(uv, depthRaw));
	float centerCoc = FinalDofSignedCoc(centerDistance, focusDistance);
	float centerBlur = min(FOXY_DOF_MAX_BLUR, abs(centerCoc) * FOXY_DOF_MAX_BLUR);
	if (centerBlur < 0.35) return centerColor;

	vec2 pixelRadius = SrFullPixelSize() * centerBlur;
	float lodLevel = clamp(log2(max(centerBlur, 1.0)) * 0.55, 0.0, 3.0);
	const float goldenAngle = 2.39996322973;
	float rotation = Hash12(floor(gl_FragCoord.xy)) * (2.0 * PI);
	vec3 accumulatedColor = vec3(0.0);

	for (int index = 0; index < FOXY_DOF_BOKEH_SAMPLES; ++index) {
		float sequence = (float(index) + 0.5) / float(FOXY_DOF_BOKEH_SAMPLES);
		float angle = rotation + float(index) * goldenAngle;
		float apertureRadius = sqrt(sequence);
		#if FOXY_DOF_HEXAGONAL_APERTURE == 1
			float hexSector = mod(angle + PI / 6.0, PI / 3.0) - PI / 6.0;
			apertureRadius *= cos(PI / 6.0) / max(cos(hexSector), 0.25);
		#endif
		vec2 sampleUv = clamp(
			uv + vec2(cos(angle), sin(angle)) * pixelRadius * apertureRadius,
			vec2(0.001),
			vec2(0.999)
		);
		vec3 sampleColor = DecodeSceneColor(
			FinalDofEncodedSampleLod(sampleUv, lodLevel)
		);
		accumulatedColor += max(sampleColor, vec3(0.0));
	}
	return accumulatedColor / float(FOXY_DOF_BOKEH_SAMPLES);
}
#endif

#if FOXY_CAS == 1
vec3 FinalCas(const in vec2 uv, const in vec3 centerColor) {
	vec2 px = SrFullPixelSize();
	vec3 north = DecodeSceneColor(FinalCurrentSceneEncodedSample(uv + vec2(0.0, px.y)));
	vec3 south = DecodeSceneColor(FinalCurrentSceneEncodedSample(uv - vec2(0.0, px.y)));
	vec3 east = DecodeSceneColor(FinalCurrentSceneEncodedSample(uv + vec2(px.x, 0.0)));
	vec3 west = DecodeSceneColor(FinalCurrentSceneEncodedSample(uv - vec2(px.x, 0.0)));
	vec3 localMin = min(centerColor, min(min(north, south), min(east, west)));
	vec3 localMax = max(centerColor, max(max(north, south), max(east, west)));
	vec3 contrast = localMax - localMin;
	vec3 adaptation = vec3(1.0) - Saturate3(contrast / max(localMax + vec3(0.05), vec3(1.0e-4)));
	vec3 laplacian = centerColor * 4.0 - (north + south + east + west);
	vec3 sharpened = centerColor + laplacian * adaptation * (0.04 + FOXY_CAS_STRENGTH * 0.12);
	vec3 guard = contrast * (0.08 + FOXY_CAS_STRENGTH * 0.08) + vec3(1.0e-4);
	return clamp(sharpened, localMin - guard, localMax + guard);
}
#endif

void main() {
	float presentationDither = Bayer16(gl_FragCoord.xy);
	vec2 sceneUv = FinalSceneUv(texcoord);
	vec2 sceneResourceUv = SrSceneSampleUv(sceneUv);
	float depthRaw = texture2D(depthtex0, sceneResourceUv).r;
	Endpoint sceneEndpoint = EndpointUnpack(LoadLayerEndpoint(sceneUv));
	float sceneSurfaceMask = 1.0 - step(FOXY_ENDPOINT_INFINITY * 0.5, sceneEndpoint.rayDistance);
	vec3 centerEncoded = FinalCurrentSceneEncodedSample(texcoord);
	vec3 centerHdr = DecodeSceneColor(centerEncoded);
	vec3 hdr = FinalMotionBlur(texcoord, depthRaw, centerHdr, sceneEndpoint, presentationDither);
	#if FOXY_DOF == 1
		hdr = FinalDepthOfField(texcoord, depthRaw, hdr);
	#endif
	#if FOXY_CAS == 1
		hdr = FinalCas(texcoord, hdr);
	#endif
	vec3 finalVolumeScatter = vec3(0.0);
	#if FOXY_VOLUMETRIC_LIGHT == 1
		vec4 volume = VolumeBufferSample(texcoord);
		vec3 volumeScatter = max(volume.rgb, vec3(0.0));
		finalVolumeScatter = volumeScatter;
	#endif
	vec2 px = SrFullPixelSize();
	float autoExposure = finalVertexExposure;
	float finalSunAltitude = presentationSunAltitude;
	float finalNightAdaptation = 1.0 - smoothstep(-0.105, 0.035, finalSunAltitude);
	float purkinjeSkyMask = step(0.99999, depthRaw) * (1.0 - sceneSurfaceMask);
	if (purkinjeSkyMask > 0.0) {
		float purkinjeEyeSky = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
		vec3 shiftedSky = ApplyPurkinjeVision(hdr, finalSunAltitude, 0.0, 1.0, purkinjeEyeSky);
		hdr = mix(hdr, shiftedSky, purkinjeSkyMask);
	}
	vec3 bloom = vec3(0.0);
	float bloomLuma = 0.0;
	vec3 graded = hdr;
	bloom = FinalBloom(texcoord, px);
	bloomLuma = Luma(bloom);
	float screenVignette = Saturate(1.20 - dot(texcoord - vec2(0.5), texcoord - vec2(0.5)) * 1.35);
	float atmosphereBloom = mix(0.82, 1.30, AtmosphereStyleWarp());
	float bloomHaze = Saturate(FOXY_BLOOM_STRENGTH * atmosphereBloom * (0.10 + bloomLuma * 0.42) * screenVignette);
	vec3 bloomFogTarget = hdr + max(bloom - hdr * 0.10, vec3(0.0)) * 0.52;
	bloom *= FOXY_BLOOM_STRENGTH * atmosphereBloom * mix(0.38, 0.62, Saturate(bloomLuma * 0.30)) * screenVignette;
	float bloomFog = FOXY_BLOOM_FOG * smoothstep(0.995, 1.0, depthRaw) * (1.0 - sceneSurfaceMask) * (0.35 + rainStrength * 0.50);
	bloom *= 1.0 + bloomFog;
	graded = mix(hdr, bloomFogTarget, bloomHaze) + bloom;
	if (isEyeInWater == 1) {
		vec3 underwaterBloom = bloom * (1.55 + Saturate(FOXY_WATER_FOG) * 1.10);
		float underwaterBloomHaze = Saturate((0.22 + bloomLuma * 0.58) * FOXY_BLOOM_STRENGTH * (0.72 + FOXY_WATER_UNDERWATER * 0.68));
		graded = mix(graded, graded + underwaterBloom, underwaterBloomHaze);
		float waterAmount = Saturate(FOXY_WATER_UNDERWATER);
		float waterFogStrength = Saturate(FOXY_WATER_FOG);
		vec3 viewPos = EndpointViewPosition(
			sceneEndpoint,
			texcoord,
			depthRaw,
			gbufferProjectionInverse
		);
		float sceneHit = max(
			1.0 - step(0.99999, depthRaw),
			sceneSurfaceMask
		);
		float viewDistance = mix(64.0, length(viewPos), sceneHit);
		vec3 upView = vertexUpView;
		vec3 sunView = vertexSunView;
		vec3 moonView = vertexMoonView;
		float sunAltitude = vertexSunAltitude;
		float moonAltitude = vertexMoonAltitude;
		float twilight = TwilightFactor(sunAltitude);
		vec3 sunColor = vertexSunLightColor;
		vec3 moonColor = vertexMoonLightColor;
		float sunRainScale = mix(1.0, 0.35, rainStrength);
		vec3 timeFog = FogColorFromClearSunColor(sunAltitude, rainStrength, sunColor / max(sunRainScale, 1.0e-4));
		vec3 viewDir = normalize(viewPos);
		float viewUp = dot(viewDir, upView);
		float surfaceDepth = max(waterEnteredAltitude - cameraPosition.y, 0.35);
		float upwardSurfacePath = surfaceDepth / max(viewUp, 0.12);
		float skyWaterPath = mix(34.0, upwardSurfacePath, smoothstep(0.45, 0.72, viewUp));
		float waterPath = mix(skyWaterPath, viewDistance, sceneHit);
		waterPath = min(waterPath, mix(42.0, 64.0, 1.0 - waterFogStrength));
		waterPath *= mix(0.92, 1.28, waterFogStrength) * mix(0.85, 1.20, waterAmount);
		vec3 extinction = FinalWaterExtinction(waterFogStrength);
		vec3 transmittance = exp(-extinction * max(waterPath, 0.0));
		float waterOcclusion = Saturate(1.0 - max(max(transmittance.r, transmittance.g), transmittance.b));
		float day = smoothstep(-0.10, 0.20, sunAltitude);
		float skyEye = Saturate(float(eyeBrightnessSmooth.y) / 240.0);
		float blockEye = Saturate(float(eyeBrightnessSmooth.x) / 240.0);
		float solarDiscVisibility = SolarDiscVisibility(sunAltitude);
		vec3 activeLightView = mix(moonView, sunView, step(0.01, solarDiscVisibility));
		float mu = dot(activeLightView, viewDir);
		float phase = FinalWaterHgPhase(mu, 0.42) * 0.72 + (1.0 / (4.0 * PI)) * 0.28;
		vec3 activeLightColor = sunColor * solarDiscVisibility + moonColor * (1.0 - solarDiscVisibility);
		vec3 ambientWater = (vertexSkyAmbientColor + MoonAmbientColorFromMoonColor(moonColor)) * (0.16 + skyEye * 0.78);
		ambientWater += TorchColor(blockEye) * blockEye * 0.20;
		vec3 directWater = activeLightColor * phase * (0.35 + skyEye * 0.85) * (1.0 - rainStrength * 0.35);
		vec3 waterScatterColor = FinalWaterScatterColor(ambientWater, activeLightColor, mix(max(moonAltitude, 0.0), day, solarDiscVisibility) * skyEye, skyEye, rainStrength);
		vec3 scatterIntegral = (ambientWater * (1.0 / (4.0 * PI)) + directWater) * (vec3(1.0) - transmittance);
		scatterIntegral *= vec3(0.010) / max(extinction, vec3(1.0e-4));
		scatterIntegral += waterScatterColor * waterOcclusion * (0.42 + day * 0.16);
		vec3 twilightTint = timeFog * mix(vec3(0.10, 0.24, 0.35), vec3(0.46, 0.20, 0.08), twilight);
		scatterIntegral = mix(scatterIntegral, twilightTint * waterOcclusion, twilight * 0.18);
		scatterIntegral *= mix(0.80, 1.18, waterAmount);
		scatterIntegral += finalVolumeScatter * (0.34 + waterFogStrength * 0.32);
		vec3 mediumColor = graded * mix(vec3(1.0), transmittance, waterAmount) + scatterIntegral * waterAmount;
		float underwaterGlow = Saturate((Luma(scatterIntegral) * 2.8 + bloomLuma * 0.85) * (0.30 + waterOcclusion * 0.88));
		mediumColor = mix(mediumColor, mediumColor + scatterIntegral * 1.85 + underwaterBloom * 0.34, underwaterGlow);
		graded = mediumColor;
	}
	graded = FinalApplyWhiteBalance(graded);
	graded = FinalApplyColorGrade(graded);
	graded *= FinalVignette(texcoord);
	vec3 mapped = LinearToSrgb(TonemapWithExposure(
		graded,
		autoExposure,
		finalNightAdaptation,
		PresentationDayWeight(finalSunAltitude)
	));
	mapped = FinalDither(mapped, presentationDither);
	FinalOutput = vec4(Saturate3(mapped), 1.0);
}
