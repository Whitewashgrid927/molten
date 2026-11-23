#include <metal_stdlib>
#include <metal_raytracing>
using namespace metal;
using namespace raytracing;

struct Uniforms {
    float4 viewport;       // width, height, simulation time, timestep
    float4 pointer;        // normalized x/y, pressed, inside
    float4 parameters;    // intensity, speed, exposure, palette
    uint4 options;        // scene, frame, particle count, detail
    float4 interaction;   // pointer delta x/y, unused, unused
    float4 controls;      // scene-specific controls
};
struct VertexOut { float4 position [[position]]; float2 uv; };
constant float PI = 3.14159265359;
constexpr sampler linearClamp(coord::normalized, address::clamp_to_edge, filter::linear);

float hash11(float p) { return fract(sin(p * 127.1 + 311.7) * 43758.5453); }
float3 film(float3 x) {
    x = max(x, 0.0);
    return pow(clamp((x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14), 0.0, 1.0), float3(1.0 / 2.2));
}
float3 spectrum(float t) {
    return 0.5 + 0.5 * cos(6.28318 * (float3(0.02, 0.32, 0.57) + t));
}
float3 studio(float3 r, float time, float palette) {
    float3 c = mix(float3(0.014, 0.019, 0.03), float3(0.12, 0.17, 0.24), smoothstep(-0.5, 0.8, r.y));
    float box1 = exp(-pow(abs(r.x + 0.48) * 4.4, 8.0) - pow(abs(r.y - 0.43) * 2.3, 8.0));
    float box2 = exp(-pow(abs(r.x - 0.73) * 7.0, 6.0) - pow(abs(r.y + 0.02) * 1.7, 8.0));
    float strip = exp(-pow((r.y + 0.48 + 0.05 * sin(r.x * 5.0)) * 14.0, 2.0));
    c += float3(2.6, 3.0, 3.7) * box1;
    c += float3(0.15, 0.72, 1.6) * box2;
    c += float3(1.4, 0.55, 0.17) * strip * (0.5 + 0.5 * r.x);
    if (palette > 1.5) c += spectrum(r.y * 0.55 + r.x * 0.22 + time * 0.025) * 0.42;
    return c;
}
float3 backdrop(float2 uv, float aspect, float palette) {
    float2 p = (uv - 0.5) * float2(aspect, 1.0);
    float glow = exp(-dot(p - float2(0.0, -0.03), p - float2(0.0, -0.03)) * 3.7);
    float3 base = float3(0.009, 0.015, 0.025) + glow * float3(0.025, 0.051, 0.074);
    base += float3(0.035, 0.017, 0.009) * exp(-length(p - float2(0.6, -0.35)) * 5.0);
    return base;
}

vertex VertexOut fullscreenVertex(uint id [[vertex_id]]) {
    float2 p = float2((id << 1) & 2, id & 2);
    return {float4(p * float2(2, -2) + float2(-1, 1), 0, 1), p};
}
fragment float4 presentFragment(VertexOut in [[stage_in]], texture2d<float> image [[texture(0)]]) {
    return image.sample(linearClamp, in.uv);
}

float smoothMinimum(float a, float b, float k) {
    float h = clamp(0.5 + 0.5 * (b - a) / k, 0.0, 1.0);
    return mix(b, a, h) - k * h * (1.0 - h);
}
float liquidDistance(float3 p, constant Uniforms& u) {
    float t = u.viewport.z * 0.56;
    float3 q = p;
    q.x += 0.09 * sin(p.y * 3.5 + t * 1.4);
    q.z += 0.08 * cos(p.x * 3.1 - t);
    float d = length(q - float3(-0.23, 0.03, 0.0)) - 0.91;
    d = smoothMinimum(d, length(q - float3(0.61 * cos(t * 0.7), 0.64 + 0.22 * sin(t), 0.18)) - 0.63, 0.55);
    d = smoothMinimum(d, length(q - float3(0.85 + 0.16 * sin(t), -0.34, 0.27 * cos(t))) - 0.58, 0.5);
    d = smoothMinimum(d, length(q - float3(-0.75, -0.61 + 0.17 * sin(t * 1.3), 0.08)) - 0.46, 0.46);
    float2 mouse = (u.pointer.xy - 0.5) * float2(3.1 * u.viewport.x / u.viewport.y, -3.1);
    float influence = u.pointer.w * (0.2 + 0.8 * u.pointer.z);
    d = smoothMinimum(d, length(q - float3(mouse, 0.55)) - 0.3 * influence, 0.37 * influence + 0.01);
    float ripple = sin(p.x * 7.0 + t * 2.0) * sin(p.y * 6.0 - t * 1.4) * sin(p.z * 5.0 + t);
    return d + ripple * 0.018 * u.parameters.x;
}
float3 liquidNormal(float3 p, constant Uniforms& u) {
    float2 e = float2(0.0015, -0.0015);
    return normalize(e.xyy * liquidDistance(p + e.xyy, u) +
                     e.yyx * liquidDistance(p + e.yyx, u) +
                     e.yxy * liquidDistance(p + e.yxy, u) +
                     e.xxx * liquidDistance(p + e.xxx, u));
}
kernel void liquid(texture2d<float, access::write> output [[texture(0)]],
                   constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float aspect = u.viewport.x / u.viewport.y;
    float2 screen = (uv - 0.5) * float2(aspect, -1.0) * 2.0;
    float3 origin = float3(0, 0.04, 4.65);
    float3 rayDirection = normalize(float3(screen, -2.35));
    float distance = 0.0;
    bool hit = false;
    for (int i = 0; i < 76; ++i) {
        float d = liquidDistance(origin + rayDirection * distance, u);
        if (d < 0.0012) { hit = true; break; }
        distance += max(d * 0.82, 0.0008);
        if (distance > 8.0) break;
    }
    float palette = u.parameters.w;
    float3 color = backdrop(uv, aspect, palette);
    float shadow = exp(-pow(screen.x * 1.05, 2.0) - pow((screen.y + 0.73) * 8.0, 2.0));
    color *= 1.0 - shadow * 0.75;
    if (hit) {
        float3 point = origin + rayDirection * distance;
        float3 normal = liquidNormal(point, u);
        float3 reflection = reflect(rayDirection, normal);
        float fresnel = pow(1.0 - max(dot(normal, -rayDirection), 0.0), 4.0);
        color = studio(reflection, u.viewport.z, palette);
        float ao = clamp(liquidDistance(point + normal * 0.19, u) / 0.19, 0.3, 1.0);
        color *= ao * (0.73 + 0.27 * fresnel);
        if (palette > 0.5 && palette < 1.5) color *= float3(0.21, 0.29, 0.39);
        if (palette > 1.5) {
            float3 transmitted = studio(refract(rayDirection, normal, 0.72), u.viewport.z, 2.0);
            float3 tint = spectrum(dot(normal, float3(0.0, 0.8, 0.4)) * 0.42 + u.viewport.z * 0.03);
            color = mix(transmitted * tint * 0.65, color * (0.35 + tint), 0.35 + 0.65 * fresnel);
        }
        color += pow(max(dot(normal, normalize(float3(-0.5, 0.8, 1))), 0.0), 90.0) * float3(1.0, 0.94, 0.82);
    }
    output.write(float4(film(color * u.parameters.z), 1), gid);
}

// Semi-Lagrangian advection and pressure projection run entirely on the GPU.
kernel void velocityAdvect(texture2d<float, access::sample> source [[texture(0)]],
                           texture2d<float, access::write> dest [[texture(1)]],
                           constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 size = float2(dest.get_width(), dest.get_height());
    float2 uv = (float2(gid) + 0.5) / size;
    float dt = min(u.viewport.w, 0.034);
    float2 v = source.sample(linearClamp, uv).xy;
    v = source.sample(linearClamp, uv - v * dt).xy * exp(-0.22 * dt);
    float t = u.viewport.z;
    float2 emitter = float2(0.5 + 0.18 * cos(t * 0.45), 0.5 + 0.2 * sin(t * 0.61));
    float2 d = uv - emitter;
    v += float2(-d.y, d.x) * exp(-dot(d, d) * 32.0) * dt * 2.4 * u.parameters.x;
    float2 d2 = uv - float2(0.3 + 0.12 * sin(t * 0.37), 0.46 + 0.13 * cos(t * 0.49));
    v -= float2(-d2.y, d2.x) * exp(-dot(d2, d2) * 45.0) * dt * 1.7;
    v += float2(sin(uv.y * 37.0 + t * 0.7), sin(uv.x * 31.0 - t * 0.6)) * dt * 0.12 * u.parameters.x;
    float2 m = uv - u.pointer.xy;
    float force = exp(-dot(m * float2(size.x / size.y, 1), m * float2(size.x / size.y, 1)) * 450.0);
    v += force * (u.interaction.xy * 15.0 + float2(-m.y, m.x) * 6.0) * u.pointer.z;
    if (gid.x < 2 || gid.x > uint(size.x) - 3) v.x = 0;
    if (gid.y < 2 || gid.y > uint(size.y) - 3) v.y = 0;
    dest.write(float4(clamp(v, -1.5, 1.5), 0, 1), gid);
}
kernel void fluidCurl(texture2d<float, access::sample> velocity [[texture(0)]],
                       texture2d<float, access::write> curl [[texture(1)]],
                       uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= curl.get_width() || gid.y >= curl.get_height()) return;
    float2 step = 1.0 / float2(curl.get_width(), curl.get_height());
    float2 uv = (float2(gid) + 0.5) * step;
    float l = velocity.sample(linearClamp, uv - float2(step.x, 0)).y;
    float r = velocity.sample(linearClamp, uv + float2(step.x, 0)).y;
    float b = velocity.sample(linearClamp, uv - float2(0, step.y)).x;
    float t = velocity.sample(linearClamp, uv + float2(0, step.y)).x;
    curl.write(float4(0.5 * (r - l - t + b)), gid);
}
kernel void fluidVorticity(texture2d<float, access::read> velocity [[texture(0)]],
                           texture2d<float, access::sample> curl [[texture(1)]],
                           texture2d<float, access::write> dest [[texture(2)]],
                           constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 step = 1.0 / float2(dest.get_width(), dest.get_height());
    float2 uv = (float2(gid) + 0.5) * step;
    float2 gradient = float2(
        abs(curl.sample(linearClamp, uv + float2(step.x, 0)).r) - abs(curl.sample(linearClamp, uv - float2(step.x, 0)).r),
        abs(curl.sample(linearClamp, uv + float2(0, step.y)).r) - abs(curl.sample(linearClamp, uv - float2(0, step.y)).r));
    gradient /= length(gradient) + 0.00001;
    float omega = curl.sample(linearClamp, uv).r;
    float2 force = float2(gradient.y, -gradient.x) * omega * 32.0 * u.parameters.x;
    dest.write(float4(clamp(velocity.read(gid).xy + force * min(u.viewport.w, 0.034), -1.5, 1.5), 0, 1), gid);
}
kernel void fluidDivergence(texture2d<float, access::sample> velocity [[texture(0)]],
                            texture2d<float, access::write> divergence [[texture(1)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= divergence.get_width() || gid.y >= divergence.get_height()) return;
    float2 step = 1.0 / float2(divergence.get_width(), divergence.get_height());
    float2 uv = (float2(gid) + 0.5) * step;
    float l = velocity.sample(linearClamp, uv - float2(step.x, 0)).x;
    float r = velocity.sample(linearClamp, uv + float2(step.x, 0)).x;
    float b = velocity.sample(linearClamp, uv - float2(0, step.y)).y;
    float t = velocity.sample(linearClamp, uv + float2(0, step.y)).y;
    divergence.write(float4(0.5 * (r - l + t - b)), gid);
}
kernel void fluidPressure(texture2d<float, access::sample> pressure [[texture(0)]],
                          texture2d<float, access::read> divergence [[texture(1)]],
                          texture2d<float, access::write> dest [[texture(2)]],
                          uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 step = 1.0 / float2(dest.get_width(), dest.get_height());
    float2 uv = (float2(gid) + 0.5) * step;
    float p = pressure.sample(linearClamp, uv - float2(step.x, 0)).r
            + pressure.sample(linearClamp, uv + float2(step.x, 0)).r
            + pressure.sample(linearClamp, uv - float2(0, step.y)).r
            + pressure.sample(linearClamp, uv + float2(0, step.y)).r;
    dest.write(float4((p - divergence.read(gid).r) * 0.25), gid);
}
kernel void fluidProject(texture2d<float, access::read> velocity [[texture(0)]],
                         texture2d<float, access::sample> pressure [[texture(1)]],
                         texture2d<float, access::write> dest [[texture(2)]],
                         uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 step = 1.0 / float2(dest.get_width(), dest.get_height());
    float2 uv = (float2(gid) + 0.5) * step;
    float2 gradient = float2(
        pressure.sample(linearClamp, uv + float2(step.x, 0)).r - pressure.sample(linearClamp, uv - float2(step.x, 0)).r,
        pressure.sample(linearClamp, uv + float2(0, step.y)).r - pressure.sample(linearClamp, uv - float2(0, step.y)).r);
    dest.write(float4(velocity.read(gid).xy - 0.5 * gradient, 0, 1), gid);
}
float3 inkColor(float phase, float palette) {
    if (palette < 0.5) return mix(float3(0.02, 0.55, 0.8), float3(1.1, 0.27, 0.035), smoothstep(-0.4, 0.7, sin(phase)));
    if (palette < 1.5) return mix(float3(0.45, 0.06, 0.85), float3(0.08, 0.9, 0.58), 0.5 + 0.5 * sin(phase));
    return mix(float3(0.55, 0.68, 0.8), float3(1.0, 0.88, 0.66), 0.5 + 0.5 * sin(phase));
}
kernel void dyeAdvect(texture2d<float, access::sample> source [[texture(0)]],
                      texture2d<float, access::sample> velocity [[texture(1)]],
                      texture2d<float, access::write> dest [[texture(2)]],
                      constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= dest.get_width() || gid.y >= dest.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(dest.get_width(), dest.get_height());
    float dt = min(u.viewport.w, 0.034);
    float2 v = velocity.sample(linearClamp, uv).xy;
    float3 dye = source.sample(linearClamp, uv - v * dt).rgb * exp(-dt * 0.24);
    float t = u.viewport.z;
    for (int j = 0; j < 3; j++) {
        float phase = t * 0.5 + float(j) * 2.094;
        float2 center = float2(0.5 + 0.21 * cos(phase), 0.5 + 0.22 * sin(phase * 1.21));
        float2 d = (uv - center) * float2(1.1, 1.0);
        float splat = exp(-dot(d, d) * 620.0);
        dye += inkColor(phase + float(j), u.parameters.w) * splat * dt * 3.0 * u.parameters.x;
    }
    if (u.options.y == 0) {
        float2 p = (uv - 0.5) * float2(1.2, 1.0);
        float ring = exp(-pow((length(p) - 0.24 - 0.008 * sin(atan2(p.y, p.x) * 13.0)) * 56.0, 2.0));
        float filaments = 0.55 + 0.45 * pow(0.5 + 0.5 * sin(length(p) * 430.0 + sin(p.x * 80.0)), 2.0);
        dye += inkColor(atan2(p.y, p.x) * 1.4, u.parameters.w) * ring * filaments * 1.0;
    }
    float2 m = (uv - u.pointer.xy) * float2(1.2, 1.0);
    dye += inkColor(t + 1.0, u.parameters.w) * exp(-dot(m, m) * 1200.0) * u.pointer.z * dt * 16.0;
    dest.write(float4(min(dye, 4.0), 1), gid);
}
kernel void inkRender(texture2d<float, access::sample> dye [[texture(0)]],
                      texture2d<float, access::write> output [[texture(1)]],
                      constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float2 step = 1.0 / float2(dye.get_width(), dye.get_height());
    float3 c = dye.sample(linearClamp, uv).rgb;
    float l = length(dye.sample(linearClamp, uv - step).rgb);
    float r = length(dye.sample(linearClamp, uv + step).rgb);
    float lighting = clamp(1.0 + (l - r) * 1.5, 0.65, 1.4);
    float3 bg = float3(0.006, 0.009, 0.016);
    c = c * lighting * 1.9 + bg;
    output.write(float4(film(c * u.parameters.z), 1), gid);
}
kernel void clearTexture(texture2d<float, access::write> texture [[texture(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x < texture.get_width() && gid.y < texture.get_height()) texture.write(float4(0), gid);
}

struct Particle { float4 position; float4 velocity; };
kernel void particleInitialize(device Particle* p [[buffer(0)]],
                               constant Uniforms& u [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.options.z) return;
    float a = hash11(float(id) + 1.0) * 2.0 * PI;
    float r = 0.2 + sqrt(hash11(float(id) + 93.0)) * 2.15;
    float arm = float(id % 3) * 2.094 + r * 1.85;
    a = arm + (a - PI) * (0.1 + r * 0.08);
    float y = (hash11(float(id) + 53.0) - 0.5) * 0.15 * r;
    p[id].position = float4(cos(a) * r, y, sin(a) * r, hash11(float(id) + 173.0));
    p[id].velocity = float4(0, 0, 0, hash11(float(id) + 83.0));
}
kernel void particleUpdate(device Particle* particles [[buffer(0)]],
                           constant Uniforms& u [[buffer(1)]], uint id [[thread_position_in_grid]]) {
    if (id >= u.options.z) return;
    Particle p = particles[id];
    float dt = min(u.viewport.w, 0.034);
    float r = max(length(p.position.xz), 0.15);
    float angle = dt * (0.19 + 0.43 / (r + 0.4)) * u.parameters.x;
    float2 xz = p.position.xz;
    p.position.x = cos(angle) * xz.x - sin(angle) * xz.y;
    p.position.z = sin(angle) * xz.x + cos(angle) * xz.y;
    float2 mouse = (u.pointer.xy - 0.5) * float2(5.0 * u.viewport.x / u.viewport.y, -5.0);
    float3 toPointer = float3(mouse.x, mouse.y, 0) - p.position.xyz;
    float dist = length(toPointer);
    if (u.pointer.z > 0.5) p.velocity.xyz += normalize(toPointer + 0.001) * dt * 2.0 / (0.3 + dist * dist);
    p.velocity.xyz *= exp(-dt * 2.0);
    p.position.xyz += p.velocity.xyz * dt;
    p.position.y += dt * sin(u.viewport.z * 0.55 + p.position.w * 20.0 + r) * 0.045;
    p.position.y *= exp(-dt * 0.2);
    if (length(p.position.xyz) > 5.0) p.position.xyz *= 0.5;
    particles[id] = p;
}
// Project and accumulate particles directly, avoiding a million point primitives.
// Integer addition is deterministic and safe with simultaneous contributions.
// At most one contribution per particle per pixel, with < 1.3 color/channel:
// 1,000,000 * ceil(1.3 * 1024) < 2^31 even if every particle overlaps.
// Red's spare high bit marks a fully saturated pixel, whose final BGRA8
// value cannot change. Dense clusters can then skip redundant atomic writes.
constant uint particleSaturated = 0x80000000u;
kernel void particleSplat(device const Particle* particles [[buffer(0)]],
                         constant Uniforms& u [[buffer(1)]],
                         device atomic_uint* accumulation [[buffer(2)]],
                         uint id [[thread_position_in_grid]]) {
    if (id >= u.options.z) return;
    Particle p = particles[id];
    float3 pos = p.position.xyz;
    float a = 0.7 + sin(u.viewport.z * 0.07) * 0.12;
    pos.yz = float2(cos(a) * pos.y - sin(a) * pos.z, sin(a) * pos.y + cos(a) * pos.z);
    float depth = 5.5 - pos.z;
    float2 projected = pos.xy * 2.25 / depth;
    projected.x /= u.viewport.x / u.viewport.y;
    float radius = length(p.position.xz);
    float3 color;
    if (u.parameters.w < 0.5) color = mix(float3(1.0, 0.55, 0.17), float3(0.08, 0.48, 1.0), smoothstep(0.1, 2.3, radius));
    else if (u.parameters.w < 1.5) color = spectrum(p.position.w * 0.25 + radius * 0.16 + 0.2);
    else color = mix(float3(0.4, 0.72, 1.0), float3(0.9, 0.96, 1.0), p.position.w);
    float size = max(1.0, (1.6 + p.position.w * 3.1) * max(0.75, u.viewport.y / 800.0) * 5.0 / depth);
    float density = sqrt(180000.0 / float(u.options.z));
    color *= (0.18 + p.position.w * 0.6) * density * u.parameters.z;
    float2 center = (projected * float2(0.5, -0.5) + 0.5) * u.viewport.xy;
    int2 lower = max(int2(0), int2(ceil(center - size * 0.5 - 0.5)));
    int2 upper = min(int2(u.viewport.xy) - 1, int2(floor(center + size * 0.5 - 0.5)));
    for (int y = lower.y; y <= upper.y; ++y) {
        for (int x = lower.x; x <= upper.x; ++x) {
            float2 offset = (float2(x, y) + 0.5 - center) / size;
            float weight = exp(-16.0 * dot(offset, offset));
            uint3 value = uint3(color * (weight * 1024.0) + 0.5);
            if (!any(value != uint3(0))) continue;
            uint index = (uint(y) * uint(u.viewport.x) + uint(x)) * 3;
            uint red = atomic_load_explicit(&accumulation[index], memory_order_relaxed);
            if ((red & particleSaturated) != 0) continue;
            if (red >= 1024 &&
                atomic_load_explicit(&accumulation[index + 1], memory_order_relaxed) >= 1024 &&
                atomic_load_explicit(&accumulation[index + 2], memory_order_relaxed) >= 1024) {
                atomic_fetch_or_explicit(&accumulation[index], particleSaturated, memory_order_relaxed);
                continue;
            }
            atomic_fetch_add_explicit(&accumulation[index], value.x, memory_order_relaxed);
            atomic_fetch_add_explicit(&accumulation[index + 1], value.y, memory_order_relaxed);
            atomic_fetch_add_explicit(&accumulation[index + 2], value.z, memory_order_relaxed);
        }
    }
}
kernel void particleResolve(device const uint* accumulation [[buffer(0)]],
                            constant Uniforms& u [[buffer(1)]],
                            texture2d<float, access::write> output [[texture(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    uint index = (gid.y * output.get_width() + gid.x) * 3;
    if ((accumulation[index] & particleSaturated) != 0) {
        output.write(float4(1), gid);
        return;
    }
    float3 color = float3(accumulation[index], accumulation[index + 1], accumulation[index + 2]) / 1024.0;
    float2 p = (float2(gid) + 0.5) / u.viewport.xy - 0.5;
    float halo = exp(-dot(p * float2(1, 1.8), p * float2(1, 1.8)) * 28.0);
    output.write(float4(color + float3(0.009, 0.014, 0.025) + halo * float3(0.035, 0.025, 0.045), 1), gid);
}

// Actual Metal ray queries against a triangle acceleration structure.
// Geometry is three closed sphere meshes; primitive ranges identify each sphere.
constant float3 glassCenters[3] = {float3(-0.71, 0.05, 0), float3(0.77, 0.37, -0.48), float3(0.51, -0.65, 0.39)};
constant float glassRadii[3] = {0.86, 0.69, 0.47};
kernel void glass(texture2d<float, access::write> output [[texture(0)]],
                  constant Uniforms& u [[buffer(0)]],
                  primitive_acceleration_structure scene [[buffer(1)]],
                  uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float aspect = u.viewport.x / u.viewport.y;
    float2 xy = (uv - 0.5) * float2(aspect, -1.0) * 2.0;
    float yaw = sin(u.viewport.z * 0.16) * 0.13 + (u.pointer.x - 0.5) * u.pointer.w * 0.24;
    float3 origin = float3(sin(yaw) * 4.7, 0.15, cos(yaw) * 4.7);
    float3 forward = normalize(-origin);
    float3 right = normalize(cross(forward, float3(0, 1, 0)));
    float3 up = cross(right, forward);
    float3 direction = normalize(forward * 2.4 + right * xy.x + up * xy.y);
    float3 color = backdrop(uv, aspect, u.parameters.w);
    intersector<triangle_data> tracer;
    tracer.assume_geometry_type(geometry_type::triangle);
    tracer.force_opacity(forced_opacity::opaque);
    ray r;
    r.origin = origin; r.direction = direction; r.min_distance = 0.001; r.max_distance = 20;
    auto hit = tracer.intersect(r, scene);
    if (hit.type != intersection_type::none) {
        uint sphere = min(hit.primitive_id / 3968u, 2u);
        float3 center = glassCenters[sphere];
        float3 point = origin + direction * hit.distance;
        float3 normal = normalize(point - center);
        float eta = 1.0 / (1.28 + 0.3 * u.parameters.x);
        float fresnel = 0.04 + 0.96 * pow(1.0 - max(dot(-direction, normal), 0.0), 5.0);
        float3 inside = refract(direction, normal, eta);
        ray innerRay;
        innerRay.origin = point + inside * 0.004;
        innerRay.direction = inside; innerRay.min_distance = 0.001; innerRay.max_distance = 10;
        auto exitHit = tracer.intersect(innerRay, scene);
        float3 exitDirection = inside;
        float thickness = 1.0;
        if (exitHit.type != intersection_type::none) {
            float3 exitPoint = innerRay.origin + inside * exitHit.distance;
            float3 exitNormal = normalize(exitPoint - center);
            exitDirection = refract(inside, -exitNormal, 1.0 / eta);
            if (dot(exitDirection, exitDirection) < 0.001) exitDirection = reflect(inside, -exitNormal);
            thickness = exitHit.distance;
        }
        float3 tint = u.parameters.w < 0.5 ? float3(0.56, 0.82, 0.96) :
                      u.parameters.w < 1.5 ? float3(0.95, 0.51, 0.19) : spectrum(float(sphere) * 0.24 + 0.1) * 0.65 + 0.35;
        float3 transmitted = studio(exitDirection, u.viewport.z, 2) * pow(tint, float3(thickness * 1.2));
        float3 reflected = studio(reflect(direction, normal), u.viewport.z, u.parameters.w);
        color = mix(transmitted * 0.6 + tint * 0.035, reflected, fresnel);
        color += pow(1.0 - abs(dot(normal, direction)), 5.0) * tint * 0.5;
        color += pow(max(dot(reflect(direction, normal), normalize(float3(-0.4, 0.8, 0.7))), 0.0), 180.0) * 2.0;
    }
    output.write(float4(film(color * u.parameters.z * 1.35), 1), gid);
}
