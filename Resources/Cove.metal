// Sakura Cove: GPU animation, transported petals, a persistent wave field and
// hardware ray queries against the same world geometry for every light path.
struct CoveVertex { float4 position,normal,color,rig; };
struct CoveFrame { float4 eye,right,up,forward,actor,animation,touch,clock; };
struct CovePetal { float4 position; float4 velocity; };
float3 coveRotateX(float3 p,float a){return float3(p.x,cos(a)*p.y-sin(a)*p.z,sin(a)*p.y+cos(a)*p.z);}
float3 coveRotateY(float3 p,float a){return float3(cos(a)*p.x+sin(a)*p.z,p.y,-sin(a)*p.x+cos(a)*p.z);}
float3 coveRotateZ(float3 p,float a){return float3(cos(a)*p.x-sin(a)*p.y,sin(a)*p.x+cos(a)*p.y,p.z);}
float coveRand(float x){return fract(sin(x*127.1+311.7)*43758.5453);}
float3 coveWave(float2 p,constant Uniforms& u,constant CoveFrame& f) {
    float3 result=float3(u.controls.z,0,0);
    float wind=0.65+u.controls.y*0.6, scale=u.parameters.x;
    for(uint i=0;i<6;i++){
        float n=float(i),a=n*2.399+0.35;
        float2 dir=float2(cos(a),sin(a));
        float frequency=0.85*pow(1.92,n),amplitude=0.040*pow(0.49,n)*scale;
        float phase=dot(p,dir)*frequency-f.clock.x*sqrt(9.81*frequency)*wind;
        result.x+=amplitude*sin(phase);
        result.yz+=amplitude*frequency*cos(phase)*dir;
    }
    return result;
}
kernel void coveInitialize(constant Uniforms& u[[buffer(0)]],constant StageUniforms& s[[buffer(1)]],constant CoveFrame& f[[buffer(2)]],
                           device CovePetal* a[[buffer(3)]],device CovePetal* b[[buffer(4)]],texture2d<float,access::write> wa[[texture(0)]],texture2d<float,access::write> wb[[texture(1)]],uint2 p[[thread_position_in_grid]]) {
    if(p.x>=wa.get_width()||p.y>=wa.get_height())return;
    wa.write(float4(0),p);wb.write(float4(0),p);
    uint i=p.y*wa.get_width()+p.x;
    if(i<uint(f.clock.w)){
        float id=float(i),x=coveRand(id+1),y=coveRand(id+54),z=coveRand(id+123);
        CovePetal q={float4(-1.2+x*6,0.6+y*4,-3+z*5,coveRand(id+91)*6.283185),float4(0,-0.12,0,0)};a[i]=q;b[i]=q;
    }
}
kernel void coveWaves(constant Uniforms& u[[buffer(0)]],constant StageUniforms& s[[buffer(1)]],constant CoveFrame& f[[buffer(2)]],
                      texture2d<float,access::read> src[[texture(0)]],texture2d<float,access::write> dst[[texture(1)]],uint2 p[[thread_position_in_grid]]) {
    uint side=src.get_width();if(p.x>=side||p.y>=side)return;
    if(p.x==0||p.y==0||p.x+1==side||p.y+1==side){dst.write(float4(0),p);return;}
    float2 q=src.read(p).xy,world=(float2(p)+0.5)/float(side)*24-12;
    float lap=src.read(p+uint2(1,0)).x+src.read(p-uint2(1,0)).x+src.read(p+uint2(0,1)).x+src.read(p-uint2(0,1)).x-4*q.x;
    float d=length(world-f.touch.xy),brush=exp(-d*d*18)*f.touch.z;
    float force=brush*(0.015+f.touch.w*0.014)*sin(f.clock.x*17);
    q.y=(q.y+lap*0.20+force)*0.975;q.x=clamp(q.x+q.y,-0.32,0.32);
    float edge=smoothstep(0.0,0.7,12-max(abs(world.x),abs(world.y)));
    dst.write(float4(q*edge,0,0),p);
}
kernel void covePetals(constant Uniforms& u[[buffer(0)]],constant StageUniforms& s[[buffer(1)]],constant CoveFrame& f[[buffer(2)]],device const CovePetal* src[[buffer(3)]],device CovePetal* dst[[buffer(4)]],uint i[[thread_position_in_grid]]) {
    if(i>=uint(f.clock.w))return;
    CovePetal p=src[i];float seed=float(i),dt=f.clock.y;
    float3 x=p.position.xyz;
    bool terrace=abs(x.x)<3.2&&x.z>-2.45&&x.z<2.72;
    float floorY=terrace?0.561:coveWave(x.xz,u,f).x+0.012;
    float wind=u.controls.y,flutter=sin(f.clock.x*2.5+seed*1.2);
    if(x.y>floorY+0.035){
        float3 target=float3(wind*(0.18+0.12*flutter),-0.15-0.08*coveRand(seed+31),wind*0.10*cos(seed+f.clock.x));
        float2 to=x.xz-f.touch.xy;float d=length(to);
        target.xz+=normalize(to+0.001)*exp(-d*d*1.3)*f.touch.z*1.4;
        float2 away=x.xz-f.actor.xz;target.xz+=normalize(away+0.001)*exp(-dot(away,away)*7)*min(f.animation.y,2.0)*0.6;
        p.velocity.xyz=mix(p.velocity.xyz,target,dt*2.0);x+=p.velocity.xyz*dt;
        p.position.w=fmod(p.position.w+dt*(1.5+wind),6.283185);
    }else{
        x.y=floorY;p.velocity.w+=dt;
        if(!terrace){x.xz+=float2(0.035+wind*0.04,0.025*sin(f.clock.x+seed))*dt;p.position.w=fmod(p.position.w+dt*0.2,6.283185);}
    }
    if(x.y<floorY)x.y=floorY;
    if(p.velocity.w>7.0+coveRand(seed)*5||abs(x.x)>9||abs(x.z)>9){
        float cycle=floor(f.clock.x*0.1),a=coveRand(seed+cycle*17)*6.283185,r=sqrt(coveRand(seed+cycle*19+21))*1.65;
        x=float3(1.6+cos(a)*r,3.5+coveRand(seed+cycle*13)*0.65,-2.0+sin(a)*r*0.8);p.velocity=float4(0,-0.1,0,0);
    }
    p.position.xyz=x;dst[i]=p;
}
kernel void coveDeform(constant Uniforms& u[[buffer(0)]],constant StageUniforms& s[[buffer(1)]],constant CoveFrame& f[[buffer(2)]],device const CoveVertex* rest[[buffer(3)]],device CoveVertex* output[[buffer(4)]],device const CovePetal* petals[[buffer(5)]],uint i[[thread_position_in_grid]]) {
    if(i>=uint(f.clock.z))return;
    CoveVertex v=rest[i];float3 p=v.position.xyz,n=v.normal.xyz;uint part=uint(v.rig.w+0.5);
    if(part>=100){
        CovePetal q=petals[part-100];float a=q.position.w;
        p=coveRotateY(coveRotateX(p,sin(a)*0.55),a)+q.position.xyz;
        n=coveRotateY(coveRotateX(n,sin(a)*0.55),a);
    }else if(part==10){
        float height=max(p.y-0.7,0.0),phase=f.clock.x*1.1+p.z*0.7+p.x*0.5;
        float sway=(sin(phase)*0.018+sin(phase*2.2)*0.006)*height*height*u.controls.y;
        p.x+=sway;p.z+=sway*0.31;n=normalize(n+float3(0.012*cos(phase)*u.controls.y,0,0));
    }else if(part==9){p=coveRotateZ(p-v.rig.xyz,f.animation.w)+v.rig.xyz;n=coveRotateZ(n,f.animation.w);}
    else if(part>0){
        float sit=f.animation.z,walk=min(f.animation.y/1.25,1.6),swing=sin(f.animation.x)*0.52*walk;
        float angle=0;
        if(part==2||part==3||part==4||part==5){
            float sign=part<=3?1.0:-1.0;angle=mix(sign*swing,-1.48,sit);
            if(part==3||part==5){
                float bend=mix(max(0.0,-sign*sin(f.animation.x))*0.85*walk,1.48,sit);
                float3 knee=float3(v.rig.x,0.31,0);p=coveRotateX(p-knee,bend)+knee;n=coveRotateX(n,bend);
            }
        }else if(part==6||part==7)angle=mix((part==6?-1.0:1.0)*swing*0.65,-0.45,sit);
        else if(part==8){
            angle=-sit*0.90;p.x+=sin(f.clock.x*2.8+p.z*11)*max(0.0,0.61-p.y)*(0.05+walk*0.12)*u.controls.y;
        }
        p=coveRotateX(p-v.rig.xyz,angle)+v.rig.xyz;n=coveRotateX(n,angle);
        p=coveRotateY(p,f.actor.w)+f.actor.xyz;n=coveRotateY(n,f.actor.w);
        p.y+=sin(f.animation.x*2)*0.014*walk*(1-sit);
    }
    v.position.xyz=p;v.normal.xyz=n;output[i]=v;
}
float coveDay(constant Uniforms& u){return smoothstep(-0.12,0.18,sin((u.controls.x-6.0)*6.283185/24));}
float3 coveSun(constant Uniforms& u){float a=(u.controls.x-6)*6.283185/24;return normalize(float3(cos(a),max(0.10,sin(a)),0.43));}
float3 coveKey(constant Uniforms& u){return coveDay(u)>0.05?coveSun(u):normalize(float3(-0.45,0.65,-0.60));}
float3 coveSky(float3 d,constant Uniforms& u,constant CoveFrame& f){
    float day=coveDay(u),h=pow(1-saturate(d.y),4.0),warm=pow(1-saturate(coveSun(u).y),3.0);
    float3 daylight=mix(float3(0.12,0.31,0.54),mix(float3(0.52,0.70,0.82),float3(1.15,0.65,0.30),warm),h);
    float3 night=mix(float3(0.003,0.009,0.035),float3(0.025,0.058,0.13),h);
    float3 color=mix(night,daylight,day);
    float2 cloud=d.xz/max(d.y+0.18,0.08)*1.7+float2(f.clock.x*0.005,0);
    float density=smoothstep(0.53,0.75,fbm3(float3(cloud,3.6),4))*smoothstep(-0.03,0.18,d.y);
    color=mix(color,mix(float3(0.025,0.038,0.075),float3(0.78,0.77,0.69),day),density*0.62);
    float sunDistance=length(d-coveKey(u));
    color+=mix(float3(1.5,1.8,2.3),float3(8,6,3.5),day)*(1-smoothstep(0.014,0.018,sunDistance));
    color+=mix(float3(0.03,0.05,0.12),float3(0.18,0.11,0.045),day)*exp(-sunDistance*9);
    color+=nightStars(d)*(1-day)*0.5*(1-density)*smoothstep(0.06,0.30,d.y);
    return color;
}
struct CoveMaterial {float3 p,n,base;float rough,kind;};
CoveMaterial coveMaterial(RiverHit hit,float3 ro,float3 rd,device const CoveVertex* vertices,device const uint* indices,texture2d_array<float> colors,texture2d_array<float> normals,texture2d_array<float> arm,constant Uniforms& u,constant CoveFrame& f){
    uint3 ids=uint3(indices[hit.primitive*3],indices[hit.primitive*3+1],indices[hit.primitive*3+2]);
    CoveVertex a=vertices[ids.x],b=vertices[ids.y],c=vertices[ids.z];float3 weights=float3(1-hit.bary.x-hit.bary.y,hit.bary);
    CoveMaterial m;m.p=ro+rd*hit.t;m.n=normalize(a.normal.xyz*weights.x+b.normal.xyz*weights.y+c.normal.xyz*weights.z);if(dot(m.n,rd)>0)m.n=-m.n;
    m.base=a.color.xyz;m.rough=a.color.w;m.kind=a.position.w;uint kind=uint(m.kind+0.5);float seed=a.normal.w;
    float lod=max(0.0,log2(max(hit.t,1.0)*0.32)),noise=noise3(m.p*18);
    if(kind==0||kind==1||kind==9){
        uint index=kind==0?2:kind==1?0:1;float3 q=m.p*(kind==9?float3(1.4,0.5,1.4):float3(0.85));
        m.base=riverMap(colors,index,q,m.n,lod).rgb*(kind==0?float3(0.94,0.86,0.68):kind==1?float3(0.95,0.88,0.72):float3(0.65,0.50,0.45));
        m.n=riverMapNormal(normals,index,q,m.n,lod);m.rough=riverMap(arm,index,q,m.n,lod).g;
        float wet=1-smoothstep(u.controls.z+0.05,u.controls.z+0.36,m.p.y);m.base*=1-wet*0.58;m.rough=mix(m.rough,0.28,wet);
        if(kind==1){float moss=smoothstep(0.51,0.71,fbm3(m.p*3.6,3))*smoothstep(0.05,0.5,m.n.y);m.base=mix(m.base,float3(0.064,0.11,0.025),moss*0.8);}
    }else if(kind==2){
        float weather=fbm3(m.p*8+seed*11,3),pores=smoothstep(0.70,0.85,noise3(m.p*135));
        m.base*=0.8+weather*0.35-pores*0.3;m.n=normalize(m.n+float3(noise3(m.p*70)-0.5,0,noise3(m.p*73+2)-0.5)*0.13);
    }else if(kind==3){
        float damage=smoothstep(0.47,0.64,fbm3(m.p*7,4));m.base=mix(m.base,float3(0.62,0.56,0.43),damage*0.85);
        m.base*=0.82+noise*0.25;m.n=normalize(m.n+float3(noise3(m.p*65)-0.5,noise3(m.p*69+2)-0.5,0)*0.25);
        m.base*=0.7+0.3*smoothstep(0.55,1.05,m.p.y);
    }else if(kind==4){float grain=noise3(m.p*float3(2,30,80));m.base*=0.65+grain*0.65;m.rough=0.42;}
    else if(kind==5){m.base*=0.8+0.2*noise;m.rough=0.8;}
    else if(kind==6){m.rough=0.27;}
    else if(kind==10){
        float3 local=coveRotateY(m.p-f.actor.xyz,-f.actor.w);float2 uv=float2(atan2(local.z,local.x)*0.6,local.y)*17;
        float2 cell=floor(uv),q=fract(uv)-0.5;float seed=coveRand(dot(cell,float2(23,61)));
        float petals=0.18+0.06*cos(atan2(q.y,q.x)*5+seed*6);float flower=(1-smoothstep(petals,petals+0.025,length(q)))*step(0.23,seed);
        m.base=mix(m.base,float3(0.82,0.78,0.62),flower*0.94);m.rough=0.88;
    }else if(kind==12){float weave=sin(m.p.x*420)*sin(m.p.z*420);m.base*=0.88+0.08*weave;m.rough=0.8;}
    return m;
}
float3 coveLantern(constant CoveFrame& f){return float3(-2.93,3.08,-1.35)+coveRotateZ(float3(0,-0.39,0),f.animation.w);}
float3 coveShade(CoveMaterial m,float3 rd,constant Uniforms& u,constant CoveFrame& f,primitive_acceleration_structure scene,bool detailed,thread uint& rng){
    float day=coveDay(u),nl=max(dot(m.n,coveKey(u)),0.0),elevation=coveSun(u).y;
    float3 key=mix(float3(0.13,0.21,0.38),mix(float3(3.2,1.8,0.75),float3(2.5,2.65,2.8),smoothstep(0.12,0.65,elevation)),day);
    float shadow=nl>0?riverVisibility(m.p+m.n*0.012,coveKey(u),25,scene):0;
    float3 ambient=mix(float3(0.025,0.043,0.085),float3(0.22,0.30,0.39),day)*(0.55+0.45*saturate(m.n.y*0.5+0.5));
    float ao=1;
    if(detailed&&u.options.w>=2&&m.kind!=7){
        float3 probe=normalize(m.n+float3(0.31,0.65,0.22));
        RiverHit h=riverIntersect(m.p+m.n*0.015,probe,0.65,scene);if(h.hit)ao=0.38+0.62*saturate(h.t/0.65);
    }
    float3 color=m.base*(ambient*ao+key*nl*shadow);
    if(m.kind==5||m.kind==8)color+=m.base*key*pow(max(0.0,dot(-m.n,coveKey(u))),1.8)*0.22;
    float3 lamp=coveLantern(f)-m.p;float distance=length(lamp);lamp/=max(distance,0.01);
    float lampNL=max(0.0,dot(m.n,lamp));float lampShadow=0;
    if(distance<6&&lampNL>0&&m.kind!=7)lampShadow=riverVisibility(m.p+m.n*0.015,lamp,max(0.01,distance-0.26),scene);
    float3 lampLight=float3(1,0.46,0.10)*(7.0-4.5*day)/(0.35+distance*distance);
    color+=m.base*lampLight*lampNL*lampShadow;
    float3 halfV=normalize(coveKey(u)-rd);float spec=pow(max(0.0,dot(m.n,halfV)),mix(90.0,6.0,m.rough));
    color+=key*spec*shadow*(1-m.rough)*0.12;
    if(m.kind==7)color=float3(6.0,3.0,0.65)*(0.8+0.2*sin(f.clock.x*3));
    return color;
}
// Fresnel water with world-space reflection/refraction rays, depth extinction,
// stable sun glints and a shallow, moving foam fringe around real geometry.
kernel void coveRender(constant Uniforms& u[[buffer(0)]],constant StageUniforms& s[[buffer(1)]],constant CoveFrame& f[[buffer(2)]],device const CoveVertex* vertices[[buffer(3)]],device const uint* indices[[buffer(4)]],primitive_acceleration_structure scene[[buffer(6)]],texture2d<float,access::write> output[[texture(0)]],texture2d<float> waves[[texture(1)]],texture2d_array<float> colors[[texture(2)]],texture2d_array<float> normals[[texture(3)]],texture2d_array<float> arm[[texture(4)]],uint2 p[[thread_position_in_grid]]){
    if(p.x>=output.get_width()||p.y>=output.get_height())return;
    uint rng=p.x*1973+p.y*9277+uint(s.state.x)*26699+911;
    float2 jitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float2 uv=(float2(p)+jitter)/float2(output.get_width(),output.get_height()),q=uv*2-1;q.x*=u.viewport.x/u.viewport.y;q.y=-q.y;
    float3 ro=f.eye.xyz,rd=normalize(f.forward.xyz*f.eye.w+f.right.xyz*q.x+f.up.xyz*q.y);
    RiverHit hit=riverIntersect(ro,rd,180,scene);float3 color=coveSky(rd,u,f);
    float tw=rd.y< -0.0001?(u.controls.z-ro.y)/rd.y:1e5;
    if(tw>0&&tw<180){
        for(uint i=0;i<5;i++){
            float3 pt=ro+rd*tw,w=coveWave(pt.xz,u,f);
            float wave=waves.sample(linearClamp,pt.xz/24+0.5).x;w.x+=wave;
            tw-=clamp((pt.y-w.x)/(rd.y-dot(w.yz,rd.xz)),-0.5,0.5);
        }
    }
    if(tw>0&&tw<hit.t&&tw<180){
        float3 pt=ro+rd*tw,water=coveWave(pt.xz,u,f);
        float2 wuv=pt.xz/24+0.5,du=float2(1.0/256,0);
        float2 slope=float2(waves.sample(linearClamp,wuv+du).x-waves.sample(linearClamp,wuv-du).x,waves.sample(linearClamp,wuv+du.yx).x-waves.sample(linearClamp,wuv-du.yx).x)*(256.0/48);
        float brush=exp(-dot(pt.xz-f.touch.xy,pt.xz-f.touch.xy)*5)*f.touch.z;
        slope+=sin(length(pt.xz-f.touch.xy)*22-f.clock.x*12)*normalize(pt.xz-f.touch.xy+0.001)*brush*0.15;
        float distanceFade=1/(1+tw*0.008),nscale=distanceFade;
        float3 n=normalize(float3(-(water.y+slope.x)*nscale,1,-(water.z+slope.y)*nscale));
        float3 reflection=reflect(rd,n);RiverHit reflected=riverIntersect(pt+n*0.018,reflection,60,scene);
        float3 reflectedColor=coveSky(reflection,u,f);
        if(reflected.hit){CoveMaterial m=coveMaterial(reflected,pt+n*0.018,reflection,vertices,indices,colors,normals,arm,u,f);reflectedColor=coveShade(m,reflection,u,f,scene,false,rng);}
        float3 refracted=refract(rd,n,1.0/1.333);RiverHit bottom=riverIntersect(pt-n*0.018,refracted,25,scene);
        float depth=bottom.hit?min(12.0,bottom.t):12.0;
        float3 deep=mix(float3(0.005,0.025,0.055),float3(0.018,0.21,0.26),coveDay(u));
        float3 bed=deep;
        if(bottom.hit){
            CoveMaterial m=coveMaterial(bottom,pt-n*0.018,refracted,vertices,indices,colors,normals,arm,u,f);
            bed=coveShade(m,refracted,u,f,scene,false,rng);
            float2 ca=m.p.xz*3.2+water.yz*2;
            float c1=abs(sin(ca.x+sin(ca.y*1.3+f.clock.x)*0.7)),c2=abs(sin(ca.y-cos(ca.x*1.7-f.clock.x*0.7)*0.6));
            float caustic=pow(1-min(c1,c2),14.0);bed+=float3(0.075,0.13,0.12)*caustic*exp(-depth*0.5)*coveDay(u);
        }
        float3 transmission=exp(-depth*float3(0.95,0.24,0.17));bed=bed*transmission+deep*(1-transmission);
        float fresnel=0.0204+0.9796*pow(1-saturate(dot(-rd,n)),5.0);color=mix(bed,reflectedColor,fresnel);
        float3 h=normalize(coveKey(u)-rd);float nh=max(dot(n,h),0.0),a=0.028+u.controls.y*0.009,a2=a*a,denom=nh*nh*(a2-1)+1;
        float distribution=a2/(PI*denom*denom+0.00001);
        float glint=distribution*0.0204*max(dot(n,coveKey(u)),0.0)*0.12;
        if(glint>0.025)glint*=riverVisibility(pt+n*0.025,coveKey(u),25,scene);
        color+=mix(float3(0.15,0.23,0.45),float3(3,2.5,1.5),coveDay(u))*min(glint,5.0);
        float edgeDepth=bottom.hit?bottom.t*max(0.1,-refracted.y):3.0;
        float shore=(1-smoothstep(0.008,0.04,edgeDepth))*(0.35+0.65*pow(0.5+0.5*sin(edgeDepth*40-f.clock.x*2+noise3(pt*4)*4),3.0));
        float foam=shore*smoothstep(0.24,0.62,noise3(float3(pt.xz*21,f.clock.x*0.25)));
        color=mix(color,mix(float3(0.10,0.17,0.25),float3(0.70,0.77,0.70),coveDay(u)),foam*0.48);
        float mist=1-exp(-tw*0.0018);color=mix(color,coveSky(float3(rd.x,0.04,rd.z),u,f)*0.65,mist);
    }else if(hit.hit){
        CoveMaterial m=coveMaterial(hit,ro,rd,vertices,indices,colors,normals,arm,u,f);color=coveShade(m,rd,u,f,scene,true,rng);
        color=mix(color,coveSky(rd,u,f)*0.6,1-exp(-hit.t*0.001));
    }
    // Analytic lens bloom is depth-tested against the same scene, not a screen sticker.
    float3 lamp=coveLantern(f),toLamp=lamp-ro;float along=dot(toLamp,rd),radial=length(toLamp-rd*along);
    if(along>0&&(hit.t>along-0.35)){float glow=exp(-radial*radial*18)*0.12+exp(-radial*radial*100)*0.32;color+=float3(1,0.46,0.09)*glow*(1.3-coveDay(u)*0.8);}
    output.write(float4(max(color,float3(0)),1),p);
}
