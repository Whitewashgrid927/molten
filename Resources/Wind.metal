// Tracer advection through a procedural turbine wake, not a calibrated CFD solver.
// Every tracer has persistent position/velocity. No neighbor grid or history textures.
struct WindFrame {
    float4 eye,right,up,forward,state,wind,pointer,viewport;
};
struct WindParticle { float4 position,velocity; };
struct WindVertex { float4 position,normal,color; };
float windHash(float n) { return fract(sin(n*127.13+17.77)*43758.5453); }
uint windBits(uint x) { x^=x>>16;x*=0x7feb352du;x^=x>>15;x*=0x846ca68bu;x^=x>>16;return x; }
float3 windHash3(uint i) {
    // Integer hashing avoids float-sine quantization collapsing a million
    // tracers onto a small number of identical paths.
    return float3(windBits(i^0x517cc1b7u)>>8,windBits(i^0x68bc21ebu)>>8,windBits(i^0x02e5be93u)>>8)/16777216.;
}
float4 windClip(float3 p,constant WindFrame& f) {
    float3 q=p-f.eye.xyz;
    float z=dot(q,f.forward.xyz),aspect=f.viewport.x/f.viewport.y;
    return float4(dot(q,f.right.xyz)*f.right.w/aspect,dot(q,f.up.xyz)*f.right.w,z*30./29.9-3./29.9,z);
}
float3 windField(float3 p,constant WindFrame& f) {
    float2 radial=float2(p.y-0.45,p.z);float r=length(radial),down=max(0.,1.25-p.x);
    float wake=smoothstep(0.,0.20,down)*exp(-down*0.07)*exp(-pow(r/2.4,6));
    float deficit=0.40*exp(-r*r/2.8)*wake;
    float3 v=float3(-f.wind.x*(1-deficit),0,0);
    float swirl=f.wind.y*0.22*wake/(0.6+r*r);
    v.yz+=float2(-radial.y,radial.x)*swirl;
    float helix=f.state.z-down*f.wind.y/max(0.35,f.wind.x*0.85);
    for(int blade=0;blade<3;blade++){
        float angle=helix+float(blade)*2.0943951;
        float radius=1.91+down*0.025;
        float2 center=float2(cos(angle),sin(angle))*radius;
        float2 d=radial-center;float d2=dot(d,d);
        v.yz+=float2(-d.y,d.x)*(f.wind.y*0.13*wake/(0.10+d2));
        v.x+=exp(-d2*5)*f.wind.x*0.12*wake;
    }
    // Bounded coherent eddies at two scales retain the recognizable helical wake.
    float t=f.state.x;
    float3 curl=float3(sin(p.y*2.5+t*0.53)+cos(p.z*2.1-t*0.31),
                      sin(p.z*2.7+p.x*1.8-t*0.48),cos(p.x*2.2+p.y*2.4+t*0.29));
    curl+=float3(sin(p.z*7.3+p.y*4.1-t),cos(p.x*6.1+p.z*5.7+t*0.8),sin(p.y*6.3-p.x*4.2+t))*0.28;
    v+=curl*(0.14+down*0.025)*f.wind.z*wake;
    v.yz+=radial*(0.012+0.015*f.wind.z)*wake;
    if(f.pointer.w>0){
        float3 d=p-f.pointer.xyz;
        float weight=exp(-dot(d,d)*0.8);
        v+=float3(-d.y,d.x,d.x*0.25)*weight*2.7+float3(-0.25,0.2,0)*weight;
    }
    return clamp(v,float3(-6),float3(6));
}
float3 windBirth(uint id,float generation,constant WindFrame& f) {
    float3 h=windHash3(id+uint(generation)*7919);
    float radius=pow(h.y,0.47)*1.96,angle=h.z*6.283185;
    if(h.x>0.72)radius=1.80+h.y*0.16;
    return float3(1.24,0.45+cos(angle)*radius,sin(angle)*radius);
}
kernel void windInitialize(constant WindFrame& f [[buffer(0)]],device WindParticle* particles [[buffer(1)]],
                           uint id [[thread_position_in_grid]]) {
    if(id>=uint(f.state.w))return;
    float3 h=windHash3(id),p=windBirth(id,0,f);
    float down=windHash3(id^0x98b5a12fu).x*6.8;p.x-=down;
    float angle=atan2(p.z,p.y-0.45)+down*0.22+0.16*sin(down*1.8+h.z*9);
    float r=length(float2(p.y-0.45,p.z))*(1+down*0.015);
    r+=sin(angle*3-down*2.2)*0.10*f.wind.z;
    p.y=0.45+cos(angle)*r;p.z=sin(angle)*r;
    float3 v=windField(p,f);
    particles[id].position=float4(p,0);
    particles[id].velocity=float4(v,0);
}
kernel void windStep(constant WindFrame& f [[buffer(0)]],device WindParticle* particles [[buffer(1)]],
                     uint id [[thread_position_in_grid]]) {
    if(id>=uint(f.state.w))return;
    WindParticle a=particles[id];
    float3 v=windField(a.position.xyz,f);
    float3 next=a.position.xyz+v*(f.state.y*0.5);
    float3 velocity=windField(next,f);
    a.position.xyz+=velocity*f.state.y;
    a.velocity=float4(velocity,length(velocity-v)*12);
    float r=length(a.position.yz-float2(0.45,0));
    if(a.position.x< -5.6 || a.position.x>2 || r>3.25 || !all(isfinite(a.position.xyz))){
        a.position.w+=1;a.position.xyz=windBirth(id,a.position.w,f);a.velocity=float4(windField(a.position.xyz,f),0);
    }
    particles[id]=a;
}
struct WindSolidOut { float4 position [[position]]; float3 normal; float3 world; float3 color; };
vertex WindSolidOut windSolidVertex(constant WindFrame& f [[buffer(0)]],device const WindVertex* vertices [[buffer(1)]],uint id [[vertex_id]]) {
    WindVertex v=vertices[id];float3 p=v.position.xyz,n=v.normal.xyz;
    if(v.position.w>0){
        float3 q=p-float3(1.25,0.45,0);float c=cos(f.state.z),s=sin(f.state.z);
        p=float3(q.x,q.y*c-q.z*s,q.y*s+q.z*c)+float3(1.25,0.45,0);
        n=float3(n.x,n.y*c-n.z*s,n.y*s+n.z*c);
    }
    WindSolidOut out;out.position=windClip(p,f);out.world=p;out.normal=n;out.color=v.color.rgb;return out;
}
fragment float4 windSolidFragment(WindSolidOut in [[stage_in]],constant WindFrame& f [[buffer(0)]]) {
    float3 n=normalize(in.normal),v=normalize(f.eye.xyz-in.world),l=normalize(float3(2,4,5));
    if(dot(n,v)<0)n=-n;
    float diffuse=max(0.,dot(n,l)),spec=pow(max(0.,dot(n,normalize(l+v))),65);
    float rim=pow(1-max(0.,dot(n,v)),3);
    float3 color=in.color*(0.19+0.67*diffuse)+float3(0.60,0.77,1)*rim*0.12+spec*0.24;
    return float4(color,1);
}
float3 windPalette(float r,float energy,float x,int preset) {
    float t=clamp(r/2.12+energy*0.10+sin(x*1.3+r*6)*0.055,0.,1.);
    if(preset==1)return mix(float3(0.08,0.35,0.9),float3(0.55,1.1,0.9),t)+energy*float3(0.2,0.3,0.1);
    if(preset==2)return mix(float3(0.22,0.055,0.55),float3(1.5,0.32,0.07),smoothstep(0.1,0.85,t))+pow(t,5)*float3(0.25,0.75,0.3);
    float3 a=float3(0.12,0.28,0.95),b=float3(0.10,1.02,0.92),c=float3(1.08,0.94,0.35),d=float3(1.25,0.31,0.67);
    if(t<0.42)return mix(a,b,smoothstep(0.,0.42,t));
    if(t<0.70)return mix(b,c,smoothstep(0.42,0.70,t));
    return mix(c,d,smoothstep(0.70,0.97,t));
}
struct WindParticleOut { float4 position [[position]]; float size [[point_size]]; float3 color; float opacity; };
vertex WindParticleOut windParticleVertex(constant WindFrame& f [[buffer(0)]],device const WindParticle* particles [[buffer(1)]],uint id [[vertex_id]]) {
    WindParticle a=particles[id];float3 p=a.position.xyz;
    WindParticleOut out;out.position=windClip(p,f);
    float scale=f.viewport.x/1440.;
    float base=f.viewport.z<0.5 ? 2.8:(f.viewport.z<1.5 ? 1.9:1.25);
    out.size=max(1.,base*scale);
    float r=length(p.yz-float2(0.45,0));
    float energy=clamp(a.velocity.w+abs(a.velocity.y)*0.4,0.,1.);
    float colorRadius=r+0.14*sin(p.x*2.2+p.y*2+p.z*3)+0.10*sin(p.y*5-p.x*3);
    out.color=windPalette(colorRadius,energy,p.x,int(f.viewport.w+0.5));
    float endFade=smoothstep(-5.6,-5.1,p.x)*(1-smoothstep(1.18,1.26,p.x));
    float brightness=0.72+0.55*windHash(float(id)*1.17);
    out.opacity=0.68*(900000./f.state.w)*(scale*scale/(out.size*out.size))*f.wind.w*endFade*brightness;
    if(out.position.w<0.1){out.position=float4(2,2,2,1);out.opacity=0;}
    return out;
}
fragment float4 windParticleFragment(WindParticleOut in [[stage_in]],float2 point [[point_coord]]) {
    float2 q=point*2-1;float r2=dot(q,q);
    if(r2>1)discard_fragment();
    float coverage=exp(-r2*2.5)*in.opacity;
    return float4(in.color*coverage,0);
}
kernel void windResolve(constant WindFrame& f [[buffer(0)]],texture2d<float,access::read> color [[texture(0)]],
                        texture2d<float,access::write> output [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(output.get_width(),output.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(output.get_width(),output.get_height());
    float3 c=color.read(id).rgb;
    float vignette=1-0.30*dot(uv-0.5,uv-0.5);
    c*=vignette*1.28;
    c=c/(1+c*0.58);
    c=pow(max(c,0.),float3(1/2.2));
    output.write(float4(clamp(c,0.,1.),1),id);
}
