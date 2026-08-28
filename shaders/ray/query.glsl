#ifndef RAY_QUERY_GLSL
#define RAY_QUERY_GLSL

#define RAY_LOBE_DIFFUSE 0
#define RAY_LOBE_SPECULAR 1
#define RAY_LOBE_TRANSMISSION 2
#define RAY_BACKEND_NONE 0
#define RAY_BACKEND_SCREEN 1
#define RAY_BACKEND_VOXEL 2
#define RAY_BACKEND_SKY 3

struct RayQuery {
	vec3 worldOrigin;
	vec3 worldDirection;
	float maxDistance;
	float coneWidth;
	float roughness;
	int lobe;
};

struct RayHit {
	vec3 worldPosition;
	vec3 worldNormal;
	vec3 albedo;
	vec3 emission;
	vec2 lightmap;
	float surfaceClass;
	float distance;
	float roughness;
	float metalness;
	float validity;
	int backend;
};

RayHit RayHitEmpty() {
	RayHit hit;
	hit.worldPosition = vec3(0.0);
	hit.worldNormal = vec3(0.0, 1.0, 0.0);
	hit.albedo = vec3(0.0);
	hit.emission = vec3(0.0);
	hit.lightmap = vec2(0.0);
	hit.surfaceClass = 0.0;
	hit.distance = 0.0;
	hit.roughness = 1.0;
	hit.metalness = 0.0;
	hit.validity = 0.0;
	hit.backend = RAY_BACKEND_NONE;
	return hit;
}

#endif
