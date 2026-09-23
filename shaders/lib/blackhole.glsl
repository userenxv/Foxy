#ifndef FOXY_BLACKHOLE_GLSL
#define FOXY_BLACKHOLE_GLSL

const float BH_MASS     = 0.5;
const float R_ESCAPE    = FOXY_BLACKHOLE_ESCAPE;
const float DISK_OUTER  = FOXY_BLACKHOLE_DISK_OUTER;
const float DISK_FLARE  = FOXY_BLACKHOLE_DISK_FLARE;
const float DISK_MIN_H  = 0.009;
const float DISK_TEMP   = FOXY_BLACKHOLE_DISK_TEMP;
const float DISK_EMIT   = FOXY_BLACKHOLE_DISK_EMIT;
const float DISK_ABSORB = FOXY_BLACKHOLE_DISK_ABSORB;
const float DOPPLER_EXP = FOXY_BLACKHOLE_DOPPLER_EXP;
const int   MAX_STEPS   = 1024;

const float BH_SPIN         = FOXY_BLACKHOLE_SPIN;
const int   BH_STEPS        = FOXY_BLACKHOLE_STEPS;
const float BH_DISK_OPACITY = FOXY_BLACKHOLE_DISK_OPACITY;
const float BH_DOPPLER_MIX  = FOXY_BLACKHOLE_DOPPLER;
const float BH_TURB         = float(FOXY_BLACKHOLE_TURB);
const float BH_FINE_STEP    = float(FOXY_BLACKHOLE_FINE_STEP);
const float BH_TEMP_CONTRAST = FOXY_BLACKHOLE_TEMP_CONTRAST;
const float BH_NO_DISK      = 0.00;
const float BH_FLAT_SHADE   = 0.00;
const float BH_AUTO_ROTATE  = FOXY_BLACKHOLE_AUTO_ROTATE;
const float BH_ORBIT_SPEED  = FOXY_BLACKHOLE_ORBIT_SPEED;
const float BH_ORBIT_NEAR   = FOXY_BLACKHOLE_ORBIT_NEAR;
const float BH_ORBIT_FAR    = FOXY_BLACKHOLE_ORBIT_FAR;

struct Ks {
    float r, r2, f, N, a2, lxn, lyn;
    float invRa2, invR2, invDen, invDen2;
    vec3  l, dr;
};
Ks KsTerms(vec3 x, float a) {
    Ks K;
    float a2  = a * a;
    if (a2 < 1.0e-12) {
        float r2   = max(dot(x, x), 1.0e-12);
        float invR = inversesqrt(r2);
        K.a2      = 0.0;
        K.r2      = r2;
        K.r       = r2 * invR;
        K.f       = 2.0 * BH_MASS * invR;
        K.l       = x * invR;
        K.dr      = K.l;
        return K;
    }
    float b   = dot(x, x) - a2;
    float D   = sqrt(max(b * b + 4.0 * a2 * x.z * x.z, 1e-12));
    K.a2 = a2;
    K.r2 = max(0.5 * (b + D), 1e-12);
    K.r  = sqrt(K.r2);
    float ra2 = K.r2 + a2;
    float den = max(K.r2 * K.r2 + a2 * x.z * x.z, 1e-12);
    float invD = 1.0 / D, invR = 1.0 / K.r, invDen = 1.0 / den;
    K.invRa2  = 1.0 / ra2;
    K.invR2   = invR * invR;
    K.invDen  = invDen;
    K.invDen2 = invDen * invDen;
    K.f   = 2.0 * BH_MASS * K.r2 * K.r * invDen;
    K.N   = 2.0 * BH_MASS * K.r2 * K.r;
    K.lxn = K.r * x.x + a * x.y;
    K.lyn = K.r * x.y - a * x.x;
    K.l   = vec3(K.lxn * K.invRa2, K.lyn * K.invRa2, x.z * invR);
    K.dr  = vec3(x.x * (1.0 + b * invD), x.y * (1.0 + b * invD),
                 x.z * (1.0 + (b + 2.0 * a2) * invD)) * (0.5 * invR);
    return K;
}
vec3 GradVector(vec3 x, vec3 p, Ks K, float S, float a) {
    if (K.a2 < 1.0e-12) {
        float invR = inversesqrt(K.r2);
        float inv3 = invR * invR * invR;
        vec3 df    = (-2.0 * BH_MASS * inv3) * x;
        vec3 inner = invR * p - (dot(x, p) * inv3) * x;
        return S * (0.5 * S * df + K.f * inner);
    }
    vec3 dri  = K.dr;
    vec3 dden = 4.0 * K.r2 * K.r * dri + 2.0 * K.a2 * x.z * vec3(0.0, 0.0, dri.z);
    vec3 df   = 6.0 * BH_MASS * K.r2 * dri * K.invDen - K.N * dden * K.invDen2;
    vec3 k    = (2.0 * K.r * K.invRa2 * K.invRa2) * dri;
    vec3 dlx  = (dri * x.x + vec3(K.r, a, 0.0)) * K.invRa2 - K.lxn * k;
    vec3 dly  = (dri * x.y + vec3(-a, K.r, 0.0)) * K.invRa2 - K.lyn * k;
    vec3 dlz  = (vec3(0.0, 0.0, K.r) - x.z * dri) * K.invR2;
    return S * (0.5 * S * df + K.f * (dlx * p.x + dly * p.y + dlz * p.z));
}
void Rhs(vec3 x, vec3 p, float pt, float a, out vec3 dx, out vec3 dp, out Ks K) {
    K = KsTerms(x, a);
    float S = dot(K.l, p) - pt;
    dx = p - K.f * S * K.l;
    dp = GradVector(x, p, K, S, a);
}
void Rk4(inout vec3 x, inout vec3 p, float pt, float a, float dl, vec3 k1x, vec3 k1p) {
    Ks Kd; vec3 k2x, k2p, k3x, k3p, k4x, k4p;
    Rhs(x + 0.5 * dl * k1x, p + 0.5 * dl * k1p, pt, a, k2x, k2p, Kd);
    Rhs(x + 0.5 * dl * k2x, p + 0.5 * dl * k2p, pt, a, k3x, k3p, Kd);
    Rhs(x +       dl * k3x, p +       dl * k3p, pt, a, k4x, k4p, Kd);
    x += (dl / 6.0) * (k1x + 2.0 * k2x + 2.0 * k3x + k4x);
    p += (dl / 6.0) * (k1p + 2.0 * k2p + 2.0 * k3p + k4p);
}

float IscoRadius(float a) {
    if (a * a < 1.0e-12) {
        return 6.0 * BH_MASS;
    }
    float ap = clamp(a / BH_MASS, 0.0, 0.999999);
    float c  = pow(1.0 - ap * ap, 1.0 / 3.0);
    float z1 = 1.0 + c * (pow(1.0 + ap, 1.0 / 3.0) + pow(1.0 - ap, 1.0 / 3.0));
    float z2 = sqrt(3.0 * ap * ap + z1 * z1);
    return BH_MASS * (3.0 + z2 - sqrt(max((3.0 - z1) * (3.0 + z1 + 2.0 * z2), 0.0)));
}
float DiskTemperature(float r, float rin) {
    float x = rin / r;
    if (x >= 1.0) return 0.0;
    float sx  = sqrt(x);
    float x75 = sx * sqrt(sx);
    float q   = max(1.0 - sx, 0.0);
    return x75 * sqrt(sqrt(q)) / 0.4879;
}
float KeplerOmega(float r, float a) {
    float sM = sqrt(BH_MASS);
    return sM / (r * sqrt(r) + a * sM);
}
float Redshift(float r, float E, float Lz, float a) {
    float om  = KeplerOmega(r, a);
    float gtt = -(1.0 - 2.0 * BH_MASS / r);
    float gtp = -2.0 * BH_MASS * a / r;
    float gpp = r * r + a * a + 2.0 * BH_MASS * a * a / r;
    float den = max(-(gtt + 2.0 * om * gtp + om * om * gpp), 1e-4);
    float ut  = inversesqrt(den);
    float Eemit = max(ut * (E - om * Lz), 1e-3);
    return clamp(E / Eemit, 0.05, 3.5);
}

float ErfApprox(float x) {
    float ax = abs(x);
    float t = 1.0 / (1.0 + 0.3275911 * ax);
    float p = t * (0.254829592 + t * (-0.284496736 + t * (1.421413741
            + t * (-1.453152027 + t * 1.061405429))));
    return sign(x) * (1.0 - p * exp(-ax * ax));
}
float GaussStepAvg(float y0, float vy, float dl, float H) {
    float inv = 1.0 / (1.41421356 * H);
    if (abs(vy) * dl < 1.0e-6 * H) return exp(-0.5 * (y0 / H) * (y0 / H));
    float dE = ErfApprox((y0 + vy * dl) * inv) - ErfApprox(y0 * inv);
    return dE * (1.25331414 * H) / (vy * dl);
}

float BhHash12(vec2 p) {
    uvec2 i = uvec2(floor(p) + 4096.0);
    uint n = i.x * 374761393u + i.y * 668265263u;
    n = (n ^ (n >> 13u)) * 1274126177u;
    n ^= n >> 16u;
    return float(n & 0x00ffffffu) / 16777216.0;
}
float BhHash13(vec3 p) {
    uvec3 i = uvec3(floor(p) + 4096.0);
    uint n = i.x * 374761393u + i.y * 668265263u + i.z * 3057644241u;
    n = (n ^ (n >> 13u)) * 1274126177u;
    n ^= n >> 16u;
    return float(n & 0x00ffffffu) / 16777216.0;
}
float VnoiseWrapY(vec2 p, float perY) {
    vec2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    float y0 = mod(i.y, perY), y1 = mod(i.y + 1.0, perY);
    return mix(mix(BhHash12(vec2(i.x, y0)),     BhHash12(vec2(i.x + 1.0, y0)),     f.x),
               mix(BhHash12(vec2(i.x, y1)),     BhHash12(vec2(i.x + 1.0, y1)),     f.x), f.y);
}

uniform sampler3D diskNoiseVolume;

const float BH_TURB_BAND_CELLS = 3.0;    // finest is 8x this
const float BH_TURB_TEX_STD    = 0.22;   // spread baked into the channels
const float BH_TURB_SIGMA      = 0.20;   // spread handed to the shaping step
const float BH_TURB_SHAPE      = 2.2;    // shaping window, in standard deviations
const float BH_TURB_AZ         = 2.0;    // azimuthal repeats per turn at scale 1
const float BH_TURB_RADIAL     = 0.95;   // radial repeats per e-fold of r at scale 1
const float BH_TURB_SPIRAL     = -0.33;
const float BH_TURB_VERT       = 0.012;
const float BH_TURB_EMIS_LO    = 0.20;   // emission multiplier in the voids
const float BH_TURB_EMIS_HI    = 1.90;   // ... and on the filaments
const float BH_TURB_DENS_LO    = 0.60;   // optical depth multiplier in the voids
const float BH_TURB_DENS_HI    = 1.40;   // ... and on the filaments

const int   BH_TURB_LAYERS       = 4;    // rigid rate tiers
const float BH_TURB_INNER_PERIOD = 10.0; // seconds per turn at the a=0 anchor radius
const float BH_TURB_ANCHOR_RADIUS = 1.36111111 * 6.0 * BH_MASS; // 49/36 r_in at a=0
const float BH_TURB_BLEND_WIDTH  = 0.15; // tier transition half-width, in tier units
const float BH_TURB_LAYER_RADIAL = 0.60; // outermost tier: radial frequency multiplier

const float BH_DISK_STEP_LOD   = 180.0 / float(BH_STEPS);

float BhTurbBand(const in float footprint, const in float cells) {
    return 1.0 - smoothstep(0.30, 0.50, footprint * cells);
}

void BhTurbAccum(
    const in float channel,
    const in float amplitude,
    const in float weight,
    inout float dev,
    inout float asq
) {
    float t = amplitude * weight;
    dev += t * (channel - 0.5);
    asq += t * t;
}

vec2 BhTurbPattern(const in vec3 u, const in float fp) {
    vec4 v1 = texture3D(diskNoiseVolume, u);

    float dev = 0.0;
    float asq = 0.0;
    BhTurbAccum(v1.r, 1.000, BhTurbBand(fp, BH_TURB_BAND_CELLS),       dev, asq);
    BhTurbAccum(v1.g, 0.780, BhTurbBand(fp, BH_TURB_BAND_CELLS * 2.0), dev, asq);
    #if FOXY_BLACKHOLE_EROSION == 1
    vec4 v2 = texture3D(diskNoiseVolume, fract(u * 2.0 + 0.37));
    BhTurbAccum(v1.b, 0.610, BhTurbBand(fp, BH_TURB_BAND_CELLS * 4.0),  dev, asq);
    BhTurbAccum(v1.a, 0.475, BhTurbBand(fp, BH_TURB_BAND_CELLS * 8.0),  dev, asq);
    BhTurbAccum(v2.r, 0.780, BhTurbBand(fp, BH_TURB_BAND_CELLS * 2.0),  dev, asq);
    BhTurbAccum(v2.g, 0.610, BhTurbBand(fp, BH_TURB_BAND_CELLS * 4.0),  dev, asq);
    BhTurbAccum(v2.b, 0.475, BhTurbBand(fp, BH_TURB_BAND_CELLS * 8.0),  dev, asq);
    BhTurbAccum(v2.a, 0.370, BhTurbBand(fp, BH_TURB_BAND_CELLS * 16.0), dev, asq);
    #endif

    float n = 0.5 + dev * (BH_TURB_SIGMA / (BH_TURB_TEX_STD * sqrt(max(asq, 1.0e-6))));

    float d = smoothstep(0.5 - BH_TURB_SHAPE * BH_TURB_SIGMA,
                         0.5 + BH_TURB_SHAPE * BH_TURB_SIGMA, n);

    return vec2(BH_TURB_EMIS_LO + (BH_TURB_EMIS_HI - BH_TURB_EMIS_LO) * d,
                BH_TURB_DENS_LO + (BH_TURB_DENS_HI - BH_TURB_DENS_LO) * d);
}

float BhTurbAzReps(const in float scale) {
    return max(1.0, floor(BH_TURB_AZ * scale + 0.5));
}

float BhTurbTierSpan() {
    return max(float(BH_TURB_LAYERS - 1), 1.0);
}

float BhTurbTierCoord(const in float r, const in float rPeak) {
    float lo = log(max(rPeak, 1.0e-4));
    float hi = log(max(DISK_OUTER, rPeak * 1.0001));
    return clamp((log(max(r, 1.0e-4)) - lo) / max(hi - lo, 1.0e-6), 0.0, 1.0)
         * BhTurbTierSpan();
}

float BhTurbTierRadius(const in float tier, const in float rPeak) {
    float t = clamp(tier / BhTurbTierSpan(), 0.0, 1.0);
    return rPeak * exp(t * log(max(DISK_OUTER, 1.0e-4) / max(rPeak, 1.0e-4)));
}

float BhTurbTierRate(const in float tier, const in float a, const in float rPeak) {
    float r = BhTurbTierRadius(tier, rPeak);
    float anchor = max(KeplerOmega(BH_TURB_ANCHOR_RADIUS, 0.0), 1.0e-6);
    return KeplerOmega(r, a) / anchor * (1.0 / BH_TURB_INNER_PERIOD);
}

vec3 BhTurbTierUv(
    const in float tier,
    const in float turns,
    const in float lnRS,
    const in float zHS,
    const in float spiralS,
    const in float scale,
    const in float azReps,
    const in float a,
    const in float rPeak,
    const in float bhTime
) {
    float t = clamp(tier / BhTurbTierSpan(), 0.0, 1.0);
    float radialMul = mix(1.0, BH_TURB_LAYER_RADIAL, t);
    float offset = BhHash12(vec2(tier, 3.7));
    float turn = turns + bhTime * BhTurbTierRate(tier, a, rPeak);
    return fract(vec3((turn + spiralS) * azReps,
                      zHS * BH_TURB_VERT * scale + offset,
                      lnRS * BH_TURB_RADIAL * radialMul * scale + offset));
}

float BhTurbTierFootprint(
    const in float tier,
    const in float dPhi,
    const in float dLnR,
    const in float dz,
    const in float scale,
    const in float azReps
) {
    float t = clamp(tier / BhTurbTierSpan(), 0.0, 1.0);
    float radialMul = mix(1.0, BH_TURB_LAYER_RADIAL, t);
    return length(vec3(azReps * (dPhi + BH_TURB_SPIRAL * dLnR),
                       dz * BH_TURB_VERT * scale,
                       dLnR * BH_TURB_RADIAL * radialMul * scale));
}

vec2 DiskTurbulence(vec3 x, vec3 xEnd, float rb, float turns, float a, float bhTime) {
    float rbS = max(rb, 0.05);
    float rbE = sqrt(max(xEnd.x * xEnd.x + xEnd.y * xEnd.y - a * a, 0.0));
    float hS  = max(DISK_FLARE * rb,  DISK_MIN_H);
    float hE  = max(DISK_FLARE * rbE, DISK_MIN_H);
    float scale = FOXY_BLACKHOLE_TURB_SCALE;
    float azReps = BhTurbAzReps(scale);
    float turnsE = atan(xEnd.y, xEnd.x) * 0.15915494;
    float lnRS = log(rbS), lnRE = log(max(rbE, 0.05));
    float zHS  = x.z    / max(hS, 1.0e-4);
    float zHE  = xEnd.z / max(hE, 1.0e-4);

    float dPhi = turnsE - turns;
    dPhi -= floor(dPhi + 0.5);
    float dLnR = lnRE - lnRS;
    float dz = zHE - zHS;
    float spiralS = BH_TURB_SPIRAL * lnRS;

    float rin = max(IscoRadius(a), 1.0e-3);
    float rPeak = rin * 1.36111111;
    float tierCoord = BhTurbTierCoord(rbS, rPeak);
    float tier0 = floor(tierCoord);
    float tier1 = min(tier0 + 1.0, float(BH_TURB_LAYERS - 1));
    float tierBlend = smoothstep(0.5 - BH_TURB_BLEND_WIDTH,
                                 0.5 + BH_TURB_BLEND_WIDTH,
                                 fract(tierCoord));

    if (tierBlend <= 0.001) {
        return BhTurbPattern(
            BhTurbTierUv(tier0, turns, lnRS, zHS, spiralS, scale, azReps, a, rPeak, bhTime),
            BhTurbTierFootprint(tier0, dPhi, dLnR, dz, scale, azReps)
        );
    }
    if (tierBlend >= 0.999) {
        return BhTurbPattern(
            BhTurbTierUv(tier1, turns, lnRS, zHS, spiralS, scale, azReps, a, rPeak, bhTime),
            BhTurbTierFootprint(tier1, dPhi, dLnR, dz, scale, azReps)
        );
    }
    return mix(
        BhTurbPattern(
            BhTurbTierUv(tier0, turns, lnRS, zHS, spiralS, scale, azReps, a, rPeak, bhTime),
            BhTurbTierFootprint(tier0, dPhi, dLnR, dz, scale, azReps)
        ),
        BhTurbPattern(
            BhTurbTierUv(tier1, turns, lnRS, zHS, spiralS, scale, azReps, a, rPeak, bhTime),
            BhTurbTierFootprint(tier1, dPhi, dLnR, dz, scale, azReps)
        ),
        tierBlend
    );
}

vec3 Blackbody(float kelvin) {
    float t = clamp(kelvin, 1000.0, 40000.0) / 100.0;
    float r, g, b;
    if (t <= 66.0) { r = 255.0; g = 99.4708025861 * log(max(t, 1.0)) - 161.1195681661; }
    else { r = 329.698727446 * pow(t - 60.0, -0.1332047592);
           g = 288.1221695283 * pow(t - 60.0, -0.0755148492); }
    if (t >= 66.0) b = 255.0;
    else if (t <= 19.0) b = 0.0;
    else b = 138.5177312231 * log(max(t - 10.0, 1e-3)) - 305.0447927307;
    return clamp(vec3(r, g, b) / 255.0, 0.0, 1.0);
}

vec3 Enrich(vec3 c, float k) {
    float lum = dot(c, vec3(0.2126, 0.7152, 0.0722));
    return max(mix(vec3(lum), c, k), 0.0);
}

#if FOXY_NASA_GALAXY == 1 && defined(FOXY_DIM_END)
uniform sampler2D nasaGalaxy;
vec2 BhGalaxyUv(const in vec3 worldDir) {
    float u = fract(atan(worldDir.x, -worldDir.z) / (2.0 * 3.141592653589793) + 0.5);
    float v = acos(clamp(worldDir.y, -1.0, 1.0)) / 3.141592653589793;
    return vec2(u, v);
}

vec3 BhBackgroundRadiance(const in vec3 worldDir) {
    vec3 galaxy = max(texture2D(nasaGalaxy, BhGalaxyUv(normalize(worldDir))).rgb, vec3(0.0));
    return galaxy * FOXY_BLACKHOLE_GALAXY_EXPOSURE;
}
#else
vec3 BhBackgroundRadiance(const in vec3 worldDir) {
    return vec3(0.0);
}
#endif

vec3 TraceBlackHole(
    vec3 origin,
    vec3 dir,
    float bhTime,
    float bhYaw,
    const in mat3 bhToWorld,
    const in float diskTemp,
    const in float backgroundGain,
    out float skyTransmittance,
    out vec3 escapedWorldDir
) {
    escapedWorldDir = normalize(bhToWorld * dir);
    float a  = BH_SPIN * BH_MASS;
    float rp = BH_MASS + sqrt(max(BH_MASS * BH_MASS - a * a, 0.0));
    float rin = IscoRadius(a);

    Ks K0 = KsTerms(origin, a);
    vec3  x  = origin;
    vec3  p  = dir;
    float pt = -1.0;
    float receiverFactor = 1.0;
    #if FOXY_BLACKHOLE_TETRAD_CAMERA == 1
        if (K0.f < 1.0) {
            float f0 = min(K0.f, 0.999);
            float lDotDir = dot(K0.l, dir);
            float dirScale = inversesqrt(max(
                lDotDir * lDotDir / (1.0 - f0) + (1.0 - lDotDir * lDotDir),
                1.0e-6
            ));
            float pContraT = inversesqrt(1.0 - f0) + f0 * lDotDir * dirScale / (1.0 - f0);
            vec3  pSpatial = dirScale * dir;
            float pContraS = dot(K0.l, pSpatial);
            pt = -(1.0 - f0) * pContraT + f0 * pContraS;              // p_t = g_tmu p^mu
            p  = f0 * K0.l * (pContraT + pContraS) + pSpatial;        // p_i = g_imu p^mu
            receiverFactor = clamp(1.0 / max(-pt, 1.0e-4), 0.0, 4.0);
        } else {
            float c0 = dot(K0.l, dir);
            float e0 = (sqrt(max(1.0 + K0.f * (1.0 - c0 * c0), 0.0)) - K0.f * c0) / (1.0 + K0.f);
            pt = -e0;
        }
    #else
        float c0 = dot(K0.l, dir);
        float legacyE = (sqrt(max(1.0 + K0.f * (1.0 - c0 * c0), 0.0)) - K0.f * c0) / (1.0 + K0.f);
        pt = -legacyE;
    #endif
    float E = -pt;

    vec3  col = vec3(0.0);
    float trans = 1.0;
    bool  captured = false;
    bool camOutside = length(origin) > rp;

    for (int i = 0; i < MAX_STEPS; i++) {
        if (i >= BH_STEPS) break;
        Ks K; vec3 k1x, k1p;
        Rhs(x, p, pt, a, k1x, k1p, K);
        float r = K.r;
        if (camOutside ? !(r >= rp * 0.995) : (r < 1.0e-3)) { captured = true; break; }
        if (r > R_ESCAPE) break;

        float dzdl = k1x.z;
        float rb   = sqrt(max(x.x * x.x + x.y * x.y - a * a, 0.0));
        float H    = max(DISK_FLARE * rb, DISK_MIN_H);

        float bandZ = max(DISK_FLARE * DISK_OUTER, DISK_MIN_H) * 12.0;
        float dlCap = 0.30;
        if (r > DISK_OUTER * 1.15 || (abs(x.z) > bandZ && x.z * dzdl > 0.0)) {
            dlCap = 0.30 * (1.0 + max(r - 5.0, 0.0) * 0.8);
        }
        float dl = clamp(0.11 * (r - rp), camOutside ? 0.012 : 0.030, dlCap);
        if (min(abs(x.z), abs(x.z + dzdl * dl)) < 12.0 * H) {
            dl = min(dl, max(H / max(abs(dzdl), 1.0e-4), 0.006));
        }
        if (x.z * x.z < 64.0 * H * H && rb > rin * 0.70 && rb < DISK_OUTER * 1.15) {
            dl = min(dl, mix(0.30, 0.16, BH_FINE_STEP) * BH_DISK_STEP_LOD);
        }

        if (BH_NO_DISK < 0.5 && trans > 0.004 && rb > rin * 0.70 && rb < DISK_OUTER * 1.10 && x.z * x.z < 100.0 * H * H) {
            float turns = atan(x.y, x.x) * 0.15915494;
            vec3 xEnd = x + dl * k1x;
            float radial = smoothstep(rin, rin * 1.08, rb)
                         * (1.0 - smoothstep(DISK_OUTER * 0.88, DISK_OUTER, rb));
            float colFrac = GaussStepAvg(x.z, dzdl, dl, H) * dl / (2.5066283 * H);
            if (radial * colFrac > 1.0e-8) {
                float Lz  = x.x * p.y - x.y * p.x;
                float g   = Redshift(rb, E, Lz, a);
                float gm  = mix(1.0, g, BH_DOPPLER_MIX);

                vec3 emis;
                vec2 turb = mix(vec2(1.0), DiskTurbulence(x, xEnd, rb, turns, a, bhTime), BH_TURB);
                if (BH_FLAT_SHADE > 0.5) {
                    emis = vec3(0.5);
                } else {
                float tNorm = DiskTemperature(rb, rin);
                float Tcol  = diskTemp * mix(1.0, tNorm, BH_TEMP_CONTRAST) * gm * receiverFactor;
                float tNorm2 = tNorm * tNorm;
                float emit  = tNorm2 * tNorm2;
                emis = Enrich(Blackbody(Tcol), 1.80) * emit
                     * mix(1.0, pow(gm, DOPPLER_EXP), BH_DOPPLER_MIX) * turb.x;
                }

                float kappa = DISK_ABSORB * BH_DISK_OPACITY * turb.y;
                float tau   = radial * colFrac * kappa;
                float att   = exp(-tau);
                vec3  src   = emis * DISK_EMIT;
                col   += trans * src * (1.0 - att);
                trans *= att;
            }
        }

        Rk4(x, p, pt, a, dl, k1x, k1p);
    }

    if (!captured) {
        Ks Ke = KsTerms(x, a);
        float S = dot(Ke.l, p) - pt;
        vec3 escapedBhDir = normalize(p - Ke.f * S * Ke.l);
        float bgCy = cos(bhYaw), bgSy = sin(bhYaw);
        escapedBhDir = vec3(
            bgCy * escapedBhDir.x - bgSy * escapedBhDir.y,
            bgSy * escapedBhDir.x + bgCy * escapedBhDir.y,
            escapedBhDir.z
        );
        escapedWorldDir = normalize(bhToWorld * escapedBhDir);
        vec3 background = BhBackgroundRadiance(escapedWorldDir) * backgroundGain;
        col += trans * background;
    }
    skyTransmittance = captured ? 0.0 : trans;
    return col * receiverFactor * receiverFactor * receiverFactor;
}

const float BH_CAM_YAW       = FOXY_BLACKHOLE_CAM_YAW;
const float BH_CAM_PITCH_DEG = FOXY_BLACKHOLE_CAM_PITCH;
const float BH_CAM_DIST      = FOXY_BLACKHOLE_CAM_DIST;

const vec3 BH_SKY_CENTER_DIR = vec3(1.0, 0.0, 0.0);

struct BhBodyView {
    float dist;
    float pitchDeg;
    float yaw;
    float tiltDeg;
    float diskTemp;
    float brightness;
};

const float BH_FOLLOW_BLOCKS_PER_UNIT = FOXY_BLACKHOLE_FOLLOW_SCALE;
const vec3 BH_FOLLOW_REFERENCE = vec3(0.0, 50.0, 0.0);

vec3 BhCameraPosition(const in float bhTime, const in float dist0, const in float pitchDeg, const in float yaw0) {
    float p = pitchDeg * 3.14159265358979 / 180.0;
    float cp = cos(p), sp = sin(p);
    float yaw = yaw0;
    float dist = dist0;
    #if FOXY_BLACKHOLE_ORBIT == 1
        float nu = bhTime * BH_ORBIT_SPEED;
        float rMax = BH_ORBIT_FAR;
        float rMin = clamp(BH_ORBIT_NEAR, rMax * 1.0e-3, rMax * 0.999);
        float ecc = min((rMax - rMin) / max(rMax + rMin, 1.0e-4), 0.999);
        float semiLatus = rMax * (1.0 - ecc);
        yaw += nu;
        dist = semiLatus / max(1.0 - ecc * cos(nu), 1.0e-4);
    #endif
    return vec3(dist * cp * sin(yaw),
               -dist * cp * cos(yaw),
                dist * sp);
}

vec3 BhCameraPosition(const in float bhTime) {
    return BhCameraPosition(bhTime, BH_CAM_DIST, BH_CAM_PITCH_DEG, BH_CAM_YAW);
}

mat3 BhWorldToBlackHole(const in float bhTime, const in vec3 camPos, const in vec3 skyTarget) {
    vec3 f0 = -normalize(camPos);
    vec3 upHint = vec3(0.0, 0.0, 1.0);
    vec3 right0 = normalize(cross(f0, upHint));
    vec3 up0 = cross(right0, f0);
    mat3 b0 = mat3(right0, up0, -f0);

    vec3 target = skyTarget;
    vec3 upT = vec3(0.0, 1.0, 0.0);
    if (abs(target.y) > 0.999) {
        upT = vec3(0.0, 0.0, 1.0);
    }
    vec3 rightT = normalize(cross(target, upT));
    vec3 upT2 = cross(rightT, target);
    mat3 bt = mat3(rightT, upT2, -target);

    return b0 * transpose(bt);
}

mat3 BhWorldToBlackHole(const in float bhTime, const in vec3 camPos) {
    return BhWorldToBlackHole(bhTime, camPos, BH_SKY_CENTER_DIR);
}

vec3 BhFollowCameraPosition(
    const in float bhTime,
    const in vec3 playerPosition,
    const in mat3 worldToBh
) {
    vec3 base = BhCameraPosition(bhTime);
    #if FOXY_BLACKHOLE_FOLLOW == 1
        vec3 moved = worldToBh *
            ((playerPosition - BH_FOLLOW_REFERENCE) * (1.0 / BH_FOLLOW_BLOCKS_PER_UNIT));
        base += moved;
    #endif
    return base;
}

vec3 BhTiltRoll(const in vec3 worldDirection, const in float tiltDeg, const in vec3 skyTarget) {
    float ta = radians(tiltDeg);
    float tc = cos(ta);
    float ts = sin(ta);
    vec3 d = normalize(worldDirection);
    float ax = dot(skyTarget, d);
    return d * tc + cross(skyTarget, d) * ts
         + skyTarget * (ax * (1.0 - tc));
}

vec3 BhTiltRoll(const in vec3 worldDirection) {
    return BhTiltRoll(worldDirection, FOXY_BLACKHOLE_TILT, BH_SKY_CENTER_DIR);
}
vec3 BlackHoleBackground(
    const in vec3 worldDirection,
    const in float bhTime,
    const in vec3 playerPosition
) {
    mat3 worldToBh = BhWorldToBlackHole(bhTime, BhCameraPosition(bhTime));
    vec3 camPos = BhFollowCameraPosition(bhTime, playerPosition, worldToBh);
    vec3 dir = normalize(worldToBh * BhTiltRoll(worldDirection));
    float bhYaw = bhTime * BH_AUTO_ROTATE;
    float ignoredTransmittance;
    vec3 ignoredEscapedDir;
    return max(
        TraceBlackHole(camPos, dir, bhTime, bhYaw, transpose(worldToBh),
                       DISK_TEMP, 1.0, ignoredTransmittance, ignoredEscapedDir),
        vec3(0.0)
    );
}

vec4 BlackHoleBodyOverlay(
    const in vec3 worldDirection,
    const in float bhTime,
    const in vec3 bodyDirection,
    const in BhBodyView view,
    out vec3 lensedDirection
) {
    vec3 skyTarget = normalize(bodyDirection);
    vec3 camPos = BhCameraPosition(bhTime, view.dist, view.pitchDeg, view.yaw);
    mat3 worldToBh = BhWorldToBlackHole(bhTime, camPos, skyTarget);
    vec3 dir = normalize(worldToBh * BhTiltRoll(worldDirection, view.tiltDeg, skyTarget));
    float transmittance = 1.0;
    vec3 col = TraceBlackHole(camPos, dir, bhTime, bhTime * BH_AUTO_ROTATE,
                              transpose(worldToBh), view.diskTemp, 0.0, transmittance,
                              lensedDirection);
    return vec4(max(col, vec3(0.0)) * view.brightness, transmittance);
}

#endif
