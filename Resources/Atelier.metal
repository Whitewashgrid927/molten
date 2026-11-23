// Two tactile worlds. Color is authored as ink on paper, without film tonemapping.
struct AtelierUniforms { float4 record, touch, clock; };
struct KoiActor { float4 body; float4 motion; };
float atHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float atNoise(float2 p) {
    float2 i=floor(p), f=fract(p); f=f*f*(3-2*f);
    return mix(mix(atHash(i),atHash(i+float2(1,0)),f.x),mix(atHash(i+float2(0,1)),atHash(i+1),f.x),f.y);
}
float atFbm(float2 p) { return atNoise(p)*0.56+atNoise(p*2.07+19)*0.28+atNoise(p*4.17-7)*0.16; }
float2 atRotate(float2 p,float a) { return float2(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y); }
float atLine(float2 p,float2 a,float2 b) {
    float2 d=b-a; return length(p-a-d*clamp(dot(p-a,d)/max(dot(d,d),1e-5),0.0,1.0));
}
float atBox(float2 p,float2 b) { float2 d=abs(p)-b; return length(max(d,0.0))+min(max(d.x,d.y),0.0); }
float atMask(float d,float aa) { return 1-smoothstep(-aa,aa,d); }
float2 atPoint(float2 uv,constant Uniforms& u,constant StageUniforms& s) {
    float2 p=(uv-0.5)*float2(u.viewport.x/u.viewport.y,1)*3.1*exp(s.camera.z);
    p.y/=max(0.5,cos(s.camera.y*0.5)); return atRotate(p,s.camera.x*0.12);
}

kernel void atelierInitialize(texture2d<float,access::write> w0 [[texture(0)]],
                              texture2d<float,access::write> w1 [[texture(1)]],
                              device KoiActor* f0 [[buffer(3)]],device KoiActor* f1 [[buffer(4)]],
                              uint2 p [[thread_position_in_grid]]) {
    w0.write(float4(0),p); w1.write(float4(0),p);
    if(p.y==0 && p.x<7) {
        float a=float(p.x)*2*PI/7+0.32, r=0.53+0.20*sin(float(p.x)*3.7);
        KoiActor f; f.body=float4(cos(a)*r,sin(a)*r,a+PI/2,1.02+0.12*sin(float(p.x)*4.1));
        f.motion=float4(0.12, float(p.x)*1.7,0,0); f0[p.x]=f; f1[p.x]=f;
    }
}
kernel void atelierWaves(texture2d<float,access::read> previous [[texture(0)]],
                         texture2d<float,access::write> next [[texture(1)]],
                         constant Uniforms& u [[buffer(0)]],constant AtelierUniforms& a [[buffer(2)]],
                         device const KoiActor* fish [[buffer(3)]],uint2 p [[thread_position_in_grid]]) {
    uint w=previous.get_width(),h=previous.get_height();
    float2 xy=(float2(p)+0.5)/float2(w,h)*2.2-1.1;
    float4 v=previous.read(p);
    float lap=previous.read(neighbor(p,int2(1,0),w,h)).x+previous.read(neighbor(p,int2(-1,0),w,h)).x
        +previous.read(neighbor(p,int2(0,1),w,h)).x+previous.read(neighbor(p,int2(0,-1),w,h)).x-4*v.x;
    float force=0;
    if(a.touch.z>0.5) force=exp(-dot(xy-a.touch.xy,xy-a.touch.xy)*380)*0.055;
    if(u.options.x==20) {
        for(uint i=0;i<7;i++) { float2 d=xy-fish[i].body.xy; force+=exp(-dot(d,d)*1300)*sin(a.clock.x*12+float(i))*0.0018; }
    }
    float velocity=(v.y+lap*0.28+force)*0.965;
    float height=clamp(v.x+velocity,-1.0,1.0);
    float ink=max(v.z*0.993,force*5);
    float boundary=u.options.x==20 ? 1-smoothstep(0.93,0.985,length(xy)) : 1-smoothstep(0.94,1.08,max(abs(xy.x),abs(xy.y)));
    next.write(float4(height*boundary,velocity*boundary,ink*boundary,0),p);
}
kernel void koiStep(constant Uniforms& u [[buffer(0)]],constant AtelierUniforms& a [[buffer(2)]],
                    device const KoiActor* previous [[buffer(3)]],device KoiActor* next [[buffer(4)]],
                    uint id [[thread_position_in_grid]]) {
    if(id>=7)return;
    KoiActor f=previous[id]; float2 p=f.body.xy;
    float r=max(length(p),0.01), dt=1.0/60;
    float2 radial=p/r, tangent=float2(-radial.y,radial.x);
    float desiredRadius=0.53+0.17*sin(float(id)*3.7+a.clock.x*0.13);
    float direction=a.record.y < -0.15 ? -1 : 1;
    float2 desire=tangent*(0.15*u.controls.x*direction)+radial*(desiredRadius-r)*0.9;
    for(uint j=0;j<7;j++)if(j!=id) {
        float2 d=p-previous[j].body.xy; float d2=dot(d,d);
        desire+=d/max(d2,0.006)*0.016*(1-smoothstep(0.12,0.32,sqrt(d2)));
        desire+=float2(cos(previous[j].body.z),sin(previous[j].body.z))*u.controls.y*0.012*(1-smoothstep(0.2,0.6,sqrt(d2)));
    }
    if(a.touch.z>0.5) {
        float2 d=p-a.touch.xy; float d2=dot(d,d);
        desire+=d/max(d2,0.015)*0.055*(1-smoothstep(0.1,0.65,sqrt(d2)));
    }
    desire+=float2(sin(a.clock.x*0.42+float(id)*4),cos(a.clock.x*0.37+float(id)))*0.017;
    float target=atan2(desire.y,desire.x);
    float turn=atan2(sin(target-f.body.z),cos(target-f.body.z));
    f.body.z+=clamp(turn,-dt*2.4,dt*2.4);
    f.body.z=atan2(sin(f.body.z),cos(f.body.z));
    float swim=(0.10+0.045*sin(float(id)*2.3))*u.controls.x;
    float2 flow=tangent*clamp(a.record.y,-3.0,3.0)*r*0.22;
    p+=(float2(cos(f.body.z),sin(f.body.z))*swim+flow)*dt;
    float radius=length(p);
    if(radius>0.80)p*=0.80/radius;
    if(radius<0.31)p*=0.31/max(radius,0.001);
    f.body.xy=p; f.motion.x=swim; f.motion.y=fmod(f.motion.y+dt*(4+swim*24),2*PI);
    next[id]=f;
}

float atFishBody(float2 q) {
    float x=q.x;
    float width=0.061*sqrt(max(0.0,1-pow((x-0.025)/0.145,2.0)))*(0.72+0.28*smoothstep(-0.1,0.1,x));
    return max(abs(q.y)-width,max(-0.121-x,x-0.17));
}
float atFin(float2 p,float2 a,float2 b,float2 c) {
    float2 ba=b-a,cb=c-b,ac=a-c;
    float s=sign(ba.x*ac.y-ba.y*ac.x);
    float d=min(atLine(p,a,b),min(atLine(p,b,c),atLine(p,c,a)));
    bool inside=s*(ba.x*(p.y-a.y)-ba.y*(p.x-a.x))<=0
        &&s*(cb.x*(p.y-b.y)-cb.y*(p.x-b.x))<=0
        &&s*(ac.x*(p.y-c.y)-ac.y*(p.x-c.x))<=0;
    return inside ? -d : d;
}
float3 atKoi(float3 color,float2 p,KoiActor fish,uint id,float aa,float time,int preset) {
    float scale=fish.body.w;
    float2 q=atRotate(p-fish.body.xy,-fish.body.z)/scale;
    if(length(q)>0.34)return color;
    float bend=sin(fish.motion.y)*0.024;
    q.y-=sin(clamp((0.13-q.x)*7.0,0.0,3.5))*bend;
    float2 shadowQ=q-float2(0.012,0.022);
    float shadow=atFishBody(shadowQ);
    color*=1-0.21*(1-smoothstep(-0.01,0.035,shadow));
    float tail=atFin(q,float2(-0.105,0),float2(-0.255,-0.074+bend),float2(-0.207,bend));
    tail=min(tail,atFin(q,float2(-0.105,0),float2(-0.207,bend),float2(-0.255,0.074+bend)));
    float fin=min(atFin(q,float2(0.05,0.032),float2(-0.014,0.10+0.01*sin(time*5+id)),float2(-0.05,0.029)),
                  atFin(q,float2(0.05,-0.032),float2(-0.014,-0.10-0.01*sin(time*5+id)),float2(-0.05,-0.029)));
    float3 cream=float3(0.96,0.94,0.82);
    float finLines=0.035*cos(atan2(q.y,q.x+0.10)*80);
    color=mix(color,cream+finLines,atMask(min(fin,tail),aa)*0.73);
    float body=atFishBody(q),mask=atMask(body,aa);
    float patches=atNoise(q*18+float(id)*11);
    float redMask=smoothstep(0.51,0.55,patches+0.18*sin(q.x*38+float(id)));
    redMask*=1-smoothstep(0.115,0.16,q.x);
    float3 vermilion=preset==1?float3(0.96,0.49,0.08):float3(0.79,0.15,0.085);
    float3 bodyColor=mix(cream,vermilion,redMask);
    if(id==5 || preset==2)bodyColor=mix(bodyColor,float3(0.12,0.15,0.14),smoothstep(0.68,0.72,atFbm(q*32-float(id)*4)));
    bodyColor*=0.87+0.13*(1-smoothstep(0.01,0.055,abs(q.y)));
    float gill=abs(length((q-float2(0.105,0))*float2(0.6,1))-0.045);
    bodyColor*=1-0.10*atMask(gill-0.001,aa);
    color=mix(color,bodyColor,mask);
    for(int side=-1;side<=1;side+=2) {
        float eye=length(q-float2(0.125,0.025*side));
        color=mix(color,float3(0.08,0.12,0.10),atMask(eye-0.0045,aa));
        color=mix(color,cream,atMask(length(q-float2(0.126,0.024*side))-0.0015,aa));
    }
    return color;
}
kernel void koiRender(texture2d<float,access::write> output [[texture(0)]],texture2d<float> waves [[texture(1)]],
                      constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],
                      constant AtelierUniforms& a [[buffer(2)]],device const KoiActor* fish [[buffer(3)]],
                      uint2 pixel [[thread_position_in_grid]]) {
    float2 uv=(float2(pixel)+0.5)/u.viewport.xy,p=atPoint(uv,u,s);
    float aa=2.7/u.viewport.y*exp(s.camera.z),r=length(p); int preset=int(u.parameters.w);
    float paper=atNoise(p*230)*0.5+atNoise(p*68)*0.3+atNoise(p*4)*0.2-0.5;
    float3 paperColor=preset==2?float3(0.14,0.19,0.20):float3(0.90,0.875,0.80);
    float3 color=paperColor+paper*0.085*u.controls.z;
    float shadow=1-smoothstep(0.95,1.08,length(p-float2(0.018,0.038)));
    color*=1-shadow*0.20;
    float rim=atMask(r-1.005,aa);
    color=mix(color,float3(0.15,0.35,0.34)*(0.82+0.18*dot(normalize(p+0.0001),normalize(float2(-1,-1)))),rim);
    if(r<0.994) {
        constexpr sampler linearSampler(coord::normalized,address::clamp_to_edge,filter::linear);
        float2 wuv=(p+1.1)/2.2,texel=1.0/float2(waves.get_width(),waves.get_height());
        float wave=waves.sample(linearSampler,wuv).x;
        float2 normal=float2(waves.sample(linearSampler,wuv+float2(texel.x,0)).x-waves.sample(linearSampler,wuv-float2(texel.x,0)).x,
                             waves.sample(linearSampler,wuv+float2(0,texel.y)).x-waves.sample(linearSampler,wuv-float2(0,texel.y)).x);
        float2 wp=p+normal*0.12*u.parameters.x;
        float wr=length(wp),theta=atan2(wp.y,wp.x)-a.record.x;
        float3 teal=preset==1?float3(0.19,0.44,0.33):preset==2?float3(0.06,0.24,0.30):float3(0.075,0.43,0.48);
        // Filter grooves above the pixel budget; otherwise resizing produces
        // moving moire bands that look like unintended waves in the platter.
        float footprint=3.1/u.viewport.y*exp(s.camera.z)/max(0.5,cos(s.camera.y*0.5));
        float rings=sin(wr*440)*0.006+sin(wr*950+atNoise(wp*15)*0.6)*0.010*(1-smoothstep(2.0,PI,950*footprint));
        float sheen=pow(abs(sin(theta+0.3)),16.0)*0.045;
        color=teal*(0.82+0.22*smoothstep(0.2,0.98,wr))+rings+sheen+paper*0.035;
        color+=normal.x*0.7*u.parameters.x+normal.y*0.4;
        color+=pow(max(0.0,sin(wr*95-a.clock.x*2+sin(theta*5)*0.3)),18.0)*0.012;
        for(uint i=0;i<7;i++) {
            float2 d=wp-fish[i].body.xy;
            float2 local=atRotate(d,-fish[i].body.z);
            float wake=exp(-abs(local.y)*42)*exp(-pow(local.x+0.15,2.0)*25)*(1-smoothstep(-0.02,0.05,local.x));
            color+=wake*pow(max(0.0,sin(length(d)*180-a.clock.x*8)),12.0)*0.06*u.parameters.x;
            color=atKoi(color,wp,fish[i],i,aa,a.clock.x,preset);
        }
        // The cut lily-pad label rotates with the vinyl, with radial branching veins.
        float2 lp=atRotate(p,-a.record.x*0.34-sin(a.clock.x*0.7)*0.025);
        lp.y*=1+wave*0.015;
        float lr=length(lp),la=atan2(lp.y,lp.x);
        float leafD=lr-(0.268+0.004*sin(la*11));
        float notch=max(-lp.x,abs(lp.y)-lp.x*0.16);
        leafD=max(leafD,-notch);
        float leafShadow=max(length(lp-float2(0.008,0.014))-0.276,-notch);
        color*=1-0.30*(1-smoothstep(-0.003,0.02,leafShadow));
        float vein=pow(max(0.0,cos(la*12+sin(lr*18)*0.25)),22.0);
        float branches=pow(max(0.0,cos(lr*115+la*13)),30.0)*0.35;
        float3 leaf=mix(float3(0.43,0.55,0.055),float3(0.72,0.76,0.12),0.55+paper);
        leaf*=1-0.25*vein-branches*0.16;
        leaf+=0.08*pow(max(0.0,-lp.x-lp.y),1.0);
        color=mix(color,leaf,atMask(leafD,aa));
        color=mix(color,float3(0.25,0.32,0.23),atMask(lr-0.018,aa));
        color=mix(color,float3(0.86,0.88,0.75),atMask(length(lp+float2(0.002))-0.012,aa));
        if(a.touch.z>0.5) {
            float d=length(p-a.touch.xy);
            color+=float3(0.08,0.12,0.10)*exp(-d*15)*pow(max(0.0,cos(d*140)),12.0)*u.parameters.x;
        }
        color=mix(color,teal*1.30,atMask(abs(r-0.976)-0.003,aa)*0.6);
    }
    // A physical speed fader, motor switch and hinged tonearm.
    float2 sp=p-float2(-1.24,0);
    color*=1-0.13*(1-smoothstep(-0.02,0.03,atBox(sp-float2(0.009,0.014),float2(0.045,0.43))-0.045));
    color=mix(color,float3(0.17,0.47,0.48),atMask(atBox(sp,float2(0.025,0.40))-0.04,aa));
    color=mix(color,float3(0.12,0.23,0.23),atMask(atBox(sp,float2(0.006,0.37)),aa));
    for(int i=0;i<9;i++)color=mix(color,paperColor*0.7,atMask(atBox(sp-float2(0.044,-0.34+float(i)*0.085),float2(0.007,0.001)),aa));
    float2 slider=sp-float2(0,0.40-a.record.z*0.4);
    color=mix(color,float3(0.94,0.90,0.77),atMask(atBox(slider,float2(0.034,0.023))-0.009,aa));
    color=mix(color,float3(0.77,0.20,0.09),atMask(atBox(slider,float2(0.022,0.014))-0.005,aa));
    float2 button=p-float2(-1.24,0.66);
    color=mix(color,float3(0.13,0.41,0.43),atMask(length(button)-0.057,aa));
    float circle=abs(length(button)-0.031);
    float power=min(max(circle-0.004,-button.y-0.012),atBox(button-float2(0,-0.026),float2(0.004,0.021)));
    color=mix(color,a.record.z>0 ? float3(0.84,0.28,0.10):paperColor,atMask(power,aa));
    float2 pivot=float2(1.13,-0.86), tip=pivot+float2(-0.34*a.record.w,1.39);
    color*=1-0.17*(1-smoothstep(0.02,0.045,atLine(p-float2(0.012,0.022),pivot,tip)));
    color=mix(color,float3(0.76,0.22,0.075),atMask(length(p-pivot)-0.108,aa));
    float rod=atLine(p,pivot,tip);
    color=mix(color,float3(0.28,0.29,0.25),atMask(rod-0.018,aa));
    color=mix(color,float3(0.76,0.77,0.67),atMask(rod-0.012,aa));
    color=mix(color,float3(0.96,0.94,0.84),atMask(atLine(p,pivot-float2(0.006,0),tip-float2(0.006,0))-0.0025,aa));
    color=mix(color,float3(0.12,0.17,0.15),atMask(length(p-pivot)-0.054,aa));
    color=mix(color,float3(0.83,0.84,0.75),atMask(length(p-pivot)-0.019,aa));
    float2 head=atRotate(p-tip,atan2(tip.x-pivot.x,tip.y-pivot.y));
    color=mix(color,float3(0.19,0.23,0.19),atMask(atBox(head,float2(0.031,0.064))-0.006,aa));
    color=mix(color,float3(0.79,0.25,0.11),atMask(atBox(head,float2(0.026,0.054)),aa));
    for(int i=-1;i<=1;i+=2) color=mix(color,float3(0.94,0.88,0.71),atMask(length(head-float2(0,float(i)*0.028))-0.007,aa));
    output.write(float4(color,1),pixel);
}

// A ray-marched, extruded arch and eroded terrain, shaded as registered ink layers.
float atPath(float z,float time) { return sin(z*0.57+0.6)*1.05+sin(z*0.22-0.4)*0.55+sin(z*0.9-time*0.35)*0.045; }
float atTerrain(float2 p,constant Uniforms& u) {
    float distance=abs(p.x-atPath(p.y,0));
    float bank=smoothstep(1.6,3.7,distance);
    float ridges=atFbm(p*0.59+9)*1.3+atNoise(p*1.8)*0.25;
    float hills=bank*(0.55+ridges*2.4)*u.controls.z*smoothstep(-16.0,-3.0,p.y);
    float archClearing=1-smoothstep(1.7,3.0,length((p-float2(0,-2))*float2(1,0.7)));
    return hills*(1-archClearing*0.92)+0.08*sin(p.y*0.5);
}
float atArch(float3 p) {
    float2 q=p.xy-float2(0,2.65);
    float ring=abs(length(q)-1.34)-0.23;
    float top=max(ring,-q.y);
    float legs=atBox(float2(abs(p.x)-1.34,p.y-1.325),float2(0.23,1.325));
    return max(min(top,legs),abs(p.z+2)-0.34);
}
float2 atWorld(float3 p,constant Uniforms& u) {
    float ground=(p.y-atTerrain(p.xz,u))*0.45;
    float arch=atArch(p);
    float orb=length(p-float3(3.2,4.8,-5.0))-0.48;
    float2 result=float2(ground,1);
    if(arch<result.x)result=float2(arch,2);
    if(orb<result.x)result=float2(orb,3);
    return result;
}
float3 atWorldNormal(float3 p,constant Uniforms& u) {
    const float e=0.003;
    return normalize(float3(atWorld(p+float3(e,0,0),u).x-atWorld(p-float3(e,0,0),u).x,
        atWorld(p+float3(0,e,0),u).x-atWorld(p-float3(0,e,0),u).x,
        atWorld(p+float3(0,0,e),u).x-atWorld(p-float3(0,0,e),u).x));
}
void atPalette(int preset,thread float3& orange,thread float3& purple,thread float3& cream,thread float3& black) {
    orange=float3(1.0,0.255,0.025);purple=float3(0.61,0.21,0.91);cream=float3(0.94,0.855,0.69);black=float3(0.025,0.03,0.028);
    if(preset==1) { orange=float3(0.08,0.29,0.92);purple=float3(1,0.38,0.25);cream=float3(0.91,0.93,0.77); }
    if(preset==2) { orange=float3(0.78,0.90,0.13);purple=float3(0.98,0.22,0.48);cream=float3(0.96,0.91,0.76); }
}
float3 atPrint(float3 color,float3 p,float3 normal,float grain,float3 cream,float3 black,float footprint) {
    // Surface coordinates keep the paper fibers and stippling attached while orbiting.
    float2 coord=abs(normal.y)>0.65?p.xz:abs(normal.z)>0.5?p.xy:p.zy;
    float n=atHash(floor(coord*180)),n2=atNoise(coord*62);
    float dots=length(fract(atRotate(coord,0.28)*85)-0.5);
    float shade=saturate(0.5-dot(normal,normalize(float3(-1,2,2)))*0.4);
    float detail=1-smoothstep(0.002,0.012,footprint);
    float halftone=(1-smoothstep(0.10+shade*0.16,0.14+shade*0.16,dots))*0.11*grain*detail;
    color=mix(color,black,halftone);
    float fleck=smoothstep(0.89-grain*0.08,0.99,n)*grain*detail;
    color=mix(color,cream,fleck*0.65);
    color*=1+(n2-0.5)*0.10*grain;
    return color;
}
kernel void portalRender(texture2d<float,access::write> output [[texture(0)]],texture2d<float> waves [[texture(1)]],
                         constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],
                         constant AtelierUniforms& a [[buffer(2)]],uint2 pixel [[thread_position_in_grid]]) {
    float2 uv=(float2(pixel)+0.5)/u.viewport.xy;
    float travel=max(0.0,s.camera.w),sector=floor(travel/11.2),advance=fmod(travel,11.2);
    float3 orange,purple,cream,black; atPalette((int(u.parameters.w)+int(sector))%3,orange,purple,cream,black);
    float3 target=float3(0,1.8,-2),offset=float3(0,1.35,8.5)*exp(s.camera.z);
    offset=rotateY(rotateX(offset,s.camera.y*0.65),s.camera.x*0.65);
    float3 ro=target+offset; ro.z-=advance;
    ro.y=mix(ro.y,1.55,smoothstep(0.0,6.0,advance));
    ro.y=max(ro.y,atTerrain(ro.xz,u)+0.65);
    float3 forward=normalize(float3(0,1.8,-2)-float3(0,3.15,8));
    if(advance<7)forward=normalize(target-ro);
    forward=rotateY(rotateX(forward,s.camera.y*0.15),s.camera.x*0.18);
    float3 right=normalize(cross(forward,float3(0,1,0))),up=cross(right,forward);
    float2 screen=(uv-0.5)*float2(u.viewport.x/u.viewport.y,-1)*2;
    float3 rd=normalize(forward*2.35+right*screen.x+up*screen.y);
    float3 color=orange; float t=0,material=0; bool hit=false;
    int maxSteps=u.options.w==0?72:u.options.w==3?144:112;
    for(int i=0;i<maxSteps;i++) {
        float3 p=ro+rd*t; float2 h=atWorld(p,u);
        if(h.x<0.002+0.0002*t) { hit=true;material=h.y;break; }
        t+=max(h.x*0.85,0.003); if(t>38)break;
    }
    float holeT=rd.z<-0.0001?(-2.015-ro.z)/rd.z:-1;
    float3 holePoint=ro+rd*holeT;
    bool inHole=holePoint.y>0.04 && (holePoint.y<2.65?abs(holePoint.x)<1.10:length(holePoint.xy-float2(0,2.65))<1.10);
    bool through=holeT>0 && holeT<t && inHole;
    if(through) {
        // The aperture reveals a second landscape and a small moon at real depth.
        color=black;
        float moonT=dot(float3(0.15,2.4,-6)-ro,rd);
        float md=length(ro+rd*moonT-float3(0.15,2.4,-6));
        if(moonT>holeT && md<0.25)color=cream;
        float groundT=(-0.03-ro.y)/min(-0.00001,rd.y);
        if(rd.y<0 && groundT>holeT && groundT<45) {
            float3 gp=ro+rd*groundT;
            float path=abs(gp.x-atPath(gp.z+a.clock.x*0.05,0)*0.65);
            if(path<1.5)color=fract(path*0.95+sin(gp.z*0.8-a.clock.x*u.controls.x)*0.15)<0.4?purple:cream;
        }
        color=atPrint(color,holePoint,float3(0,0,1),u.controls.y,cream,black,0.001);
    } else if(hit) {
        float3 p=ro+rd*t,n=atWorldNormal(p,u);
        float rock=atFbm(p.xz*1.8+p.y*1.1)+atNoise(p.xy*7)*0.13;
        if(material<1.5) {
            float pathDistance=abs(p.x-atPath(p.z,0));
            if(pathDistance<1.65 && p.y<0.38) {
                constexpr sampler smp(coord::normalized,address::clamp_to_edge,filter::linear);
                float wave=waves.sample(smp,p.xz*0.06+0.5).x;
                float stripe=(p.x-atPath(p.z,0))*0.72+sin(p.z*0.9-a.clock.x*u.controls.x)*0.15;
                stripe+=atFbm(p.xz*4.0)*0.055+wave*u.parameters.x*1.4;
                if(u.pointer.z>0.5)stripe+=sin(length(uv-u.pointer.xy)*30)*exp(-length(uv-u.pointer.xy)*7)*u.parameters.x*0.55;
                float bands=fract(stripe);
                color=bands<0.24?cream:bands<0.55?purple:orange;
                float fibers=atNoise(float2(p.x*62,p.z*4+u.viewport.z*u.controls.x));
                if(fibers>0.74 && bands>0.2)color=cream;
            } else {
                float layer=rock+dot(n,normalize(float3(-1,1.3,0.5)))*0.20;
                color=layer>0.69?purple:black;
                if(layer>0.88)color=cream;
                float faults=abs(sin(p.y*11+p.x*7+atFbm(p.xz*5)*9));
                if(faults<0.08 && rock>0.60)color=cream;
            }
        } else if(material<2.5) {
            float front=abs(n.z);
            color=front>0.7?cream:purple;
            float ink=atFbm(p.xy*2.4+p.z*1.2)+0.12*sin(p.y*4+p.x*3);
            if(ink>0.58)color=purple;
            if(ink>0.72 || (n.x< -0.7))color=black;
            float speckle=atNoise(p.xy*23+p.z*19);
            if(speckle>0.70)color=front>0.6?purple:cream;
        } else { color=cream; if(dot(n,normalize(float3(-1,0.3,1)))< -0.15 && atNoise(p.xy*44)>0.45)color=orange; }
        color=atPrint(color,p,n,u.controls.y*u.parameters.x,cream,black,t/(u.viewport.y*2.35));
    } else {
        float grain=atHash(floor(uv*u.viewport.xy*0.7));
        color=mix(color,cream,smoothstep(0.94,1.0,grain)*0.60*u.controls.y);
        color*=1+(atNoise(uv*200)-0.5)*0.08*u.controls.y;
    }
    // A short paper-colored wipe makes successive spaces continuous at crossing.
    float crossing=smoothstep(10.6,11.2,advance);
    float arrival=1-smoothstep(0.0,0.45,advance);
    if(sector>0 || advance>10.6)color=mix(color,cream,max(crossing,sector>0?arrival:0));
    output.write(float4(color,1),pixel);
}
