// Depth-aware river surface and advected disturbances, entirely on the GPU.
float riverCenter(float z) { return 1.65*sin(z*0.17)+0.65*sin(z*0.41); }
float riverSlope(float z) { return 0.2805*cos(z*0.17)+0.2665*cos(z*0.41); }
float riverWidth(float z) { return 2.08+0.31*sin(z*0.37+1.3)+0.19*sin(z*0.83)+0.10*sin(z*1.71+0.7); }
float riverLevel(float z) { return -0.007*(z+4)+0.10*(1-smoothstep(-13.0,-10.0,z))+0.09*(1-smoothstep(-3.0,-1.0,z)); }
float riverBank(float2 p) { return abs(p.x-riverCenter(p.y))-riverWidth(p.y); }
float2 riverUV(float2 p) { return (p-float2(-12,-36))/float2(24,56); }
float2 riverWorld(float2 uv) { return uv*float2(24,56)+float2(-12,-36); }
// Keep this definition identical to RiverWorld.groundHeight: mesh, collision,
// camera clearance, optical depth, and solver boundaries share one riverbed.
float riverGround(float2 p) {
    float x=p.x,z=p.y,lateral=x-riverCenter(z),bank=riverBank(p);
    float pool=0.28+0.24*pow(0.5+0.5*sin(z*0.43+0.6),2.0);
    float bar=0.17*exp(-pow((lateral-0.9*sin(z*0.31))*1.35,2.0))*pow(0.5+0.5*sin(z*0.77),4.0);
    float shingle=0.022*sin(x*13+z*4)*sin(z*10-x*3)+0.035*sin(x*4.3+z*1.3)*sin(z*3.7);
    float bed=-pool+bar+shingle,shore=0.10+0.065*sin(z*1.7+x*2.9)+0.035*sin(z*4.1-x*1.3);
    float blend=smoothstep(-0.48,0.20,bank);
    float hummocks=smoothstep(0.0,2.0,bank)*(0.22*sin(x*1.2+z*0.44)*sin(z*0.81)+0.12*sin(x*2.3-z*0.9));
    return riverLevel(z)+mix(bed,shore,blend)+max(bank-0.25,0.0)*0.16
        +smoothstep(1.0,8.0,bank)*(0.45+0.25*sin(z*0.29+x*0.41))+hummocks;
}
float riverWet(float2 p) { return smoothstep(0.008,0.055,riverLevel(p.y)-riverGround(p))*(1-smoothstep(-0.12,0.04,riverBank(p))); }
float4 riverRock(uint i) {
    if(i==0)return float4(riverCenter(-3)+0.7,0.12,-3,0.72);
    if(i==1)return float4(riverCenter(5)-0.8,0.05,5,0.56);
    if(i==2)return float4(riverCenter(-11)-0.6,0.05,-11,0.52);
    if(i==3)return float4(riverCenter(-19)+0.7,0.05,-19,0.66);
    float z=-26+hash11(float(i)*7.3+1)*40;
    float x=riverCenter(z)+(i%2==0?-1:1)*(riverWidth(z)-0.15+hash11(float(i)+9)*0.65);
    return float4(x,0.12,z,0.45+hash11(float(i)+31)*0.65);
}
float2 riverCurrent(float2 p,float speed) {
    float2 base=normalize(float2(riverSlope(p.y),1))*(0.4+speed*1.25);
    base*=clamp(0.42/max(riverLevel(p.y)-riverGround(p),0.18),0.72,1.7);
    float2 current=base;
    for(uint i=0;i<4;++i) {
        float4 rock=riverRock(i);float2 d=p-rock.xz;float d2=max(dot(d,d),0.04);
        float influence=min(0.95,rock.w*rock.w/d2);
        float2 n=d*rsqrt(d2);
        current+=influence*(base-2*n*dot(base,n));
    }
    float2 logStart=float2(-3.9,-6.2),logSegment=float2(4.4,-3.6);
    float along=saturate(dot(p-logStart,logSegment)/dot(logSegment,logSegment));
    float2 logOffset=p-logStart-logSegment*along;
    float logDistance=max(dot(logOffset,logOffset),0.025);
    float2 logNormal=logOffset*rsqrt(logDistance);
    current+=min(0.75,0.09/logDistance)*(base-2*logNormal*dot(base,logNormal));
    current*=0.25+0.75*smoothstep(0.0,0.65,-riverBank(p));
    return clamp(current,float2(-4),float2(4))*riverWet(p);
}
void riverBasis(constant StageUniforms& s,thread float3& ro,thread float3& f,thread float3& right,thread float3& up) {
    float3 target=float3(-0.2,0.05,-8),offset=float3(1.1,1.8,11.8)*exp(s.camera.z);
    ro=target+rotateY(rotateX(offset,s.camera.y*0.65),s.camera.x);
    ro.y=max(ro.y,max(riverLevel(ro.z)+0.60,riverGround(ro.xz)+0.38));
    f=normalize(target-ro);right=normalize(cross(f,float3(0,1,0)));up=cross(right,f);
}
float2 riverBrush(constant Uniforms& u,constant StageUniforms& s) {
    float3 ro,f,r,up;riverBasis(s,ro,f,r,up);float2 xy=screenPoint(u.pointer.xy,u);
    float3 rd=normalize(f*1.85+r*xy.x+up*xy.y);
    if(rd.y>-0.012)return float2(1000);
    float t=-ro.y/rd.y;if(t>80)return float2(1000);
    for(int i=0;i<4;++i)t=(riverLevel((ro+rd*t).z)-ro.y)/rd.y;
    return (ro+rd*t).xz;
}
kernel void riverInitialize(texture2d<float,access::write> state [[texture(0)]],texture2d<float,access::write> flow [[texture(1)]],
                            texture2d<float,access::write> bed [[texture(2)]],
                            constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(state.get_width(),state.get_height())))return;
    float2 p=riverWorld((float2(id)+0.5)/s.simulation.zw);float wet=riverWet(p);
    for(uint i=0;i<4;++i){float4 r=riverRock(i);wet*=smoothstep(r.w*0.78,r.w*1.04,length(p-r.xz));}
    bed.write(float4(max(0.02,riverLevel(p.y)-riverGround(p)),wet,riverCurrent(p,1.0)),id);
    state.write(float4(0),id);flow.write(float4(0),id);
}
// Semi-Lagrangian velocity plus a free-surface pressure gradient. Two 120 Hz
// substeps per simulation tick satisfy the shallow-water wave CFL at every grid.
// The prescribed steady current is depth/obstacle dependent; perturbations and
// surface elevation exchange momentum, with no-flux wet/dry boundaries.
kernel void riverFlowStep(texture2d<float> previous [[texture(0)]],texture2d<float,access::write> next [[texture(1)]],
                          texture2d<float> surface [[texture(2)]],texture2d<float> bed [[texture(3)]],
                          constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(next.get_width(),next.get_height())))return;
    float2 uv=(float2(id)+0.5)/s.simulation.zw,p=riverWorld(uv),duv=1/s.simulation.zw,cell=float2(24,56)*duv;
    float4 geometry=bed.sample(linearClamp,uv),prior=previous.sample(linearClamp,uv);float wet=geometry.y,dt=s.simulation.y;
    float2 velocity=geometry.zw*((0.4+u.controls.x*1.25)/1.65)+prior.xy;
    float4 advected=previous.sample(linearClamp,uv-velocity*dt/float2(24,56));
    float2 perturb=advected.xy*exp(-dt*0.70);
    float center=surface.sample(linearClamp,uv).x;
    float2 dx=float2(duv.x,0),dz=float2(0,duv.y);
    float hl=mix(center,surface.sample(linearClamp,uv-dx).x,bed.sample(linearClamp,uv-dx).y);
    float hr=mix(center,surface.sample(linearClamp,uv+dx).x,bed.sample(linearClamp,uv+dx).y);
    float hb=mix(center,surface.sample(linearClamp,uv-dz).x,bed.sample(linearClamp,uv-dz).y);
    float ht=mix(center,surface.sample(linearClamp,uv+dz).x,bed.sample(linearClamp,uv+dz).y);
    perturb-=9.81*float2(hr-hl,ht-hb)/(2*cell)*dt;
    float turbulence=0;
    for(uint i=0;i<4;++i){
        float4 r=riverRock(i);float2 d=p-r.xz;
        float wake=exp(-d.x*d.x/(r.w*r.w))*smoothstep(0.15,0.7,d.y)*exp(-max(d.y,0.0)*0.95);
        float phase=s.simulation.x*(2.8+u.controls.x)-d.y*4;
        perturb+=float2(sin(phase),cos(phase)*0.30)*wake*dt*0.28*u.controls.x;
        turbulence+=wake*0.09*u.controls.x;
    }
    float wake=advected.w*exp(-dt*0.72);
    if(u.pointer.z>0.5) {
        float2 d=p-riverBrush(u,s);float falloff=exp(-dot(d,d)*4);
        float3 ro,f,right,up;riverBasis(s,ro,f,right,up);
        float2 motion=right.xz*u.interaction.x*70-up.xz*u.interaction.y*110;
        perturb+=(clamp(motion,float2(-1),float2(1))+float2(-d.y,d.x)*dt*1.3)*falloff;
        wake=min(1.5,wake+falloff*dt*4.0);
    }
    float2 gradient=float2(bed.sample(linearClamp,uv+dx).y-bed.sample(linearClamp,uv-dx).y,
                           bed.sample(linearClamp,uv+dz).y-bed.sample(linearClamp,uv-dz).y);
    if(dot(gradient,gradient)>0.0001){float2 inward=normalize(gradient);perturb-=inward*min(0.0,dot(perturb,inward));}
    next.write(float4(clamp(perturb,float2(-2),float2(2))*wet,turbulence*wet,wake*wet),id);
}
float riverFlux(float2 uv,float2 offset,uint axis,texture2d<float> flow,texture2d<float> bed) {
    float4 a=bed.sample(linearClamp,uv),b=bed.sample(linearClamp,uv+offset);
    float v=(flow.sample(linearClamp,uv)[axis]+flow.sample(linearClamp,uv+offset)[axis])*0.5;
    return v*min(a.x,b.x)*min(a.y,b.y);
}
kernel void riverSurfaceStep(texture2d<float> previous [[texture(0)]],texture2d<float,access::write> next [[texture(1)]],texture2d<float> flow [[texture(2)]],
                             texture2d<float> bed [[texture(3)]],
                             constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(next.get_width(),next.get_height())))return;
    float2 uv=(float2(id)+0.5)/s.simulation.zw,p=riverWorld(uv),duv=1/s.simulation.zw,cell=float2(24,56)*duv;
    float4 geometry=bed.sample(linearClamp,uv),disturbance=flow.sample(linearClamp,uv);
    float2 velocity=geometry.zw*((0.4+u.controls.x*1.25)/1.65)+disturbance.xy;
    float4 old=previous.sample(linearClamp,uv-velocity*s.simulation.y/float2(24,56));
    float2 dx=float2(duv.x,0),dz=float2(0,duv.y);
    float divergence=(riverFlux(uv,dx,0,flow,bed)-riverFlux(uv,-dx,0,flow,bed))/cell.x
                    +(riverFlux(uv,dz,1,flow,bed)-riverFlux(uv,-dz,1,flow,bed))/cell.y;
    float dt=s.simulation.y,height=old.x*exp(-dt*0.12)-divergence*dt,excitation=0;
    if(u.pointer.z>0.5){
        float2 d=p-riverBrush(u,s);float falloff=exp(-dot(d,d)*6);
        height+=falloff*(s.object.w*0.025+length(u.interaction.xy)*0.035)*u.controls.y;
        excitation=falloff*3.4;
    }
    float wet=geometry.y,wave=clamp((height-old.x)/dt,-0.6,0.6);
    float shear=length(flow.sample(linearClamp,uv+dx).xy-flow.sample(linearClamp,uv-dx).xy)
               +length(flow.sample(linearClamp,uv+dz).xy-flow.sample(linearClamp,uv-dz).xy);
    float shallows=1-smoothstep(0.12,0.32,geometry.x);
    float breaking=disturbance.z+shear*0.12+max(0.0,-divergence)*0.12;
    float glow=old.z*exp(-dt*0.95)+dt*(breaking*0.55+excitation);
    float foam=old.w*exp(-dt*1.35)+dt*(breaking*0.32+shallows*length(velocity)*0.012);
    if(uv.y<0.008){height=0;wave=0;glow=0;foam=0;}
    next.write(float4(clamp(height,-0.15,0.15)*wet,wave*wet,clamp(glow,0.0,2.0)*wet,clamp(foam,0.0,1.0)*wet),id);
}

float3 riverGlowColor(constant Uniforms& u) {
    return u.parameters.w<0.5?float3(0.012,0.62,1.0):u.parameters.w<1.5?float3(0.02,1.0,0.40):float3(0.28,0.10,1.0);
}
float riverSurfaceHeight(float2 p,float time,constant Uniforms& u,texture2d<float> surface) {
    float4 state=surface.sample(linearClamp,riverUV(p));
    float depth=max(0.02,riverLevel(p.y)-riverGround(p));
    float2 q=float2(p.x-riverCenter(p.y),p.y-time*(0.4+u.controls.x*1.25));
    float ripple=(noise3(float3(q*float2(4,7),1.1))-0.5)*0.014
                +(noise3(float3(q*float2(13,21),2.7))-0.5)*0.002;
    float riffle=1-smoothstep(0.15,0.44,depth);
    float standing=sin(p.y*19+sin(p.x*8)*0.7-time*6)*0.008*riffle;
    return riverLevel(p.y)+state.x+(ripple*(0.35+riffle)+standing)*u.controls.y;
}

// Quarter-resolution, separable bloom; all work remains on the active GPU.
kernel void riverBloomExtract(texture2d<float> image [[texture(0)]],texture2d<float,access::write> bloom [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(bloom.get_width(),bloom.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(bloom.get_width(),bloom.get_height());float2 texel=1/float2(image.get_width(),image.get_height());
    float3 c=0;
    for(int y=-1;y<=1;++y)for(int x=-1;x<=1;++x)c+=max(image.sample(linearClamp,uv+float2(x,y)*texel).xyz-0.35,0.0);
    bloom.write(float4(c/9,1),id);
}
kernel void riverBloomHorizontal(texture2d<float> previous [[texture(0)]],texture2d<float,access::write> next [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(next.get_width(),next.get_height())))return;
    float2 size=float2(next.get_width(),next.get_height()),uv=(float2(id)+0.5)/size;float3 c=0;float weights=0;
    for(int x=-5;x<=5;++x){float w=exp(-float(x*x)/12);c+=previous.sample(linearClamp,uv+float2(float(x)/size.x,0)).xyz*w;weights+=w;}
    next.write(float4(c/weights,1),id);
}
kernel void riverBloomComposite(texture2d<float,access::read_write> image [[texture(0)]],texture2d<float> bloom [[texture(1)]],uint2 id [[thread_position_in_grid]]) {
    if(any(id>=uint2(image.get_width(),image.get_height())))return;
    float2 uv=(float2(id)+0.5)/float2(image.get_width(),image.get_height());float3 c=0;float weights=0;
    for(int y=-5;y<=5;++y){float w=exp(-float(y*y)/12);c+=bloom.sample(linearClamp,uv+float2(0,float(y)/float(bloom.get_height()))).xyz*w;weights+=w;}
    float4 original=image.read(id);image.write(float4(original.xyz+c/weights*0.28,original.w),id);
}
