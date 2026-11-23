// The cinematic collection: GPU light transport, position-based 3D liquid,
// Eulerian combustion, planetary volume integration, and a fractal distance field.
// All resources and compute passes use public Metal APIs.
struct StageUniforms {
    float4 camera;       // orbit yaw, pitch, logarithmic zoom, reserved
    float4 eye;          // free-flight translation
    float4 object;       // optical object translation
    float4 light;        // optical area light position
    float4 metal;        // movable metal sphere
    float4 state;        // accumulated samples, progressive flag, input modifiers, interacting
    float4 simulation;   // fixed-step clock, timestep, particle capacity, volume side
};
uint randomBits(thread uint& state) {
    state = state * 747796405u + 2891336453u;
    uint word = ((state >> ((state >> 28u) + 4u)) ^ state) * 277803737u;
    return (word >> 22u) ^ word;
}
float random01(thread uint& state) { return float(randomBits(state)) * (1.0 / 4294967296.0); }
float hash31(float3 p) {
    p = fract(p * 0.1031); p += dot(p, p.yzx + 33.33);
    return fract((p.x + p.y) * p.z);
}
float noise3(float3 p) {
    float3 i = floor(p), f = fract(p); f = f * f * (3 - 2 * f);
    return mix(mix(mix(hash31(i), hash31(i + float3(1,0,0)), f.x),
                   mix(hash31(i + float3(0,1,0)), hash31(i + float3(1,1,0)), f.x), f.y),
               mix(mix(hash31(i + float3(0,0,1)), hash31(i + float3(1,0,1)), f.x),
                   mix(hash31(i + float3(0,1,1)), hash31(i + 1), f.x), f.y), f.z);
}
float fbm3(float3 p, int octaves = 4) {
    float value = 0, amplitude = 0.5;
    for (int i = 0; i < octaves; ++i) { value += noise3(p) * amplitude; p = p * 2.03 + float3(11.7,3.1,7.3); amplitude *= 0.5; }
    return value;
}
float3 rotateY(float3 p, float a) { return float3(cos(a)*p.x+sin(a)*p.z,p.y,-sin(a)*p.x+cos(a)*p.z); }
float3 rotateX(float3 p, float a) { return float3(p.x,cos(a)*p.y-sin(a)*p.z,sin(a)*p.y+cos(a)*p.z); }
float2 intersectBox(float3 ro, float3 rd, float3 low, float3 high) {
    float3 inv = 1.0 / select(rd, float3(0.000001), abs(rd) < 0.000001);
    float3 a = (low - ro) * inv, b = (high - ro) * inv;
    return float2(max(max(min(a.x,b.x),min(a.y,b.y)),min(a.z,b.z)),
                  min(min(max(a.x,b.x),max(a.y,b.y)),max(a.z,b.z)));
}
float2 intersectSphere(float3 ro, float3 rd, float3 center, float radius) {
    float3 p = ro-center; float b = dot(p,rd), h = b*b-dot(p,p)+radius*radius;
    return h < 0 ? float2(-1) : float2(-b-sqrt(h),-b+sqrt(h));
}
void stageCamera(float2 uv, constant Uniforms& u, constant StageUniforms& s, thread float3& ro, thread float3& rd) {
    float3 target = float3(0,0.65,0), offset = float3(0,1.65,4.8);
    if (u.options.x == 13) { target.y = 0.85; offset = float3(2.7,1.7,4.0); }
    if (u.options.x == 14) { target.y = 1.0; offset = float3(2.4,0.95,4.0); }
    if (u.options.x == 15) {
        target = 0; offset = normalize(float3(0,0.15,1)) * (1.008 + 2.1 * exp(s.camera.z));
    } else { offset *= exp(s.camera.z); }
    offset = rotateY(rotateX(offset, s.camera.y), s.camera.x);
    ro = target + offset;
    rd = cameraRay(screenPoint(uv,u),ro,target,2.2);
    if (u.options.x == 15) {
        // On descent, tilt from the orbital view toward the horizon. Looking
        // straight down inside a cloud otherwise fills the frame with fog.
        float3 normal=normalize(ro), tangent=normalize(cross(float3(0,1,0),normal));
        float approach=1-smoothstep(1.12,1.8,length(ro));
        float3 forward=normalize(mix(-normal,normalize(tangent-normal*0.3),approach));
        float3 upHint=normalize(mix(float3(0,1,0),normal,approach));
        float3 right=normalize(cross(forward,upHint)),up=cross(right,forward);
        float2 screen=screenPoint(uv,u);
        rd=normalize(forward*2.2+right*screen.x+up*screen.y);
    }
    if (u.options.x == 16) {
        ro = float3(0,0.05,-4.1) + s.eye.xyz;
        rd = rotateY(rotateX(normalize(float3(screenPoint(uv,u),2.0)), -s.camera.y), -s.camera.x);
        ro.z += s.camera.z * -1.4;
    }
}
float3 stageEnvironment(float3 rd, float palette = 0) {
    float3 c = studio(rd,0,palette) * 0.7;
    c += float3(2.8,1.9,0.9) * pow(max(0.0,dot(rd,normalize(float3(-0.8,0.7,-0.2)))),128.0);
    return c;
}
float3 cosineDirection(float3 n, thread uint& rng) {
    float a = random01(rng)*2*PI, r = sqrt(random01(rng));
    float3 t = normalize(cross(n,abs(n.y) < 0.9 ? float3(0,1,0) : float3(1,0,0)));
    return normalize(t*(r*cos(a))+cross(n,t)*(r*sin(a))+n*sqrt(max(0.0,1-r*r)));
}
float3 pointerInTank(constant Uniforms& u, constant StageUniforms& s, float y) {
    float3 ro,rd; stageCamera(u.pointer.xy,u,s,ro,rd);
    float t = (y-ro.y) / (abs(rd.y) < 0.01 ? -0.01 : rd.y);
    float3 p = ro + rd * clamp(t,0.0,20.0);
    return float3(clamp(p.x,-0.78,0.78),y,clamp(p.z,-0.78,0.78));
}

kernel void stageResolve(texture2d<float,access::read> sample [[texture(0)]],
                         texture2d<float,access::read> history [[texture(1)]],
                         texture2d<float,access::write> next [[texture(2)]],
                         texture2d<float,access::write> output [[texture(3)]],
                         constant Uniforms& u [[buffer(0)]], constant StageUniforms& s [[buffer(1)]],
                         uint2 p [[thread_position_in_grid]]) {
    if (any(p >= uint2(output.get_width(),output.get_height()))) return;
    float4 fresh = sample.read(p);
    float3 color = fresh.xyz;
    if (!all(isfinite(color))) color = float3(0); // bounded display fallback; state tests detect solver failures
    float weight = s.state.y > 0.5 ? min(s.state.x,127.0) : 0;
    float3 accumulated = weight > 0 ? mix(history.read(p).xyz,color,1.0/(weight+1)) : color;
    next.write(float4(accumulated,fresh.w),p);
    // Depth-aware preview filtering, without an external model or a hidden CPU pass.
    if (u.options.x == 12 && weight < 8) {
        float3 filtered = 0; float total = 0;
        for (int y=-1;y<=1;++y) for (int x=-1;x<=1;++x) {
            uint2 q = neighbor(p,int2(x,y),output.get_width(),output.get_height());
            float4 v = sample.read(q);
            float w = exp(-abs(v.w-fresh.w)*40.0) * (x==0 && y==0 ? 2.0 : 1.0);
            filtered += v.xyz*w; total += w;
        }
        color = mix(filtered/max(total,0.001),accumulated,saturate(weight/8.0));
    } else color = accumulated;
    float2 uv = (float2(p)+0.5)/u.viewport.xy;
    float vignette = 1.0-0.16*dot(uv-0.5,uv-0.5);
    // Printed artwork is authored in display color; preserve its ink palette.
    output.write(float4((u.options.x == 20 || u.options.x == 21 || u.options.x == 23) ? saturate(color) : film(color*vignette),1),p);
}

// ---- Spectral light lab ----------------------------------------------------
struct OpticalHit { float distance; float3 normal; int material; };
void opticalPlane(float3 ro,float3 rd,float3 n,float d,thread float& enter,thread float& leave,
                  thread float3& en,thread float3& ex,thread bool& miss) {
    float denom = dot(rd,n), numer = d-dot(ro,n);
    if (abs(denom)<1e-6) { if (numer<0) miss=true; return; }
    float t=numer/denom;
    if (denom<0 && t>enter) { enter=t; en=n; }
    if (denom>0 && t<leave) { leave=t; ex=n; }
}
OpticalHit opticalPoly(float3 ro,float3 rd,int preset,float3 offset) {
    ro -= offset;
    float enter=-1e5,leave=1e5; float3 en=0,ex=0; bool miss=false;
    if (preset==0) {
        ro.x += 0.43;
        opticalPlane(ro,rd,float3(0,-1,0),-0.06,enter,leave,en,ex,miss);
        opticalPlane(ro,rd,normalize(float3(-0.88,0.47,0)),0.775,enter,leave,en,ex,miss);
        opticalPlane(ro,rd,normalize(float3(0.88,0.47,0)),0.602,enter,leave,en,ex,miss);
        opticalPlane(ro,rd,float3(0,0,1),0.55,enter,leave,en,ex,miss);
        opticalPlane(ro,rd,float3(0,0,-1),0.55,enter,leave,en,ex,miss);
    } else {
        ro -= float3(-0.4,0.72,0);
        ro = rotateY(ro,0.2); rd=rotateY(rd,0.2);
        opticalPlane(ro,rd,float3(0,1,0),0.34,enter,leave,en,ex,miss);
        opticalPlane(ro,rd,float3(0,-1,0),0.65,enter,leave,en,ex,miss);
        for(int i=0;i<8;++i) {
            float a=float(i)*PI/4;
            float3 n=normalize(float3(cos(a),0.65,sin(a)));
            opticalPlane(ro,rd,n,0.67/length(float3(cos(a),0.65,sin(a))),enter,leave,en,ex,miss);
            n=normalize(float3(cos(a+PI/8),-0.98,sin(a+PI/8)));
            opticalPlane(ro,rd,n,0.65/length(float3(cos(a),-0.98,sin(a))),enter,leave,en,ex,miss);
        }
        en=rotateY(en,-0.2); ex=rotateY(ex,-0.2);
    }
    if(miss || leave<max(enter,0.001)) return {1e5,float3(0),1};
    return enter>0.001 ? OpticalHit{enter,en,1} : OpticalHit{leave,ex,1};
}
void opticalSphere(float3 ro,float3 rd,float3 center,float radius,int mat,thread OpticalHit& hit) {
    float2 t=intersectSphere(ro,rd,center,radius);
    float d=t.x>0.001 ? t.x : t.y;
    if(d>0.001 && d<hit.distance) hit={d,normalize(ro+rd*d-center),mat};
}
OpticalHit opticalScene(float3 ro,float3 rd,constant Uniforms& u,constant StageUniforms& s) {
    int preset=int(u.parameters.w);
    OpticalHit h={1e5,float3(0),0};
    if(preset<2) h=opticalPoly(ro,rd,preset,s.object.xyz);
    else opticalSphere(ro,rd,float3(-0.48,0.72,0)+s.object.xyz,0.69,1,h);
    opticalSphere(ro,rd,float3(0.48,0.5,-0.55),0.48,1,h);
    opticalSphere(ro,rd,s.metal.xyz,0.39,2,h);
    if(rd.y < -1e-6) { float t=-ro.y/rd.y; if(t>0.001 && t<h.distance) h={t,float3(0,1,0),0}; }
    if(rd.z < -1e-6) { float t=(-2.6-ro.z)/rd.z; if(t>0.001 && t<h.distance) h={t,float3(0,0,1),3}; }
    return h;
}
float opticalIOR(float nm,constant Uniforms& u) {
    float wavelength=nm*0.001;
    float dispersion=0.006+0.020*u.controls.x;
    return (u.parameters.w>0.5 && u.parameters.w<1.5 ? 2.05 : 1.38) + dispersion/(wavelength*wavelength);
}
float opticalFresnel(float cosine,float eta) { float f=(1-eta)/(1+eta); return f*f+(1-f*f)*pow(1-cosine,5.0); }
float3 opticalAlbedo(float3 p,int mat) {
    if(mat==2) return float3(0.97,0.72,0.32);
    if(mat==3) return p.x<0 ? float3(0.025,0.07,0.12) : float3(0.16,0.055,0.02);
    float grout = smoothstep(0.015,0.025,min(abs(fract(p.x*0.7)-0.5),abs(fract(p.z*0.7)-0.5)));
    return mix(float3(0.055,0.065,0.08),float3(0.15,0.18,0.21),grout);
}
kernel void spectralPhotons(device atomic_uint* map [[buffer(2)]],constant Uniforms& u [[buffer(0)]],
                            constant StageUniforms& s [[buffer(1)]],uint id [[thread_position_in_grid]]) {
    if(id>=131072) return;
    uint rng=id*9781u+uint(s.state.x)*6271u+7817u;
    uint band=id%3; float nm=band==0?625:band==1?535:455;
    float3 ro=s.light.xyz;
    ro.xz += (float2(random01(rng),random01(rng))-0.5)*u.controls.y;
    float3 aim=float3((random01(rng)-0.5)*3.4,0.35,(random01(rng)-0.5)*2.8);
    float3 rd=normalize(aim-ro); float throughput=1; bool specular=false;
    for(int bounce=0;bounce<8;++bounce) {
        OpticalHit h=opticalScene(ro,rd,u,s);
        if(h.distance>100) break;
        float3 p=ro+rd*h.distance;
        if(h.material==0) {
            if(specular && abs(p.x)<3 && abs(p.z)<3) {
                uint2 cell=uint2(clamp((p.xz/6+0.5)*512,0.0,511.0));
                uint index=(cell.y*512+cell.x)*3+band;
                atomic_fetch_add_explicit(map+index,uint(min(throughput,2.0)*4096),memory_order_relaxed);
            }
            break;
        }
        if(h.material==3) break;
        specular=true;
        if(h.material==2) { rd=reflect(rd,h.normal); throughput*=opticalAlbedo(p,2)[band]; }
        else {
            bool enter=dot(rd,h.normal)<0; float3 n=enter?h.normal:-h.normal;
            float eta=enter?1/opticalIOR(nm,u):opticalIOR(nm,u);
            float3 transmitted=refract(rd,n,eta);
            if(length_squared(transmitted)<0.001 || random01(rng)<opticalFresnel(-dot(rd,n),eta)) rd=reflect(rd,n);
            else rd=transmitted;
            throughput*=0.985;
        }
        ro=p+rd*0.002;
    }
}
kernel void photonResolve(texture2d<float,access::write> output [[texture(0)]],device atomic_uint* map [[buffer(2)]],
                          uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(512))) return;
    float3 c=0; float weight=0;
    for(int y=-2;y<=2;++y) for(int x=-2;x<=2;++x) {
        uint2 q=neighbor(p,int2(x,y),512,512); uint i=(q.y*512+q.x)*3;
        float w=exp(-float(x*x+y*y)*0.45); weight+=w;
        c+=float3(atomic_load_explicit(map+i,memory_order_relaxed),atomic_load_explicit(map+i+1,memory_order_relaxed),
                  atomic_load_explicit(map+i+2,memory_order_relaxed))*w;
    }
    output.write(float4(c/max(weight,0.001)*(1.0/4096.0)*1.9,1),p);
}
float spectralPath(float3 ro,float3 rd,uint band,thread uint& rng,texture2d<float> caustics,
                   constant Uniforms& u,constant StageUniforms& s) {
    float nm=band==0?625:band==1?535:455, energy=1, value=0; bool inside=false;
    int bounces=u.options.w==0?3:u.options.w==1?5:u.options.w==2?7:10;
    for(int bounce=0;bounce<bounces;++bounce) {
        OpticalHit h=opticalScene(ro,rd,u,s);
        if(h.distance>100) { value+=energy*stageEnvironment(rd,2)[band]*0.45; break; }
        float3 p=ro+rd*h.distance;
        if(inside) {
            float3 absorption=u.parameters.w>1.5?float3(0.65,0.08,0.22):float3(0.06,0.025,0.012);
            energy*=exp(-h.distance*absorption[band]);
        }
        if(h.material==1) {
            bool entering=dot(rd,h.normal)<0; float3 n=entering?h.normal:-h.normal;
            float eta=entering?1/opticalIOR(nm,u):opticalIOR(nm,u);
            float3 transmission=refract(rd,n,eta);
            float fresnel=opticalFresnel(-dot(rd,n),eta);
            if(length_squared(transmission)<0.001 || random01(rng)<fresnel) rd=reflect(rd,n);
            else { rd=transmission; inside=entering; }
        } else if(h.material==2) {
            float3 reflection=reflect(rd,h.normal);
            rd=normalize(mix(reflection,cosineDirection(h.normal,rng),u.controls.z*u.controls.z));
            energy*=opticalAlbedo(p,2)[band];
        } else {
            float albedo=opticalAlbedo(p,h.material)[band];
            float3 light=s.light.xyz;
            light.xz += (float2(random01(rng),random01(rng))-0.5)*u.controls.y*2;
            float3 ld=light-p; float d2=length_squared(ld); ld=normalize(ld);
            OpticalHit shadow=opticalScene(p+h.normal*0.003,ld,u,s);
            float visible=shadow.distance*shadow.distance>d2 ? 1.0 : 0.0;
            value+=energy*albedo*(0.025+visible*max(0.0,dot(h.normal,ld))*18.0*u.parameters.x/max(d2,0.1));
            if(h.material==0 && abs(p.x)<3 && abs(p.z)<3)
                value+=energy*albedo*caustics.sample(linearClamp,p.xz/6+0.5)[band]*u.parameters.x;
            energy*=albedo;
            rd=cosineDirection(h.normal,rng);
        }
        ro=p+rd*0.002;
        if(bounce>3) { float survive=clamp(energy,0.15,0.85); if(random01(rng)>survive) break; energy/=survive; }
    }
    return min(value,24.0);
}
kernel void spectralRender(texture2d<float,access::write> output [[texture(0)]],texture2d<float> caustics [[texture(1)]],
                           constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 p [[thread_position_in_grid]]) {
    if(any(p>=uint2(output.get_width(),output.get_height()))) return;
    uint rng=(p.x+p.y*uint(u.viewport.x))*747796405u+uint(s.state.x)*2891336453u+7217u;
    float2 jitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float3 ro,rd; stageCamera((float2(p)+jitter)/u.viewport.xy,u,s,ro,rd);
    float3 color;
    for(uint band=0;band<3;++band) {
        // Correlated wavelength paths reduce false-color Monte Carlo noise.
        uint wavelengthRNG=rng;
        color[band]=spectralPath(ro,rd,band,wavelengthRNG,caustics,u,s);
    }
    output.write(float4(color,min(opticalScene(ro,rd,u,s).distance,100.0)),p);
}

// ---- 3D position-based liquid ---------------------------------------------
// A bounded uniform grid accelerates neighbor queries. Three density projection
// iterations run at 120 Hz. A separate field reconstructs a continuous surface.
struct LiquidParticle { float4 position; float4 velocity; float4 predicted; float4 reserved; };
constant uint TANK_N=16384, GRID_SIDE=20, CELL_CAPACITY=96;
constant float TANK_H=0.1, REST_DENSITY=3.85;
uint tankCell(int3 p) { return uint((p.z*20+p.y)*20+p.x); }
int3 tankCoords(float3 p) { return clamp(int3(floor((p+float3(1,0,1))*10)),int3(0),int3(19)); }
float tankWeight(float3 d) { float q=max(0.0,1-dot(d,d)/(TANK_H*TANK_H)); return q*q*q; }
float3 tankGradient(float3 d) {
    float q=max(0.0,1-dot(d,d)/(TANK_H*TANK_H));
    return -6.0*q*q*d/(TANK_H*TANK_H*REST_DENSITY);
}
float3 tankBoundary(float3 p,float4 body,float radius) {
    p=clamp(p,float3(-0.975,0.025,-0.975),float3(0.975,1.975,0.975));
    float3 d=p-body.xyz; float lengthD=length(d), r=radius+0.025;
    if(lengthD<r) p=body.xyz+(lengthD>1e-5?d/lengthD:float3(0,1,0))*r;
    return clamp(p,float3(-0.975,0.025,-0.975),float3(0.975,1.975,0.975));
}
kernel void tankInitialize(device LiquidParticle* particles [[buffer(2)]],device float4* body [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N) return;
    float3 p=float3(float(i%24)*0.055-0.86,float((i/24)%18)*0.055+0.06,float(i/(24*18))*0.055-0.63);
    float active=i<24*18*24?1.0:0.0;
    particles[i]={float4(p,active),float4(0),float4(p,active),float4(0)};
    if(i==0) { body[0]=float4(0.45,1.65,0.1,1); body[1]=0; }
}
kernel void tankBody(texture3d<float> field [[texture(0)]],device float4* body [[buffer(2)]],
                     constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i>0) return;
    float3 p=body[0].xyz,v=body[1].xyz; float radius=u.controls.z, dt=s.simulation.y;
    if(u.pointer.z>0.5 && (uint(s.state.z)&1)) { p=pointerInTank(u,s,1.2); v=0; }
    else {
        float submerged=0;
        for(int n=0;n<12;++n) {
            float a=float(n)*2.399963, y=1-2*(float(n)+0.5)/12;
            float3 sample=p+float3(cos(a)*sqrt(1-y*y),y,sin(a)*sqrt(1-y*y))*radius*0.75;
            submerged+=smoothstep(0.25,0.7,field.sample(linearClamp,(sample+float3(1,0,1))/2).x)/12;
        }
        v.y+=(-5.5*u.controls.y+submerged*12)*dt;
        v*=exp(-dt*(0.3+submerged*3)); p+=v*dt;
        if(p.y<radius+0.025) { p.y=radius+0.025; v.y=abs(v.y)*0.3; }
        p.xz=clamp(p.xz,float2(-1+radius),float2(1-radius));
    }
    p.y=clamp(p.y,radius+0.025,1.975-radius);
    body[0]=float4(p,1); body[1]=float4(v,0);
}
kernel void tankPredict(device LiquidParticle* particles [[buffer(2)]],device const float4* body [[buffer(3)]],
                        constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N) return;
    LiquidParticle p=particles[i]; float dt=s.simulation.y;
    if(u.pointer.z>0.5 && !(uint(s.state.z)&1)) {
        float rate=1800*u.parameters.x;
        uint first=uint(floor(s.simulation.x*rate)), last=uint(floor((s.simulation.x+dt)*rate));
        uint relative=(i+TANK_N-first%TANK_N)%TANK_N;
        if(relative<last-first) {
            uint rng=i*713u+uint(s.simulation.x*120);
            float3 emitter=pointerInTank(u,s,1.7);
            p.position=float4(emitter+float3(random01(rng)-0.5,random01(rng)-0.5,random01(rng)-0.5)*0.13,1);
            p.velocity=float4(0,-1.7,0,0);
        }
    }
    if(p.position.w<0.5) { particles[i]=p; return; }
    p.velocity.y-=5.5*u.controls.y*dt;
    p.velocity.xyz*=exp(-dt*0.15);
    p.predicted=float4(tankBoundary(p.position.xyz+p.velocity.xyz*dt,body[0],u.controls.z),1);
    particles[i]=p;
}
kernel void tankGrid(device const LiquidParticle* particles [[buffer(2)]],device atomic_uint* counts [[buffer(3)]],
                     device uint* cells [[buffer(4)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N || particles[i].predicted.w<0.5) return;
    uint cell=tankCell(tankCoords(particles[i].predicted.xyz));
    uint slot=atomic_fetch_add_explicit(counts+cell,1,memory_order_relaxed);
    if(slot<CELL_CAPACITY) cells[cell*CELL_CAPACITY+slot]=i;
}
kernel void tankLambda(device const LiquidParticle* particles [[buffer(2)]],device const atomic_uint* counts [[buffer(3)]],
                       device const uint* cells [[buffer(4)]],device float* lambda [[buffer(5)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N) return;
    if(particles[i].predicted.w<0.5) { lambda[i]=0; return; }
    float3 p=particles[i].predicted.xyz; int3 cell=tankCoords(p);
    float density=0,denom=0; float3 sum=0;
    for(int z=-1;z<=1;++z) for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        int3 q=cell+int3(x,y,z); if(any(q<0)||any(q>=20)) continue;
        uint c=tankCell(q),n=min(atomic_load_explicit(counts+c,memory_order_relaxed),CELL_CAPACITY);
        for(uint a=0;a<n;++a) {
            uint j=cells[c*CELL_CAPACITY+a]; float3 d=p-particles[j].predicted.xyz;
            density+=tankWeight(d);
            if(j!=i) { float3 g=tankGradient(d); sum+=g; denom+=dot(g,g); }
        }
    }
    denom+=dot(sum,sum);
    lambda[i]=-max(density/REST_DENSITY-1,0.0)/(denom+120.0);
}
kernel void tankCorrect(device const LiquidParticle* particles [[buffer(2)]],device const atomic_uint* counts [[buffer(3)]],
                        device const uint* cells [[buffer(4)]],device const float* lambda [[buffer(5)]],
                        device float4* corrected [[buffer(6)]],device const float4* body [[buffer(7)]],
                        constant Uniforms& u [[buffer(0)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N) return;
    if(particles[i].predicted.w<0.5) { corrected[i]=particles[i].predicted; return; }
    float3 p=particles[i].predicted.xyz,correction=0; int3 cell=tankCoords(p);
    for(int z=-1;z<=1;++z) for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        int3 q=cell+int3(x,y,z); if(any(q<0)||any(q>=20)) continue;
        uint c=tankCell(q),n=min(atomic_load_explicit(counts+c,memory_order_relaxed),CELL_CAPACITY);
        for(uint a=0;a<n;++a) {
            uint j=cells[c*CELL_CAPACITY+a]; if(j==i) continue;
            float3 d=p-particles[j].predicted.xyz;
            float antiClump=-0.00008*pow(tankWeight(d)/0.753571,4.0);
            correction+=(lambda[i]+lambda[j]+antiClump)*tankGradient(d);
        }
    }
    float mag=length(correction); correction*=min(1.0,0.025/max(mag,0.00001));
    corrected[i]=float4(tankBoundary(p+correction,body[0],u.controls.z),1);
}
kernel void tankApply(device LiquidParticle* p [[buffer(2)]],device const float4* corrected [[buffer(3)]],uint i [[thread_position_in_grid]]) {
    if(i<TANK_N) p[i].predicted=corrected[i];
}
kernel void tankFinish(device const LiquidParticle* particles [[buffer(2)]],device LiquidParticle* next [[buffer(3)]],
                       device const atomic_uint* counts [[buffer(4)]],device const uint* cells [[buffer(5)]],
                       constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N) return;
    LiquidParticle p=particles[i]; if(p.predicted.w<0.5) { next[i]=p; return; }
    float3 v=(p.predicted.xyz-p.position.xyz)/s.simulation.y;
    float3 average=0; float weight=0; int3 cell=tankCoords(p.predicted.xyz);
    for(int z=-1;z<=1;++z) for(int y=-1;y<=1;++y) for(int x=-1;x<=1;++x) {
        int3 q=cell+int3(x,y,z); if(any(q<0)||any(q>=20)) continue;
        uint c=tankCell(q),n=min(atomic_load_explicit(counts+c,memory_order_relaxed),CELL_CAPACITY);
        for(uint a=0;a<n;++a) {
            LiquidParticle other=particles[cells[c*CELL_CAPACITY+a]];
            float w=tankWeight(p.predicted.xyz-other.predicted.xyz);
            average+=(other.predicted.xyz-other.position.xyz)/s.simulation.y*w; weight+=w;
        }
    }
    float viscosity=0.025+u.controls.x*0.3+(u.parameters.w>0.5&&u.parameters.w<1.5?0.28:0.0);
    v=mix(v,average/max(weight,0.0001),viscosity);
    v*=min(1.0,6.0/max(length(v),0.001));
    p.velocity=float4(v,0); p.position=p.predicted; next[i]=p;
}
kernel void tankSplat(device const LiquidParticle* particles [[buffer(2)]],device atomic_uint* density [[buffer(3)]],
                      constant StageUniforms& s [[buffer(1)]],uint i [[thread_position_in_grid]]) {
    if(i>=TANK_N || particles[i].position.w<0.5) return;
    int side=int(s.simulation.w); float3 p=particles[i].position.xyz;
    float3 voxel=(p+float3(1,0,1))*0.5*float(side)-0.5; int3 center=int3(floor(voxel));
    int radius=int(ceil(TANK_H*float(side)*0.5));
    for(int z=-radius;z<=radius;++z) for(int y=-radius;y<=radius;++y) for(int x=-radius;x<=radius;++x) {
        int3 q=center+int3(x,y,z); if(any(q<0)||any(q>=side)) continue;
        float3 world=(float3(q)+0.5)/float(side)*2-float3(1,0,1);
        float w=tankWeight(world-p);
        if(w>0.001) atomic_fetch_add_explicit(density+(q.z*side+q.y)*side+q.x,uint(w*4096),memory_order_relaxed);
    }
}
kernel void tankField(texture3d<float,access::write> field [[texture(0)]],device const atomic_uint* density [[buffer(2)]],uint3 p [[thread_position_in_grid]]) {
    uint side=field.get_width(); if(any(p>=side)) return;
    float d=float(atomic_load_explicit(density+(p.z*side+p.y)*side+p.x,memory_order_relaxed))/(4096.0*REST_DENSITY);
    field.write(float4(d),p);
}
float tankDensity(float3 p,texture3d<float> field) {
    if(any(p<float3(-1,0,-1))||any(p>float3(1,2,1))) return 0;
    return field.sample(linearClamp,(p+float3(1,0,1))/2).x;
}
float3 tankFloor(float3 ro,float3 rd,constant Uniforms& u) {
    float3 color=stageEnvironment(rd)*0.22;
    if(rd.y < -0.001) {
        float3 p=ro+rd*(-ro.y/rd.y);
        float grid=min(abs(fract(p.x*2)-0.5),abs(fract(p.z*2)-0.5));
        float base=smoothstep(0.012,0.025,grid);
        float pool=1-smoothstep(1.05,1.09,max(abs(p.x),abs(p.z)));
        color=mix(float3(0.02,0.028,0.04),mix(float3(0.04,0.11,0.14),float3(0.14,0.22,0.26),base),pool);
        color*=0.7+0.5*exp(-dot(p.xz,p.xz)*0.3);
    }
    return color;
}
kernel void tankRender(texture2d<float,access::write> output [[texture(0)]],texture3d<float> field [[texture(1)]],
                       device const float4* body [[buffer(2)]],constant Uniforms& u [[buffer(0)]],
                       constant StageUniforms& s [[buffer(1)]],uint2 px [[thread_position_in_grid]]) {
    if(any(px>=uint2(output.get_width(),output.get_height()))) return;
    uint rng=(px.y*uint(u.viewport.x)+px.x)*719u+uint(s.state.x)*7193u;
    float2 jitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float3 ro,rd; stageCamera((float2(px)+jitter)/u.viewport.xy,u,s,ro,rd);
    float3 color=backdrop((float2(px)+0.5)/u.viewport.xy,u.viewport.x/u.viewport.y,0)*0.6; float depth=100;
    float2 box=intersectBox(ro,rd,float3(-1,0,-1),float3(1,2,1));
    float2 ball=intersectSphere(ro,rd,body[0].xyz,u.controls.z);
    float end=min(box.y,ball.x>0?ball.x:100.0),start=max(0.0,box.x),hit=-1,previous=start;
    int steps=u.options.w==0?72:u.options.w==1?104:u.options.w==2?144:192;
    float stepSize=2.8/float(steps);
    if(end>start) {
        for(int i=0;i<steps;++i) {
            float t=start+float(i)*stepSize; if(t>end) break;
            if(tankDensity(ro+rd*t,field)>0.45) {
                float a=previous,b=t;
                for(int j=0;j<6;++j) { float m=(a+b)*0.5; if(tankDensity(ro+rd*m,field)>0.45) b=m; else a=m; }
                hit=b; break;
            }
            previous=t;
        }
    }
    if(hit>0) {
        depth=hit; float3 p=ro+rd*hit; float e=1.0/float(field.get_width());
        float3 n=-normalize(float3(tankDensity(p+float3(e,0,0),field)-tankDensity(p-float3(e,0,0),field),
                                   tankDensity(p+float3(0,e,0),field)-tankDensity(p-float3(0,e,0),field),
                                   tankDensity(p+float3(0,0,e),field)-tankDensity(p-float3(0,0,e),field))+1e-7);
        float f=0.025+0.975*pow(1-max(0.0,dot(n,-rd)),5.0);
        float3 reflected=stageEnvironment(reflect(rd,n),2);
        if(u.parameters.w>1.5) color=reflected*float3(0.82,0.91,1.0);
        else {
            float ior=u.parameters.w>0.5?1.47:1.333;
            float3 refracted=refract(rd,n,1/ior); float thickness=0;
            for(int j=1;j<56;++j) {
                float d=float(j)*0.025;
                if(tankDensity(p+refracted*d,field)<0.42) { thickness=d; break; }
                thickness=d;
            }
            float3 absorption=u.parameters.w>0.5?float3(0.25,1.5,4.8):float3(1.8,0.32,0.13);
            float3 trans=exp(-absorption*thickness*1.4);
            float3 behind=tankFloor(p+refracted*max(thickness,0.02),refracted,u)*2;
            float2 bt=intersectSphere(p+refracted*0.02,refracted,body[0].xyz,u.controls.z);
            if(bt.x>0 && bt.x<2) behind=float3(0.92,0.27,0.06)*0.6;
            float3 scatter=u.parameters.w>0.5?float3(0.7,0.2,0.018):float3(0.015,0.35,0.46);
            color=mix(behind*trans+scatter*(1-trans)*0.7,reflected,f);
        }
        float rim=pow(max(0.0,dot(n,normalize(float3(-0.4,1,0.3)))),24.0);
        color+=float3(0.5,0.8,1)*rim*0.25;
    } else if(ball.x>0) {
        depth=ball.x; float3 p=ro+rd*ball.x,n=normalize(p-body[0].xyz);
        color=float3(0.9,0.24,0.055)*(0.15+max(0.0,dot(n,normalize(float3(-1,3,2))))*0.7)
             +stageEnvironment(reflect(rd,n))*0.25;
    }
    // Subtle tank edges convey the 3D bounds without covering the liquid.
    if(box.y>max(box.x,0.0)) {
        float3 p=ro+rd*max(box.x,0.0);
        float3 edge=min(abs(p-float3(-1,0,-1)),abs(p-float3(1,2,1)));
        float line=1-smoothstep(0.003,0.008,min(max(edge.x,edge.y),min(max(edge.y,edge.z),max(edge.x,edge.z))));
        color+=float3(0.12,0.32,0.42)*line;
    }
    output.write(float4(color,depth),px);
}

// ---- Fuel / temperature / smoke / velocity in a 3D Eulerian grid -----------
uint3 fireNeighbor(uint3 p,int3 d,uint side) { return uint3(clamp(int3(p)+d,int3(0),int3(side-1))); }
float3 fireWorld(uint3 p,uint side) { return (float3(p)+0.5)/float(side)*2-float3(1,0,1); }
float3 fireObstacle(constant StageUniforms& s) { return s.object.xyz; }
bool fireSolid(float3 p,constant StageUniforms& s) { return distance(p,fireObstacle(s))<0.22; }
kernel void fireInitialize(texture3d<float,access::write> velocity [[texture(0)]],texture3d<float,access::write> chemistry [[texture(1)]],
                           texture3d<float,access::write> p0 [[texture(2)]],texture3d<float,access::write> p1 [[texture(3)]],
                           constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float3 world=fireWorld(p,side);
    float r=length(world.xz-float2(0.06*sin(world.y*8),0.04*cos(world.y*11)));
    float plume=exp(-r*r/(0.015+world.y*0.045))*exp(-world.y*1.5);
    plume*=0.55+fbm3(world*9);
    float flame=plume*max(0.0,1.4-world.y)*1.9;
    if(u.parameters.w>1.5) { float d=length(world-float3(0,0.65,0)); plume=exp(-d*d*13); flame=plume*2.6; }
    if(fireSolid(world,s)) { plume=0; flame=0; }
    float3 startVelocity=float3(0,plume*0.7,0);
    if(u.parameters.w>1.5) startVelocity=normalize(world-float3(0,0.65,0)+1e-5)*plume*1.7;
    velocity.write(float4(startVelocity,0),p);
    chemistry.write(float4(plume*0.5,flame,plume*(u.parameters.w>0.5&&u.parameters.w<1.5?1.7:0.7),flame),p);
    p0.write(float4(0),p); p1.write(float4(0),p);
}
kernel void fireAdvect(texture3d<float> velocity [[texture(0)]],texture3d<float> chemistry [[texture(1)]],
                      texture3d<float,access::write> nextVelocity [[texture(2)]],texture3d<float,access::write> nextChemistry [[texture(3)]],
                      constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float3 uv=(float3(p)+0.5)/float(side),world=uv*2-float3(1,0,1); float dt=s.simulation.y;
    float3 v=velocity.sample(linearClamp,uv).xyz;
    float3 back=clamp(uv-v*dt*0.5,0.5/float(side),1-0.5/float(side));
    float3 advected=velocity.sample(linearClamp,back).xyz*exp(-dt*0.18);
    float4 c=chemistry.sample(linearClamp,back);
    c.x*=exp(-dt*0.25); c.y*=exp(-dt*0.7); c.z*=exp(-dt*0.11);
    float t=s.simulation.x;
    float3 nozzle=float3(0,0.12,0);
    float2 sourceOffset=float2(sin(t*1.3),cos(t*1.7))*0.1;
    float jet=exp(-dot(world.xz-sourceOffset,world.xz-sourceOffset)*12)*exp(-pow((world.y-0.1)*10,2.0));
    if(u.parameters.w>1.5) {
        float pulse=exp(-pow(fmod(t,6.0)*3,2.0));
        jet=exp(-length_squared(world-float3(0,0.55,0))*35)*pulse*4;
    }
    if(u.pointer.z>0.5 && !(uint(s.state.z)&1)) {
        float3 source=pointerInTank(u,s,0.95);
        jet+=exp(-length_squared(world-source)*95)*4;
    }
    c.x+=jet*dt*7*u.parameters.x;
    c.y+=jet*dt*11;
    float burn=min(c.x,dt*3.0*smoothstep(0.35,1.2,c.y));
    c.x-=burn; c.y+=burn*2.8;
    c.z+=burn*(u.parameters.w>0.5&&u.parameters.w<1.5?1.8:0.8);
    c.w=burn/max(dt,0.001);
    if(fireSolid(world,s)) { c=0; advected=0; }
    nextVelocity.write(float4(advected,0),p);
    nextChemistry.write(clamp(c,float4(0),float4(3,5,4,8)),p);
}
kernel void fireCurl(texture3d<float,access::read> velocity [[texture(0)]],texture3d<float,access::write> curl [[texture(1)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float3 dx=velocity.read(fireNeighbor(p,int3(1,0,0),side)).xyz-velocity.read(fireNeighbor(p,int3(-1,0,0),side)).xyz;
    float3 dy=velocity.read(fireNeighbor(p,int3(0,1,0),side)).xyz-velocity.read(fireNeighbor(p,int3(0,-1,0),side)).xyz;
    float3 dz=velocity.read(fireNeighbor(p,int3(0,0,1),side)).xyz-velocity.read(fireNeighbor(p,int3(0,0,-1),side)).xyz;
    float3 w=float3(dy.z-dz.y,dz.x-dx.z,dx.y-dy.x)*float(side)*0.25;
    curl.write(float4(w,length(w)),p);
}
kernel void fireForce(texture3d<float,access::read> velocity [[texture(0)]],texture3d<float,access::read> chemistry [[texture(1)]],
                     texture3d<float,access::read> curl [[texture(2)]],texture3d<float,access::write> result [[texture(3)]],
                     constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float3 eta=float3(curl.read(fireNeighbor(p,int3(1,0,0),side)).w-curl.read(fireNeighbor(p,int3(-1,0,0),side)).w,
                      curl.read(fireNeighbor(p,int3(0,1,0),side)).w-curl.read(fireNeighbor(p,int3(0,-1,0),side)).w,
                      curl.read(fireNeighbor(p,int3(0,0,1),side)).w-curl.read(fireNeighbor(p,int3(0,0,-1),side)).w);
    eta/=max(length(eta),0.001);
    float3 v=velocity.read(p).xyz; float4 c=chemistry.read(p);
    float3 force=cross(eta,curl.read(p).xyz)*u.controls.x*0.24;
    force.y+=c.y*1.5*u.controls.z-c.z*0.12;
    float3 w=fireWorld(p,side); float t=s.simulation.x;
    force.x+=sin(w.y*8+t*2.3+w.z*11)*c.y*0.42;
    force.z+=cos(w.y*7-t*1.7+w.x*13)*c.y*0.42;
    v+=force*s.simulation.y;
    v*=min(1.0,3.0/max(length(v),0.001));
    if(fireSolid(w,s)) v=0;
    if(p.x==0||p.x==side-1) v.x=0;
    if(p.y==0) v.y=0;
    if(p.z==0||p.z==side-1) v.z=0;
    result.write(float4(v,0),p);
}
kernel void fireDivergence(texture3d<float,access::read> velocity [[texture(0)]],texture3d<float,access::write> divergence [[texture(1)]],
                          texture3d<float,access::write> pressure [[texture(2)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float d=velocity.read(fireNeighbor(p,int3(1,0,0),side)).x-velocity.read(fireNeighbor(p,int3(-1,0,0),side)).x
           +velocity.read(fireNeighbor(p,int3(0,1,0),side)).y-velocity.read(fireNeighbor(p,int3(0,-1,0),side)).y
           +velocity.read(fireNeighbor(p,int3(0,0,1),side)).z-velocity.read(fireNeighbor(p,int3(0,0,-1),side)).z;
    divergence.write(float4(d*float(side)*0.25),p); pressure.write(float4(0),p);
}
kernel void firePressure(texture3d<float,access::read> pressure [[texture(0)]],texture3d<float,access::read> divergence [[texture(1)]],
                        texture3d<float,access::write> next [[texture(2)]],uint3 p [[thread_position_in_grid]]) {
    uint side=pressure.get_width(); if(any(p>=side)) return;
    float sum=pressure.read(fireNeighbor(p,int3(1,0,0),side)).x+pressure.read(fireNeighbor(p,int3(-1,0,0),side)).x
             +pressure.read(fireNeighbor(p,int3(0,1,0),side)).x+pressure.read(fireNeighbor(p,int3(0,-1,0),side)).x
             +pressure.read(fireNeighbor(p,int3(0,0,1),side)).x+pressure.read(fireNeighbor(p,int3(0,0,-1),side)).x;
    float h=2.0/float(side);
    next.write(float4((sum-divergence.read(p).x*h*h)/6),p);
}
kernel void fireProject(texture3d<float,access::read> velocity [[texture(0)]],texture3d<float,access::read> pressure [[texture(1)]],
                       texture3d<float,access::write> next [[texture(2)]],constant StageUniforms& s [[buffer(1)]],uint3 p [[thread_position_in_grid]]) {
    uint side=velocity.get_width(); if(any(p>=side)) return;
    float3 grad=float3(pressure.read(fireNeighbor(p,int3(1,0,0),side)).x-pressure.read(fireNeighbor(p,int3(-1,0,0),side)).x,
                      pressure.read(fireNeighbor(p,int3(0,1,0),side)).x-pressure.read(fireNeighbor(p,int3(0,-1,0),side)).x,
                      pressure.read(fireNeighbor(p,int3(0,0,1),side)).x-pressure.read(fireNeighbor(p,int3(0,0,-1),side)).x)*float(side)*0.25;
    float3 v=velocity.read(p).xyz-grad;
    if(fireSolid(fireWorld(p,side),s)) v=0;
    if(p.x==0||p.x==side-1) v.x=0;
    if(p.y==0) v.y=0;
    if(p.z==0||p.z==side-1) v.z=0;
    next.write(float4(v,0),p);
}
float4 fireSample(float3 p,texture3d<float> chemistry) {
    if(any(p<float3(-1,0,-1))||any(p>float3(1,2,1))) return 0;
    return chemistry.sample(linearClamp,(p+float3(1,0,1))/2);
}
float3 fireEmission(float temperature) {
    float t=max(temperature-0.35,0.0);
    float3 c=mix(float3(1.0,0.035,0.001),float3(1,0.5,0.03),smoothstep(0.0,1.3,t));
    c=mix(c,float3(1.0,0.9,0.55),smoothstep(1.3,3.0,t));
    return c*t*t*2.7;
}
kernel void fireRender(texture2d<float,access::write> output [[texture(0)]],texture3d<float> chemistry [[texture(1)]],
                       constant Uniforms& u [[buffer(0)]],constant StageUniforms& s [[buffer(1)]],uint2 px [[thread_position_in_grid]]) {
    if(any(px>=uint2(output.get_width(),output.get_height()))) return;
    uint rng=(px.x+px.y*uint(u.viewport.x))*2891u+uint(s.state.x)*6271u;
    float2 cameraJitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float3 ro,rd; stageCamera((float2(px)+cameraJitter)/u.viewport.xy,u,s,ro,rd);
    float3 base=float3(0.004,0.007,0.013);
    float depth=100;
    if(rd.y<0) {
        float3 floorPoint=ro-rd*ro.y/rd.y; depth=-ro.y/rd.y;
        float glow=exp(-dot(floorPoint.xz,floorPoint.xz)*1.8);
        base=float3(0.016,0.022,0.033)+float3(0.21,0.035,0.003)*glow*u.parameters.x;
    }
    float2 ball=intersectSphere(ro,rd,fireObstacle(s),0.22);
    if(ball.x>0 && ball.x<depth) {
        depth=ball.x; float3 n=normalize(ro+rd*ball.x-fireObstacle(s));
        base=stageEnvironment(reflect(rd,n))*0.09+float3(0.18,0.024,0.004)*max(0.0,-n.y);
    }
    float2 bounds=intersectBox(ro,rd,float3(-1,0,-1),float3(1,2,1));
    float start=max(bounds.x,0.0),end=min(bounds.y,depth);
    int steps=u.options.w==0?64:u.options.w==1?96:u.options.w==2?144:192;
    if(s.state.w>0.5) steps=steps*3/4;
    float stride=2.8/float(steps),transmittance=1; float3 radiance=0;
    float jitter=s.state.y>0.5?random01(rng):0.5;
    float3 key=normalize(float3(-0.6,0.8,0.4));
    for(int i=0;i<steps && end>start;++i) {
        float t=start+(float(i)+jitter)*stride; if(t>end||transmittance<0.008) break;
        float3 p=ro+rd*t; float4 c=fireSample(p,chemistry);
        float detail=noise3(p*24-float3(0,u.viewport.z*1.7,0));
        c.y*=0.72+detail*0.48; c.z*=0.8+detail*0.4;
        float density=c.z*u.controls.y*3+c.x*0.4;
        if(density<0.005 && c.y<0.15) continue;
        float optical=0;
        for(int k=1;k<=7;++k) optical+=fireSample(p+key*(float(k)*0.07),chemistry).z*0.07*u.controls.y*3;
        float shade=exp(-optical);
        float alpha=1-exp(-density*stride);
        float3 smoke=float3(0.18,0.24,0.33)*(0.15+0.85*shade);
        // Light scattering into smoke from nearby hot gas.
        float4 hot=fireSample(p+float3(0,-0.12,0),chemistry);
        smoke+=fireEmission(hot.y)*0.13;
        float3 emission=fireEmission(c.y)*(u.parameters.w>0.5&&u.parameters.w<1.5?0.25:1.0);
        radiance+=transmittance*(smoke*alpha+emission*stride*0.8);
        transmittance*=1-alpha;
    }
    output.write(float4(radiance+base*transmittance,min(depth,end)),px);
}

// ---- Storm planet: curved atmosphere, 3D clouds, ocean and terrain ----------
float3 planetSun(constant Uniforms& u,constant StageUniforms& s) {
    float az=s.light.w-(u.parameters.w>0.5 && u.parameters.w<1.5?0.8:0.0);
    return normalize(rotateY(float3(-0.9,u.controls.y,0.65),az));
}
float cloudDensity(float3 p,constant Uniforms& u) {
    float radius=length(p), altitude=(radius-1.018)/0.09;
    if(altitude<=0 || altitude>=1) return 0;
    float time=u.viewport.z*(u.parameters.w>0.5&&u.parameters.w<1.5?0.075:0.045);
    float3 n=rotateY(p/radius,time);
    float3 axis=normalize(float3(-0.42,0.3,0.82));
    float3 tangent=normalize(cross(axis,float3(0,1,0))),up=cross(tangent,axis);
    float2 q=float2(dot(n,tangent),dot(n,up));
    float r=length(q),a=atan2(q.y,q.x);
    float hurricane=exp(-r*r*14)*smoothstep(0.2,0.7,dot(n,axis));
    float spiral=a-r*27+time*2;
    float bands=pow(0.5+0.5*cos(spiral*2),2.0);
    float3 advected=n*5+float3(time*0.8,0,time*0.2);
    float broad=fbm3(advected,4);
    float billows=noise3(n*37+float3(time*2,altitude*3,0));
    float coverage=clamp(u.controls.x+(u.parameters.w>1.5?-0.13:u.parameters.w>0.5?0.14:0.0),0.05,1.0);
    float cloud=smoothstep(0.64-coverage*0.36,0.82-coverage*0.36,broad+billows*0.13);
    cloud=mix(cloud,0.35+bands*0.9,hurricane*clamp(u.parameters.x,0.0,1.0));
    cloud*=1-hurricane*exp(-r*r*850);
    float profile=smoothstep(0.0,0.18,altitude)*(1-smoothstep(0.55,1.0,altitude));
    return max(0.0,cloud-0.16*noise3(p*81))*profile*(4+u.parameters.x*4);
}
float planetCloudShadow(float3 p,float3 sun,constant Uniforms& u) {
    float optical=0;
    for(int i=0;i<7;++i) optical+=cloudDensity(p+sun*(0.018+float(i)*0.022),u)*0.022*12;
    return exp(-optical);
}
float3 planetSurface(float3 p,float3 rd,float3 sun,constant Uniforms& u) {
    float3 n=normalize(p),q=rotateY(n,u.viewport.z*0.045);
    float height=fbm3(q*3.4+float3(2.2,0,0),5);
    float shore=smoothstep(0.47,0.485,height);
    if(u.parameters.w>1.5) shore=smoothstep(0.36,0.38,height);
    float3 land=mix(float3(0.12,0.18,0.055),float3(0.38,0.25,0.1),smoothstep(0.53,0.7,height));
    land=mix(land,float3(0.65,0.73,0.75),smoothstep(0.68,0.82,abs(n.y)+height*0.12));
    float3 water=u.parameters.w>1.5?float3(0.11,0.028,0.015):float3(0.008,0.08,0.16);
    float3 albedo=mix(water,land,shore);
    float wave=noise3(q*180+u.viewport.z*0.12);
    float3 waveNormal=normalize(n+float3(sin(q.y*210+wave*5),sin(q.z*190),sin(q.x*213+wave*7))*0.012);
    float diffuse=max(0.0,dot(n,sun));
    float shadow=planetCloudShadow(p*1.022,sun,u);
    float3 color=albedo*(0.01+diffuse*shadow*1.9);
    float spec=pow(max(0.0,dot(reflect(rd,waveNormal),sun)),u.parameters.w>0.5?170.0:340.0)*(1-shore);
    color+=float3(1.5,1.25,0.85)*spec*shadow;
    // Settlements appear only on the dark side and over land.
    float city=pow(noise3(q*180),18.0)*shore*(1-smoothstep(-0.15,0.15,dot(n,sun)));
    color+=float3(1,0.5,0.13)*city*0.4;
    if(u.parameters.w>1.5) {
        float fissure=pow(1-abs(noise3(q*54)*2-1),30.0)*smoothstep(0.4,0.6,height);
        color+=float3(2.6,0.19,0.008)*fissure*(0.3+0.7*(1-diffuse));
    }
    return color;
}
float3 planetAtmosphere(float3 ro,float3 rd,float end,float3 sun,constant Uniforms& u,thread float3& transmittance) {
    float2 sphere=intersectSphere(ro,rd,float3(0),1.22);
    float start=max(0.0,sphere.x); end=min(end,sphere.y);
    transmittance=float3(1); if(end<=start) return 0;
    float3 beta=float3(5.8,13.5,33.1)*u.controls.z*0.12;
    if(u.parameters.w>1.5) beta=beta.zyx*float3(1.1,0.6,0.35);
    float mu=dot(rd,sun),rayleigh=0.059683*(1+mu*mu);
    float mie=0.012*(1-0.76*0.76)/pow(1+0.76*0.76-1.52*mu,1.5);
    int count=u.options.w==0?16:u.options.w==1?24:u.options.w==2?32:48;
    float step=(end-start)/float(count); float3 optical=0,scatter=0;
    for(int i=0;i<count;++i) {
        float3 p=ro+rd*(start+(float(i)+0.5)*step);
        float height=max(0.0,length(p)-1),density=exp(-height/0.035);
        float along=dot(p,sun);
        float axisDistance=sqrt(max(0.0,dot(p,p)-along*along));
        float visibility=along>0?1.0:smoothstep(0.985,1.015,axisDistance);
        float sunOptical=0;
        if(visibility>0.001) {
            float exit=intersectSphere(p,sun,float3(0),1.22).y;
            for(int j=0;j<5;++j) {
                float3 l=p+sun*(float(j)+0.5)*exit/5;
                sunOptical+=exp(-max(0.0,length(l)-1)/0.035)*exit/5;
            }
            scatter+=visibility*exp(-beta*(optical+sunOptical))*density*step*(beta*rayleigh+float3(mie)*exp(-height/0.012))*12;
        }
        optical+=density*step;
    }
    transmittance=exp(-beta*optical);
    return scatter;
}
kernel void planetRender(texture2d<float,access::write> output [[texture(0)]],constant Uniforms& u [[buffer(0)]],
                         constant StageUniforms& s [[buffer(1)]],uint2 px [[thread_position_in_grid]]) {
    if(any(px>=uint2(output.get_width(),output.get_height()))) return;
    uint rng=(px.x+px.y*uint(u.viewport.x))*3671u+uint(s.state.x)*8971u;
    float2 cameraJitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float3 ro,rd; stageCamera((float2(px)+cameraJitter)/u.viewport.xy,u,s,ro,rd);
    float3 sun=planetSun(u,s),color=nightStars(rd)*0.3;
    float2 earth=intersectSphere(ro,rd,float3(0),1.0);
    float end=earth.x>0?earth.x:100;
    if(end<100) color=planetSurface(ro+rd*end,rd,sun,u);
    float2 cloud=intersectSphere(ro,rd,float3(0),1.108);
    float begin=max(0.0,cloud.x),stop=min(end,cloud.y);
    int count=u.options.w==0?36:u.options.w==1?56:u.options.w==2?80:112;
    if(s.state.w>0.5) count=count*3/4;
    float stride=max(0.001,(stop-begin)/float(count)),trans=1; float3 scattered=0;
    float jitter=s.state.y>0.5?random01(rng):0.5;
    float flash=exp(-pow(fmod(u.viewport.z+0.7,4.5)*14,2.0))*u.parameters.x;
    if(u.parameters.w>0.5&&u.parameters.w<1.5) flash+=exp(-pow((fmod(u.viewport.z+0.2,3.1)-0.2)*18,2.0))*1.3;
    float3 flashPoint=normalize(float3(-0.42,0.3,0.82))*1.055;
    for(int i=0;i<count&&stop>begin;++i) {
        float t=begin+(float(i)+jitter)*stride; if(trans<0.015) break;
        float3 p=ro+rd*t; float density=cloudDensity(p,u);
        if(density<0.01) continue;
        float shade=planetCloudShadow(p,sun,u);
        float diffuse=smoothstep(-0.18,0.35,dot(normalize(p),sun));
        float forward=pow(max(0.0,dot(rd,sun)),8.0)*1.6;
        float3 light=float3(0.04,0.065,0.11)+float3(1.1,0.96,0.78)*shade*diffuse*(0.55+forward);
        light+=float3(0.38,0.6,1.0)*flash*exp(-length_squared(p-flashPoint)*180)*25;
        float alpha=1-exp(-density*stride*17);
        scattered+=trans*alpha*light; trans*=1-alpha;
    }
    color=scattered+color*trans;
    float3 atmosphericTrans;
    color=color*0.95;
    float3 scattering=planetAtmosphere(ro,rd,min(end,100.0),sun,u,atmosphericTrans);
    color=color*atmosphericTrans+scattering;
    output.write(float4(color,end),px);
}

// ---- Fractal cathedral: folded distance estimator and free-flight camera ---
float2 cathedralDE(float3 p,constant Uniforms& u) {
    float morph=u.controls.x;
    if(u.pointer.z>0.5) morph=clamp(morph+(u.pointer.x-0.5)*0.5,0.0,1.0);
    float3 q=p;
    // Repeated chambers make the structure explorable beyond its first facade.
    q.z=fract((q.z+3.0)/6.0)*6.0-3.0;
    float3 z=q; float derivative=1,trap=1e5;
    float scale=mix(-1.68,-2.15,morph);
    int iterations=7+int(u.parameters.x*2);
    if(u.options.w==0) iterations-=2;
    for(int i=0;i<iterations;++i) {
        z=clamp(z,-1.0,1.0)*2-z;
        float r2=dot(z,z);
        float fold=clamp(1.0/max(r2,0.00001),1.0,4.0);
        z*=fold; derivative*=fold;
        z=rotateY(z,0.08+0.19*morph);
        z=z*scale+q;
        derivative=derivative*abs(scale)+1;
        trap=min(trap,length(z.xy)*0.5+abs(z.z)*0.12);
    }
    float d=length(z)/abs(derivative)*0.82;
    // A central nave provides a continuous flight path through the folded walls.
    float tunnel=min(0.32-abs(p.x),0.44-abs(p.y));
    d=max(d,tunnel);
    return float2(d,trap);
}
float3 cathedralNormal(float3 p,float epsilon,constant Uniforms& u) {
    float2 e=float2(epsilon,-epsilon);
    return normalize(e.xyy*cathedralDE(p+e.xyy,u).x+e.yyx*cathedralDE(p+e.yyx,u).x
                    +e.yxy*cathedralDE(p+e.yxy,u).x+e.xxx*cathedralDE(p+e.xxx,u).x);
}
float cathedralShadow(float3 p,float3 ld,constant Uniforms& u) {
    float shadow=1,t=0.012;
    for(int i=0;i<24;++i) {
        float d=cathedralDE(p+ld*t,u).x;
        shadow=min(shadow,10*d/t);
        t+=clamp(d,0.015,0.15);
        if(d<0.0005 || t>3.5) break;
    }
    return clamp(shadow,0.05,1.0);
}
float3 cathedralMaterial(float trap,float3 p,constant Uniforms& u) {
    float veins=0.5+0.5*cos(trap*9+fbm3(p*3,3)*2);
    if(u.parameters.w<0.5) return mix(float3(0.13,0.065,0.02),float3(0.95,0.57,0.15),veins);
    if(u.parameters.w<1.5) return mix(float3(0.025,0.18,0.16),float3(0.32,0.66,0.61),veins);
    return mix(float3(0.015,0.018,0.035),float3(0.15,0.12,0.22),veins);
}
kernel void fractalRender(texture2d<float,access::write> output [[texture(0)]],constant Uniforms& u [[buffer(0)]],
                          constant StageUniforms& s [[buffer(1)]],uint2 px [[thread_position_in_grid]]) {
    if(any(px>=uint2(output.get_width(),output.get_height()))) return;
    uint rng=(px.x+px.y*uint(u.viewport.x))*7919u+uint(s.state.x)*6271u;
    float2 jitter=s.state.y>0.5?float2(random01(rng),random01(rng)):float2(0.5);
    float3 ro,rd; stageCamera((float2(px)+jitter)/u.viewport.xy,u,s,ro,rd);
    float t=0; float2 result=0; bool hit=false;
    int steps=u.options.w==0?100:u.options.w==1?160:u.options.w==2?224:320;
    if(s.state.w>0.5) steps=steps*3/4;
    for(int i=0;i<steps;++i) {
        result=cathedralDE(ro+rd*t,u);
        float epsilon=max(0.00065,t*(s.state.y>0.5?0.38:0.7)/u.viewport.y);
        if(result.x<epsilon) { hit=true; break; }
        t+=max(result.x*0.8,epsilon*0.3);
        if(t>24) break;
    }
    float3 fogColor=u.parameters.w<0.5?float3(0.10,0.13,0.18):u.parameters.w<1.5?float3(0.04,0.16,0.18):float3(0.16,0.055,0.1);
    float3 color=fogColor*0.5;
    if(hit) {
        float3 p=ro+rd*t,n=cathedralNormal(p,max(0.001,t*0.8/u.viewport.y),u);
        float3 light=float3(0.4*sin(u.viewport.z*0.18),1.4,ro.z+0.6);
        float3 ld=normalize(light-p),vd=-rd;
        float shadow=cathedralShadow(p+n*0.004,ld,u);
        float ao=1;
        for(int i=1;i<=4;++i) { float r=float(i)*0.055; ao-=max(0.0,r-cathedralDE(p+n*r,u).x)*1.6/float(i); }
        ao=clamp(ao,0.12,1.0);
        float3 albedo=cathedralMaterial(result.y,p,u);
        float diffuse=max(0.0,dot(n,ld));
        color=albedo*(0.16*ao+diffuse*shadow*1.6);
        float spec=pow(max(0.0,dot(n,normalize(ld+vd))),64.0);
        color+=float3(1.1,0.9,0.6)*spec*shadow;
        if(u.controls.y>0.01) {
            float3 reflectRay=reflect(rd,n),reflectOrigin=p+n*0.006;
            float reflectionT=0.01; bool reflectionHit=false; float trap=0;
            int bounces=u.options.w>=2?40:20;
            for(int j=0;j<bounces;++j) {
                float2 d=cathedralDE(reflectOrigin+reflectRay*reflectionT,u); trap=d.y;
                if(d.x<0.002) { reflectionHit=true; break; }
                reflectionT+=max(d.x*0.8,0.001); if(reflectionT>5) break;
            }
            float3 reflected=reflectionHit?cathedralMaterial(trap,reflectOrigin+reflectRay*reflectionT,u)*0.32:stageEnvironment(reflectRay)*0.45;
            float fresnel=0.2+0.8*pow(1-max(0.0,dot(n,vd)),5.0);
            color=mix(color,reflected,u.controls.y*fresnel);
        }
        float edge=pow(max(0.0,1-abs(dot(n,rd))),3.0);
        color+=fogColor*edge*0.3;
    }
    float mist=1-exp(-min(t,24.0)*u.controls.z*0.28);
    color=mix(color,fogColor,mist);
    output.write(float4(color,min(t,100.0)),px);
}
