// Original procedural artwork and GPU ecosystem. No network or external assets.
float roundedRect(float2 p, float2 b, float radius) {
    float2 q = abs(p) - b + radius;
    return length(max(q,0.0)) + min(max(q.x,q.y),0.0) - radius;
}
float lineMask(float d, float width, float aa) { return 1-smoothstep(width-aa,width+aa,abs(d)); }
float mothShape(float2 p) {
    p.x=abs(p.x);
    float2 q=p-float2(0.30,0.18);
    q=float2(0.83*q.x-0.56*q.y,0.56*q.x+0.83*q.y);
    float upper=(length(q/float2(0.35,0.22))-1)*0.22;
    q=p-float2(0.22,-0.13);
    q=float2(0.86*q.x+0.51*q.y,-0.51*q.x+0.86*q.y);
    float lower=(length(q/float2(0.20,0.30))-1)*0.20;
    float body=(length((p-float2(0,-0.015))/float2(0.044,0.28))-1)*0.044;
    return min(body,min(upper,lower));
}
float cardLetters(float2 p, bool back, texture2d<float> atlas) {
    float2 uv=p/float2(1.68,2.5)+0.5;
    uv.y=1-uv.y; uv.x=uv.x*0.5+(back?0.5:0);
    return atlas.sample(linearClamp,uv).r;
}
float cardRelief(float2 p, bool back, texture2d<float> atlas) {
    float border=lineMask(roundedRect(p,float2(0.768,1.178),0.073),0.005,0.002);
    border+=lineMask(roundedRect(p,float2(0.733,1.143),0.065),0.0018,0.001);
    float text=cardLetters(p,back,atlas);
    float ornament=0;
    if(back) {
        float2 q=p-float2(0,0.03); float a=atan2(q.y,q.x),r=length(q);
        ornament=lineMask(r-0.46,0.005,0.001)+lineMask(r-0.40,0.002,0.001);
        ornament+=lineMask(r-(0.29+0.075*cos(a*8)),0.004,0.001);
        ornament+=lineMask(length(q/float2(0.22,0.14))-1,0.022,0.006);
        ornament+=1-smoothstep(0.06,0.068,length(q));
    } else {
        float2 q=p-float2(0,0.19);
        float a=atan2(q.y,q.x),r=length(q);
        ornament=lineMask(r-0.625,0.002,0.001)*smoothstep(-0.48,-0.42,q.y);
        ornament+=lineMask(r-0.655,0.002,0.001)*pow(abs(sin(a*24)),16.0)*smoothstep(-0.43,-0.37,q.y);
        // Four small cut-metal corner flourishes.
        float2 c=abs(p)-float2(0.64,1.035);
        ornament+=lineMask(abs(c.x)+abs(c.y)-0.045,0.004,0.001)*float(length(c)<0.08);
    }
    return saturate(border+ornament+text);
}
float3 foilSpectrum(float2 p,float3 n,float3 view,float3 light,float strength) {
    float3 h=normalize(view+light);
    float angle=atan2(p.y-0.13,p.x);
    float grooves=0.4*angle+0.7*length(p)+0.12*sin(p.y*19)*sin(p.x*15);
    float phase=dot(h,float3(cos(grooves*2.1),sin(grooves*2.1),0))*2.8+grooves*0.7;
    float3 color=pow(0.5+0.5*cos(PI*2*(phase+float3(0,0.34,0.67))),float3(2.8));
    float sparkle=pow(hash31(float3(floor(p*700),0.73)),26.0);
    float sheen=pow(max(dot(n,h),0.0),22.0)+0.18*pow(1-max(dot(n,view),0.0),2.0);
    return color*(0.11+sheen*1.8+sparkle*0.5)*strength;
}
kernel void cardRender(texture2d<float,access::write> image [[texture(0)]], texture2d<float> atlas [[texture(1)]],
                       constant Uniforms& u [[buffer(0)]], constant StageUniforms& s [[buffer(1)]], uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(image.get_width(),image.get_height()))) return;
    uint rng=id.x+id.y*uint(u.viewport.x)+uint(s.state.x)*94739+19;
    float2 jitter=s.state.y>0.5 ? float2(random01(rng),random01(rng))-0.5 : float2(0);
    float2 uv=(float2(id)+0.5+jitter)/u.viewport.xy, xy=screenPoint(uv,u);
    float3 ro=float3(0,0,4.25*exp(s.camera.z)),rd=normalize(float3(xy,-2.2));
    float yaw=s.camera.x+0.16,pitch=s.camera.y-0.08;
    ro=rotateX(rotateY(ro,-yaw),-pitch);rd=rotateX(rotateY(rd,-yaw),-pitch);
    float3 worldLight=normalize(float3(sin(u.controls.z+s.light.x)*2.0,0.9+s.light.y,2.5));
    float3 light=rotateX(rotateY(worldLight,-yaw),-pitch);
    float3 baseMetal=u.parameters.w<0.5?float3(0.64,0.76,0.90):u.parameters.w<1.5?float3(0.82,0.87,0.96):float3(0.90,0.59,0.22);
    float3 c=float3(0.003,0.005,0.011)+float3(0.010,0.020,0.037)*exp(-dot(xy,xy)*0.6);
    c+=float3(0.025,0.009,0.032)*exp(-dot(xy-float2(-0.8,0.3),xy-float2(-0.8,0.3))*2.5);
    bool back=ro.z<0; float z=back?-0.018:0.018;
    float t=(z-ro.z)/(abs(rd.z)<0.0001?0.0001:rd.z);
    float3 p=ro+rd*t;
    float edge=roundedRect(p.xy,float2(0.84,1.25),0.085);
    // Thin bevel remains visible at edge-on angles and gives the card thickness.
    float2 slab=intersectBox(ro,rd,float3(-0.84,-1.25,-0.018),float3(0.84,1.25,0.018));
    if(slab.x>0 && slab.y>slab.x && (edge>0 || t<0)) {
        float3 hit=ro+rd*slab.x;
        if(roundedRect(hit.xy,float2(0.84,1.25),0.085)<0.004) {
            c=baseMetal*(0.12+pow(0.5+0.5*sin(hit.y*280),4.0)*0.08); t=slab.x;
        }
    }
    if(t>0 && edge<0) {
        float2 q=p.xy;if(back)q.x=-q.x;
        float3 v=normalize(-rd);if(back){v.x=-v.x;v.z=-v.z;light.x=-light.x;light.z=-light.z;}
        float eps=0.0015, relief=cardRelief(q,back,atlas);
        float dx=cardRelief(q+float2(eps,0),back,atlas)-cardRelief(q-float2(eps,0),back,atlas);
        float dy=cardRelief(q+float2(0,eps),back,atlas)-cardRelief(q-float2(0,eps),back,atlas);
        float3 n=normalize(float3(-dx,-dy,0.65/(0.15+u.controls.x)));
        float edgeBevel=smoothstep(-0.012,0.0,edge);
        n=normalize(n+float3(normalize(q+0.0001)*edgeBevel*0.75,0));
        float3 h=normalize(v+light);
        float spec=pow(max(dot(n,h),0.0),95.0);
        float rough=hash31(float3(floor(q*900),0.4));
        c=(u.parameters.w<0.5?float3(0.003,0.004,0.009):u.parameters.w<1.5?float3(0.025,0.035,0.060):float3(0.014,0.009,0.005));
        c*=0.94+0.06*rough;
        c+=float3(0.12,0.17,0.23)*spec*0.20;
        float micro=lineMask(sin(q.x*74+sin(q.y*34)),0.03,0.015)*0.035;
        c+=foilSpectrum(q,n,v,light,u.controls.y*u.parameters.x)*(0.012+micro*0.25);
        float metalBrightness=0.25+0.7*max(dot(n,light),0.0)+1.3*spec;
        c=mix(c,baseMetal*metalBrightness+foilSpectrum(q,n,v,light,u.controls.y*u.parameters.x)*0.5,relief);
        c+=baseMetal*edgeBevel*(0.3+spec);
        if(!back) {
            // The illustration sits below the foil plane; each layer has its own parallax.
            float2 art=q-float2(0,0.19)+v.xy/max(v.z,0.24)*(0.025+u.controls.x*0.035);
            float moon=length(art-float2(0,0.28));
            float halo=exp(-pow((moon-0.24)*40,2.0));
            c+=baseMetal*halo*0.16+float3(0.02,0.04,0.10)*exp(-moon*5);
            float shape=mothShape(art),inside=1-smoothstep(-0.002,0.003,shape);
            float2 wing=abs(art-float2(0,0.02));
            float a=atan2(wing.y+0.12,wing.x+0.025),r=length(wing);
            float vein=pow(0.5+0.5*cos(a*41+r*25),18.0);
            float ridge=pow(0.5+0.5*cos(r*74+sin(a*6)*2),14.0);
            float outline=lineMask(shape,0.003,0.0015);
            float3 wn=normalize(float3(sin(a*41+r*25)*0.18,cos(r*74)*0.10,1));
            float3 iridescence=foilSpectrum(art,wn,v,light,u.controls.y*u.parameters.x);
            float body=exp(-pow(art.x*27,2.0))*inside;
            float eyes=exp(-dot((wing-float2(0.29,0.18))*float2(30,36),(wing-float2(0.29,0.18))*float2(30,36)));
            float3 ink=baseMetal*(0.035+vein*0.18+ridge*0.045)+iridescence*(0.08+vein*0.48+ridge*0.14);
            ink+=baseMetal*(body*0.25+outline*0.5)+float3(0.15,0.68,1.1)*eyes;
            c=mix(c,ink,inside);
            // Antennae and angle-revealed constellation, both etched into the top coat.
            float2 aq=float2(abs(art.x),art.y);
            float ant=lineMask(aq.x-(0.02+0.31*pow(max(aq.y-0.23,0.0),0.72)),0.003,0.0015)*smoothstep(0.22,0.25,aq.y)*(1-smoothstep(0.47,0.49,aq.y));
            c+=baseMetal*ant*0.6;
            float reveal=smoothstep(0.10,0.45,v.x);
            float constellation=lineMask(length(art)-0.53,0.0015,0.001)*pow(abs(sin(atan2(art.y,art.x)*9)),28.0);
            c+=spectrum(0.6+v.x)*constellation*reveal*u.parameters.x;
        } else {
            float2 art=q+v.xy*0.045;
            float lattice=lineMask(sin(art.x*38)*sin(art.y*38),0.025,0.02);
            c+=foilSpectrum(art,n,v,light,u.controls.y*u.parameters.x)*lattice*0.12;
        }
    }
    image.write(float4(c,t>0&&edge<0?t:25),id);
}

// ---- Reef simulation ------------------------------------------------------
struct ReefAgent { float4 position; float4 velocity; };
float3 reefUV(float3 p) { return (p-float3(-7,0,-7))/float3(14,6,14); }
float3 reefPosition(float3 p) { return p*float3(14,6,14)+float3(-7,0,-7); }
void reefBasis(constant StageUniforms& s,thread float3& ro,thread float3& f,thread float3& right,thread float3& up) {
    float3 target=float3(0,1.9,0),offset=float3(0,0.65,8.8)*exp(s.camera.z);
    ro=target+rotateY(rotateX(offset,s.camera.y*0.65),s.camera.x);
    ro.y=max(ro.y,0.7);
    f=normalize(target-ro);right=normalize(cross(f,float3(0,1,0)));up=cross(right,f);
}
float3 reefBrush(constant Uniforms& u,constant StageUniforms& s) {
    float3 ro,f,r,up;reefBasis(s,ro,f,r,up);
    float2 xy=screenPoint(u.pointer.xy,u);
    return float3(0,1.9,0)+(r*xy.x+up*xy.y)*(length(ro-float3(0,1.9,0))/2.2);
}
float3 reefAmbient(float3 p,float time,float strength) {
    return float3(0.12+0.10*sin(p.z*0.7+time*0.3),0.045*sin(p.x+p.z+time*0.4),0.09*cos(p.x*0.6+time*0.27))*strength;
}
kernel void reefInitialize(device ReefAgent* actors [[buffer(2)]],device ReefAgent* particles [[buffer(3)]],
                           constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    uint rng=id*3917+73;float3 h=float3(random01(rng),random01(rng),random01(rng));
    uint count=uint(s.simulation.z);
    if(id<count+12) {
        float group=float(id%3),a=h.x*PI*2;
        float3 p=float3(cos(a)*(0.7+h.y),sin(a*2)*0.35+h.z*0.55, sin(a)*(0.8+h.z));
        p+=float3((group-1)*2.15,1.45+group*0.38,-1.1-group*0.6);
        float3 vel=float3(-sin(a),0.08,cos(a))*(0.45+h.y*0.18);
        if(id>=count) {uint j=id-count;p=float3((hash11(float(j)+17)-0.5)*8.0,1.7+hash11(float(j)+2)*2.6,-4.5+hash11(float(j)+24)*6.5);if(j==0)p=float3(2.35,2.85,2.5);if(j==1)p=float3(-2.5,3.3,0.4);vel=float3(0,0.08,0);}
        actors[id]={float4(p,h.x*PI*2),float4(vel,0)};
    }
    if(id<uint(s.simulation.w))particles[id]={float4(reefPosition(h),random01(rng)),float4(0,0,0,0)};
}
kernel void reefFlowInitialize(texture3d<float,access::write> flow [[texture(0)]],uint3 id [[thread_position_in_grid]]) {
    if(any(id>=uint3(flow.get_width(),flow.get_height(),flow.get_depth())))return;
    flow.write(float4(0),id);
}
kernel void reefFlowStep(texture3d<float> previous [[texture(0)]],texture3d<float,access::write> next [[texture(1)]],
                         constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint3 id [[thread_position_in_grid]]) {
    float3 size=float3(next.get_width(),next.get_height(),next.get_depth());if(any(id>=uint3(size)))return;
    float3 uv=(float3(id)+0.5)/size,p=reefPosition(uv);
    float4 old=previous.sample(linearClamp,uv);
    float4 advected=previous.sample(linearClamp,uv-old.xyz*s.simulation.y/float3(14,6,14));
    float3 v=advected.xyz*exp(-s.simulation.y*0.7);
    float wake=advected.w*exp(-s.simulation.y*0.75);
    if(u.pointer.z>0.5) {
        float3 d=p-reefBrush(u,s);float falloff=exp(-dot(d,d)*1.6);
        float3 ro,f,r,up;reefBasis(s,ro,f,r,up);
        float3 push=r*clamp(u.interaction.x*70.0,-3.0,3.0)-up*clamp(u.interaction.y*70.0,-3.0,3.0);
        v+=(push+cross(f,d)*0.06+up*0.035)*falloff;
        wake=min(1.0,wake+falloff*0.12);
    }
    v=clamp(v,float3(-2.5),float3(2.5));
    next.write(float4(v,wake),id);
}
kernel void reefActorsStep(device const ReefAgent* previous [[buffer(2)]],device ReefAgent* next [[buffer(3)]],texture3d<float> flow [[texture(0)]],
                           constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    uint count=uint(s.simulation.z);if(id>=count+12)return;
    ReefAgent a=previous[id];float3 p=a.position.xyz,v=a.velocity.xyz;
    float4 water=flow.sample(linearClamp,reefUV(p));float time=s.simulation.x,dt=s.simulation.y;
    float3 force=0;float group=float(id%3);
    if(id<count) {
        float3 separation=0,alignment=0,center=0;float neighbors=0;
        for(uint j=0;j<count;++j) {
            if(j==id)continue;float3 d=p-previous[j].position.xyz;float d2=dot(d,d);
            if(d2<0.12)separation+=d/max(d2,0.006);
            if(d2<2.25 && j%3==id%3) {alignment+=previous[j].velocity.xyz;center+=previous[j].position.xyz;neighbors+=1;}
        }
        if(neighbors>0)force+=(alignment/neighbors-v)*u.controls.y*1.6+(center/neighbors-p)*u.controls.y*0.65;
        force+=clamp(separation,float3(-5),float3(5))*0.19;
        float3 goal=float3(sin(time*0.19+group*2.1)*2.8,1.7+group*0.40+sin(time*0.33+group)*0.35,cos(time*0.16+group*2.1)*2.0-1.3);
        force+=(goal-p)*0.12+float3(sin(a.position.w+time),0,cos(a.position.w+time))*0.04;
        if(p.y<0.8)force.y+=(0.8-p.y)*4;
        if(p.y>4.2)force.y-=(p.y-4.2)*2;
        if(u.pointer.z>0.5){float3 d=p-reefBrush(u,s);force+=d/max(dot(d,d),0.1)*exp(-dot(d,d)*0.6)*1.4;}
        force+=(water.xyz+reefAmbient(p,time,u.controls.x)-v*0.13)*0.9;
        v+=force*dt;
        float speed=length(v);v*=clamp(speed,0.28,1.2)/max(speed,0.0001);
    } else {
        float phase=float(id-count)*1.7;
        float j=float(id-count);
        float3 goal=float3((hash11(j+17)-0.5)*8.0,1.7+hash11(j+2)*2.6,-4.5+hash11(j+24)*6.5);
        if(id==count)goal=float3(2.35,2.85,2.5);if(id==count+1)goal=float3(-2.5,3.3,0.4);
        goal+=float3(sin(time*0.1+phase)*0.5,sin(time*0.25+phase)*0.28,cos(time*0.08+phase)*0.3);
        v=mix(v,(goal-p)*0.09+water.xyz*0.55+reefAmbient(p,time,u.controls.x)*0.3+float3(0,sin(time*2.8+phase)*0.10,0),0.025);
    }
    p+=v*dt;
    p=clamp(p,float3(-6.5,0.45,-6.5),float3(6.5,5.5,6.5));
    a.position.xyz=p;a.velocity=float4(v,max(water.w,a.velocity.w*exp(-dt*1.3)));next[id]=a;
}
kernel void reefPlanktonStep(device const ReefAgent* previous [[buffer(2)]],device ReefAgent* next [[buffer(3)]],texture3d<float> flow [[texture(0)]],
                             constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    if(id>=uint(s.simulation.w))return;ReefAgent a=previous[id];
    float3 p=a.position.xyz;float4 water=flow.sample(linearClamp,reefUV(p));
    float3 v=water.xyz+reefAmbient(p,s.simulation.x,u.controls.x)+float3(0,0.015,0);
    p+=v*s.simulation.y;p=reefPosition(fract(reefUV(p)));
    a.position.xyz=p;a.velocity=float4(v,max(water.w,a.velocity.w*exp(-s.simulation.y*1.8)));next[id]=a;
}

// ---- Reef rendering: depth-tested meshes over an underwater volume ---------
float reefFloor(float2 p) { return -0.12+0.10*sin(p.x*0.8)*cos(p.y*0.65)+0.05*sin(p.x*2+p.y); }
float3 reefWater(constant Uniforms& u) {
    return u.parameters.w<0.5?float3(0.009,0.12,0.17):u.parameters.w<1.5?float3(0.0025,0.018,0.045):float3(0.028,0.035,0.10);
}
float3 reefGlow(float seed,constant Uniforms& u) {
    return mix(float3(0.025,0.85,0.65),float3(0.46,0.08,1.0),smoothstep(0.2,0.9,seed+u.parameters.w*0.12));
}
kernel void reefBackground(texture2d<float,access::write> image [[texture(0)]],texture2d<float,access::write> distance [[texture(1)]],texture3d<float> flow [[texture(2)]],
                           constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(image.get_width(),image.get_height())))return;
    float2 uv=(float2(id)+0.5)/u.viewport.xy;
    float3 ro,f,right,up;reefBasis(s,ro,f,right,up);
    float2 xy=screenPoint(uv,u);float3 rd=normalize(f*2.2+right*xy.x+up*xy.y);
    float3 water=reefWater(u),c=water*(0.42+0.6*saturate(rd.y+0.6));
    float time=u.viewport.z,sun=u.controls.z*(u.parameters.w>0.5&&u.parameters.w<1.5?0.20:1.0);
    float t=30;float3 normal=float3(0,1,0);float rock=0;
    if(rd.y < -0.001) {
        t=-ro.y/rd.y;
        for(int i=0;i<4;++i)t=(reefFloor((ro+rd*t).xz)-ro.y)/rd.y;
        t=clamp(t,0.1,30.0);
    }
    for(int i=0;i<9;++i) {
        float seed=float(i)*7.31;
        float3 center=float3((hash11(seed+1)-0.5)*11,0.08,-4+hash11(seed+2)*8);
        float3 radii=float3(0.45+hash11(seed+3)*0.6,0.32+hash11(seed+4)*0.5,0.45+hash11(seed+5)*0.6);
        float3 a=(ro-center)/radii,b=rd/radii;float bb=dot(a,b),aa=dot(b,b),h=bb*bb-aa*(dot(a,a)-1);
        if(h>0) {float hit=(-bb-sqrt(h))/aa;if(hit>0&&hit<t){t=hit;normal=normalize((ro+rd*t-center)/(radii*radii));rock=1;}}
    }
    if(t<29.9) {
        float3 p=ro+rd*t;
        if(rock<0.5)normal=normalize(float3((reefFloor(p.xz-float2(0.02,0))-reefFloor(p.xz+float2(0.02,0)))*25,1,
                                                         (reefFloor(p.xz-float2(0,0.02))-reefFloor(p.xz+float2(0,0.02)))*25));
        float grain=noise3(p*29),ripple=0.5+0.5*sin(p.x*19+sin(p.z*2)*2);
        float3 sand=mix(float3(0.17,0.24,0.23),float3(0.07,0.13,0.14),rock)*(0.7+grain*0.3+ripple*0.05);
        float caustic=causticNetwork(p.xz*2.3,time*0.6);
        float lighting=0.13+sun*(max(dot(normal,normalize(float3(-0.3,1,0.2))),0.0)*0.45+caustic*0.45);
        c=sand*lighting;
        float coralGlow=pow(0.5+0.5*sin(p.x*2.7)*sin(p.z*3.3),15.0)*0.08*u.parameters.x;
        c+=reefGlow(grain,u)*coralGlow;
        float3 trans=exp(-float3(0.13,0.065,0.045)*t);
        c=c*trans+water*(1-trans);
    }
    // A bounded integration of sunlight shafts and bioluminescent current wakes.
    int steps=u.options.w==0?8:16;float travel=min(t,20.0);
    float3 volume=0;
    for(int i=0;i<steps;++i) {
        float d=(float(i)+0.5)*travel/float(steps);float3 p=ro+rd*d;
        float2 surface=p.xz+float2(-0.32,0.12)*(6-p.y);
        float beam=pow(0.5+0.5*sin(surface.x*1.5+surface.y*0.55+time*0.08),14.0)
                  *pow(0.5+0.5*cos(surface.y*0.9-surface.x*0.3-time*0.05),4.0);
        float shaft=exp(-pow((surface.x+surface.y*0.25+2.8)/0.20,2.0))+0.65*exp(-pow((surface.x+surface.y*0.25+1.1)/0.34,2.0))
                   +0.4*exp(-pow((surface.x+surface.y*0.25-1.3)/0.5,2.0));
        volume+=float3(0.20,0.46,0.39)*(beam*0.4+shaft)*sun*exp(-d*0.055)*0.11*travel/float(steps);
        float wake=flow.sample(linearClamp,reefUV(p)).w;
        volume+=float3(0.015,0.30,0.24)*wake*u.parameters.x*0.11*travel/float(steps);
    }
    c+=volume;
    float surfaceGlow=pow(max(dot(rd,normalize(float3(-0.3,0.9,-0.2))),0.0),8.0);
    c+=float3(0.14,0.32,0.32)*surfaceGlow*sun;
    image.write(float4(c,t),id);distance.write(float4(t),id);
}
struct ReefVertex {
    float4 position [[position]];
    float3 world;
    float3 normal;
    float3 color;
    float2 uv;
    float glow;
    float style;
};
ReefVertex reefProject(float3 p,float3 n,float3 color,float2 uv,float glow,float style,constant Uniforms& u,constant StageUniforms& s) {
    float3 ro,f,r,up;reefBasis(s,ro,f,r,up);float3 relative=p-ro;
    float z=dot(relative,f);
    float4 clip=float4(dot(relative,r)*2.2*u.viewport.y/u.viewport.x,dot(relative,up)*2.2,z*36.0/35.92-0.08*36.0/35.92,z);
    if(s.state.y>0.5){uint rng=uint(s.state.x)*94739+19;float2 jitter=float2(random01(rng),random01(rng))-0.5;clip.xy+=jitter/u.viewport.xy*clip.w*2;}
    return {clip,p,n,color,uv,glow,style};
}
float2 quadCorner(uint id) {
    const float2 points[6]={float2(0,0),float2(1,0),float2(0,1),float2(0,1),float2(1,0),float2(1,1)};
    return points[id%6];
}
vertex ReefVertex reefFishVertex(uint id [[vertex_id]],uint fish [[instance_id]],device const ReefAgent* actors [[buffer(2)]],
                                 constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    ReefAgent a=actors[fish];float seed=hash11(float(fish)+11),size=0.11+seed*0.09;
    float3 f=normalize(a.velocity.xyz+float3(0.0001,0,0)),side=normalize(cross(float3(0,1,0),f)),up=cross(f,side);
    float3 p,n;float2 uv;
    if(id<12*8*6) {
        float2 corner=quadCorner(id);uint cell=id/6;
        float theta=(float(cell%12)+corner.x)/12*PI*2,phi=(float(cell/12)+corner.y)/8*PI;
        p=float3(cos(phi)*size,sin(phi)*cos(theta)*size*0.32,sin(phi)*sin(theta)*size*0.20);
        n=normalize(float3(cos(phi)*0.25,sin(phi)*cos(theta),sin(phi)*sin(theta)*1.6));
        uv=float2(cos(phi),theta/(PI*2));
    } else {
        float2 corner=quadCorner(id);float crossFin=float((id-12*8*6)/6);
        p=float3(-size*(0.8+corner.x*1.1),mix(-1.0,1.0,corner.y)*corner.x*size*0.7*(1-crossFin),mix(-1.0,1.0,corner.y)*corner.x*size*0.5*crossFin);
        n=float3(0,crossFin,1-crossFin);uv=float2(-1,corner.y);
    }
    p.z+=sin(u.viewport.z*10+a.position.w-p.x*14)*size*0.18*saturate(-p.x/size);
    float3 color=fish%3==0?float3(0.14,0.72,0.78):fish%3==1?float3(0.48,0.30,0.78):float3(0.74,0.62,0.30);
    return reefProject(a.position.xyz+f*p.x+up*p.y+side*p.z,normalize(f*n.x+up*n.y+side*n.z),color,uv,a.velocity.w,0,u,s);
}
vertex ReefVertex reefKelpVertex(uint id [[vertex_id]],uint plant [[instance_id]],texture3d<float> flow [[texture(0)]],
                                 constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    uint stalk=plant/7,leaf=plant%7;float h=hash11(float(stalk)+31),h2=hash11(float(stalk)+91);
    float3 root=float3((stalk%2==0?-1:1)*(1.8+h*4.1),0,-5+h2*9);
    root.y=reefFloor(root.xz)-0.03;
    float height=1.3+hash11(float(stalk)+47)*2.7;
    float2 q=quadCorner(id);float t=(float(id/6)+q.y)/24;
    float angle=h*PI*2+float(leaf)*2.4;
    float attach=leaf==0?0:(0.12+float(leaf)*0.11);
    float along=leaf==0?t:attach+t*0.27;
    float3 current=flow.sample(linearClamp,reefUV(root+float3(0,height*along,0))).xyz;
    float3 bend=float3(sin(u.viewport.z*(0.6+u.controls.x*0.2)+h*9+along*2),0,cos(u.viewport.z*0.4+h*5+along*3))*(0.12+u.controls.x*0.12);
    bend+=current*0.40;
    float3 p=root+float3(0,height*along,0)+bend*along*along*height;
    float3 direction=float3(cos(angle),0,sin(angle));
    if(leaf>0)p+=direction*sin(t*1.7)*(0.35+h2*0.55)+float3(0,sin(t*PI)*0.12,0);
    float width=leaf==0?0.015:sin(PI*t)*0.13*(0.6+h);
    float3 lateral=float3(-sin(angle),0.12*cos(t*PI*2),cos(angle));
    p+=lateral*(q.x*2-1)*width;
    float3 normal=normalize(cross(lateral,float3(0,1,0)+direction*0.5));
    float3 color=mix(float3(0.035,0.22,0.12),float3(0.08,0.38,0.24),h);
    return reefProject(p,normal,color,float2(q.x,t),pow(t,8.0)*0.04,1,u,s);
}
vertex ReefVertex reefCoralVertex(uint id [[vertex_id]],uint branch [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    uint cluster=branch/15,node=branch%15;float seed=float(cluster)*11.7;
    float3 base=float3((hash11(seed+1)-0.5)*10,0,-4.5+hash11(seed+3)*9);
    base.y=reefFloor(base.xz);
    float height=0.35+hash11(seed+4)*0.65;
    float3 direction=float3(0,1,0);float length=height*0.5,radius=0.055;
    // A complete binary branch tree, with shared endpoints and tapering tubes.
    uint path=node+1,level=0;uint temp=path;while(temp>1){level++;temp>>=1;}
    for(uint step=0;step<level;++step) {
        base+=direction*length;
        uint bit=(path>>(level-step-1))&1;
        float angle=seed+float(step)*2.1+(bit?1.15:-1.15);
        direction=normalize(direction*0.7+float3(cos(angle)*0.65,0.45,sin(angle)*0.65));
        length*=0.78;radius*=0.69;
    }
    float2 q=quadCorner(id);float a=(float((id/6)%12)+q.x)/12*PI*2;
    float3 tangent=normalize(cross(direction,float3(1,0.01,0))),other=cross(direction,tangent);
    float3 n=tangent*cos(a)+other*sin(a);
    float t=(float((id/6)/12)+q.y)/4;
    float3 p=base+direction*length*t+n*radius*(1-t*0.3)+tangent*sin(t*PI)*length*0.16;
    float glow=(0.15+pow(t,7.0)*0.45)*float(level>=2);
    float3 color=reefGlow(hash11(seed+5),u)*0.36+float3(0.05,0.015,0.03);
    return reefProject(p,n,color,float2(a,t),glow,2,u,s);
}
float3 reefFog(float3 color,float distance,constant Uniforms& u) {
    float3 trans=exp(-float3(0.13,0.065,0.045)*distance);
    return color*trans+reefWater(u)*(1-trans);
}
vertex ReefVertex reefPolypVertex(uint id [[vertex_id]],uint polyp [[instance_id]],
                                  constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    uint colony=polyp/9;float seed=float(colony)*9.87,offset=float(polyp%9);
    float3 base=float3((hash11(seed+8)-0.5)*10,0,-3.7+hash11(seed+2)*8);
    base.xz+=float2(cos(offset*2.4),sin(offset*2.4))*sqrt(offset)*0.16;
    base.y=reefFloor(base.xz);
    float size=0.12+hash11(float(polyp)+29)*0.14;
    float2 q=quadCorner(id);uint cell=id/6;
    float theta=(float(cell%12)+q.x)/12*PI*2,phi=(float(cell/12)+q.y)/8*PI*0.65;
    float radial=sin(phi)*(1+0.07*sin(theta*12+u.viewport.z*0.3));
    float3 p=base+float3(cos(theta)*radial*size,(cos(phi)+0.4)*size*1.5,sin(theta)*radial*size);
    float3 n=normalize(float3(cos(theta)*sin(phi),cos(phi),sin(theta)*sin(phi)));
    return reefProject(p,n,reefGlow(hash11(seed+3),u)*0.28,float2(theta,phi),0.2,3,u,s);
}
fragment float4 reefSolidFragment(ReefVertex in [[stage_in]],texture2d<float,access::read> seabed [[texture(0)]],
                                  constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    float3 ro,f,r,up;reefBasis(s,ro,f,r,up);float distance=length(in.world-ro);
    if(distance>seabed.read(uint2(in.position.xy)).r+0.035)discard_fragment();
    float3 n=normalize(in.normal),v=normalize(ro-in.world),light=normalize(float3(-0.3,1,0.2));
    float sun=u.controls.z*(u.parameters.w>0.5&&u.parameters.w<1.5?0.2:1.0);
    float illumination=0.18+sun*(0.35+abs(dot(n,light))*0.65);
    float3 c=in.color*illumination;
    if(in.style<0.5) {
        float stripe=0.6+0.4*pow(0.5+0.5*cos(in.uv.x*27),4.0);
        c*=stripe;
        c+=float3(0.45,0.76,0.85)*pow(max(dot(n,normalize(v+light)),0.0),40.0)*sun;
        float eye=smoothstep(0.58,0.72,in.uv.x)*(1-smoothstep(0.85,0.94,in.uv.x))
            *pow(abs(sin(in.uv.y*PI*2)),30.0);
        c=mix(c,float3(0.004,0.008,0.014),eye);
        c+=in.color*in.glow*u.parameters.x*0.9;
    } else if(in.style<1.5) {
        float vein=lineMask(in.uv.x-0.5,0.025,0.008);
        c*=0.83+vein*0.20+0.035*cos(in.uv.y*120-abs(in.uv.x-0.5)*24);
        c+=float3(0.06,0.28,0.12)*pow(max(dot(-n,light),0.0),2.0)*sun*0.4;
    } else if(in.style<2.5) c+=in.color*in.glow*u.parameters.x*(u.parameters.w>0.5?3.5:1.5);
    else {
        float mouth=exp(-pow(in.uv.y*7,2.0));
        float ring=exp(-pow((in.uv.y-0.25)*18,2.0));
        c*=0.8+0.2*cos(in.uv.x*12);
        c=mix(c,float3(0.002,0.004,0.009),mouth);
        c+=in.color*ring*u.parameters.x*2.5;
    }
    c=reefFog(c,distance,u);
    return float4(c,1);
}
vertex ReefVertex reefJellyVertex(uint id [[vertex_id]],uint jelly [[instance_id]],device const ReefAgent* actors [[buffer(2)]],
                                  constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    ReefAgent a=actors[uint(s.simulation.z)+jelly];float2 q=quadCorner(id);uint cell=id/6;
    float theta=(float(cell%32)+q.x)/32*PI*2,phi=(float(cell/32)+q.y)/14*1.92;
    float pulse=0.92+0.10*sin(u.viewport.z*2.8+float(jelly)*1.7),radius=(jelly==0?0.58:0.26+hash11(float(jelly)+44)*0.20)*pulse;
    float rib=1+0.035*cos(theta*16)*sin(phi);
    float3 p=float3(cos(theta)*sin(phi)*radius*rib,cos(phi)*radius*0.68,sin(theta)*sin(phi)*radius*rib);
    float3 normal=normalize(float3(cos(theta)*sin(phi),cos(phi)/0.68,sin(theta)*sin(phi)));
    return reefProject(a.position.xyz+p,normal,reefGlow(hash11(float(jelly)+0.8),u),float2(theta,phi),0.45+a.velocity.w,0,u,s);
}
vertex ReefVertex reefTentacleVertex(uint id [[vertex_id]],uint tentacle [[instance_id]],device const ReefAgent* actors [[buffer(2)]],texture3d<float> flow [[texture(0)]],
                                     constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    uint jelly=tentacle/10,arm=tentacle%10;ReefAgent a=actors[uint(s.simulation.z)+jelly];
    float2 q=quadCorner(id);float t=(float(id/6)+q.y)/24;
    float theta=float(arm)/10*PI*2,radius=(jelly==0?0.58:0.26+hash11(float(jelly)+44)*0.20)*0.65;
    float3 p=a.position.xyz+float3(cos(theta)*radius,-0.08-t*(0.75+hash11(float(tentacle)+19)*0.65),sin(theta)*radius);
    float time=u.viewport.z;
    p.x+=sin(time*1.6+t*8+theta)*t*0.10;p.z+=cos(time*1.4+t*7+theta)*t*0.10;
    p+=flow.sample(linearClamp,reefUV(p)).xyz*t*0.35;
    float3 ro,f,right,up;reefBasis(s,ro,f,right,up);
    p+=right*(q.x*2-1)*(0.009+0.008*sin(t*15+theta))*(1-t*0.65);
    return reefProject(p,-f,reefGlow(hash11(float(jelly)+0.8),u),float2(q.x,t),0.45+a.velocity.w,1,u,s);
}
fragment float4 reefJellyFragment(ReefVertex in [[stage_in]],texture2d<float,access::read> seabed [[texture(0)]],
                                  constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    float3 ro,f,r,up;reefBasis(s,ro,f,r,up);float distance=length(in.world-ro);
    if(distance>seabed.read(uint2(in.position.xy)).r+0.03)discard_fragment();
    float fresnel=pow(1-abs(dot(normalize(in.normal),normalize(ro-in.world))),2.0);
    float ribs=pow(0.5+0.5*cos(in.uv.x*16),12.0);
    float rim=exp(-pow((in.uv.y-1.78)*18,2.0));
    float alpha=in.style<0.5?0.06+fresnel*0.32+ribs*0.07+rim*0.22:0.28;
    float brightness=in.style<0.5?0.14+fresnel*0.7+ribs*0.15+rim*0.6:0.45;
    float3 c=in.color*brightness*(0.5+u.parameters.x*in.glow)*(u.parameters.w>0.5?1.3:0.85);
    c+=float3(0.18,0.25,0.28)*fresnel*u.controls.z*0.25;
    c*=exp(-float3(0.13,0.065,0.045)*distance);
    return float4(c,alpha);
}
vertex ReefVertex reefPlanktonVertex(uint id [[vertex_id]],uint particle [[instance_id]],device const ReefAgent* particles [[buffer(2)]],
                                     constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    ReefAgent a=particles[particle];float3 ro,f,right,up;reefBasis(s,ro,f,right,up);
    float2 q=quadCorner(id)*2-1;
    float radius=0.009+a.position.w*0.008+a.velocity.w*0.027;
    float3 p=a.position.xyz+(right*q.x+up*q.y)*radius;
    return reefProject(p,-f,reefGlow(a.position.w,u),q,a.velocity.w,a.position.w,u,s);
}
fragment float4 reefPlanktonFragment(ReefVertex in [[stage_in]],texture2d<float,access::read> seabed [[texture(0)]],
                                     constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]]) {
    float rr=dot(in.uv,in.uv);if(rr>1)discard_fragment();
    float3 ro,f,r,up;reefBasis(s,ro,f,r,up);float distance=length(in.world-ro);
    if(distance>seabed.read(uint2(in.position.xy)).r)discard_fragment();
    float brightness=exp(-rr*5)*(0.045+in.glow*2.5+pow(in.style,14.0)*0.3)*u.parameters.x;
    float3 color=in.color*brightness*exp(-float3(0.13,0.065,0.045)*distance);
    return float4(color,min(0.55,brightness*0.3));
}
