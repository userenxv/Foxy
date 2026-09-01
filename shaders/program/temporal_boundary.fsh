#include "/lib/settings.glsl"
#include "/lib/math.glsl"

uniform sampler2D colortex0;
uniform sampler2D colortex3;
uniform sampler2D colortex14;
#if FOXY_TAA_ENABLED == 1
uniform sampler2D colortex2;
uniform sampler2D colortex12;
uniform sampler2D depthtex0;
uniform sampler2D depthtex1;
uniform mat4 gbufferProjectionInverse;
uniform mat4 gbufferModelViewInverse;
uniform mat4 gbufferPreviousModelView;
uniform mat4 gbufferPreviousProjection;
uniform vec3 cameraPosition;
uniform vec3 previousCameraPosition;
uniform float far;
#endif
uniform float viewWidth;
uniform float viewHeight;
uniform int frameCounter;
uniform vec2 temporalJitter;
#if FOXY_TAA_ENABLED == 1
uniform vec2 previousTemporalJitter;
#endif

varying vec2 texcoord;

#include "/lib/sr.glsl"
#include "/lib/contracts/endpoint.glsl"
#define FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG
#define FOXY_IMAGE_WATER_SEGMENT_CURRENT
#include "/lib/contracts/images.glsl"
#if FOXY_TAA_ENABLED == 1
	#include "/lib/taa_slot_contract.glsl"
	#include "/features/taa/resolve/native_temporal.glsl"
#else
	#include "/features/taa/resolve/bypass.glsl"
#endif

vec2 TemporalCurrentRasterUv(const in vec2 viewUv) {
	#if FOXY_TEMPORAL_JITTER_ACTIVE == 1
		return viewUv + temporalJitter * 0.5;
	#else
		return viewUv;
	#endif
}

Endpoint TemporalPresentationEndpoint(const in vec2 viewUv) {

	vec2 endpointRenderUv = SrSceneSampleUv(viewUv);
	Endpoint endpoint = EndpointUnpack(LoadLayerEndpoint(endpointRenderUv));
	vec2 waterRasterUv = TemporalCurrentRasterUv(viewUv);
	vec2 waterRenderUv = SrSceneSampleUv(waterRasterUv);
	WaterSegment water = WaterSegmentUnpack(LoadWaterSegment(waterRenderUv));
	return ResolveWaterEndpoint(
		endpoint,
		water.frontRayDistance,
		water.frontViewDistance,
		water.valid,
		water.owner,
		FOXY_ENDPOINT_MEDIUM_WATER
	);
}

void main() {
	#if FOXY_TAA_ENABLED == 1

		vec3 currentWorld = vec3(0.0);
	#else
		vec2 renderUv = SrSceneSampleUv(texcoord);
		#if FOXY_VOLUMETRIC_LIGHT == 1
			vec3 currentWorld = texture2D(colortex0, renderUv).rgb;
		#else
			vec3 currentWorld = texture2D(colortex14, renderUv).rgb;
		#endif
	#endif
	vec3 resolvedWorld = ResolveTemporalWorldEncoded(texcoord, currentWorld);

	vec2 transientRasterUv = TemporalCurrentRasterUv(texcoord);
	vec4 transientLayer = texture2D(colortex3, SrSceneSampleUv(transientRasterUv));
	float transientAlpha = Saturate(transientLayer.a);
	Endpoint presentationEndpoint = TemporalPresentationEndpoint(texcoord);
	StoreLayerEndpoint(texcoord, EndpointPack(presentationEndpoint));

	vec3 presentation = transientLayer.rgb + resolvedWorld * (1.0 - transientAlpha);
	gl_FragData[0] = vec4(presentation, 1.0);
	#if FOXY_TAA_ENABLED == 1
	gl_FragData[1] = FormalHistoryOutput;
	#endif
}
