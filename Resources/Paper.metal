// A miniature paper sculpture: five layered folders and fifteen loose notes.
// Every surface is a curved mesh, generated from a fixed grid on the GPU.
struct PaperFrame {
    float4 eye, right, up, forward;
    float4 lightEye, lightRight, lightUp, lightForward;
    float4 viewport, controls, focus;
};
struct PaperSurface {
    float3 position;
    float2 local;
};
struct PaperRaster {
    float4 position [[position]];
    float3 world, normal;
    float2 uv, local;
    float depth;
    uint folder [[flat]], part [[flat]];
};
float paperHash(float2 p) {
    uint2 n = uint2(int2(floor(p)));
    uint h = n.x * 1597334677u ^ n.y * 3812015801u;
    h ^= h >> 16; h *= 2246822519u; h ^= h >> 13;
    return float(h & 0xffffffu) / 16777216.0;
}
float paperNoise(float2 p) {
    float2 i = floor(p), v = fract(p); v = v * v * (3 - 2 * v);
    return mix(mix(paperHash(i), paperHash(i + float2(1,0)), v.x),
               mix(paperHash(i + float2(0,1)), paperHash(i + 1), v.x), v.y);
}
float2 paperUV(uint id) {
    constexpr float2 corner[6] = {float2(0,0), float2(1,0), float2(1,1), float2(0,0), float2(1,1), float2(0,1)};
    uint q = id / 6;
    return (float2(q % 96, q / 96) + corner[id % 6]) / float2(96,24);
}
float3 paperBase(uint i, float spread) {
    return float3((float(i) - 2) * 0.22, (4 - float(i)) * 0.30, (float(i) - 2) * (0.46 + spread * 0.34));
}
PaperSurface paperShape(float2 uv, uint folder, uint part, constant PaperFrame &f, constant float4 *states) {
    float4 s = states[folder];
    float time = f.viewport.z, breeze = f.controls.y;
    float3 p;
    float2 local;
    if (part < 2) {
        float x = (uv.x - 0.5) * 4.36;
        float edge = max(0.0, abs(x) - 2.03);
        float round = 0.15 - sqrt(max(0.0, 0.0225 - edge * edge));
        float center = part == 0 ? -1.05 + float(folder) * 0.07 : 1.25;
        float tab = smoothstep(center - 0.75, center - 0.48, x) * (1 - smoothstep(center + 0.48, center + 0.75, x));
        float height = (part == 0 ? 3.05 : 2.16) + (part == 0 ? 0.32 : 0.20) * tab - round;
        float y = mix(round, height, uv.y);
        local = float2(x,y);
        float curl = sin(x * 1.15 + float(folder) * 0.7 + time * 0.65) * 0.032 * breeze;
        float open = part == 0 ? 0.025 : 0.22 + s.z * 0.9;
        p = float3(x + s.w * y * 0.18, y, (part == 0 ? 0.0 : 0.13) + pow(y / 3.05, 2.0) * open);
        p.z += curl * uv.y * uv.y + 0.045 * x * x * uv.y;
        p.z += s.w * x * uv.y;
        p.y += sin(x * 0.7 + time * 0.8 + float(folder)) * 0.016 * breeze * uv.y;
    } else {
        uint note = part - 2;
        float w = note == 0 ? 0.88 : note == 1 ? 0.76 : 0.95;
        float h = note == 0 ? 1.12 : note == 1 ? 1.04 : 0.80;
        float2 q = float2((uv.x - 0.5) * w, uv.y * h);
        // All corners are gently rounded without alpha cutouts in the shadow pass.
        float e = max(0.0, abs(q.x) - w * 0.5 + 0.06);
        float rounding = 0.06 - sqrt(max(0.0, 0.0036 - e * e));
        q.y = mix(rounding, h - rounding, uv.y);
        local = q;
        float active = folder == 4 ? 1.0 : folder == 3 ? 0.28 : 0.0;
        float lift = active * (note == 0 ? 0.48 : note == 1 ? 1.30 : 0.08);
        lift += s.z * (0.55 + float(note) * 0.26);
        float phase = float(folder) * 1.7 + float(note) * 2.4;
        float wave = sin(time * 1.35 + phase + uv.y * 2.3) * breeze;
        float angle = (note == 0 ? -0.23 : note == 1 ? -0.30 : 0.07) + wave * 0.045 + s.w;
        p = float3(cos(angle) * q.x - sin(angle) * q.y, sin(angle) * q.x + cos(angle) * q.y, 0);
        p.x += note == 2 ? -0.28 : 0.86 + float(note) * 0.2;
        p.y += 1.48 + lift + sin(time * 0.95 + phase) * (0.018 + s.z * 0.055) * breeze;
        p.z = 0.12 + float(note) * 0.028 + s.z * 0.28;
        p.z += uv.y * uv.y * (0.18 + wave * (0.12 + s.z * 0.18));
        p.x += wave * uv.y * 0.028;
    }
    p += paperBase(folder, f.controls.x) + float3(s.xy, 0);
    return {p, local};
}
float4 paperLightClip(float3 p, constant PaperFrame &f) {
    float3 q = p - f.lightEye.xyz;
    return float4(dot(q, f.lightRight.xyz) / f.lightRight.w,
                  dot(q, f.lightUp.xyz) / f.lightRight.w,
                  dot(q, f.lightForward.xyz) / 20.0, 1);
}
vertex float4 paperShadowVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                               constant PaperFrame &f [[buffer(0)]], constant float4 *states [[buffer(1)]]) {
    return paperLightClip(paperShape(paperUV(id), instance / 5, instance % 5, f, states).position, f);
}
vertex PaperRaster paperVertex(uint id [[vertex_id]], uint instance [[instance_id]],
                               constant PaperFrame &f [[buffer(0)]], constant float4 *states [[buffer(1)]]) {
    uint folder = instance / 5, part = instance % 5;
    float2 uv = paperUV(id);
    PaperSurface surface = paperShape(uv, folder, part, f, states);
    float3 du = paperShape(uv + float2(0.001,0), folder, part, f, states).position - surface.position;
    float3 dv = paperShape(uv + float2(0,0.001), folder, part, f, states).position - surface.position;
    float3 n = normalize(cross(du, dv));
    float3 q = surface.position - f.eye.xyz;
    float z = dot(q, f.forward.xyz), near = 0.05, far = 40;
    PaperRaster out;
    out.position = float4(dot(q, f.right.xyz) * f.right.w * f.viewport.y / f.viewport.x,
                          dot(q, f.up.xyz) * f.right.w, z * far / (far - near) - near * far / (far - near), z);
    out.world = surface.position; out.normal = n; out.uv = uv; out.local = surface.local;
    out.depth = z; out.folder = folder; out.part = part;
    return out;
}
float3 paperPigment(uint folder, uint preset) {
    constexpr float3 sorbet[5] = {float3(0.28,0.49,0.84), float3(0.93,0.56,0.67), float3(0.60,0.68,0.48), float3(0.57,0.44,0.65), float3(1.0,0.62,0.38)};
    constexpr float3 botanical[5] = {float3(0.38,0.55,0.61), float3(0.65,0.71,0.52), float3(0.38,0.53,0.43), float3(0.72,0.64,0.48), float3(0.82,0.62,0.40)};
    constexpr float3 twilight[5] = {float3(0.39,0.47,0.70), float3(0.64,0.53,0.73), float3(0.50,0.62,0.77), float3(0.73,0.55,0.66), float3(0.86,0.64,0.62)};
    return preset == 1 ? botanical[folder] : preset == 2 ? twilight[folder] : sorbet[folder];
}
fragment half4 paperFragment(PaperRaster in [[stage_in]], bool front [[front_facing]],
                             constant PaperFrame &f [[buffer(0)]], depth2d<float> shadow [[texture(0)]],
                             texture2d<float> labels [[texture(1)]]) {
    constexpr sampler linearSampler(coord::normalized, address::clamp_to_edge, filter::linear);
    constexpr sampler shadowSampler(coord::normalized, address::clamp_to_edge, filter::linear, compare_func::less_equal);
    float3 n = normalize(in.normal) * (front ? 1.0 : -1.0);
    float3 light = normalize(f.lightEye.xyz - in.world);
    float3 color = paperPigment(in.folder, uint(f.viewport.w));
    if (in.part == 1) color *= 0.96;
    if (in.part > 1) {
        color = in.part == 2 ? float3(0.98,0.79,0.42) : in.part == 3 ? float3(0.99,0.95,0.79) : float3(0.58,0.65,0.86);
        if (uint(f.viewport.w) == 1) color = mix(color, float3(0.78,0.84,0.65), 0.38);
        if (uint(f.viewport.w) == 2) color = mix(color, float3(0.82,0.76,0.91), 0.40);
    }
    float4 lp = paperLightClip(in.world, f);
    float2 st = lp.xy * float2(0.5,-0.5) + 0.5;
    float occlusion = 0;
    for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
        occlusion += shadow.sample_compare(shadowSampler, st + float2(x,y) * 2.3 / float(shadow.get_width()), lp.z - 0.0017);
    }
    occlusion /= 9;
    // Broad window light and restrained transmission keep the card stock soft.
    float diffuse = 0.90 + 0.12 * max(0.0, dot(n,light));
    diffuse *= mix(0.86,1.0,occlusion);
    color *= diffuse;
    float fiber = paperNoise(in.local * float2(480,840) + float(in.folder) * 23);
    float mottle = paperNoise(in.local * 20) * 0.65 + paperNoise(in.local * 63) * 0.35;
    color += ((fiber - 0.5) * 0.14 + (mottle - 0.5) * 0.065) * f.controls.w;
    // Fine cream cut edges make the stock thickness legible without outlines.
    float edge = min(min(in.uv.x, 1-in.uv.x), min(in.uv.y, 1-in.uv.y));
    float rim = 1 - smoothstep(0.001,0.004,edge);
    color = mix(color, color * 0.75 + 0.25, rim * 0.42);
    if (in.part == 0) {
        float center = -1.05 + float(in.folder) * 0.07;
        float2 textUV = float2((in.local.x - center) / 0.94 + 0.5, 1 - (in.local.y - 3.07) / 0.235);
        if (all(textUV >= 0) && all(textUV <= 1)) {
            float ink = labels.sample(linearSampler, float2(textUV.x,(float(in.folder)+textUV.y)/5)).r;
            color = mix(color, color * float3(0.23,0.24,0.23), ink * 0.88);
        }
    } else if (in.part > 1) {
        float2 uv = in.uv;
        float stroke = 0;
        for (int i = 0; i < 3; i++) {
            float y = 0.68 - float(i) * 0.125;
            float length = i == 2 ? 0.51 : 0.72;
            stroke = max(stroke, (1-smoothstep(0.018,0.028,abs(uv.y-y))) * smoothstep(0.16,0.20,uv.x) * (1-smoothstep(length,length+0.04,uv.x)));
        }
        color = mix(color,color*0.65,stroke*0.35);
    }
    return half4(half3(max(color,0.0)),half(in.depth));
}
kernel void paperResolve(texture2d<half, access::sample> source [[texture(0)]],
                         texture2d<half, access::write> output [[texture(1)]],
                         constant PaperFrame &f [[buffer(0)]], uint2 p [[thread_position_in_grid]]) {
    if (p.x >= output.get_width() || p.y >= output.get_height()) return;
    constexpr sampler s(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);
    float2 size = f.viewport.xy, uv = (float2(p)+0.5)/size;
    float4 center = float4(source.sample(s,uv,level(0)));
    float coc = min(29.0, max(0.0, abs(center.a-f.focus.x) - 0.32) * 9.0 * f.controls.z) * size.y / 900;
    uint taps = f.focus.y < 1 ? 8 : f.focus.y < 2 ? 12 : f.focus.y < 3 ? 16 : 24;
    float lod = max(0.0,log2(max(1.0,coc * 0.4)));
    float3 color = center.rgb;
    float weight = 1;
    if (coc > 0.4) {
        for (uint i = 0; i < taps; i++) {
            float angle = float(i) * 2.39996323;
            float radius = sqrt((float(i)+0.5)/float(taps));
            float2 offset = float2(cos(angle),sin(angle)) * radius * coc / size;
            float4 sample = float4(source.sample(s,uv+offset,level(lod)));
            // Suppress bleeding from unrelated distant surfaces at sharp edges.
            float w = sample.a > center.a + 1.3 && center.a < f.focus.x ? 0.2 : 1.0;
            color += sample.rgb*w; weight += w;
        }
    }
    color /= weight;
    float2 q = (uv-float2(0.51,0.48))*float2(1.18,1.10);
    float haze = smoothstep(0.29,0.70,length(q)) * 0.87;
    // White light blooms into the far layers, as in a close-focus macro lens.
    haze += smoothstep(f.focus.x+0.5,f.focus.x+3.6,center.a) * 0.16;
    color = mix(color,float3(0.975,0.967,0.95),saturate(haze));
    output.write(half4(half3(saturate(color)),1),p);
}
