// A compact river garden: one bounded wave field, three stones, three plant clumps.
struct PoolFrame {
    float4 stone, shape, motion, touch, state, view, impact, velocity;
    float4 stone1, stone2, plant0, plant1, plant2, selection;
};
constant float POOL_EXTENT=2.36, POOL_RADIUS=2.08;
float poolHash(float2 p) { return fract(sin(dot(p,float2(127.1,311.7)))*43758.5453); }
float poolNoise(float2 p) {
    float2 i=floor(p),f=fract(p); f=f*f*(3-2*f);
    return mix(mix(poolHash(i),poolHash(i+float2(1,0)),f.x),mix(poolHash(i+float2(0,1)),poolHash(i+1),f.x),f.y);
}
float poolFBM(float2 p) { return poolNoise(p)*0.55+poolNoise(p*2.07+7)*0.28+poolNoise(p*4.13-11)*0.17; }
float gardenCenter(float z) { return 0.30*sin(z*1.4)-0.10; }
float gardenWidth(float z) { return 0.90+0.12*cos(z*2); }
float gardenWaterDistance(float2 p) { return max(abs(p.x-gardenCenter(p.y))-gardenWidth(p.y),length(p)-POOL_RADIUS); }
float4 gardenStone(int i,constant PoolFrame& f) { return i==0 ? f.stone : (i==1 ? f.stone1:f.stone2); }
float2 gardenRoot(int i) { return i==0 ? float2(-1.20,0.14):(i==1 ? float2(1.27,-0.45):float2(-1.32,-1.20)); }
float4 gardenPlant(int i,constant PoolFrame& f) { return i==0 ? f.plant0:(i==1 ? f.plant1:f.plant2); }

kernel void poolInitialize(texture2d<float,access::write> a [[texture(0)]],
    texture2d<float,access::write> b [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(a.get_width(),a.get_height())))return; a.write(float4(0),id); b.write(float4(0),id);
}
float poolNeighbor(texture2d<float,access::read> a,int2 q,float center) {
    q=clamp(q,int2(0),int2(a.get_width()-1,a.get_height()-1));
    float2 p=((float2(q)+0.5)/float2(a.get_width(),a.get_height())*2-1)*POOL_EXTENT;
    return gardenWaterDistance(p)>0 ? center:a.read(uint2(q)).x;
}
kernel void poolStep(constant Uniforms& u [[buffer(0)]],constant PoolFrame& f [[buffer(1)]],
    constant float4* impulses [[buffer(2)]],constant uint& count [[buffer(3)]],
    texture2d<float,access::read> a [[texture(0)]],texture2d<float,access::write> b [[texture(1)]],
    uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(a.get_width(),a.get_height())))return;
    float2 p=((float2(id)+0.5)/float2(a.get_width(),a.get_height())*2-1)*POOL_EXTENT;
    float bank=gardenWaterDistance(p); if(bank>=0){b.write(float4(0),id);return;}
    float2 q=a.read(id).xy; int2 c=int2(id);
    float lap=poolNeighbor(a,c+int2(1,0),q.x)+poolNeighbor(a,c-int2(1,0),q.x)
        +poolNeighbor(a,c+int2(0,1),q.x)+poolNeighbor(a,c-int2(0,1),q.x)-4*q.x;
    float impulse=0;
    for(uint i=0;i<count;i++){
        float4 e=impulses[i];float d=dot(p-e.xy,p-e.xy)/max(0.001,e.w*e.w);
        impulse+=e.z*(exp(-d*2)-0.25*exp(-d*0.5));
    }
    float damping=mix(0.992,0.965,smoothstep(-0.12,0.,bank));
    float v=(q.y+lap*0.24+impulse*0.09)*damping,h=(q.x+v+impulse*0.32)*0.9994;
    b.write(float4(clamp(h,-0.13,0.13),clamp(v,-0.06,0.06),0,0),id);
}
float poolWave(texture2d<float,access::sample> waves,float2 p) {
    constexpr sampler s(coord::normalized,address::clamp_to_edge,filter::linear);
    return waves.sample(s,p/(2*POOL_EXTENT)+0.5).x;
}
float3 poolRay(float2 uv,constant PoolFrame& f) {
    float3 eye=float3(0,4.5,4),forward=normalize(-eye),right=float3(1,0,0),up=cross(right,forward);
    float2 xy=(uv+float2(0,0.075)-0.5)*float2(2*f.view.x,-2);
    return normalize(forward*(2.15*exp(-f.view.y))+right*xy.x+up*xy.y);
}
float poolStoneHit(float3 ro,float3 rd,float3 center,float3 radii) {
    float3 o=(ro-center)/radii,d=rd/radii;
    float a=dot(d,d),b=dot(o,d),c=dot(o,o)-1,h=b*b-a*c;
    return h<0 ? 1e5:((-b-sqrt(h))/a>0.0001 ? (-b-sqrt(h))/a:1e5);
}
float3 poolSky(float3 r,int preset) {
    float sky=smoothstep(-0.3,0.85,r.y);
    float3 c=mix(float3(0.12,0.20,0.13),float3(0.83,0.91,0.94),sky);
    float sun=pow(max(0.,dot(r,normalize(float3(-0.6,1,0.4)))),180);
    c+=float3(1.0,0.87,0.66)*sun*2.8;
    c+=pow(max(0.,dot(r,normalize(float3(-0.4,0.8,-0.65)))),24)*float3(0.30,0.36,0.38);
    c+=float3(1.3,1.6,1.5)*exp(-pow((r.z+0.68)*35,2)-pow(abs(r.x)*1.7,6));
    if(preset==1)c=c*float3(0.26,0.43,0.72)+float3(0.02,0.04,0.075);
    if(preset==2)c*=float3(1.20,0.90,0.59);
    return c;
}
float3 gardenLight(float3 c,int preset) {
    return c*(preset==1 ? float3(0.21,0.38,0.57):(preset==2 ? float3(1.14,0.88,0.61):float3(1)));
}
float3 poolStoneColor(float3 p,float3 n,float3 rd,int index,constant PoolFrame& f,int preset) {
    float4 stone=gardenStone(index,f); float3 local=(p-stone.xyz)/f.shape.xyz;
    float2 tex=local.xz*3.0+float2(local.y*1.3,local.y*0.8);
    if(int(f.selection.x)==index)tex+=float2(f.motion.y,f.motion.x)*3;
    float grain=poolFBM(tex*3.1),fine=poolNoise(tex*105);
    float seam=1-smoothstep(0.028,0.065,abs(sin(tex.y*2.3+tex.x*0.7+(poolFBM(tex*1.7)-0.5)*2.1)));
    float3 base=mix(float3(0.036,0.056,0.058),float3(0.095,0.125,0.12),grain);
    if(index==1)base=mix(float3(0.12,0.18,0.12),float3(0.25,0.31,0.21),grain);
    if(index==2)base=mix(float3(0.32,0.26,0.17),float3(0.47,0.41,0.30),grain);
    base=mix(base,float3(0.48,0.49,0.39),seam*0.55)*(0.94+fine*0.12);
    float3 light=normalize(float3(-0.6,1,0.4)),v=-rd,h=normalize(light+v);
    float nl=max(0.,dot(n,light)),nv=max(0.001,dot(n,v)),nh=max(0.,dot(n,h));
    float rough=mix(0.29,0.14,stone.w),a=rough*rough,a2=a*a,denom=nh*nh*(a2-1)+1;
    float spec=a2/(3.14159*denom*denom+0.0001),fresnel=0.035+0.965*pow(1-nv,5);
    float3 c=gardenLight(base*(0.34+nl*0.85),preset)+poolSky(reflect(rd,n),preset)*(0.035+fresnel*0.34)
        +gardenLight(float3(1,0.92,0.75)*min(1.5,spec*0.035*nl),preset);
    if(int(f.selection.y)==index)c+=pow(1-nv,3)*f.motion.z*float3(0.19,0.34,0.32);
    return c;
}
float gardenHeight(float2 p) {
    float d=gardenWaterDistance(p),r=length(p);
    float edge=2.25+0.035*sin(atan2(p.y,p.x)*7)+0.025*sin(atan2(p.y,p.x)*13);
    float h=mix(-0.29,0.13,smoothstep(-0.16,0.20,d));
    h+=(poolFBM(p*5)-0.5)*0.09*smoothstep(-0.06,0.22,d);
    return mix(h,-0.36,smoothstep(edge-0.25,edge+0.03,r));
}
float gardenTerrainHit(float3 ro,float3 rd) {
    float t=(0.23-ro.y)/rd.y;
    for(int i=0;i<32;i++){
        float3 p=ro+rd*t; if(p.y< -0.36)return 1e5;
        float d=p.y-gardenHeight(p.xz);
        if(d<0.001)return length(p.xz)>2.4 ? 1e5:t;
        t+=max(0.001,d*0.7);
    }
    return 1e5;
}
float3 gardenTerrainNormal(float2 p) {
    float e=0.003;
    return normalize(float3(gardenHeight(p-float2(e,0))-gardenHeight(p+float2(e,0)),2*e,
        gardenHeight(p-float2(0,e))-gardenHeight(p+float2(0,e))));
}
float3 gardenTerrainColor(float3 p,float3 n,int preset) {
    float bank=gardenWaterDistance(p.xz),m=poolFBM(p.xz*8),grain=poolNoise(p.xz*250);
    float3 gravel=mix(float3(0.22,0.19,0.13),float3(0.52,0.46,0.32),m)*(0.83+grain*0.30);
    float moss=smoothstep(0.04,0.32,bank)*smoothstep(0.32,0.57,poolFBM(p.xz*4+7));
    moss*=1-smoothstep(2.03,2.24,length(p.xz));
    float3 greens=mix(float3(0.075,0.15,0.035),float3(0.25,0.36,0.09),m)*(0.80+grain*0.42);
    float3 c=mix(gravel,greens,moss*0.95)*(0.44+0.65*max(0.,dot(n,normalize(float3(-0.6,1,0.4)))));
    for(int i=0;i<3;i++){
        float2 d=(p.xz-gardenRoot(i)-float2(0.15,-0.10))/float2(0.44,0.32);
        c*=1-0.40*exp(-dot(d,d)*2);
    }
    for(int i=0;i<18;i++){
        float seed=poolHash(float2(i,2)),z=-1.65+float(i/2)*0.40,side=(i%2==0 ? -1.:1.);
        float x=gardenCenter(z)+side*(gardenWidth(z)+0.07+seed*0.11);
        float2 d=(p.xz-float2(x+0.045,z-0.025))/(0.14+seed*0.1);
        c*=1-0.35*exp(-dot(d,d)*1.3);
    }
    return gardenLight(c,preset);
}
float3 poolBed(float2 p,constant PoolFrame& f,int preset,float caustic) {
    float3 sand=mix(float3(0.36,0.40,0.26),float3(0.61,0.63,0.42),poolFBM(p*4));
    sand*=0.90+poolNoise(p*215)*0.16;
    float2 cell=floor(p*15),local=fract(p*15)-0.5;
    sand*=1-(1-smoothstep(0.035,0.10,length(local)))*step(0.76,poolHash(cell))*0.35;
    for(int i=0;i<3;i++){
        float4 stone=gardenStone(i,f);float2 shift=float2(-0.6,0.4)*max(0.15,stone.y+0.27);
        float2 d=(p-stone.xz+shift)/float2(0.40,0.30);sand*=1-exp(-dot(d,d)*1.5)*0.56;
    }
    return gardenLight(sand*(0.9+caustic*0.16),preset);
}
// Leaf ribbons have four curved sections, a tapered outline and a central vein.
float3 gardenLeafPoint(float3 root,float2 radial,float2 bend,float t,float seed) {
    return root+float3(radial.x,0,radial.y)*(0.43*pow(t,1.55))
        +float3(0,(0.80+seed*0.18)*t-(0.43+seed*0.06)*t*t,0)
        +float3(bend.x,0,bend.y)*t*t;
}
float3 gardenTriangle(float3 ro,float3 rd,float3 a,float3 b,float3 c) {
    float3 e=b-a,g=c-a,h=cross(rd,g);float det=dot(e,h);
    if(abs(det)<1e-7)return float3(1e5,0,0);
    float3 s=ro-a;float u=dot(s,h)/det;if(u<0 || u>1)return float3(1e5,0,0);
    float3 q=cross(s,e);float v=dot(rd,q)/det,t=dot(g,q)/det;
    return v<0 || u+v>1 || t<0 ? float3(1e5,0,0):float3(t,u,v);
}

kernel void poolRender(constant Uniforms& u [[buffer(0)]],constant PoolFrame& f [[buffer(1)]],
    texture2d<float,access::sample> waves [[texture(0)]],texture2d<float,access::write> out [[texture(1)]],
    uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(out.get_width(),out.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(out.get_width(),out.get_height());
    float3 ro=float3(0,4.5,4),rd=poolRay(uv,f),light=normalize(float3(-0.6,1,0.4));
    int preset=int(u.parameters.w+0.5);
    float groundT=(-0.36-ro.y)/rd.y,nearest=groundT;
    float3 ground=ro+rd*groundT;
    float shadow=1-smoothstep(2.08,2.64,length(ground.xz+float2(0.13,-0.08)));
    float3 color=float3(0.72,0.70,0.62)*(1-shadow*0.27)*(0.98+poolNoise(ground.xz*200)*0.025);
    if(preset==1)color=float3(0.023,0.037,0.045)*(1-shadow*0.3);
    if(preset==2)color*=float3(1.04,0.94,0.80);
    float terrain=gardenTerrainHit(ro,rd);
    if(terrain<nearest){
        float3 p=ro+rd*terrain;
        color=gardenTerrainColor(p,gardenTerrainNormal(p.xz),preset); nearest=terrain;
    }
    float waterT=-ro.y/rd.y;float3 wp=ro+rd*waterT;
    bool waterVisible=gardenWaterDistance(wp.xz)<0 && waterT<nearest;
    if(waterVisible){
        float calm=smoothstep(0.,1.4,f.state.y),wave=poolWave(waves,wp.xz)*u.parameters.x*calm;
        wp=ro+rd*((wave-ro.y)/rd.y);
        float eps=2*POOL_EXTENT/256;
        float hx=(poolWave(waves,wp.xz+float2(eps,0))-poolWave(waves,wp.xz-float2(eps,0)))/(2*eps);
        float hz=(poolWave(waves,wp.xz+float2(0,eps))-poolWave(waves,wp.xz-float2(0,eps)))/(2*eps);
        float2 slope=float2(hx,hz)*u.parameters.x*calm;float meniscus=0;
        for(int i=0;i<3;i++){
            float4 stone=gardenStone(i,f);float2 delta=(wp.xz-stone.xz)/f.shape.xz;
            float m=exp(-pow((length(delta)-0.94)*16,2))*exp(-abs(stone.y-0.10)*17);
            slope+=normalize(delta+0.0001)*m*0.042;meniscus+=m;
        }
        float3 normal=normalize(float3(-slope.x,1,-slope.y)),refracted=refract(rd,normal,1/1.333);
        float3 bed=wp+refracted*((-0.29-wp.y)/refracted.y);
        float n=poolFBM(bed.xz*3);
        float caustic=pow(max(0.,1-abs(sin(bed.x*19+bed.z*8+n*6+slope.x*18)*sin(bed.z*17-bed.x*4+n*5+slope.y*18))),10);
        float3 below=poolBed(bed.xz,f,preset,caustic);
        float depth=length(bed-wp),clarity=clamp(u.controls.y,0.2,1.0);
        float3 absorption=exp(-float3(2.6,0.63,0.58)*depth*(1.45-clarity*0.6));
        below=below*absorption+float3(0.028,0.18,0.155)*(1-absorption);
        float3 reflection=poolSky(reflect(rd,normal),preset);float reflectionT=1e5;
        for(int i=0;i<3;i++){
            float4 stone=gardenStone(i,f);float3 rr=reflect(rd,normal);
            float t=poolStoneHit(wp+normal*0.002,rr,stone.xyz,f.shape.xyz);
            if(t<reflectionT && t<4){
                float3 p=wp+normal*0.002+rr*t,sn=normalize((p-stone.xyz)/(f.shape.xyz*f.shape.xyz));
                reflection=poolStoneColor(p,sn,rr,i,f,preset);reflectionT=t;
            }
        }
        float fresnel=0.0204+0.9796*pow(1-max(0.,dot(-rd,normal)),5);
        color=mix(below,reflection,fresnel)+pow(max(0.,dot(normal,normalize(light-rd))),430)*gardenLight(float3(1,0.92,0.76),preset);
        color+=meniscus*float3(0.17,0.24,0.21)*0.2;
        color*=1-(1-smoothstep(0.,0.09,-gardenWaterDistance(wp.xz)))*0.22;
        if(f.touch.z>0)color+=exp(-dot(wp.xz-f.touch.xy,wp.xz-f.touch.xy)*1300)*float3(0.20,0.32,0.25)*0.28;
        nearest=waterT;
    }
    // Eighteen low bank stones give the edge a physical, irregular silhouette.
    for(int i=0;i<18;i++){
        float seed=poolHash(float2(i,2)),z=-1.65+float(i/2)*0.40,side=(i%2==0 ? -1.:1.);
        float x=gardenCenter(z)+side*(gardenWidth(z)+0.07+seed*0.11);
        float3 center=float3(x,0.055+seed*0.06,z),radii=float3(0.16+seed*0.10,0.09+seed*0.07,0.15+seed*0.08);
        if(length(center.xz)>2.05)continue;
        float t=poolStoneHit(ro,rd,center,radii);
        if(t<nearest){
            float3 p=ro+rd*t,n=normalize((p-center)/(radii*radii));
            float grain=poolFBM(p.xz*31),fine=poolNoise(p.xz*240);
            float3 base=mix(float3(0.20,0.22,0.16),float3(0.46,0.44,0.31),seed);
            color=gardenLight(base*(0.72+grain*0.34+fine*0.1)*(0.36+0.7*max(0.,dot(n,light))),preset);
            nearest=t;waterVisible=false;
        }
    }
    for(int i=0;i<3;i++){
        float4 stone=gardenStone(i,f);float t=poolStoneHit(ro,rd,stone.xyz,f.shape.xyz);
        float3 p=ro+rd*t;
        if(t<nearest || (waterVisible && p.y> -0.24 && t<groundT)){
            float3 n=normalize((p-stone.xyz)/(f.shape.xyz*f.shape.xyz));
            color=poolStoneColor(p,n,rd,i,f,preset);
            if(p.y<0)color=mix(color*float3(0.58,0.83,0.80),gardenLight(float3(0.06,0.23,0.20),preset),min(0.45,-p.y*2));
            nearest=t;waterVisible=false;
        }
    }
    for(int plant=0;plant<3;plant++){
        float2 root2=gardenRoot(plant);float3 root=float3(root2.x,0.09,root2.y);
        float4 state=gardenPlant(plant,f);float2 bend=state.xy;
        float bankX=gardenCenter(root2.y)+(root2.x<gardenCenter(root2.y) ? -1.:1.)*(gardenWidth(root2.y)-0.05);
        float ripple=poolWave(waves,float2(bankX,root2.y))*smoothstep(0.,1.4,f.state.y);
        bend+=float2(ripple*18,ripple*9);
        if(poolStoneHit(ro,rd,root+float3(bend.x*0.4,0.34,bend.y*0.4),float3(0.69,0.48,0.69))>nearest)continue;
        for(int leaf=0;leaf<11;leaf++){
            float seed=poolHash(float2(leaf,plant+10)),angle=float(leaf)*2.39996+plant;
            float2 radial=float2(cos(angle),sin(angle));
            float3 sideways=float3(-radial.y,0,radial.x);
            for(int section=0;section<6;section++){
                float t0=float(section)/6,t1=float(section+1)/6;
                float3 a=gardenLeafPoint(root,radial,bend,t0,seed),b=gardenLeafPoint(root,radial,bend,t1,seed);
                float w0=0.083*pow(max(0.001,sin(t0*3.14159)),0.7)*(0.7+seed*0.4);
                float w1=0.083*pow(max(0.001,sin(t1*3.14159)),0.7)*(0.7+seed*0.4);
                float3 l0=a-sideways*w0,r0=a+sideways*w0,l1=b-sideways*w1,r1=b+sideways*w1;
                float3 hitA=gardenTriangle(ro,rd,l0,r0,r1),hitB=gardenTriangle(ro,rd,l0,r1,l1);
                float t=min(hitA.x,hitB.x);
                if(t<nearest){
                    float across=hitA.x<hitB.x ? hitA.y+hitA.z:hitB.y;
                    float along=mix(t0,t1,hitA.x<hitB.x ? hitA.z:hitB.y+hitB.z);
                    float3 tangent=float3(radial.x,0,radial.y)*(0.43*1.55*pow(max(0.01,along),0.55))
                        +float3(0,(0.80+seed*0.18)-2*(0.43+seed*0.06)*along,0)
                        +float3(bend.x,0,bend.y)*2*along;
                    float3 n=normalize(cross(sideways,tangent));
                    n=normalize(n+sideways*(across-0.5)*0.8);
                    if(dot(n,rd)>0)n=-n;
                    float vein=exp(-pow((across-0.5)*45,2));
                    float ribs=pow(max(0.,cos(along*85+abs(across-0.5)*14)),12)*0.07;
                    float3 base=mix(float3(0.035,0.12,0.035),float3(0.18,0.31,0.045),seed);
                    if(plant==1)base*=float3(0.70,1,1.40);
                    if(plant==2)base*=float3(1.30,1.15,0.70);
                    base*=0.75+along*0.35+vein*0.18+ribs;
                    float nl=max(0.,dot(n,light)),back=max(0.,dot(-n,light));
                    color=gardenLight(base*(0.42+nl*0.70)+base*float3(1.2,1.4,0.6)*back*0.45,preset);
                    color+=gardenLight(float3(0.5,0.65,0.30),preset)*pow(max(0.,dot(n,normalize(light-rd))),70)*0.13;
                    if(int(f.selection.z)==plant)color+=float3(0.035,0.055,0.015)*f.motion.z;
                    nearest=t;
                }
            }
        }
    }
    float age=f.state.x-f.impact.z;
    if(age>0 && age<0.85 && f.impact.w>0.12){
        for(int i=0;i<14;i++){
            float seed=poolHash(float2(i,5)),a=6.283185*(float(i)/14+seed*0.06),speed=(0.38+seed*0.75)*f.impact.w;
            float3 center=float3(f.impact.x+cos(a)*age*speed,0.02+age*(1.2+seed)*f.impact.w-2.5*age*age,f.impact.y+sin(a)*age*speed);
            if(center.y<0)continue;float radius=0.009+seed*0.010;
            float t=poolStoneHit(ro,rd,center,float3(radius,radius*1.5,radius));
            if(t<nearest){
                float3 n=normalize((ro+rd*t-center)/float3(1,2.25,1));color=poolSky(reflect(rd,n),preset)*0.7+float3(0.13,0.32,0.28);nearest=t;
            }
        }
    }
    color*=clamp(u.controls.z,0.25,1.5);color=max(color,0.);color=color/(1+color*0.35);
    color=pow(color,float3(1/2.2))*(1-0.09*dot(uv-0.5,uv-0.5));
    out.write(float4(clamp(color,0.,1.),1),id);
}
