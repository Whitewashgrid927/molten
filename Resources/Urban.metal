// The supplied images are the visual source. These shaders add bounded depth,
// drawn traffic and pane-local optics without replacing either composition.
struct UrbanFrame { float4 page, touch, clock; };
constexpr sampler urbanLinear(coord::normalized,address::clamp_to_edge,filter::linear);
constexpr sampler urbanMip(coord::normalized,address::clamp_to_edge,filter::linear,mip_filter::linear);

constant float2 urbanRoof0[]={{0.418,0.529},{0.568,0.485},{0.766,0.513},{0.911,0.556},{0.649,0.641}};
constant float2 urbanRoof1[]={{0.198,0.438},{0.386,0.380},{0.517,0.413},{0.478,0.428},{0.568,0.461},{0.376,0.496}};
constant float2 urbanRoof2[]={{0.499,0.379},{0.867,0.382},{0.884,0.445},{0.755,0.465},{0.581,0.444},{0.589,0.423}};
constant float2 urbanRoof3[]={{0,0.584},{0.163,0.591},{0.393,0.735},{0.247,0.773},{0.082,0.759},{0,0.724}};
constant float2 urbanRoof4[]={{0.333,0.926},{0.595,0.867},{0.834,1.014},{0.992,0.953},{1.08,1.10},{0.425,1.10}};
constant float2 urbanRoof5[]={{0,0.457},{0.099,0.452},{0.196,0.546},{0,0.540}};
float urbanRegion(float2 p,constant float2* points,uint count,float feather) {
    float distance2=10;bool inside=false;
    for(uint i=0,j=count-1;i<count;j=i++) {
        float2 a=points[i],b=points[j],edge=b-a;
        float2 d=p-a-edge*clamp(dot(p-a,edge)/max(dot(edge,edge),1e-8f),0.0,1.0);
        distance2=min(distance2,dot(d,d));
        if((a.y>p.y)!=(b.y>p.y))if(p.x<a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y))inside=!inside;
    }
    return 1-smoothstep(-feather,feather,(inside ? -1.0:1.0)*sqrt(distance2));
}
float4 urbanPane(float2 uv) {
    float left=uv.x<0.2375 ? 0:uv.x<0.535 ? 0.2375:uv.x<0.8175 ? 0.535:0.8175;
    float right=uv.x<0.2375 ? 0.2375:uv.x<0.535 ? 0.535:uv.x<0.8175 ? 0.8175:1;
    float top=uv.y<0.290 ? 0:uv.y<0.694 ? 0.290:0.694;
    float bottom=uv.y<0.290 ? 0.290:uv.y<0.694 ? 0.694:1;
    return float4(left,top,right,bottom);
}
float urbanPaneEnvelope(float2 uv) {
    float4 pane=urbanPane(uv);
    float2 edge=min(uv-pane.xy,pane.zw-uv);
    return smoothstep(0.018,0.055,min(edge.x,edge.y));
}
kernel void urbanMasks(texture2d<float> art [[texture(0)]],texture2d<float,access::write> mask [[texture(1)]],
                       constant Uniforms& u [[buffer(0)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(mask.get_width(),mask.get_height())))return;
    float2 uv=(float2(p)+0.5)/float2(mask.get_width(),mask.get_height());
    if(u.options.x==25) {
        float4 pane=urbanPane(uv);float2 local=(uv-pane.xy)/(pane.zw-pane.xy);
        mask.write(float4(urbanPaneEnvelope(uv),local,pane.x*13+pane.y*7),p);return;
    }
    float roof=max(max(urbanRegion(uv,urbanRoof0,5,0.014),urbanRegion(uv,urbanRoof1,6,0.012)),
                   max(urbanRegion(uv,urbanRoof2,6,0.011),urbanRegion(uv,urbanRoof3,6,0.013)));
    roof=max(roof,max(urbanRegion(uv,urbanRoof4,6,0.012),urbanRegion(uv,urbanRoof5,4,0.010)));
    float3 c=art.sample(urbanLinear,uv).rgb;
    float paper=smoothstep(0.06,0.15,c.r-c.b)*smoothstep(0.70,0.87,c.r);
    float perspective=pow(saturate((uv.y-0.07)/0.93),1.8);
    float depth=perspective*0.35+roof*0.37+paper*perspective*0.08;
    float facade=(1-roof)*smoothstep(0.35,0.62,uv.y)*(1-paper);
    mask.write(float4(depth,roof,facade,perspective),p);
}
kernel void urbanInitialize(texture2d<float,access::write> a [[texture(0)]],texture2d<float,access::write> b [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(a.get_width(),a.get_height())))return;a.write(float4(0),p);b.write(float4(0),p);
}
kernel void urbanFlow(texture2d<float,access::read> source [[texture(0)]],texture2d<float,access::write> result [[texture(1)]],
                      texture2d<float> mask [[texture(2)]],constant Uniforms& u [[buffer(0)]],constant UrbanFrame& f [[buffer(1)]],
                      uint2 p [[thread_position_in_grid]]) {
    uint2 size=uint2(source.get_width(),source.get_height());if(any(p>=size))return;
    float2 uv=(float2(p)+0.5)/float2(size);
    float region=u.options.x==25 ? urbanPaneEnvelope(uv):smoothstep(0.08,0.2,uv.y);
    if(p.x==0 || p.y==0 || p.x+1==size.x || p.y+1==size.y || region<0.002){result.write(float4(0),p);return;}
    float2 q=source.read(p).xy;
    float lap=source.read(p+uint2(1,0)).x+source.read(p-uint2(1,0)).x+source.read(p+uint2(0,1)).x+source.read(p-uint2(0,1)).x-4*q.x;
    float2 delta=(uv-f.touch.xy)*float2(f.clock.z/f.clock.w,1);
    float force=f.touch.z*exp(-dot(delta,delta)*380)*(0.012+0.024*f.touch.w);
    float drift=(u.options.x==25 ? u.controls.z: u.controls.y)*0.0007*sin(f.clock.x*0.9+uv.x*13-uv.y*9);
    float velocity=(q.y+lap*0.19-q.x*0.018+(force+drift)*region)*0.958;
    result.write(float4(clamp(q.x+velocity,-0.65,0.65),velocity,0,0),p);
}
float2 urbanDisplace(float2 uv,texture2d<float> mask,texture2d<float> waves,constant Uniforms& u,constant UrbanFrame& f) {
    float time=f.clock.x;
    if(u.options.x==24) {
        float4 m=mask.sample(urbanLinear,uv);
        float2 view=f.page.zw*float2(0.028,0.019)+float2(sin(time*0.22),sin(time*0.17))*0.0015;
        float2 delta=(uv-f.touch.xy)*float2(f.clock.z/f.clock.w,1);
        float pressed=f.touch.z*exp(-dot(delta,delta)*200)*0.002;
        float wave=waves.sample(urbanLinear,uv).x;
        float2 d=view*m.x*u.parameters.x;
        d.y-=(wave*0.012+pressed)*(0.25+m.y*0.75)*max(u.parameters.x,0.25);
        d+=u.controls.y*m.y*float2(0.0007*sin(time*0.61+uv.y*7),0.0011*sin(time*0.44+uv.x*9))*sin(time*0.35);
        float2 border=min(uv,1-uv);
        return d*smoothstep(0.0,0.04,min(border.x,border.y));
    }
    float envelope=urbanPaneEnvelope(uv);
    if(envelope<=0)return float2(0);
    float4 pane=urbanPane(uv);float2 local=(uv-pane.xy)/(pane.zw-pane.xy);
    float seed=pane.x*13+pane.y*7;
    float2 step=float2(1.0/192,0);
    float2 gradient=float2(waves.sample(urbanLinear,uv+step).x-waves.sample(urbanLinear,uv-step).x,
                           waves.sample(urbanLinear,uv+step.yx).x-waves.sample(urbanLinear,uv-step.yx).x);
    float2 curl=float2(sin(local.y*9+time*0.72+seed)+0.45*sin(local.x*11-time*0.48),
                      cos(local.x*8-time*0.61+seed)+0.35*sin(local.y*12+time*0.57));
    float2 lens=float2(local.x-0.5,local.y-0.5)*dot(local-0.5,local-0.5);
    float2 delta=(uv-f.touch.xy)*float2(f.clock.z/f.clock.w,1);
    float2 touch=delta*f.touch.z*exp(-dot(delta,delta)*140)*0.15;
    float2 d=curl*(0.0015+u.controls.z*0.0035)*(0.35+u.controls.x*0.65);
    d+=lens*0.045*u.controls.x+gradient*0.12+touch+f.page.zw*float2(0.015,0.012)*(0.3+u.controls.x);
    return d*envelope*u.parameters.x;
}
float3 urbanGrade(float3 c,constant Uniforms& u) {
    if(u.parameters.w<0.5)return c;
    if(u.options.x==24) {
        if(u.parameters.w<1.5)return saturate(c*float3(0.80,0.88,1.02)+float3(0.004,0.006,0.025));
        float l=dot(c,float3(0.25,0.55,0.20));return mix(c,l*float3(1.06,0.94,0.76),0.62);
    }
    if(u.parameters.w<1.5)return saturate(c*float3(0.84,0.97,1.05)+float3(0.0,0.008,0.016));
    return saturate(c*float3(1.06,0.95,0.80));
}
kernel void urbanRender(texture2d<float> art [[texture(0)]],texture2d<float> mask [[texture(1)]],texture2d<float> waves [[texture(2)]],
                        texture2d<float,access::write> result [[texture(3)]],constant Uniforms& u [[buffer(0)]],constant UrbanFrame& f [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(result.get_width(),result.get_height())))return;
    float2 uv=(float2(p)+0.5)/u.viewport.xy,base=(uv-0.5)*f.page.xy+0.5;
    if(any(base<0)||any(base>1)) {
        float3 matte=u.options.x==24 ? float3(0.91,0.88,0.80):float3(0.055,0.062,0.059);
        matte+=(atNoise(uv*u.viewport.xy*0.75)-0.5)*(u.options.x==24 ? 0.008:0.004);
        result.write(float4(urbanGrade(matte,u),1),p);return;
    }
    float2 source=base;
    for(int i=0;i<3;++i)source=base-urbanDisplace(source,mask,waves,u,f);
    float pixel=max(f.page.x*f.clock.z/u.viewport.x,f.page.y*f.clock.w/u.viewport.y);
    float lod=max(0.0,log2(max(pixel,1.0)));
    float3 color=art.sample(urbanMip,source,level(lod)).rgb;
    if(u.options.x==24) {
        float4 m=mask.sample(urbanLinear,source);
        float light=smoothstep(0.39,0.78,dot(color,float3(0.21,0.72,0.07)));
        float selected=smoothstep(0.68,0.91,atNoise(floor(source*float2(95,170))));
        color+=float3(0.13,0.085,0.015)*m.z*light*selected*u.controls.z*(0.6+0.4*sin(f.clock.x*0.42+source.x*37));
    } else {
        float envelope=urbanPaneEnvelope(base),depth=u.controls.x*u.parameters.x;
        float4 pane=urbanPane(base);float2 local=(base-pane.xy)/(pane.zw-pane.xy);
        float2 chroma=envelope*depth*0.00075*float2(sin(local.y*8),cos(local.x*8));
        color.r=art.sample(urbanMip,source+chroma,level(lod)).r;
        color.b=art.sample(urbanMip,source-chroma,level(lod)).b;
        float2 edge=min(base-pane.xy,pane.zw-base);
        float rim=envelope*(1-smoothstep(0.04,0.085,min(edge.x,edge.y)));
        float glint=0.4+0.6*pow(max(0.0,sin(local.x*5+local.y*3+f.clock.x*0.6+pane.x*5)),8.0);
        color+=float3(0.12,0.14,0.12)*rim*glint*u.controls.y;
    }
    result.write(float4(saturate(urbanGrade(color,u)),1),p);
}
float2 urbanRoad(float t,uint route) {
    // Surveyed street centers in the original drawing. Piecewise segments keep
    // vehicles in the narrow canyons instead of rounding across roof corners.
    if(route==0) {
        return t<0.53 ? mix(float2(-0.05,0.986),float2(0.550,0.817),t/0.53)
                     : mix(float2(0.550,0.817),float2(1.07,0.674),(t-0.53)/0.47);
    }
    if(t<0.43)return mix(float2(0.287,0.583),float2(0.410,0.741),t/0.43);
    if(t<0.66)return mix(float2(0.410,0.741),float2(0.550,0.817),(t-0.43)/0.23);
    return mix(float2(0.550,0.817),float2(0.820,1.025),(t-0.66)/0.34);
}
struct UrbanCarOut {float4 position [[position]];float2 uv;float4 shade;};
vertex UrbanCarOut urbanCarVertex(uint vertexID [[vertex_id]],uint instance [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]],constant UrbanFrame& f [[buffer(1)]],
                                  texture2d<float> mask [[texture(0)]],texture2d<float> waves [[texture(1)]]) {
    const float2 corners[]={{-1,-1},{1,-1},{-1,1},{-1,1},{1,-1},{1,1}};
    float2 corner=corners[vertexID];uint route=instance%2,lane=(instance/2)%2;
    float seed=hash11(float(instance)+31),speed=0.025+0.018*seed;
    float t=fract(float(instance/2)/18.0+f.clock.x*speed*(lane==0 ? 1:-1));
    float2 center=urbanRoad(t,route);
    float aspect=f.clock.z/f.clock.w;
    float2 tangent=normalize((urbanRoad(min(t+0.001,1.0),route)-urbanRoad(max(t-0.001,0.0),route))*float2(aspect,1));
    float2 side=float2(-tangent.y,tangent.x);
    center+=side*float2(1/aspect,1)*(lane==0 ? 0.004:-0.004);
    float scale=mix(0.0009,0.0028,smoothstep(0.5,1.0,center.y));
    float2 local=(side*corner.x*scale+tangent*corner.y*scale*(seed>0.85 ? 2.4:1.6))*float2(1/aspect,1);
    float2 page=center+local+urbanDisplace(center,mask,waves,u,f);
    float2 screen=(page-0.5)/f.page.xy+0.5;
    // Roof masks also occlude traffic when a narrow lane runs along a slab.
    float opacity=min(1.0,u.controls.x)*(1-smoothstep(0.08,0.45,mask.sample(urbanLinear,center+local).y));
    if(float(instance)>=ceil(u.controls.x*24) || any(page<0)||any(page>1))opacity=0;
    return {float4(screen*float2(2,-2)+float2(-1,1),0,1),corner,float4(seed,opacity,float(route),0)};
}
fragment float4 urbanCarFragment(UrbanCarOut in [[stage_in]],constant Uniforms& u [[buffer(0)]]) {
    float2 p=in.uv;
    float edge=1-smoothstep(0.80,1.0,max(abs(p.x),abs(p.y)));
    float3 ink=in.shade.x>0.85 ? float3(0.39,0.32,0.16):float3(0.12,0.14,0.21);
    float windows=(1-smoothstep(0.58,0.74,abs(p.x)))*(1-smoothstep(0.28,0.45,abs(p.y+0.25)));
    ink=mix(ink,float3(0.87,0.87,0.80),windows*0.9);
    ink=urbanGrade(ink,u);
    float alpha=edge*in.shade.y;return float4(ink*alpha,alpha);
}
