// Glass geometry and optics are synthesized here; the input is an ordinary image.
struct GlassEffectFrame {float4 page,touch,optics,clock;};
constexpr sampler blockLinear(coord::normalized,address::clamp_to_edge,filter::linear);
constexpr sampler blockMip(coord::normalized,address::mirrored_repeat,filter::linear,mip_filter::linear);
float blockDistance(float2 p,float seed) {
    float2 q=abs(p)-float2(0.419);
    float d=length(max(q,0.0))+min(max(q.x,q.y),0.0)-0.067;
    return d+0.0018*sin(p.x*27+seed)*sin(p.y*23-seed);
}
float blockEnvelope(float2 uv,float2 cells) {
    float d=blockDistance(fract(uv*cells)-0.5,0);
    return 1-smoothstep(-0.065,-0.020,d);
}
kernel void blockInitialize(texture2d<float,access::write> a [[texture(0)]],texture2d<float,access::write> b [[texture(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(a.get_width(),a.get_height())))return;a.write(float4(0),p);b.write(float4(0),p);
}
kernel void blockFlow(texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::write> b [[texture(1)]],
                      constant Uniforms& u [[buffer(0)]],constant GlassEffectFrame& f [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
    uint2 size=uint2(a.get_width(),a.get_height());if(any(p>=size))return;
    float2 uv=(float2(p)+0.5)/float2(size),cell=floor(uv*f.optics.xy);
    float envelope=blockEnvelope(uv,f.optics.xy);
    if(p.x==0||p.y==0||p.x+1==size.x||p.y+1==size.y||envelope<=0){b.write(float4(0),p);return;}
    float2 q=a.read(p).xy;float lap=-4*q.x;
    const int2 directions[]={{1,0},{-1,0},{0,1},{0,-1}};
    for(int i=0;i<4;i++) {
        uint2 other=uint2(int2(p)+directions[i]);
        float2 neighbor=floor(((float2(other)+0.5)/float2(size))*f.optics.xy);
        if(all(neighbor==cell))lap+=a.read(other).x;
    }
    float2 delta=(uv-f.touch.xy)*float2(f.optics.z/f.optics.w,1);
    float force=all(floor(f.touch.xy*f.optics.xy)==cell) ? f.touch.z*exp(-dot(delta,delta)*650)*(0.015+0.025*f.touch.w):0;
    float velocity=(q.y+lap*0.19-q.x*0.022+force*envelope)*0.952;
    b.write(float4(clamp(q.x+velocity,-0.65,0.65),velocity,0,0),p);
}
float blockHeight(float2 p,float seed,float time,float material,float ripple) {
    float d=blockDistance(p,seed),bevel=clamp(-d/0.085,0.0,1.0);
    float dome=sqrt(max(0.0,1-(1-bevel)*(1-bevel)))*0.052;
    float amplitude=material<0.5 ? 1.0:material<1.5 ? 0.18:0.58;
    float motion=ripple*0.24*sin(time*0.48+seed);
    float uneven=0.013*sin(p.x*9+2*sin(p.y*7)+seed+motion)
                 +0.006*sin(p.y*21-p.x*5+seed*1.3-motion)
                 +0.0025*sin(p.x*37+p.y*16+seed*0.7);
    return dome+(0.014*(1-dot(p,p)*2)+uneven*amplitude)*(1-smoothstep(-0.09,-0.015,d));
}
float3 blockEnvironment(float3 ray,float seed) {
    float sky=smoothstep(-0.25,0.75,ray.y);
    float3 color=mix(float3(0.16,0.22,0.19),float3(0.85,0.95,1.0),sky);
    float strip=exp(-pow((ray.x+0.20+0.09*sin(seed))*14,2.0))*smoothstep(-0.1,0.5,ray.y);
    return color+strip*float3(0.4,0.45,0.5);
}
kernel void blockRender(texture2d<float> art [[texture(0)]],texture2d<float> waves [[texture(1)]],texture2d<float,access::write> out [[texture(2)]],
                        constant Uniforms& u [[buffer(0)]],constant GlassEffectFrame& f [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(out.get_width(),out.get_height())))return;
    float2 uv=(float2(p)+0.5)/u.viewport.xy,base=(uv-0.5)*f.page.xy+0.5;
    if(any(base<0)||any(base>1)){out.write(float4(0.027,0.034,0.031,1),p);return;}
    float density=max(f.page.x*f.optics.z/u.viewport.x,f.page.y*f.optics.w/u.viewport.y);
    float lod=max(0.0,log2(max(1.0,density)));
    float3 original=art.sample(blockMip,base,level(lod)).rgb;
    float amount=clamp(u.parameters.x,0.0,2.0);
    if(amount<=0){out.write(float4(original,1),p);return;}
    float2 cells=f.optics.xy,cell=floor(base*cells),local=fract(base*cells)-0.5;
    float seed=hash11(dot(cell,float2(71.3,153.7))+9)*6.28318;
    float d=blockDistance(local,seed);
    float aa=max(f.page.x*cells.x/u.viewport.x,f.page.y*cells.y/u.viewport.y)*0.8;
    float coverage=1-smoothstep(-aa,aa,d);
    float3 mortar=float3(0.012,0.020,0.014)*(0.88+0.12*sin(base.x*790+base.y*470));
    if(coverage<=0){out.write(float4(mix(original,mortar,smoothstep(0.0,0.08,amount)),1),p);return;}
    float material=u.parameters.w,thickness=clamp(u.controls.x,0.1,2.0),ripple=u.controls.y;
    float2 e=float2(0.002,0);
    float2 slope=float2(blockHeight(local+e,seed,f.clock.x,material,ripple)-blockHeight(local-e,seed,f.clock.x,material,ripple),
                        blockHeight(local+e.yx,seed,f.clock.x,material,ripple)-blockHeight(local-e.yx,seed,f.clock.x,material,ripple))/(2*e.x);
    float2 texel=float2(1.0/256,0);
    float2 wave=float2(waves.sample(blockLinear,base+texel).x-waves.sample(blockLinear,base-texel).x,
                       waves.sample(blockLinear,base+texel.yx).x-waves.sample(blockLinear,base-texel.yx).x)*10;
    float2 delta=(base-f.touch.xy)*float2(f.optics.z/f.optics.w,1);
    float2 pressure=delta*f.touch.z*exp(-dot(delta,delta)*200)*6;
    slope+= (wave+pressure)*blockEnvelope(base,cells)*ripple;
    float3 normal=normalize(float3(-slope*(0.65+0.35*thickness),1));
    float3 incident=normalize(float3(f.page.z*0.20,f.page.w*0.16,-1));
    float3 inside=refract(incident,normal,1.0/1.48);
    float2 backSlope=0.10*float2(sin(local.y*12+seed),cos(local.x*10-seed));
    float3 outgoing=refract(inside,normalize(float3(-backSlope,1)),1.48);
    if(dot(outgoing,outgoing)<0.01)outgoing=inside;
    float2 offset=(inside.xy/max(0.25,-inside.z)*0.23+outgoing.xy/max(0.35,-outgoing.z)*0.10)*thickness*amount;
    offset=clamp(offset,float2(-0.34),float2(0.34));
    float2 source=base+offset/cells+f.page.zw*float2(0.015,0.012);
    float blur=material>1.5 ? 2.7:0;
    float chroma=material<0.5 ? 0.018:0.007;
    float3 color=art.sample(blockMip,source,level(lod+blur)).rgb;
    color.r=art.sample(blockMip,source+offset/cells*chroma,level(lod+blur)).r;
    color.b=art.sample(blockMip,source-offset/cells*chroma,level(lod+blur)).b;
    if(material>1.5) {
        float2 blurStep=0.004*thickness;
        color=(color*2+art.sample(blockMip,source+blurStep,level(lod+blur)).rgb
                    +art.sample(blockMip,source-blurStep,level(lod+blur)).rgb
                    +art.sample(blockMip,source+blurStep*float2(1,-1),level(lod+blur)).rgb
                    +art.sample(blockMip,source+blurStep*float2(-1,1),level(lod+blur)).rgb)/6;
        color=mix(color,float3(0.77,0.83,0.80),0.07);
    }
    float edge=1-smoothstep(-0.10,-0.018,d);
    float cosine=max(0.0,dot(-incident,normal)),fresnel=0.038+0.962*pow(1-cosine,5.0);
    float3 reflected=blockEnvironment(reflect(incident,normal),seed);
    color*=exp(-float3(0.11,0.025,0.075)*thickness*(0.18+(1-edge)*0.6));
    color=mix(color,reflected,min(0.78,fresnel*(1.0+0.4*thickness)));
    float rim=exp(-pow((d+0.019)/0.007,2.0));
    float inner=exp(-pow((d+0.050)/0.012,2.0));
    float3 light=normalize(float3(-0.45+f.page.z*0.25,-0.62+f.page.w*0.2,0.75));
    float spec=pow(max(0.0,dot(normal,normalize(light-incident))),material>1.5 ? 30.0:95.0);
    color+=spec*0.28+rim*float3(0.26,0.32,0.26)*(0.55+0.45*cos(local.x*7-local.y*5+seed));
    color+=inner*float3(0.09,0.15,0.10);color*=1-0.16*exp(-pow((d+0.007)/0.006,2.0));
    color=mix(mortar,saturate(color),coverage);
    out.write(float4(mix(original,color,smoothstep(0.0,0.08,amount)),1),p);
}
