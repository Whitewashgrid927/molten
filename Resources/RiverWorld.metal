// Geometry-backed river renderer. Metal hardware ray queries see the same
// forest for visibility, shadows, reflection, refraction, and diffuse probes.
struct RiverMeshVertex { float4 position; float4 normal; float4 color; };
struct RiverFrame {
    float4x4 viewProjection;
    float4x4 previousViewProjection;
    float4 jitter; // xy current jitter in input pixels, zw previous/current time
    uint4 counts;  // particles, frame, history reset, paused
};
struct RiverMaterial { float3 p,n,base; float roughness,kind,seed; };
struct RiverHit { float t; uint primitive; float2 bary; bool hit; };
float3 riverMoon() { return normalize(float3(-0.34,0.58,-0.72)); }
float3 riverSky(float3 rd,constant Uniforms& u) {
    float horizon=pow(1-saturate(rd.y),3.0);
    float3 sky=mix(float3(0.010,0.023,0.050),float3(0.025,0.043,0.075),horizon);
    float clouds=fbm3(float3(rd.xz/max(rd.y+0.3,0.15)*1.5,u.viewport.z*0.004+12),4);
    sky*=1-smoothstep(0.46,0.73,clouds)*0.68;
    sky+=nightStars(rd)*0.15*smoothstep(0.45,0.20,clouds)*smoothstep(0.06,0.3,rd.y);
    float d=length(rd-riverMoon());
    sky+=float3(3.5,3.8,4.2)*(1-smoothstep(0.017,0.020,d))*(0.2+u.controls.z);
    sky+=float3(0.07,0.10,0.14)*exp(-d*9)*(0.2+u.controls.z);
    float ridge=0.03+sin(atan2(rd.x,rd.z)*8)*0.018;
    sky=mix(float3(0.014,0.024,0.035),sky,smoothstep(ridge-0.01,ridge+0.01,rd.y));
    if(u.parameters.w>1.5)sky*=float3(1.12,0.83,1.10);
    return sky;
}
RiverHit riverIntersect(float3 origin,float3 direction,float maxDistance,primitive_acceleration_structure scene) {
    intersector<triangle_data> tracer;
    tracer.assume_geometry_type(geometry_type::triangle);tracer.force_opacity(forced_opacity::opaque);
    ray r;r.origin=origin;r.direction=direction;r.min_distance=0.003;r.max_distance=maxDistance;
    auto h=tracer.intersect(r,scene);
    return {h.type==intersection_type::none?maxDistance:h.distance,h.primitive_id,h.triangle_barycentric_coord,h.type!=intersection_type::none};
}
float riverVisibility(float3 p,float3 direction,float distance,primitive_acceleration_structure scene) {
    intersector<triangle_data> tracer;
    tracer.assume_geometry_type(geometry_type::triangle);tracer.force_opacity(forced_opacity::opaque);
    tracer.accept_any_intersection(true);
    ray r;r.origin=p;r.direction=direction;r.min_distance=0.008;r.max_distance=distance;
    return tracer.intersect(r,scene).type==intersection_type::none?1.0:0.0;
}
constexpr sampler riverRepeat(coord::normalized,address::repeat,filter::linear,mip_filter::linear);
float4 riverMap(texture2d_array<float> map,uint index,float3 p,float3 n,float lod) {
    float3 w=pow(abs(n),float3(4));w/=max(dot(w,float3(1)),0.0001);
    return map.sample(riverRepeat,p.zy,index,level(lod))*w.x
          +map.sample(riverRepeat,p.xz,index,level(lod))*w.y
          +map.sample(riverRepeat,p.xy,index,level(lod))*w.z;
}
float3 riverMapNormal(texture2d_array<float> map,uint index,float3 p,float3 n,float lod) {
    float3 w=pow(abs(n),float3(4));w/=max(dot(w,float3(1)),0.0001);
    float2 a=map.sample(riverRepeat,p.zy,index,level(lod)).xy*2-1;
    float2 b=map.sample(riverRepeat,p.xz,index,level(lod)).xy*2-1;
    float2 c=map.sample(riverRepeat,p.xy,index,level(lod)).xy*2-1;
    float3 bump=float3(0,a.y,a.x)*w.x+float3(b.x,0,b.y)*w.y+float3(c.x,c.y,0)*w.z;
    return normalize(n+(bump-n*dot(bump,n))*0.62);
}
RiverMaterial riverMaterial(RiverHit hit,float3 ro,float3 rd,device const RiverMeshVertex* vertices,device const uint* indices,
                            texture2d_array<float> colors,texture2d_array<float> details,texture2d_array<float> properties) {
    uint3 ids=uint3(indices[hit.primitive*3],indices[hit.primitive*3+1],indices[hit.primitive*3+2]);
    RiverMeshVertex a=vertices[ids.x],b=vertices[ids.y],c=vertices[ids.z];
    float3 weights=float3(1-hit.bary.x-hit.bary.y,hit.bary);
    RiverMaterial m;
    m.p=ro+rd*hit.t;m.n=normalize(a.normal.xyz*weights.x+b.normal.xyz*weights.y+c.normal.xyz*weights.z);
    m.kind=a.position.w;m.seed=a.normal.w;m.base=a.color.xyz;m.roughness=a.color.w;
    if(dot(m.n,rd)>0)m.n=-m.n;
    float lod=max(0.0,log2(max(hit.t,1.0)*0.38));
    float height=m.p.y-riverLevel(m.p.z),wet=1-smoothstep(0.02,0.32,height);
    if(m.kind<2.5) {
        uint index=m.kind<0.5?(height<0.09?0:3):m.kind<1.5?1:2;
        float3 q=m.p*(index==2?float3(1.3,0.42,1.3):index==0?float3(0.85):index==3?float3(0.55):float3(0.7));
        float4 maps=riverMap(properties,index,q,m.n,lod);
        m.base=riverMap(colors,index,q,m.n,lod).rgb*(0.75+0.25*maps.r);
        m.roughness=clamp(maps.g*(1-wet*0.26),0.32,0.94);
        m.n=riverMapNormal(details,index,q,m.n,lod);
        if(m.kind<0.5 && height>-0.04 && height<0.24){
            float blend=smoothstep(-0.04,0.24,height);
            float3 gravel=riverMap(colors,0,m.p*0.85,m.n,lod).rgb;
            float3 forest=riverMap(colors,3,m.p*0.55,m.n,lod).rgb;
            m.base=mix(gravel,forest,blend)*(0.75+0.25*maps.r);
        }
        if(m.kind<0.5 && height>0.08) {
            float cover=smoothstep(0.32,0.67,fbm3(m.p*1.5,3))*smoothstep(0.04,0.25,height);
            float3 moss=riverMap(colors,4,m.p*0.65,m.n,lod).rgb;
            m.base=mix(m.base,moss,cover*0.90);
            m.roughness=mix(m.roughness,0.91,cover);
        }
        if(m.kind>0.5) {
            float moss=smoothstep(0.44,0.68,fbm3(m.p*2.2+m.seed*7,3))*smoothstep(0.15,0.8,m.n.y);
            moss*=smoothstep(-0.04,0.20,height);
            m.base=mix(m.base,riverMap(colors,4,m.p*0.8,m.n,lod).rgb,moss*0.82);
            m.roughness=mix(m.roughness,0.89,moss);
        }
        m.base*=mix(0.82,0.48,wet);
    } else {
        float grain=noise3(m.p*30);
        m.base*=0.65+0.35*grain;m.roughness=0.65;
        if(m.kind<3.5) m.base*=float3(0.78,0.90,0.65);
    }
    return m;
}
float3 riverHemisphere(float3 n,thread uint& rng) {
    float phi=random01(rng)*PI*2,r=sqrt(random01(rng));
    float3 axis=abs(n.y)<0.9?float3(0,1,0):float3(1,0,0);
    float3 tangent=normalize(cross(n,axis));
    return normalize(tangent*cos(phi)*r+cross(n,tangent)*sin(phi)*r+n*sqrt(1-r*r));
}
float riverActivation(float2 p,texture2d<float> surface,texture2d<float> flow) {
    float4 state=surface.sample(linearClamp,riverUV(p)),f=flow.sample(linearClamp,riverUV(p));
    float alive=state.z*0.65+state.w*0.22+f.w*0.42;
    return alive*riverWet(p);
}
float3 riverWaterEmission(float2 p,constant Uniforms& u,texture2d<float> surface,texture2d<float> flow) {
    float activity=riverActivation(p,surface,flow);
    return riverGlowColor(u)*activity*0.8*u.parameters.x;
}
float3 riverShade(RiverMaterial m,float3 rd,constant Uniforms& u,primitive_acceleration_structure scene,
                  device const RiverMeshVertex* vertices,device const uint* indices,
                  texture2d<float> surface,texture2d<float> flow,thread uint& rng,bool detailed,texture2d_array<float> colors,texture2d_array<float> details,texture2d_array<float> properties) {
    float3 moon=riverMoon(),view=-rd;
    float nl=max(dot(m.n,moon),0.0),nv=max(dot(m.n,view),0.001);
    float shadow=riverVisibility(m.p+m.n*0.012,moon,70,scene);
    float3 light=float3(0.62,0.69,0.78)*(0.14+u.controls.z*0.72);
    float3 ambient=float3(0.075,0.095,0.12)*(0.35+0.65*saturate(m.n.y*0.5+0.5));
    float ao=1;
    if(detailed && u.options.w>0) {
        float3 probe=riverHemisphere(m.n,rng);RiverHit bounce=riverIntersect(m.p+m.n*0.012,probe,3.0,scene);
        ao=bounce.hit?0.25+0.5*saturate(bounce.t/3):1;
        if(bounce.hit) {
            RiverMaterial other=riverMaterial(bounce,m.p+m.n*0.012,probe,vertices,indices,colors,details,properties);
            ambient+=other.base*0.12*max(dot(other.n,moon),0.0);
        }
    }
    float3 c=m.base*(ambient*ao+light*nl*shadow);
    if(m.kind>2.5&&m.kind<3.5)c+=m.base*light*pow(max(dot(-m.n,moon),0.0),2.0)*shadow*0.20;
    float3 halfVector=normalize(moon+view);float nh=max(dot(m.n,halfVector),0.0);
    float alpha=max(0.035,m.roughness*m.roughness),a2=alpha*alpha;
    float denom=nh*nh*(a2-1)+1;
    float distribution=a2/(PI*denom*denom+0.00001);
    float k=(m.roughness+1)*(m.roughness+1)*0.125;
    float geometry=nl/(nl*(1-k)+k)*nv/(nv*(1-k)+k);
    float fresnel=0.025+0.975*pow(1-max(dot(view,halfVector),0.0),5.0);
    c+=light*shadow*distribution*geometry*fresnel/max(4*nv,0.05);
    // Sample actual emissive river locations; visibility prevents glow leaking
    // through logs or the ground. Each sample represents a patch of water.
    if(m.p.y>-0.15 && m.p.y<5 && detailed) {
        float z=m.p.z+(random01(rng)-0.5)*5;
        float3 source=float3(riverCenter(z)+(random01(rng)-0.5)*riverWidth(z)*1.5,riverLevel(z)+0.04,z);
        float3 delta=source-m.p;float distance=length(delta),cosine=max(dot(m.n,delta/max(distance,0.01)),0.0);
        float visible=cosine>0?riverVisibility(m.p+m.n*0.01,delta/max(distance,0.01),max(0.02,distance-0.05),scene):0;
        c+=m.base*riverWaterEmission(source.xz,u,surface,flow)*visible*cosine*12/(0.45+distance*distance);
    }
    return c;
}
float4 riverFog(float3 ro,float3 rd,float distance,constant Uniforms& u,primitive_acceleration_structure scene,thread uint& rng) {
    int steps=u.options.w==0?6:u.options.w==3?20:12;
    float length=min(distance,65.0),step=length/float(steps),transmittance=1;
    float3 scatter=0,moon=riverMoon();float phase=0.08+0.28*pow(max(dot(rd,moon),0.0),10.0);
    float offset=random01(rng);
    for(int i=0;i<steps;++i) {
        float t=(float(i)+offset)*step;float3 p=ro+rd*t;
        float density=exp(-max(p.y,0.0)*1.1)*0.018+0.0012;
        float wisp=noise3(float3(p.x*0.40+u.viewport.z*0.025,p.y*0.8,p.z*0.35));
        density*=smoothstep(0.2,0.78,wisp)*1.8;
        float extinction=exp(-density*step);
        float visibility=1;
        if(u.options.w>=2 && i%3==0)visibility=riverVisibility(p,moon,40,scene);
        float3 light=float3(0.045,0.08,0.12)+float3(0.22,0.30,0.42)*phase*visibility*(0.3+u.controls.z);
        scatter+=transmittance*(1-extinction)*light;transmittance*=extinction;
    }
    return float4(scatter,transmittance);
}

kernel void riverTrace(texture2d<float,access::write> color [[texture(0)]],
                       texture2d<float,access::write> depth [[texture(1)]],
                       texture2d<float,access::write> motion [[texture(2)]],
                       texture2d<float,access::write> diffuse [[texture(3)]],
                       texture2d<float,access::write> specular [[texture(4)]],
                       texture2d<float,access::write> normals [[texture(5)]],
                       texture2d<float,access::write> roughness [[texture(6)]],
                       texture2d<float,access::write> hitDistance [[texture(7)]],
                       texture2d<float,access::write> reactive [[texture(8)]],
                       texture2d<float,access::write> distanceOutput [[texture(9)]],
                       texture2d<float> surface [[texture(10)]],texture2d<float> flow [[texture(11)]],
                       texture2d_array<float> colors [[texture(12)]],texture2d_array<float> details [[texture(13)]],texture2d_array<float> properties [[texture(14)]],
                       constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],
                       constant RiverFrame& frame [[buffer(2)]],
                       primitive_acceleration_structure scene [[buffer(3)]],
                       device const RiverMeshVertex* vertices [[buffer(4)]],device const uint* indices [[buffer(5)]],
                       uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(color.get_width(),color.get_height())))return;
    float2 uv=(float2(id)+0.5+frame.jitter.xy)/u.viewport.xy,xy=screenPoint(uv,u);
    float3 ro,f,right,up;riverBasis(s,ro,f,right,up);float3 rd=normalize(f*1.85+right*xy.x+up*xy.y);
    uint rng=id.x*1973+id.y*9277+frame.counts.y*26699+37;
    RiverHit hit=riverIntersect(ro,rd,110,scene);
    float t=hit.t;float3 p=ro+rd*t,n=-rd,base=0,spec=0;
    float materialRoughness=1,secondaryDistance=0,reactivity=0;
    float3 c=riverSky(rd,u);
    bool water=false;
    if(rd.y<-0.005) {
        float tw=-ro.y/rd.y;float3 wp=ro+rd*tw;
        for(int j=0;j<6;++j){
            float h=riverSurfaceHeight(wp.xz,u.viewport.z,u,surface);
            float slope=(riverLevel(wp.z+0.03)-riverLevel(wp.z-0.03))/0.06;
            float derivative=rd.y-slope*rd.z;
            if(abs(derivative)>0.002)tw-=clamp((wp.y-h)/derivative,-4.0,4.0);
            wp=ro+rd*tw;
        }
        water=tw>0.04&&tw<t&&tw<95&&riverGround(wp.xz)<wp.y-0.008&&riverBank(wp.xz)<0;
        if(water){p=wp;t=tw;}
    }
    if(water) {
        float e=0.018;
        float dx=riverSurfaceHeight(p.xz+float2(e,0),u.viewport.z,u,surface)-riverSurfaceHeight(p.xz-float2(e,0),u.viewport.z,u,surface);
        float dz=riverSurfaceHeight(p.xz+float2(0,e),u.viewport.z,u,surface)-riverSurfaceHeight(p.xz-float2(0,e),u.viewport.z,u,surface);
        n=normalize(float3(-dx,2*e,-dz));
        float3 reflected=reflect(rd,n);RiverHit reflection=riverIntersect(p+n*0.008,reflected,90,scene);
        float3 reflectedColor=reflection.hit?riverShade(riverMaterial(reflection,p+n*0.008,reflected,vertices,indices,colors,details,properties),reflected,u,scene,vertices,indices,surface,flow,rng,false,colors,details,properties):riverSky(reflected,u);
        secondaryDistance=reflection.t;
        float3 refracted=refract(rd,n,1/1.333);RiverHit bed=riverIntersect(p-n*0.008,refracted,12,scene);
        float3 transmission=float3(0.005,0.023,0.026);
        if(bed.hit) {
            RiverMaterial bm=riverMaterial(bed,p-n*0.008,refracted,vertices,indices,colors,details,properties);
            float3 attenuation=exp(-float3(0.48,0.17,0.105)*bed.t);
            transmission=riverShade(bm,refracted,u,scene,vertices,indices,surface,flow,rng,false,colors,details,properties)*attenuation;
            transmission+=float3(0.003,0.014,0.022)*(1-attenuation);
            // A small focused-light variation; deliberately subordinate to the actual bed.
            float caustic=saturate(0.55+dot(n.xz,float2(5,-3)));
            transmission*=0.86+caustic*0.25;
        }
        float fresnel=0.0204+0.9796*pow(1-max(dot(n,-rd),0.0),5.0);
        c=mix(transmission,reflectedColor,fresnel);
        float4 state=surface.sample(linearClamp,riverUV(p.xz)),disturbance=flow.sample(linearClamp,riverUV(p.xz));
        float activation=riverActivation(p.xz,surface,flow);
        // Luminescence follows advected excitation. There is no global glowing
        // grid or shoreline outline; sparse organisms provide the fine detail.
        float veil=0.65+0.35*noise3(float3(p.xz*float2(17,11)-disturbance.xy*u.viewport.z,5.1));
        float glow=activation*veil*u.parameters.x;
        c+=riverGlowColor(u)*glow*0.85*(1-fresnel*0.75);
        float grain=noise3(float3(p.xz*38-float2(0,u.viewport.z*25),3.8));
        float foam=saturate(state.w*1.7)*smoothstep(0.47,0.67,grain);
        c=mix(c,float3(0.24,0.28,0.29)*(0.25+u.controls.z*0.45),foam);
        float moonReflection=pow(max(dot(reflected,riverMoon()),0.0),1200.0);
        c+=float3(0.40,0.60,0.95)*moonReflection*u.controls.z;
        base=float3(0.008,0.021,0.025);spec=float3(fresnel);materialRoughness=0.025+foam*0.35;
        reactivity=0.35+min(0.55,glow+foam);
    } else if(hit.hit) {
        RiverMaterial m=riverMaterial(hit,ro,rd,vertices,indices,colors,details,properties);
        n=m.n;base=m.base;materialRoughness=m.roughness;spec=float3(0.025);
        c=riverShade(m,rd,u,scene,vertices,indices,surface,flow,rng,true,colors,details,properties);
    }
    float4 clip=frame.viewProjection*float4(p,1),previous=frame.previousViewProjection*float4(p,1);
    float2 currentUV=clip.xy/max(clip.w,0.001)*float2(0.5,-0.5)+0.5;
    float2 previousUV=previous.xy/max(previous.w,0.001)*float2(0.5,-0.5)+0.5;
    if(water && frame.counts.z==0 && frame.counts.w==0) {
        float elapsed=clamp(u.viewport.z-frame.jitter.z,0.0,0.0667);
        float2 advection=riverCurrent(p.xz,u.controls.x)+flow.sample(linearClamp,riverUV(p.xz)).xy;
        float3 oldPosition=p-float3(advection.x,0,advection.y)*elapsed;
        float4 oldClip=frame.previousViewProjection*float4(oldPosition,1);
        previousUV=oldClip.xy/max(oldClip.w,0.001)*float2(0.5,-0.5)+0.5;
    }
    float2 velocity=frame.counts.z>0?float2(0):(previousUV-currentUV)*u.viewport.xy;
    float z=hit.hit||water?saturate(clip.z/max(clip.w,0.001)):1;
    color.write(float4(clamp(c,float3(0),float3(40)),1),id);
    depth.write(float4(z),id);motion.write(float4(velocity,0,0),id);
    diffuse.write(float4(base,1),id);specular.write(float4(spec,1),id);
    normals.write(float4(n,0),id);roughness.write(float4(materialRoughness),id);
    hitDistance.write(float4(secondaryDistance),id);reactive.write(float4(reactivity),id);distanceOutput.write(float4(t),id);
}

// Each organism is a persistent particle advected by the simulated flow. A
// small second population becomes spray where the water is disturbed.
struct RiverOrganism { float4 position; float4 state; };
kernel void riverOrganismInitialize(device RiverOrganism* organisms [[buffer(2)]],constant Uniforms& u [[buffer(0)]],
                                     constant StageUniforms& s [[buffer(1)]],constant RiverFrame& frame [[buffer(3)]],uint id [[thread_position_in_grid]]) {
    if(id>=frame.counts.x)return;
    uint rng=id*1973+17;float z=-35+random01(rng)*52;
    float x=riverCenter(z)+(random01(rng)*2-1)*riverWidth(z)*0.93;
    organisms[id].position=float4(x,riverLevel(z)-0.025-random01(rng)*0.16,z,random01(rng));
    organisms[id].state=float4(0,random01(rng),0,0);
    if(id%1021==0) {
        x=riverCenter(z)+(random01(rng)>0.5?1:-1)*(riverWidth(z)+random01(rng)*1.5);
        organisms[id].position=float4(x,riverGround(float2(x,z))+0.4+random01(rng)*1.1,z,random01(rng));
        organisms[id].state.w=2;
    }
}
kernel void riverOrganismStep(device RiverOrganism* organisms [[buffer(2)]],constant Uniforms& u [[buffer(0)]],
                               constant StageUniforms& s [[buffer(1)]],constant RiverFrame& frame [[buffer(3)]],
                               texture2d<float> surface [[texture(0)]],texture2d<float> flow [[texture(1)]],uint id [[thread_position_in_grid]]) {
    if(id>=frame.counts.x)return;
    RiverOrganism a=organisms[id];
    if(a.state.w>1.5) {
        float t=s.simulation.x+float(id);
        a.position.xyz+=float3(sin(t*0.7),cos(t*0.8)*0.35,cos(t*0.5))*s.simulation.y*0.10;
        organisms[id]=a;return;
    }
    float2 p=a.position.xz;float4 d=flow.sample(linearClamp,riverUV(p));
    float2 velocity=riverCurrent(p,u.controls.x)+d.xy;float dt=s.simulation.y;
    p+=velocity*dt;
    if(p.y>17)p.y=-35;
    // Re-seed particles stranded in dry shallows instead of accumulating them
    // into the visible bright boundary line of the earlier renderer.
    if(riverWet(p)<0.35){
        uint rng=id*1973+uint(s.simulation.x*120)*9277+71;
        p.x=riverCenter(p.y)+(random01(rng)*2-1)*riverWidth(p.y)*0.72;
        a.state.x*=0.1;
    }
    float4 water=surface.sample(linearClamp,riverUV(p));
    float activation=saturate(d.w*0.6+water.z*0.7+water.w*0.25);
    a.state.x=mix(a.state.x,activation,dt*(activation>a.state.x?8:0.7));
    if(id%19==0 && activation>0.18 && (water.w>0.06 || abs(water.y)>0.14) && a.position.y<=riverLevel(p.y)+0.012) {
        a.position.y=riverLevel(p.y)+0.015;a.state.z=0.3+activation*1.4;a.state.w=1;
    }
    if(a.state.w>0.5){a.state.z-=dt*3.5;a.position.y+=a.state.z*dt;if(a.position.y<riverLevel(p.y)){a.state.w=0;a.position.y=riverLevel(p.y)-0.04;}}
    else a.position.y=riverLevel(p.y)+water.x-0.015-a.state.y*0.12;
    a.position.x=p.x;a.position.z=p.y;organisms[id]=a;
}
struct RiverOrganismVertex { float4 position [[position]];float2 uv;float3 radiance;float distance; };
vertex RiverOrganismVertex riverOrganismVertex(uint vertexID [[vertex_id]],uint id [[instance_id]],
                                               device const RiverOrganism* organisms [[buffer(2)]],constant Uniforms& u [[buffer(0)]],
                                               constant StageUniforms& s [[buffer(1)]],constant RiverFrame& frame [[buffer(3)]]) {
    RiverOrganism a=organisms[id];float3 ro,f,right,up;riverBasis(s,ro,f,right,up);
    float2 q=quadCorner(vertexID)*2-1;float size=a.state.w>1.5?0.025:0.003+a.position.w*0.005+a.state.w*0.007;
    float3 p=a.position.xyz+(right*q.x+up*q.y)*size;
    float4 clip=frame.viewProjection*float4(p,1);
    float light=(0.0002+pow(a.state.x,0.85)*1.8)*(0.55+0.45*sin(a.position.w*61+u.viewport.z*1.2));
    float3 emission=riverGlowColor(u)*light*u.parameters.x;
    emission=mix(emission,emission+float3(0.15,0.23,0.28),min(a.state.w,1.0));
    if(a.state.w>1.5)emission=float3(0.5,0.85,0.18)*pow(0.5+0.5*sin(u.viewport.z*1.6+a.position.w*64),5.0);
    return {clip,q,emission,length(p-ro)};
}
fragment float4 riverOrganismFragment(RiverOrganismVertex in [[stage_in]],texture2d<float> distance [[texture(0)]],
                                       constant Uniforms& u [[buffer(0)]]) {
    float rr=dot(in.uv,in.uv);if(rr>1)discard_fragment();
    float2 uv=in.position.xy/u.viewport.xy;
    // Underwater particles remain visible through the water; opaque foreground
    // geometry occludes them. A small tolerance covers the upper water layer.
    float sceneDistance=distance.sample(linearClamp,uv).r;
    if(in.distance>sceneDistance+0.22)discard_fragment();
    return float4(in.radiance*exp(-rr*5)*exp(-in.distance*0.014),0);
}
kernel void riverCopyHDR(texture2d<float> source [[texture(0)]],texture2d<float,access::write> output [[texture(1)]],
                         texture2d<float> distance [[texture(2)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(output.get_width(),output.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(output.get_width(),output.get_height());
    output.write(float4(source.sample(linearClamp,uv).rgb,distance.sample(linearClamp,uv).r),id);
}

// Low-frequency participating media is integrated at quarter resolution. The
// composition rejects samples across geometry depth discontinuities.
kernel void riverFogPass(texture2d<float,access::write> fog [[texture(0)]],texture2d<float> distance [[texture(1)]],
                          constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],
                          constant RiverFrame& frame [[buffer(2)]],primitive_acceleration_structure scene [[buffer(3)]],
                          uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(fog.get_width(),fog.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(fog.get_width(),fog.get_height()),xy=screenPoint(uv,u);
    float3 ro,f,right,up;riverBasis(s,ro,f,right,up);float3 rd=normalize(f*1.85+right*xy.x+up*xy.y);
    uint rng=id.x*1973+id.y*9277+frame.counts.y*26699+113;
    fog.write(riverFog(ro,rd,distance.sample(linearClamp,uv).r,u,scene,rng),id);
}
kernel void riverFogComposite(texture2d<float,access::read_write> color [[texture(0)]],texture2d<float> fog [[texture(1)]],
                               texture2d<float> distance [[texture(2)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(color.get_width(),color.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(color.get_width(),color.get_height());
    float2 size=float2(fog.get_width(),fog.get_height());float center=distance.sample(linearClamp,uv).r;
    float4 sum=0;float weight=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x){
        float2 q=(floor(uv*size)+float2(x,y)+0.5)/size;
        float d=distance.sample(linearClamp,q).r;
        float w=exp(-abs(d-center)*0.6)*exp(-dot((q-uv)*size,(q-uv)*size)*0.7);
        sum+=fog.sample(linearClamp,q)*w;weight+=w;
    }
    float4 value=weight>0.0001?sum/weight:fog.sample(linearClamp,uv);
    float4 source=color.read(id);color.write(float4(source.rgb*value.a+value.rgb,source.a),id);
}
