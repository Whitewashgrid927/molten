// Additional scenes share Uniforms, the tone mapper, and the studio environment
// from Shaders.metal. Every kernel guards its output grid, including odd sizes.

float hash21(float2 p) {
    float3 p3 = fract(float3(p.xyx) * 0.1031);
    p3 += dot(p3, p3.yzx + 33.33);
    return fract((p3.x + p3.y) * p3.z);
}
float noise2(float2 p) {
    float2 i = floor(p), f = fract(p);
    f = f * f * (3.0 - 2.0 * f);
    return mix(mix(hash21(i), hash21(i + float2(1, 0)), f.x),
               mix(hash21(i + float2(0, 1)), hash21(i + 1.0), f.x), f.y);
}
float fbm2(float2 p) {
    float value = 0, amplitude = 0.5;
    for (int i = 0; i < 4; ++i) {
        value += amplitude * noise2(p);
        p = float2(1.6 * p.x - 1.2 * p.y, 1.2 * p.x + 1.6 * p.y) + 7.3;
        amplitude *= 0.5;
    }
    return value;
}
float2 screenPoint(float2 uv, constant Uniforms& u) {
    return (uv - 0.5) * float2(u.viewport.x / u.viewport.y, -1.0) * 2.0;
}
float3 cameraRay(float2 screen, float3 origin, float3 target, float focal) {
    float3 forward = normalize(target - origin);
    float3 right = normalize(cross(forward, float3(0, 1, 0)));
    return normalize(forward * focal + right * screen.x + cross(right, forward) * screen.y);
}
uint2 neighbor(uint2 p, int2 offset, uint w, uint h) {
    return uint2(clamp(int2(p) + offset, int2(0), int2(w, h) - 1));
}
float3 nightStars(float3 direction) {
    float2 sky = float2(atan2(direction.z, direction.x), asin(clamp(direction.y, -1.0, 1.0)));
    float2 grid = sky * 185.0;
    float2 cell = floor(grid), local = fract(grid) - 0.5;
    float seed = hash21(cell);
    float star = pow(max(0.0, 1.0 - length(local) * 2.5), 8.0) * step(0.97, seed);
    float band = exp(-pow((sky.y + 0.25 * sin(sky.x * 2.0)) * 5.0, 2.0));
    return float3(0.002, 0.004, 0.012) + float3(0.018, 0.012, 0.032) * band
         + star * mix(float3(0.4, 0.6, 1.0), float3(1.0, 0.8, 0.5), hash21(cell + 93.0)) * 2.0;
}

// A magnetic height field. Spike spacing and surface tension alter geometry;
// viscosity controls its response time. Bounded ray sampling avoids unbounded
// sphere tracing over this non-distance field.
float ferroHeight(float2 p, constant Uniforms& u) {
    float t = u.viewport.z * 0.3 / (0.3 + u.controls.y);
    float2 magnet = u.pointer.w > 0.5
        ? (u.pointer.xy - 0.5) * float2(3.4, -3.4)
        : float2(0.35 * sin(t), 0.28 * cos(t * 0.8));
    float2 q = p + float2(sin(t + p.y) * 0.025, cos(t + p.x) * 0.025);
    float k = 13.5 / u.controls.z;
    float lattice = (cos(q.x * k) + cos((q.x * 0.5 + q.y * 0.8660254) * k)
                    + cos((q.x * 0.5 - q.y * 0.8660254) * k)) / 3.0;
    float peaks = pow(max(0.0, lattice), mix(3.8, 1.5, u.controls.x));
    float field = exp(-dot(p - magnet, p - magnet) * 0.72);
    float envelope = 1.0 - smoothstep(1.55, 1.95, length(p));
    return envelope * (0.06 + peaks * (0.12 + field * 0.62 * u.parameters.x
                         * (1.0 + 0.35 * u.pointer.z)) + field * 0.08);
}
kernel void ferrofluid(texture2d<float, access::write> output [[texture(0)]],
                       constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy, xy = screenPoint(uv, u);
    float3 origin = float3(0, 2.7, 4.5);
    float3 ray = cameraRay(xy, origin, float3(0, 0.3, 0), 2.4);
    float3 color = backdrop(uv, u.viewport.x / u.viewport.y, 0) * 0.65;
    if (ray.y < -0.01) {
        float start = max(0.0, (2.05 - origin.y) / ray.y);
        float end = -origin.y / ray.y;
        int samples = u.options.w == 0 ? 38 : u.options.w == 1 ? 56 : 76;
        float last = start, hit = -1;
        for (int i = 0; i <= samples; ++i) {
            float d = mix(start, end, float(i) / float(samples));
            float3 p = origin + ray * d;
            if (length(p.xz) < 1.95 && p.y <= ferroHeight(p.xz, u)) {
                float low = last, high = d;
                for (int j = 0; j < 7; ++j) {
                    float mid = (low + high) * 0.5;
                    float3 m = origin + ray * mid;
                    if (m.y > ferroHeight(m.xz, u)) low = mid; else high = mid;
                }
                hit = high; break;
            }
            last = d;
        }
        if (hit > 0) {
            float3 p = origin + ray * hit;
            float e = 0.0025;
            float3 normal = normalize(float3(
                ferroHeight(p.xz - float2(e, 0), u) - ferroHeight(p.xz + float2(e, 0), u), 2.0 * e,
                ferroHeight(p.xz - float2(0, e), u) - ferroHeight(p.xz + float2(0, e), u)));
            float3 reflected = studio(reflect(ray, normal), u.viewport.z, 0);
            float3 tint = u.parameters.w < 0.5 ? float3(0.15, 0.19, 0.24) :
                          u.parameters.w < 1.5 ? float3(0.68, 0.8, 0.95) : float3(0.8, 0.32, 0.12);
            float rim = pow(1.0 - max(dot(normal, -ray), 0.0), 4.0);
            color = reflected * tint * (0.65 + rim) + float3(0.008, 0.012, 0.02);
            color += pow(max(dot(reflect(ray, normal), normalize(float3(-0.6, 1, 0.4))), 0.0), 90.0) * 2;
        } else {
            float3 p = origin + ray * end;
            float ring = exp(-pow((length(p.xz) - 1.98) * 90.0, 2.0));
            color += ring * float3(0.14, 0.22, 0.3);
        }
    }
    output.write(float4(film(color * 1.3), 1), gid);
}

// Damped wave equation. Height and velocity persist in a small fixed grid;
// analytic long waves add wind without increasing the simulation's CFL number.
kernel void oceanInitialize(texture2d<float, access::write> state [[texture(0)]],
                            constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= state.get_width() || gid.y >= state.get_height()) return;
    float2 p = (float2(gid) + 0.5) / float2(state.get_width(), state.get_height()) - 0.5;
    state.write(float4(0.002 * sin(length(p) * 70.0) * exp(-dot(p, p) * 12.0), 0, 0, 1), gid);
}
kernel void oceanStep(texture2d<float, access::read> source [[texture(0)]],
                      texture2d<float, access::write> dest [[texture(1)]],
                      constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = dest.get_width(), h = dest.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 s = source.read(gid).xy;
    float lap = source.read(neighbor(gid, int2(-1, 0), w, h)).x
              + source.read(neighbor(gid, int2(1, 0), w, h)).x
              + source.read(neighbor(gid, int2(0, -1), w, h)).x
              + source.read(neighbor(gid, int2(0, 1), w, h)).x - 4.0 * s.x;
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float2 d = uv - u.pointer.xy;
    float force = exp(-dot(d, d) * 6500.0) * u.pointer.z;
    s.y = (s.y + lap * 0.22) * 0.991;
    s.y += force * (0.0009 * sin(u.viewport.z * 27.0) + min(length(u.interaction.xy), 0.08) * 0.08);
    s.x = clamp(s.x + s.y, -0.12, 0.12);
    float edge = smoothstep(0.0, 0.035, min(min(uv.x, uv.y), min(1.0 - uv.x, 1.0 - uv.y)));
    dest.write(float4(s * mix(0.8, 1.0, edge), 0, 1), gid);
}
float oceanHeight(texture2d<float, access::sample> state, float2 p, constant Uniforms& u) {
    float t = u.viewport.z;
    float wind = u.parameters.x * (0.3 + u.controls.z);
    return state.sample(linearClamp, p).x
         + wind * (sin(dot(p, float2(21, 13)) - t * 1.2) * 0.008
                 + sin(dot(p, float2(-17, 31)) - t * 0.85) * 0.005
                 + sin(dot(p, float2(45, 27)) + t * 0.73) * 0.002);
}
float causticNetwork(float2 p, float time) {
    float2 cell = floor(p), local = fract(p);
    float first = 8, second = 8;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        float2 offset = float2(x, y);
        float2 seed = float2(hash21(cell + offset), hash21(cell + offset + 37.2));
        float2 position = 0.5 + 0.32 * sin(seed * 2.0 * PI + time * float2(0.6, 0.8));
        float distance = length(offset + position - local);
        if (distance < first) { second = first; first = distance; }
        else second = min(second, distance);
    }
    return exp(-(second - first) * 32.0);
}
kernel void oceanRender(texture2d<float, access::sample> state [[texture(0)]],
                        texture2d<float, access::write> output [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy;
    float e = 1.0 / float(state.get_width());
    float center = oceanHeight(state, uv, u);
    float left = oceanHeight(state, uv - float2(e, 0), u), right = oceanHeight(state, uv + float2(e, 0), u);
    float down = oceanHeight(state, uv - float2(0, e), u), up = oceanHeight(state, uv + float2(0, e), u);
    float2 slope = float2(right - left, up - down) / (2.0 * e);
    float3 normal = normalize(float3(-slope.x, 1.0, -slope.y));
    float depth = u.controls.x;
    float2 floorUV = uv + slope * depth * 0.045;
    float2 tiles = abs(fract(floorUV * 12.0) - 0.5);
    float grout = smoothstep(0.455, 0.49, max(tiles.x, tiles.y));
    float sand = fbm2(floorUV * 35.0) * 0.08;
    float curvature = (left + right + up + down - 4.0 * center) / (e * e);
    // Screen-space focusing approximation from the wave curvature, bounded so
    // overlapping highlights cannot overflow. This is not a photon caustics solver.
    float focus = pow(clamp(1.0 - curvature * depth * 0.025, 0.15, 3.0), 2.1);
    float ribbons = causticNetwork(floorUV * 13.0 + slope * 0.3, u.viewport.z);
    float3 water = u.parameters.w < 0.5 ? float3(0.035, 0.43, 0.45) :
                   u.parameters.w < 1.5 ? float3(0.018, 0.07, 0.2) : float3(0.34, 0.29, 0.095);
    float3 color = water * (0.38 + focus * 0.1 + sand) * (1.0 - grout * 0.22);
    color += float3(0.25, 0.65, 0.55) * ribbons * (0.3 + focus * 0.18);
    color *= exp(-depth * float3(0.65, 0.18, 0.08));
    float3 light = normalize(float3(cos(u.controls.y * PI) * 0.7, 0.65, sin(u.controls.y * PI) * 0.6));
    float3 view = normalize(float3((uv - 0.5) * 0.35, 1.0).xzy);
    float highlight = pow(max(dot(normal, normalize(view + light)), 0.0), 170.0);
    float fresnel = 0.025 + 0.975 * pow(1.0 - max(dot(normal, view), 0.0), 5.0);
    color += highlight * float3(1.2, 1.1, 0.85) + studio(reflect(-view, normal), u.viewport.z, 0) * fresnel * 0.5;
    color *= 1.0 - 0.25 * dot(uv - 0.5, uv - 0.5);
    output.write(float4(film(color * 1.7), 1), gid);
}

// An artistic gravitational-lensing approximation: bounded bent-ray integration
// through an emissive disk, with a capture radius and a distant star field.
kernel void blackHole(texture2d<float, access::write> output [[texture(0)]],
                      constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy, xy = screenPoint(uv, u);
    float yaw = (u.pointer.x - 0.5) * u.pointer.w * 1.5 + u.viewport.z * 0.025;
    float elevation = u.controls.y + (0.5 - u.pointer.y) * u.pointer.w * 0.45;
    float3 origin = float3(sin(yaw) * 6.2, sin(elevation) * 6.2, cos(yaw) * cos(elevation) * 6.2);
    float3 ray = cameraRay(xy, origin, float3(0), 1.85), p = origin;
    float3 light = 0;
    float transmittance = 1.0;
    float gravity = 0.8 + u.parameters.x * 0.3 + u.pointer.z * 0.12;
    float horizon = 0.43 * gravity;
    int steps = u.options.w == 0 ? 56 : u.options.w == 1 ? 80 : 112;
    bool captured = false;
    for (int i = 0; i < steps; ++i) {
        float r = length(p);
        if (r < horizon) { captured = true; break; }
        if (r > 11.0) break;
        float ds = clamp(r * 0.09, 0.045, 0.38);
        float3 previous = p;
        ray = normalize(ray - p * (gravity * ds * 0.56 / max(r * r * r, 0.025)));
        p += ray * ds;
        // Integrate the plane crossing analytically so thin disks survive Eco.
        float blend = clamp(previous.y / (previous.y - p.y + 0.000001), 0.0, 1.0);
        float3 diskPoint = mix(previous, p, blend);
        float radius = length(diskPoint.xz);
        float disk = smoothstep(0.74, 0.95, radius) * (1.0 - smoothstep(2.65, 3.2, radius));
        // Exact integral of exp(-abs(y) * k) along each straight ray segment.
        // This removes step-boundary bands when grazing the thin disk.
        float k = 24.0, y0 = previous.y, y1 = p.y;
        float primitive0 = copysign(1.0 - exp(-k * abs(y0)), y0) / k;
        float primitive1 = copysign(1.0 - exp(-k * abs(y1)), y1) / k;
        float layer = abs(y1 - y0) < 0.00001 ? exp(-abs((y0 + y1) * 0.5) * k) * ds
                                             : abs((primitive1 - primitive0) / (y1 - y0)) * ds;
        layer *= 9.0;
        if (disk * layer > 0.001) {
            float angle = atan2(diskPoint.z, diskPoint.x);
            float t = u.viewport.z * u.controls.x;
            float bands = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(radius * 42.0 + sin(angle * 5.0 - t * 1.8) * 2.0), 2.0);
            float turbulence = noise2(float2(radius * 17.0, angle * 8.0 - t * 3.0));
            float heat = clamp((2.8 - radius) * 0.4 + u.controls.z * 0.4, 0.0, 1.0);
            float3 hot = mix(float3(1.0, 0.12, 0.015), float3(1.7, 1.2, 0.62), heat);
            if (u.parameters.w > 0.5 && u.parameters.w < 1.5) hot = mix(float3(0.08, 0.16, 1.0), float3(0.8, 1.4, 2.2), heat);
            if (u.parameters.w > 1.5) hot = mix(float3(0.65, 0.06, 0.3), float3(0.4, 1.3, 1.8), 0.5 + 0.5 * sin(angle + t));
            float doppler = clamp(1.0 + sin(angle - yaw) * 0.65, 0.3, 1.8);
            float alpha = clamp(disk * layer * (0.35 + bands * 0.5 + turbulence * 0.2), 0.0, 0.8);
            light += transmittance * hot * alpha * doppler * 0.95;
            transmittance *= 1.0 - alpha * 0.65;
        }
    }
    if (!captured) light += nightStars(ray) * transmittance;
    output.write(float4(film(light), 1), gid);
}

// Front-to-back integration of several thin, folded emissive curtains.
kernel void aurora(texture2d<float, access::write> output [[texture(0)]],
                   constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy, xy = screenPoint(uv, u);
    float3 ray = normalize(float3(xy.x, xy.y + 0.32, -1.6));
    float3 color = nightStars(ray);
    float3 glow = 0;
    float t = u.viewport.z * 0.16, height = u.controls.y;
    int steps = u.options.w == 0 ? 24 : u.options.w == 1 ? 36 : 52;
    float stepSize = 8.0 / float(steps);
    float mouse = (u.pointer.x - 0.5) * u.pointer.w;
    for (int i = 0; i < steps; ++i) {
        float d = 1.1 + (float(i) + 0.5) * stepSize;
        float3 p = float3(0, 0.55, 0) + ray * d;
        float wave = sin(p.x * 1.4 + t + sin(p.z * 0.6 - t) * u.controls.x * 1.3);
        float folded = p.z + 3.0 + wave * 1.2 + sin(p.x * 3.1 + t * 0.7) * 0.3 + mouse;
        float curtain = exp(-pow(folded * 2.8, 2.0))
                      + exp(-pow((folded + 2.3 + sin(p.x + t)) * 3.2, 2.0)) * 0.6;
        float bottom = 0.55 + sin(p.x * 1.3 + t * 0.8) * 0.18;
        float vertical = max(p.y - bottom, 0.0) / height;
        float fade = smoothstep(0.0, 0.12, p.y - bottom) * exp(-vertical * 1.35);
        float streaks = 0.4 + 0.6 * pow(0.5 + 0.5 * sin(p.x * 45.0 + sin(p.x * 6.0 + t) * 3.0), 2.0);
        float3 low = float3(0.06, 1.2, 0.65), high = float3(0.32, 0.09, 0.7);
        if (u.parameters.w > 0.5 && u.parameters.w < 1.5) { low = float3(0.5, 0.12, 1.2); high = float3(1.0, 0.08, 0.38); }
        if (u.parameters.w > 1.5) { low = float3(1.2, 0.45, 0.1); high = float3(0.6, 0.03, 0.3); }
        float3 tint = mix(low, high, clamp(vertical * 0.5, 0.0, 1.0));
        tint = mix(tint, spectrum(vertical * 0.2 + u.controls.z) * 1.2, u.controls.z * 0.75);
        glow += tint * curtain * fade * streaks * stepSize * u.parameters.x * (1.0 + u.pointer.z * 0.5);
    }
    float horizon = exp(-pow((uv.y - 0.78) * 13.0, 2.0));
    color += glow + horizon * float3(0.018, 0.04, 0.07);
    float ridge = 0.83 + 0.035 * sin(xy.x * 5.0) + 0.012 * sin(xy.x * 17.0);
    color *= 1.0 - smoothstep(ridge, ridge + 0.003, uv.y) * 0.96;
    output.write(float4(film(color), 1), gid);
}

// Terrain state: bedrock height, water depth, suspended sediment, channel wear.
// Four outflows are limited by available water; the following gather pass moves
// water and sediment conservatively, then erodes/deposits material locally.
kernel void terrainInitialize(texture2d<float, access::write> state [[texture(0)]],
                              constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= state.get_width() || gid.y >= state.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(state.get_width(), state.get_height());
    float2 p = uv - 0.5;
    float ridge = 1.0 - abs(fbm2(uv * 5.0 + u.parameters.w * 13.0) * 2.0 - 1.0);
    float height = 0.14 + ridge * 0.5 + fbm2(uv * 17.0) * 0.17;
    height *= 1.0 - smoothstep(0.18, 0.7, length(p)) * 0.83;
    if (u.parameters.w > 1.5) height = 0.12 + exp(-dot(p, p) * 12.0) * 0.65 - exp(-dot(p, p) * 180.0) * 0.22 + ridge * 0.1;
    state.write(float4(height, 0.0001, 0, 0), gid);
}
kernel void terrainFlux(texture2d<float, access::read> state [[texture(0)]],
                        texture2d<float, access::write> flux [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = flux.get_width(), h = flux.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 center = state.read(gid);
    float surface = center.x + center.y;
    float4 l = state.read(neighbor(gid, int2(-1, 0), w, h)), r = state.read(neighbor(gid, int2(1, 0), w, h));
    float4 b = state.read(neighbor(gid, int2(0, -1), w, h)), t = state.read(neighbor(gid, int2(0, 1), w, h));
    float4 flow = max(float4(0), surface - float4(l.x + l.y, r.x + r.y, b.x + b.y, t.x + t.y)) * 0.2;
    if (gid.x == 0) flow.x = 0; if (gid.x + 1 == w) flow.y = 0;
    if (gid.y == 0) flow.z = 0; if (gid.y + 1 == h) flow.w = 0;
    flow *= min(1.0, center.y * 0.9 / max(dot(flow, float4(1)), 0.0000001));
    flux.write(flow, gid);
}
kernel void terrainStep(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::read> flux [[texture(1)]],
                        texture2d<float, access::write> dest [[texture(2)]],
                        constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = dest.get_width(), h = dest.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 s = source.read(gid), outflow = flux.read(gid);
    uint2 l = neighbor(gid, int2(-1, 0), w, h), r = neighbor(gid, int2(1, 0), w, h);
    uint2 b = neighbor(gid, int2(0, -1), w, h), t = neighbor(gid, int2(0, 1), w, h);
    float4 inflow = float4(gid.x > 0 ? flux.read(l).y : 0, gid.x + 1 < w ? flux.read(r).x : 0,
                          gid.y > 0 ? flux.read(b).w : 0, gid.y + 1 < h ? flux.read(t).z : 0);
    float4 sl = source.read(l), sr = source.read(r), sb = source.read(b), st = source.read(t);
    float outgoing = dot(outflow, float4(1)), incoming = dot(inflow, float4(1));
    float transported = dot(inflow, float4(sl.z / max(sl.y, 0.000001), sr.z / max(sr.y, 0.000001),
                                        sb.z / max(sb.y, 0.000001), st.z / max(st.y, 0.000001)));
    float sediment = max(0.0, s.z + transported - outgoing * s.z / max(s.y, 0.000001));
    float2 uv = (float2(gid) + 0.5) / float2(w, h);
    float rain = 0.000035 * u.parameters.x * (0.5 + noise2(uv * 23.0 + u.viewport.z * 0.1));
    float water = max(0.0, s.y + incoming - outgoing + rain) * 0.993;
    float slope = max(max(abs(s.x - sl.x), abs(s.x - sr.x)), max(abs(s.x - sb.x), abs(s.x - st.x)));
    float capacity = min(0.02, (incoming + outgoing) * (0.1 + slope * 100.0) * 1.5);
    float erosion = clamp((capacity - sediment) * 0.18 * u.controls.y, -0.0007, 0.0007);
    float height = max(0.035, s.x - erosion);
    float2 mouse = uv - u.pointer.xy;
    height += exp(-dot(mouse, mouse) * 1800.0) * u.pointer.z * 0.003;
    float wear = clamp(s.w + max(erosion, 0.0) * 8.0, 0.0, 1.0);
    dest.write(float4(min(height, 1.2), min(water, 0.2), max(0.0, sediment + erosion), wear), gid);
}
kernel void terrainRender(texture2d<float, access::sample> state [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy;
    // Relief-map view keeps sculpting aligned exactly with pointer coordinates.
    float e = 1.0 / float(state.get_width());
    float4 s = state.sample(linearClamp, uv);
    float l = state.sample(linearClamp, uv - float2(e, 0)).x, r = state.sample(linearClamp, uv + float2(e, 0)).x;
    float b = state.sample(linearClamp, uv - float2(0, e)).x, t = state.sample(linearClamp, uv + float2(0, e)).x;
    float3 normal = normalize(float3((l - r) * u.controls.z * 2.0, 2.0 * e, (b - t) * u.controls.z * 2.0));
    float h = s.x * u.controls.z, sea = u.controls.x;
    float3 low = float3(0.055, 0.15, 0.075), rock = float3(0.29, 0.31, 0.27);
    if (u.parameters.w > 0.5 && u.parameters.w < 1.5) { low = float3(0.28, 0.085, 0.035); rock = float3(0.7, 0.35, 0.12); }
    if (u.parameters.w > 1.5) { low = float3(0.035, 0.075, 0.04); rock = float3(0.18, 0.19, 0.2); }
    float3 land = mix(low, rock, smoothstep(sea + 0.08, 0.63, h));
    land = mix(land, float3(0.87, 0.92, 0.95), smoothstep(0.64, 0.78, h) * (u.parameters.w < 0.5 ? 1.0 : 0.0));
    land *= 0.27 + max(dot(normal, normalize(float3(-0.6, 1, -0.5))), 0.0) * 0.95;
    land *= 1.0 - min(s.w * 0.6, 0.55);
    float river = clamp(s.y * 80.0 + s.w * 0.2, 0.0, 0.7);
    land = mix(land, float3(0.025, 0.16, 0.2), river);
    float3 water = mix(float3(0.018, 0.19, 0.22), float3(0.008, 0.045, 0.11), clamp((sea - h) * 8.0, 0.0, 1.0));
    water += pow(0.5 + 0.5 * sin(uv.x * 130.0 + uv.y * 90.0 + u.viewport.z), 20.0) * 0.007;
    float3 color = mix(water, land, smoothstep(sea - 0.004, sea + 0.005, h));
    float shore = exp(-abs(h - sea) * 320.0);
    color += shore * float3(0.1, 0.12, 0.09);
    output.write(float4(film(color * 1.5), 1), gid);
}

// Analytic thin-film interference on a deforming membrane. Wavelength-dependent
// phase changes with local thickness and view angle.
float membraneHeight(float2 p, constant Uniforms& u) {
    float time = u.viewport.z * 0.4, tension = u.controls.x;
    float r2 = dot(p, p);
    float skin = sqrt(max(0.0, 1.0 - r2));
    float2 mouse = (u.pointer.xy - 0.5) * float2(u.viewport.x / u.viewport.y, -1.0) * 2.0;
    float touch = exp(-dot(p - mouse, p - mouse) * 9.0) * u.pointer.w;
    float waves = sin(p.x * 8.0 + time) * sin(p.y * 7.0 - time * 0.7) * (1.0 - tension) * 0.055;
    return skin * u.controls.y * 0.6 + waves + touch * (0.03 + u.pointer.z * 0.18);
}
kernel void membranes(texture2d<float, access::write> output [[texture(0)]],
                      constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy, p = screenPoint(uv, u) * 1.22;
    p.x += sin(p.y * 3.0 + u.viewport.z * 0.2) * 0.035;
    float radius = length(p);
    float3 color = backdrop(uv, u.viewport.x / u.viewport.y, 0) * 0.55;
    if (radius < 0.96) {
        float e = 0.002;
        float z = membraneHeight(p, u);
        float3 normal = normalize(float3(
            membraneHeight(p - float2(e, 0), u) - membraneHeight(p + float2(e, 0), u),
            membraneHeight(p - float2(0, e), u) - membraneHeight(p + float2(0, e), u), 2.0 * e));
        float thickness = (420.0 + 280.0 * fbm2(p * 3.5 + float2(u.viewport.z * 0.08, -u.viewport.z * 0.05))
                          + p.y * 190.0 + z * 250.0) * u.parameters.x;
        float3 wavelength = float3(650, 510, 475);
        float3 interference = 0.5 + 0.5 * cos(4.0 * PI * 1.33 * thickness * max(normal.z, 0.12) / wavelength
                                             + u.controls.z * 2.0 * PI);
        float3 reflected = studio(reflect(float3(0, 0, -1), normal), u.viewport.z, 0);
        float rim = pow(1.0 - max(normal.z, 0.0), 2.0);
        float3 tint = interference * interference;
        if (u.parameters.w > 0.5 && u.parameters.w < 1.5) tint = mix(tint, float3(0.75, 0.8, 0.9), 0.6);
        if (u.parameters.w > 1.5) tint = pow(tint, float3(0.55)) * spectrum(z * 0.6 + radius);
        color += tint * (0.15 + rim * 1.8) + reflected * (0.04 + tint * 0.42);
        color += exp(-pow((radius - 0.95) * 160.0, 2.0)) * float3(0.6, 0.75, 1.0);
    }
    output.write(float4(film(color), 1), gid);
}

// Diffusion-limited crystal growth: vapor diffuses towards existing solid, then
// deposits preferentially along user-selected symmetry axes.
kernel void crystalInitialize(texture2d<float, access::write> state [[texture(0)]],
                              constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= state.get_width() || gid.y >= state.get_height()) return;
    float2 p = (float2(gid) + 0.5) / float2(state.get_width(), state.get_height()) - 0.5;
    float angle = atan2(p.y, p.x), radius = length(p);
    float symmetry = round(u.controls.y);
    float arm = pow(max(0.0, 0.5 + 0.5 * cos(angle * symmetry)), 28.0);
    float seed = radius < 0.014 || (radius < 0.14 && arm > 0.94) ? 1.05 : 0.0;
    state.write(float4(seed, seed > 1.0 ? 0 : 0.7, 0, 1), gid);
}
kernel void crystalStep(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::write> dest [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = dest.get_width(), h = dest.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float4 s = source.read(gid);
    float vapor = 0, maximum = 0;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        if (x == 0 && y == 0) continue;
        float4 n = source.read(neighbor(gid, int2(x, y), w, h));
        vapor += n.y;
        maximum = max(maximum, n.x);
    }
    vapor = mix(s.y, vapor * 0.125, 0.45);
    float2 uv = (float2(gid) + 0.5) / float2(w, h), p = uv - 0.5;
    float angle = atan2(p.y, p.x);
    float symmetry = round(u.controls.y);
    float anisotropy = 0.2 + 0.8 * pow(0.5 + 0.5 * cos(angle * symmetry), 2.0 + u.controls.x * 4.0);
    float irregularity = mix(0.85, 1.15, hash21(float2(gid)));
    float ice = s.x;
    if (ice >= 1.0) { ice = min(1.6, ice + vapor * 0.025); vapor *= 0.7; }
    else if (maximum >= 1.0) {
        float deposit = min(vapor, (0.035 + u.controls.x * 0.065) * anisotropy * irregularity * u.parameters.x);
        ice += deposit; vapor -= deposit;
    } else { vapor = min(1.0, vapor + 0.0006); }
    float2 mouse = uv - u.pointer.xy;
    mouse = uv - ((u.pointer.xy - 0.5) * float2(u.viewport.x / u.viewport.y, 1.0) * 0.7 + 0.5);
    if (u.pointer.z > 0.5 && dot(mouse, mouse) < 0.00009) { ice = max(ice, 1.05); vapor = 0; }
    dest.write(float4(ice, max(vapor, 0.0), 0, 1), gid);
}
kernel void crystalRender(texture2d<float, access::sample> state [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy;
    float2 q = (uv - 0.5) * float2(u.viewport.x / u.viewport.y, 1.0) * 0.7 + 0.5;
    // Match the simulation brush to this zoomed view in crystalStep.
    float2 e = 1.0 / float2(state.get_width(), state.get_height());
    float4 s = state.sample(linearClamp, q);
    float l = state.sample(linearClamp, q - float2(e.x, 0)).x, r = state.sample(linearClamp, q + float2(e.x, 0)).x;
    float b = state.sample(linearClamp, q - float2(0, e.y)).x, t = state.sample(linearClamp, q + float2(0, e.y)).x;
    float3 normal = normalize(float3((l - r) * 2.0, (b - t) * 2.0, 0.35));
    float3 light = normalize(float3(cos(u.controls.z * 2 * PI), sin(u.controls.z * 2 * PI), 0.65));
    float coverage = smoothstep(0.02, 0.85, s.x);
    coverage *= all(q >= float2(0)) && all(q <= float2(1)) ? 1.0 : 0.0;
    float3 tint = u.parameters.w < 0.5 ? float3(0.28, 0.7, 1.0) :
                  u.parameters.w < 1.5 ? float3(0.5, 0.16, 0.92) : float3(0.95, 0.37, 0.1);
    float3 crystal = tint * (0.25 + max(dot(normal, light), 0.0) * 0.9);
    crystal += pow(max(dot(normal, normalize(light + float3(0, 0, 1))), 0.0), 28.0) * 0.9;
    float edge = clamp(abs(l - r) + abs(b - t), 0.0, 1.0);
    crystal += tint * edge * 0.8;
    float3 background = float3(0.006, 0.011, 0.025) + tint * 0.018 * exp(-dot(q - 0.5, q - 0.5) * 16.0);
    float halo = max(max(l, r), max(b, t)) * 0.025;
    output.write(float4(film(mix(background + tint * halo, crystal, coverage)), 1), gid);
}

// Gray-Scott reaction/diffusion. The nine-point Laplacian and bounded fixed
// timestep keep the same chemistry across frame-rate and render-quality choices.
kernel void patternInitialize(texture2d<float, access::write> state [[texture(0)]],
                              constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= state.get_width() || gid.y >= state.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(state.get_width(), state.get_height());
    float2 p = uv - 0.5;
    float shape = abs(length(p) - 0.23) < 0.012 ? 1.0 : 0.0;
    float seed = hash21(floor(uv * 27.0));
    shape = max(shape, seed > 0.92 && length(p) < 0.42 ? 1.0 : 0.0);
    state.write(float4(1.0 - shape * 0.5, shape * (0.25 + hash21(float2(gid)) * 0.05), 0, 1), gid);
}
kernel void patternStep(texture2d<float, access::read> source [[texture(0)]],
                        texture2d<float, access::write> dest [[texture(1)]],
                        constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    uint w = dest.get_width(), h = dest.get_height();
    if (gid.x >= w || gid.y >= h) return;
    float2 s = source.read(gid).xy, lap = -s;
    for (int y = -1; y <= 1; ++y) for (int x = -1; x <= 1; ++x) {
        if (x == 0 && y == 0) continue;
        lap += source.read(neighbor(gid, int2(x, y), w, h)).xy * (x == 0 || y == 0 ? 0.2 : 0.05);
    }
    float feed = u.controls.x, loss = u.controls.y;
    if (u.parameters.w > 0.5 && u.parameters.w < 1.5) { feed += 0.006; loss -= 0.004; }
    if (u.parameters.w > 1.5) { feed -= 0.01; loss -= 0.006; }
    float reaction = s.x * s.y * s.y;
    float timestep = min(1.0, 0.65 * u.parameters.x);
    s += (float2(0.9, 0.45) * lap + float2(-reaction + feed * (1.0 - s.x), reaction - (feed + loss) * s.y)) * timestep;
    float2 uv = (float2(gid) + 0.5) / float2(w, h), d = uv - u.pointer.xy;
    float brush = exp(-dot(d, d) * 3200.0) * u.pointer.z;
    s = mix(s, float2(0.45, 0.4), brush * 0.4);
    dest.write(float4(clamp(s, 0.0, 1.0), 0, 1), gid);
}
kernel void patternRender(texture2d<float, access::sample> state [[texture(0)]],
                          texture2d<float, access::write> output [[texture(1)]],
                          constant Uniforms& u [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / u.viewport.xy, e = 1.0 / float2(state.get_width(), state.get_height());
    float v = state.sample(linearClamp, uv).y;
    float l = state.sample(linearClamp, uv - float2(e.x, 0)).y, r = state.sample(linearClamp, uv + float2(e.x, 0)).y;
    float b = state.sample(linearClamp, uv - float2(0, e.y)).y, t = state.sample(linearClamp, uv + float2(0, e.y)).y;
    float3 normal = normalize(float3((l - r) * u.controls.z * 12.0, (b - t) * u.controls.z * 12.0, 0.35));
    float value = smoothstep(0.03, 0.32, v);
    float3 low = float3(0.008, 0.025, 0.04), high = float3(0.05, 0.65, 0.5);
    if (u.parameters.w > 0.5 && u.parameters.w < 1.5) { low = float3(0.025, 0.01, 0.055); high = float3(0.65, 0.2, 0.95); }
    if (u.parameters.w > 1.5) { low = float3(0.04, 0.018, 0.006); high = float3(0.95, 0.47, 0.12); }
    float3 color = mix(low, high, value);
    color *= 0.4 + max(dot(normal, normalize(float3(-0.5, -0.6, 1))), 0.0) * 0.8;
    color += pow(max(dot(normal, normalize(float3(-0.25, -0.3, 1))), 0.0), 35.0) * value * 0.25;
    output.write(float4(film(color), 1), gid);
}
