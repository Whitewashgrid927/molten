// The approved landscape sits beneath SwiftUI's native glass compositor.
// Preserve its colors and aspect ratio; never stretch or distort the scenery.
kernel void nativeGlassBackdrop(texture2d<float, access::write> output [[texture(0)]],
                                texture2d<float, access::sample> landscape [[texture(1)]],
                                constant Uniforms& u [[buffer(0)]],
                                uint2 gid [[thread_position_in_grid]]) {
    if (gid.x >= output.get_width() || gid.y >= output.get_height()) return;
    float2 uv = (float2(gid) + 0.5) / float2(output.get_width(), output.get_height());
    float imageAspect = float(landscape.get_width()) / float(landscape.get_height());
    float viewAspect = float(output.get_width()) / float(output.get_height());
    float2 scale = float2(min(1.0, viewAspect / imageAspect), min(1.0, imageAspect / viewAspect));
    float amount = clamp(u.controls.z / 1.5, 0.0, 1.0);
    float t = u.viewport.z * u.controls.z * 0.035;
    // Optional slow camera drift has enough overscan to keep all edges covered.
    // At zero drift the original composition is a stationary center crop.
    uv = 0.5 + (uv - 0.5) * scale / (1.0 + 0.025 * amount);
    uv += float2(0.009 * sin(t), 0.006 * sin(t * 0.73)) * amount;
    output.write(float4(landscape.sample(linearClamp, uv, level(0)).rgb, 1.0), gid);
}
