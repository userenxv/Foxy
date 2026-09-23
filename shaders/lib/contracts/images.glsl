#ifndef FOXY_CONTRACT_IMAGES_GLSL
#define FOXY_CONTRACT_IMAGES_GLSL

// Read-only stage declarations use the existing Iris custom-image sampler alias.
// texelFetch preserves FP32 payloads and integer texel selection; no filtering.
// A texture-fetch API barrier must separate the producer from these readers.

ivec2 ContractPixel(const in vec2 uv, const in ivec2 size) {
	ivec2 safeSize = max(size, ivec2(1));
	vec2 clampedUv = clamp(uv, vec2(0.0), vec2(0.999999));
	return clamp(ivec2(floor(clampedUv * vec2(safeSize))), ivec2(0), safeSize - ivec2(1));
}

#if defined(FOXY_IMAGE_OPAQUE_ENDPOINT_CURRENT)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_OPAQUE_ENDPOINT_CURRENT)
uniform sampler2D opaqueEndpointCurrent;
vec4 LoadOpaqueEndpoint(const in vec2 uv) {
	return texelFetch(opaqueEndpointCurrent, ContractPixel(uv, textureSize(opaqueEndpointCurrent, 0)), 0);
}
#else
layout(rgba32f) coherent uniform image2D imgOpaqueEndpointCurrent;

vec4 LoadOpaqueEndpoint(const in vec2 uv) {
	return imageLoad(imgOpaqueEndpointCurrent, ContractPixel(uv, imageSize(imgOpaqueEndpointCurrent)));
}

void StoreOpaqueEndpoint(const in vec2 uv, const in vec4 value) {
	imageStore(imgOpaqueEndpointCurrent, ContractPixel(uv, imageSize(imgOpaqueEndpointCurrent)), value);
}
#endif
#endif

#if defined(FOXY_IMAGE_LAYER_ENDPOINT_PING_PONG)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_LAYER_ENDPOINT_PING_PONG)
uniform sampler2D layerEndpointCurrent;
uniform sampler2D layerEndpointPrevious;
bool LayerEndpointCurrentUsesPrimary() {
	return (frameCounter & 1) == 0;
}
vec4 LoadLayerEndpoint(const in vec2 uv) {
	if (LayerEndpointCurrentUsesPrimary()) {
		return texelFetch(layerEndpointCurrent, ContractPixel(uv, textureSize(layerEndpointCurrent, 0)), 0);
	}
	return texelFetch(layerEndpointPrevious, ContractPixel(uv, textureSize(layerEndpointPrevious, 0)), 0);
}
vec4 LoadLayerEndpointPrevious(const in vec2 uv) {
	if (LayerEndpointCurrentUsesPrimary()) {
		return texelFetch(layerEndpointPrevious, ContractPixel(uv, textureSize(layerEndpointPrevious, 0)), 0);
	}
	return texelFetch(layerEndpointCurrent, ContractPixel(uv, textureSize(layerEndpointCurrent, 0)), 0);
}
vec4 LoadCloudEndpoint(const in vec2 uv) {
	return LoadLayerEndpoint(uv);
}
#else
layout(rgba32f) coherent uniform image2D imgLayerEndpointCurrent;
layout(rgba32f) coherent uniform image2D imgLayerEndpointPrevious;

bool LayerEndpointCurrentUsesPrimary() {
	return (frameCounter & 1) == 0;
}

vec4 LoadLayerEndpoint(const in vec2 uv) {
	if (LayerEndpointCurrentUsesPrimary()) {
		return imageLoad(imgLayerEndpointCurrent, ContractPixel(uv, imageSize(imgLayerEndpointCurrent)));
	}
	return imageLoad(imgLayerEndpointPrevious, ContractPixel(uv, imageSize(imgLayerEndpointPrevious)));
}

void StoreLayerEndpoint(const in vec2 uv, const in vec4 value) {
	if (LayerEndpointCurrentUsesPrimary()) {
		imageStore(imgLayerEndpointCurrent, ContractPixel(uv, imageSize(imgLayerEndpointCurrent)), value);
		return;
	}
	imageStore(imgLayerEndpointPrevious, ContractPixel(uv, imageSize(imgLayerEndpointPrevious)), value);
}

vec4 LoadLayerEndpointPrevious(const in vec2 uv) {
	if (LayerEndpointCurrentUsesPrimary()) {
		return imageLoad(imgLayerEndpointPrevious, ContractPixel(uv, imageSize(imgLayerEndpointPrevious)));
	}
	return imageLoad(imgLayerEndpointCurrent, ContractPixel(uv, imageSize(imgLayerEndpointCurrent)));
}

vec4 LoadCloudEndpoint(const in vec2 uv) {
	return LoadLayerEndpoint(uv);
}

void StoreCloudEndpoint(const in vec2 uv, const in vec4 value) {
	StoreLayerEndpoint(uv, value);
}
#endif
#else
	#if defined(FOXY_IMAGE_LAYER_ENDPOINT_CURRENT)
	layout(rgba32f) coherent uniform image2D imgLayerEndpointCurrent;

	vec4 LoadLayerEndpoint(const in vec2 uv) {
		return imageLoad(imgLayerEndpointCurrent, ContractPixel(uv, imageSize(imgLayerEndpointCurrent)));
	}

	void StoreLayerEndpoint(const in vec2 uv, const in vec4 value) {
		imageStore(imgLayerEndpointCurrent, ContractPixel(uv, imageSize(imgLayerEndpointCurrent)), value);
	}

	vec4 LoadCloudEndpoint(const in vec2 uv) {
		return LoadLayerEndpoint(uv);
	}

	void StoreCloudEndpoint(const in vec2 uv, const in vec4 value) {
		StoreLayerEndpoint(uv, value);
	}
	#endif

	#if defined(FOXY_IMAGE_LAYER_ENDPOINT_PREVIOUS)
	layout(rgba32f) coherent uniform image2D imgLayerEndpointPrevious;

	vec4 LoadLayerEndpointPrevious(const in vec2 uv) {
		return imageLoad(imgLayerEndpointPrevious, ContractPixel(uv, imageSize(imgLayerEndpointPrevious)));
	}
	#endif
#endif

#if defined(FOXY_IMAGE_WATER_SEGMENT_CURRENT)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_WATER_SEGMENT_CURRENT)
uniform sampler2D waterSegmentCurrent;
vec4 LoadWaterSegment(const in vec2 uv) {
	return texelFetch(waterSegmentCurrent, ContractPixel(uv, textureSize(waterSegmentCurrent, 0)), 0);
}
#else
layout(rgba32f) coherent uniform image2D imgWaterSegmentCurrent;

vec4 LoadWaterSegment(const in vec2 uv) {
	return imageLoad(imgWaterSegmentCurrent, ContractPixel(uv, imageSize(imgWaterSegmentCurrent)));
}

void StoreWaterSegment(const in vec2 uv, const in vec4 value) {
	imageStore(imgWaterSegmentCurrent, ContractPixel(uv, imageSize(imgWaterSegmentCurrent)), value);
}
#endif
#endif

#if defined(FOXY_IMAGE_MAIN_WATER_PRODUCER_CURRENT)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_MAIN_WATER_PRODUCER_CURRENT)
uniform sampler2D mainWaterProducerCurrent;
vec4 LoadMainWaterProducer(const in vec2 uv) {
	return texelFetch(mainWaterProducerCurrent, ContractPixel(uv, textureSize(mainWaterProducerCurrent, 0)), 0);
}
#else
layout(rgba32f) coherent uniform image2D imgMainWaterProducerCurrent;

vec4 LoadMainWaterProducer(const in vec2 uv) {
	return imageLoad(imgMainWaterProducerCurrent, ContractPixel(uv, imageSize(imgMainWaterProducerCurrent)));
}

void StoreMainWaterProducer(const in vec2 uv, const in vec4 value) {
	imageStore(imgMainWaterProducerCurrent, ContractPixel(uv, imageSize(imgMainWaterProducerCurrent)), value);
}
#endif
#endif

#if defined(FOXY_IMAGE_LOD_WATER_PRODUCER_CURRENT)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_LOD_WATER_PRODUCER_CURRENT)
uniform sampler2D lodWaterProducerCurrent;
vec4 LoadLodWaterProducer(const in vec2 uv) {
	return texelFetch(lodWaterProducerCurrent, ContractPixel(uv, textureSize(lodWaterProducerCurrent, 0)), 0);
}
#else
layout(rgba32f) coherent uniform image2D imgLodWaterProducerCurrent;

vec4 LoadLodWaterProducer(const in vec2 uv) {
	return imageLoad(imgLodWaterProducerCurrent, ContractPixel(uv, imageSize(imgLodWaterProducerCurrent)));
}

void StoreLodWaterProducer(const in vec2 uv, const in vec4 value) {
	imageStore(imgLodWaterProducerCurrent, ContractPixel(uv, imageSize(imgLodWaterProducerCurrent)), value);
}
#endif
#endif

#if defined(FOXY_IMAGE_CLOUD_LAYER_CURRENT)
#if FOXY_SEMANTIC_TEXTURE_READS == 1 && defined(FOXY_READ_ONLY_CLOUD_LAYER_CURRENT)
uniform sampler2D cloudLayerCurrent;
ivec2 CloudLayerSize() {
	return max(textureSize(cloudLayerCurrent, 0), ivec2(1));
}
vec4 LoadCloudLayer(const in vec2 uv) {
	return texelFetch(cloudLayerCurrent, ContractPixel(uv, CloudLayerSize()), 0);
}
#else
layout(rgba32f) coherent uniform image2D imgCloudLayerCurrent;

ivec2 CloudLayerSize() {
	return max(imageSize(imgCloudLayerCurrent), ivec2(1));
}

vec4 LoadCloudLayer(const in vec2 uv) {
	return imageLoad(imgCloudLayerCurrent, ContractPixel(uv, CloudLayerSize()));
}

void StoreCloudLayer(const in vec2 uv, const in vec4 value) {
	imageStore(imgCloudLayerCurrent, ContractPixel(uv, CloudLayerSize()), value);
}
#endif
#endif

#endif
