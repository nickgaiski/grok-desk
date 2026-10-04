#include <metal_stdlib>
using namespace metal;

// The window and every glass lens evaluate the SAME field in window coordinates.
// The lens changes those coordinates, with independent RGB ray offsets at its rim.
float3 field(float2 p, float2 scene, float t, float preset, float dark) {
    float2 uv = p / max(scene, float2(1));
    float3 a, b, c;
    if (preset < 0.5) { a=float3(.42,.58,.98); b=float3(.77,.49,.84); c=float3(.99,.70,.52); }
    else if (preset < 1.5) { a=float3(.22,.72,.76); b=float3(.40,.54,.90); c=float3(.75,.86,.69); }
    else if (preset < 2.5) { a=float3(.89,.48,.37); b=float3(.90,.70,.52); c=float3(.64,.49,.77); }
    else { a=float3(.52,.60,.75); b=float3(.71,.75,.82); c=float3(.93,.85,.74); }
    float wave = .14*sin(uv.x*5.4 + t*.16) + .09*cos(uv.x*8.0-t*.12);
    float ribbon = .5+.5*sin((uv.y + wave)*7.0 + uv.x*2.3 + t*.10);
    float bloom = exp(-4.8*length(uv-float2(.62+.16*sin(t*.1),.37+.16*cos(t*.13))));
    float3 col=mix(a,b,smoothstep(.12,.92,ribbon));
    col=mix(col,c,bloom*.86);
    // Broad, translucent silk folds provide detail that can visibly bend at a lens edge.
    float fold=pow(.5+.5*sin((uv.y+wave)*13.0 + uv.x*3.0+t*.08),10.0);
    col=mix(col,float3(1),fold*.23);
    return dark > .5 ? col*.26+float3(.022,.028,.044) : mix(float3(.967,.971,.985),col,.36);
}
float sdRoundRect(float2 p, float2 halfSize, float r) {
    float2 q=abs(p)-halfSize+r;
    return length(max(q,0.0))+min(max(q.x,q.y),0.0)-r;
}
[[ stitchable ]] half4 liquidField(float2 position, half4 color, float2 size, float2 origin, float2 scene,
    float time, float preset, float dark, float enabled, float radius, float glass,
    float light, float refraction, float depth, float dispersion, float frost, float splay) {
    float2 global=origin+position;
    float3 base=dark>.5 ? float3(.072,.080,.10) : float3(.963,.969,.98);
    if (glass < .5) return half4(half3(enabled>.5 ? field(global,scene,time,preset,dark) : base),1);
    float2 p=position-size*.5;
    float r=min(radius,min(size.x,size.y)*.5);
    float d=sdRoundRect(p,size*.5,r);
    float2 normal=normalize(float2(
        sdRoundRect(p+float2(.5,0),size*.5,r)-sdRoundRect(p-float2(.5,0),size*.5,r),
        sdRoundRect(p+float2(0,.5),size*.5,r)-sdRoundRect(p-float2(0,.5),size*.5,r))+float2(.00001));
    float falloff=pow(clamp(1.0-(-d)/max(3.0,depth),0.0,1.0),splay);
    float2 bent=global-normal*falloff*refraction;
    float split=dispersion*falloff*7.0;
    float3 refracted=base;
    if(enabled>.5) {
        refracted=float3(field(bent+normal*split,scene,time,preset,dark).r,
                         field(bent,scene,time,preset,dark).g,
                         field(bent-normal*split,scene,time,preset,dark).b);
        float3 blurred=(field(bent+float2(frost*16,0),scene,time,preset,dark)+field(bent-float2(frost*16,0),scene,time,preset,dark)+field(bent+float2(0,frost*16),scene,time,preset,dark)+field(bent-float2(0,frost*16),scene,time,preset,dark))*.25;
        refracted=mix(refracted,blurred,frost*.7);
    }
    // Fresnel reflection is edge-local; moving light travels along the surface normal.
    float spec=pow(max(0.0,dot(normal,float2(cos(time*.22),sin(time*.22)))),5.0);
    float rim=exp(-abs(d+1.0)*.72);
    refracted += (dark>.5 ? .20 : .12)*light*falloff + spec*rim*.30*light;
    return half4(half3(clamp(refracted,0.0,1.0)),1);
}

// The stroke mask is static; only its illumination changes on the GPU.
[[ stitchable ]] half4 glassRim(float2 position, half4 color, float2 size, float time, float dispersion) {
    float2 p = (position - size * 0.5) / max(size * 0.5, float2(1));
    float angle = atan2(p.y, p.x) - time * (6.2831853 / 18.0);
    float t = fract(angle / 6.2831853 + 1.0);
    float location = t * 6.0;
    int i = min(int(location), 5);
    half4 stops[7] = {half4(1,1,1,.9), half4(0,1,1,dispersion*.65), half4(0),
        half4(1,.2,.6,dispersion*.60), half4(1,.5,0,dispersion*.40), half4(0), half4(1,1,1,.9)};
    half4 a = stops[i], b = stops[i+1];
    a.rgb *= a.a; b.rgb *= b.a;
    return mix(a,b,half(fract(location))) * color.a;
}
