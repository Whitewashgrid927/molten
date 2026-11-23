// User-supplied artwork, animated as a continuous painted surface. All masks
// describe regions of that exact image; they do not redraw the character.
struct BatmanFrame { float4 page, touch, clock; };
constexpr sampler batLinear(coord::normalized, address::clamp_to_edge, filter::linear);
constexpr sampler batMip(coord::normalized, address::clamp_to_edge, filter::linear, mip_filter::linear);

constant float2 batFigure[] = {
    {0.379,0.147},{0.427,0.127},{0.575,0.118},{0.713,0.130},{0.801,0.155},
    {0.843,0.199},{0.867,0.315},{0.869,0.508},{0.818,0.580},{0.734,0.612},
    {0.604,0.641},{0.541,0.639},{0.492,0.635},{0.414,0.630},{0.375,0.604},
    {0.393,0.550},{0.425,0.471},{0.430,0.402},{0.404,0.418},{0.371,0.491},
    {0.307,0.497},{0.285,0.469},{0.271,0.384},{0.279,0.292},{0.301,0.240},
    {0.326,0.216}
};
constant float2 batCape[] = {
    {0.397,0.149},{0.449,0.126},{0.573,0.120},{0.710,0.131},{0.800,0.158},
    {0.843,0.199},{0.864,0.319},{0.864,0.515},{0.825,0.591},{0.711,0.622},
    {0.690,0.554},{0.687,0.420},{0.652,0.290},{0.631,0.229},{0.569,0.229},
    {0.536,0.212},{0.478,0.188}
};
constant float2 batBody[] = {
    {0.382,0.149},{0.471,0.192},{0.533,0.229},{0.552,0.161},{0.624,0.158},
    {0.638,0.239},{0.659,0.298},{0.697,0.423},{0.677,0.593},{0.604,0.633},
    {0.559,0.620},{0.558,0.490},{0.518,0.596},{0.468,0.637},{0.398,0.625},
    {0.375,0.593},{0.419,0.484},{0.443,0.396},{0.416,0.371},{0.398,0.442},
    {0.363,0.491},{0.305,0.495},{0.278,0.468},{0.277,0.340},{0.292,0.262}
};
constant float2 batSmoke[] = {
    {0.087,0.626},{0.257,0.618},{0.396,0.635},{0.490,0.621},{0.596,0.633},
    {0.708,0.601},{0.738,0.552},{0.773,0.501},{0.815,0.506},{0.847,0.565},
    {0.891,0.601},{0.981,0.620},{0.980,0.676},{0.809,0.691},{0.646,0.674},
    {0.500,0.682},{0.353,0.665},{0.157,0.673},{0.087,0.650}
};
float batRegion(float2 p, constant float2* vertices, uint count, float feather) {
    float d2 = 10; bool inside = false;
    for (uint i=0,j=count-1; i<count; j=i++) {
        float2 a=vertices[i], b=vertices[j], edge=b-a;
        float2 v=p-a-edge*clamp(dot(p-a,edge)/max(dot(edge,edge),1e-8f),0.0,1.0);
        d2=min(d2,dot(v,v));
        if ((a.y>p.y)!=(b.y>p.y)) {
            float x=a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y);
            if(p.x<x)inside=!inside;
        }
    }
    // The contour and nearby paper move together, without cutout seams.
    return 1-smoothstep(-feather,feather*1.7,(inside ? -1.0:1.0)*sqrt(d2));
}
kernel void batmanMasks(texture2d<float,access::write> result [[texture(0)]], uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(result.get_width(),result.get_height())))return;
    float2 uv=(float2(p)+0.5)/float2(result.get_width(),result.get_height());
    float figure=batRegion(uv,batFigure,26,0.016);
    float cape=batRegion(uv,batCape,17,0.012);
    float body=batRegion(uv,batBody,25,0.018);
    float smoke=batRegion(uv,batSmoke,19,0.016);
    float2 face=(uv-float2(0.592,0.213))/float2(0.061,0.070);
    float protect=1-smoothstep(0.72,1.18,length(face));
    cape*=1-protect;
    float depth=figure*0.68+smoke*0.13;
    depth=max(depth,smoothstep(0.70,1.0,uv.y)*0.18);
    result.write(float4(depth,cape,body,smoke),p);
}
kernel void batmanInitialize(texture2d<float,access::write> a [[texture(0)]],
                             texture2d<float,access::write> b [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(a.get_width(),a.get_height())))return;
    a.write(float4(0),p);b.write(float4(0),p);
}
kernel void batmanFlow(texture2d<float,access::read> source [[texture(0)]],
                       texture2d<float,access::write> result [[texture(1)]],
                       texture2d<float> masks [[texture(2)]],
                       constant Uniforms& u [[buffer(0)]],constant BatmanFrame& f [[buffer(1)]],
                       uint2 p [[thread_position_in_grid]]) {
    uint2 size=uint2(source.get_width(),source.get_height());if(any(p>=size))return;
    if(p.x==0 || p.y==0 || p.x+1==size.x || p.y+1==size.y){result.write(float4(0),p);return;}
    float2 uv=(float2(p)+0.5)/float2(size), state=source.read(p).xy;
    float lap=source.read(p+uint2(1,0)).x+source.read(p-uint2(1,0)).x
        +source.read(p+uint2(0,1)).x+source.read(p-uint2(0,1)).x-state.x*4;
    float cape=masks.sample(batLinear,uv).y;
    float2 delta=(uv-f.touch.xy)*float2(0.8025,1);
    float push=f.touch.z*exp(-dot(delta,delta)*520)*(0.010+f.touch.w*0.035);
    float breeze=0.0015*u.parameters.x*sin(f.clock.x*1.25-uv.y*9+uv.x*4);
    float velocity=(state.y+lap*0.18-state.x*0.022+(push+breeze)*cape)*0.945;
    float height=clamp(state.x+velocity,-0.65,0.65);
    result.write(float4(height,velocity,0,0),p);
}
float2 batDisplacement(float2 uv,texture2d<float> masks,texture2d<float> flow,
                      constant Uniforms& u,constant BatmanFrame& f) {
    float4 regions=masks.sample(batLinear,uv);
    float time=f.clock.x;
    float2 d=f.page.zw*regions.x*u.controls.y;
    float cape=regions.y*smoothstep(0.19,0.55,uv.y);
    float wind=u.parameters.x;
    float ripple=flow.sample(batLinear,uv).x;
    d.x+=cape*(0.0045*wind*sin(time*1.13-uv.y*8)*sin(time*0.41)+ripple*0.014);
    d.y+=cape*0.0012*wind*sin(time*0.87+uv.y*9)*sin(time*0.37);
    // The face translates gently with the chest; its expression is preserved.
    float breathing=sin(time*0.95)*u.controls.z*regions.z;
    float torso=smoothstep(0.24,0.30,uv.y)*(1-smoothstep(0.41,0.49,uv.y));
    d+=float2((uv.x-0.53)*0.009*torso,-0.0018)*breathing;
    float smoke=regions.w*u.controls.x;
    d+=smoke*float2(0.0040*sin(time*0.62+uv.y*24)*sin(time*0.31),
                   0.0022*sin(time*0.49+uv.x*16)*sin(time*0.37));
    // Keep the page, signature and finite image edges still outside the art.
    float2 border=min(uv,1-uv);
    return d*smoothstep(0.0,0.045,min(border.x,border.y));
}
float3 batPalette(float3 c,constant Uniforms& u) {
    if(u.parameters.w<0.5)return c;
    if(u.parameters.w<1.5) {
        float l=dot(c,float3(0.2126,0.7152,0.0722));
        return mix(c,c*float3(0.61,0.74,1.01),0.62)+float3(0.0,0.005,0.018)*smoothstep(0.1,0.8,l);
    }
    return saturate(c*float3(1.035,0.998,0.94));
}
kernel void batmanIllustration(texture2d<float> art [[texture(0)]],texture2d<float> masks [[texture(1)]],
                                texture2d<float> flow [[texture(2)]],texture2d<float,access::write> result [[texture(3)]],
                                constant Uniforms& u [[buffer(0)]],constant BatmanFrame& f [[buffer(1)]],
                                uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(result.get_width(),result.get_height())))return;
    float2 uv=(float2(p)+0.5)/u.viewport.xy;
    float2 base=(uv-0.5)*f.page.xy+0.5;
    float2 source=base;
    for(int i=0;i<3;++i)source=base-batDisplacement(source,masks,flow,u,f);
    float pixel=max(f.page.x*f.clock.z/u.viewport.x,f.page.y*f.clock.w/u.viewport.y);
    float lod=max(0.0,log2(max(pixel,1.0)));
    float3 color=art.sample(batMip,source,level(lod)).rgb;
    if(any(base<0) || any(base>1)) {
        // Fit the portrait on a wide screen and extend the empty paper margin.
        float3 paper=(art.sample(batMip,float2(0.15,0.07),level(3)).rgb
                     +art.sample(batMip,float2(0.45,0.07),level(3)).rgb
                     +art.sample(batMip,float2(0.75,0.07),level(3)).rgb)/3;
        paper+=(atNoise(uv*u.viewport.xy*0.8)-0.5)*0.012;
        float side=min(abs(base.x),abs(base.x-1));
        float shadow=exp(-side*75)*0.055;
        color=paper*(0.94-shadow);
    }
    result.write(float4(batPalette(color,u),1),p);
}
