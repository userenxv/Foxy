#ifndef FOXY_BACKEND_GLSL
#define FOXY_BACKEND_GLSL

#include "/lib/settings.glsl"

#define FOXY_BACKEND_DOMAIN_MAIN 1.0
#define FOXY_BACKEND_DOMAIN_DH 2.0
#define FOXY_BACKEND_DOMAIN_VOXY 3.0

#if defined(VOXY)
#if !defined(FOXY_EXTERNAL_PIPELINE_BINDINGS)
uniform vec2 taa_offset;
#endif

float BackendVoxyRenderScale() {
	float renderScale = 1.0;
#if FOXY_TAAU_ACTIVE == 1
	renderScale = max(FOXY_TAAU_RENDER_SCALE, 1.0e-6);
#endif
	return renderScale;
}

vec2 BackendVoxyJitterUv() {
#if FOXY_TEMPORAL_JITTER_ACTIVE == 1

return taa_offset * (0.5 / BackendVoxyRenderScale());
#else
	return vec2(0.0);
#endif
}

vec2 BackendVoxyRasterUvFromViewUv(const in vec2 viewUv) {
	return viewUv + BackendVoxyJitterUv();
}

vec2 BackendVoxyViewUvFromRasterUv(const in vec2 rasterUv) {
	return rasterUv - BackendVoxyJitterUv();
}

vec2 BackendVoxyViewUvFromSceneResourceUv(const in vec2 sampleUv) {
	return clamp(sampleUv / BackendVoxyRenderScale(), vec2(0.0), vec2(0.999999));
}

vec2 BackendVoxyDepthViewUv(const in vec2 sampleUv) {
	return BackendVoxyViewUvFromSceneResourceUv(sampleUv);
}
#endif

#if defined(VOXY)
uniform sampler2D vxDepthTexTrans;
uniform sampler2D vxDepthTexOpaque;
uniform mat4 vxModelView;
uniform mat4 vxModelViewInv;
uniform mat4 vxProj;
uniform mat4 vxProjInv;
uniform mat4 vxProjPrev;
uniform int vxRenderDistance;
#define FOXY_BACKEND_HAS_VOXY 1
#else
#define FOXY_BACKEND_HAS_VOXY 0
#endif

#if FOXY_BACKEND_HAS_VOXY == 0 && FOXY_DH_ACTIVE == 1
#if defined(DISTANT_HORIZONS) || defined(LOD_MOD_ACTIVE)
uniform sampler2D dhDepthTex0;
uniform sampler2D dhDepthTex1;
uniform mat4 dhProjectionInverse;
uniform mat4 dhPreviousProjection;
uniform int dhRenderDistance;
#define FOXY_BACKEND_HAS_DH 1
#else
#define FOXY_BACKEND_HAS_DH 0
#endif
#else
#define FOXY_BACKEND_HAS_DH 0
#endif

float BackendLodFrontRaw(const in vec2 sampleUv) {
#if FOXY_BACKEND_HAS_VOXY == 1
	ivec2 size = max(textureSize(vxDepthTexTrans, 0), ivec2(1));
	vec2 viewUv = BackendVoxyViewUvFromSceneResourceUv(sampleUv);
	ivec2 texel = clamp(ivec2(floor(viewUv * vec2(size))), ivec2(0), size - ivec2(1));
	return texelFetch(vxDepthTexTrans, texel, 0).r;
#elif FOXY_BACKEND_HAS_DH == 1
	ivec2 size = max(textureSize(dhDepthTex0, 0), ivec2(1));
	ivec2 texel = clamp(ivec2(floor(clamp(sampleUv, vec2(0.0), vec2(0.999999)) * vec2(size))), ivec2(0), size - ivec2(1));
	return texelFetch(dhDepthTex0, texel, 0).r;
#else
	return 1.0;
#endif
}

float BackendLodSolidRaw(const in vec2 sampleUv) {
#if FOXY_BACKEND_HAS_VOXY == 1
	ivec2 size = max(textureSize(vxDepthTexOpaque, 0), ivec2(1));
	vec2 viewUv = BackendVoxyViewUvFromSceneResourceUv(sampleUv);
	ivec2 texel = clamp(ivec2(floor(viewUv * vec2(size))), ivec2(0), size - ivec2(1));
	return texelFetch(vxDepthTexOpaque, texel, 0).r;
#elif FOXY_BACKEND_HAS_DH == 1
	ivec2 size = max(textureSize(dhDepthTex1, 0), ivec2(1));
	ivec2 texel = clamp(ivec2(floor(clamp(sampleUv, vec2(0.0), vec2(0.999999)) * vec2(size))), ivec2(0), size - ivec2(1));
	return texelFetch(dhDepthTex1, texel, 0).r;
#else
	return 1.0;
#endif
}

vec3 BackendLodViewPosition(
	const in vec2 viewUv,
	const in float rawDepth
) {
	#if FOXY_BACKEND_HAS_VOXY == 1

vec2 projectionUv = BackendVoxyViewUvFromRasterUv(viewUv);
		vec4 clip = vec4(projectionUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
		vec4 view = vxProjInv * clip;
		float safeW = abs(view.w) < 1.0e-6
			? (view.w < 0.0 ? -1.0e-6 : 1.0e-6)
			: view.w;
		return view.xyz / safeW;
	#elif FOXY_BACKEND_HAS_DH == 1
	vec4 clip = vec4(viewUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
	vec4 view = dhProjectionInverse * clip;
	float safeW = abs(view.w) < 1.0e-6
		? (view.w < 0.0 ? -1.0e-6 : 1.0e-6)
		: view.w;
	return view.xyz / safeW;
#else
	return vec3(0.0);
#endif
}

vec3 BackendLodViewRay(const in vec2 viewUv) {
	#if FOXY_BACKEND_HAS_VOXY == 1 || FOXY_BACKEND_HAS_DH == 1
		return normalize(BackendLodViewPosition(viewUv, 1.0));
#else
	return vec3(0.0, 0.0, -1.0);
	#endif
}

vec3 BackendLodViewToMainView(
	const in vec3 lodViewPosition,
	const in mat4 mainModelView
) {
	#if FOXY_BACKEND_HAS_VOXY == 1
		vec3 playerPosition = (vxModelViewInv * vec4(lodViewPosition, 1.0)).xyz;
		return (mainModelView * vec4(playerPosition, 1.0)).xyz;
	#else
		return lodViewPosition;
	#endif
}

vec3 BackendLodViewNormalToMainView(
	const in vec3 lodViewNormal,
	const in mat4 mainModelView
) {
	#if FOXY_BACKEND_HAS_VOXY == 1
		vec3 playerNormal = mat3(vxModelViewInv) * lodViewNormal;
		return normalize(mat3(mainModelView) * playerNormal);
	#else
		return normalize(lodViewNormal);
	#endif
}

vec4 BackendLodPreviousClip(const in vec4 previousViewPosition) {
	#if FOXY_BACKEND_HAS_VOXY == 1
		return vxProjPrev * previousViewPosition;
	#elif FOXY_BACKEND_HAS_DH == 1
	return dhPreviousProjection * previousViewPosition;
#else
	return previousViewPosition;
#endif
}

float BackendRenderDistance() {
	#if FOXY_BACKEND_HAS_VOXY == 1
		return max(float(vxRenderDistance) * 16.0, 0.0);
	#elif FOXY_BACKEND_HAS_DH == 1
	return max(float(dhRenderDistance), 0.0);
#else
	return 0.0;
#endif
}

float BackendDomain() {
	#if FOXY_BACKEND_HAS_VOXY == 1
		return FOXY_BACKEND_DOMAIN_VOXY;
	#elif FOXY_BACKEND_HAS_DH == 1
	return FOXY_BACKEND_DOMAIN_DH;
#else
	return FOXY_BACKEND_DOMAIN_MAIN;
#endif
}

bool BackendHasLodSurface(const in float rawDepth) {
	return rawDepth < 0.99999;
}

struct BackendOpaqueSurface {
	vec3 viewPosition;
	float rawDepth;
	float domain;
	float valid;
};

vec3 BackendMainViewPosition(
	const in vec2 viewUv,
	const in float rawDepth,
	const in mat4 mainProjectionInverse
) {
	vec4 clip = vec4(viewUv * 2.0 - 1.0, rawDepth * 2.0 - 1.0, 1.0);
	vec4 view = mainProjectionInverse * clip;
	float safeW = abs(view.w) < 1.0e-6
		? (view.w < 0.0 ? -1.0e-6 : 1.0e-6)
		: view.w;
	return view.xyz / safeW;
}

BackendOpaqueSurface BackendResolveOpaqueSurface(
	const in vec2 viewUv,
	const in vec2 sampleUv,
	const in float mainRawDepth,
	const in mat4 mainProjectionInverse
) {
	BackendOpaqueSurface surface;
	surface.viewPosition = vec3(0.0);
	surface.rawDepth = 1.0;
	surface.domain = FOXY_BACKEND_DOMAIN_MAIN;
	surface.valid = 0.0;
	if (mainRawDepth < 0.99999) {
		surface.viewPosition = BackendMainViewPosition(
			viewUv,
			mainRawDepth,
			mainProjectionInverse
		);
		surface.rawDepth = mainRawDepth;
		surface.valid = 1.0;
		return surface;
	}

#if FOXY_BACKEND_HAS_VOXY == 1 || FOXY_BACKEND_HAS_DH == 1
	float lodRawDepth = BackendLodSolidRaw(sampleUv);
	if (BackendHasLodSurface(lodRawDepth)) {
		vec2 lodViewUv = viewUv;
		#if FOXY_BACKEND_HAS_VOXY == 1
			lodViewUv = BackendVoxyDepthViewUv(sampleUv);
		#endif
		surface.viewPosition = BackendLodViewPosition(lodViewUv, lodRawDepth);
		surface.rawDepth = lodRawDepth;
		surface.domain = BackendDomain();
		surface.valid = 1.0;
	}
#endif
	return surface;
}

#endif
