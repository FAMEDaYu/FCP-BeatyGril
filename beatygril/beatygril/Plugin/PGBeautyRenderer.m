#import "PGBeautyRenderer.h"
#import <math.h>

// Original implementation reconstructed from observed processing stages, not vendor
// resources. The learned segmentation model and LUTs are deliberately not embedded.
static float PGClamp(float v, float lo, float hi) { return isfinite(v) ? fmaxf(lo, fminf(hi, v)) : lo; }
static CIImage *PGBlur(CIImage *image, CGFloat radius, CGRect extent) {
    return [[[image imageByClampingToExtent] imageByApplyingFilter:@"CIGaussianBlur"
                    withInputParameters:@{kCIInputRadiusKey:@(radius)}] imageByCroppingToRect:extent];
}
static CIColorKernel *PGKernel(NSString *body) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    return [CIColorKernel kernelWithString:body];
#pragma clang diagnostic pop
}
static CIImage *PGApply(CIColorKernel *kernel, CGRect extent, NSArray *arguments) {
    return [kernel applyWithExtent:extent arguments:arguments];
}
static NSDictionary<NSString *, CIColorKernel *> *PGKernels(void) {
    static NSDictionary *kernels;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary *k = [NSMutableDictionary dictionary];
        // The fallback mask observes the shipped G/B overlay > Gaussian high-pass >
        // repeated hard-light stages. Semantic skin support is independently estimated.
        k[@"overlay"] = PGKernel(@
            "kernel vec4 pgGB(__sample p) { vec4 q=unpremultiply(p);"
            "float g=clamp(q.g*0.5,0.0,1.0); float b=clamp(q.b*0.5,0.0,1.0);"
            "float v=2.0*g*b; return vec4(v,v,v,1.0); }");
        k[@"candidate"] = PGKernel(@
            "kernel vec4 pgCandidate(__sample p,__sample g,__sample b) {"
            "vec3 c=clamp(unpremultiply(p).rgb,0.0,1.0);"
            "float y=dot(c,vec3(0.299,0.587,0.114));"
            "float cb=(c.b-y)*0.564+0.5; float cr=(c.r-y)*0.713+0.5;"
            "float chroma=exp(-pow((cb-0.415)/0.115,2.0)-pow((cr-0.565)/0.135,2.0));"
            "float h=clamp(g.r-b.r+0.5,0.0,1.0);"
            "h=mix(2.0*h*h,1.0-2.0*(1.0-h)*(1.0-h),step(0.5,h));"
            "h=mix(2.0*h*h,1.0-2.0*(1.0-h)*(1.0-h),step(0.5,h));"
            "h=mix(2.0*h*h,1.0-2.0*(1.0-h)*(1.0-h),step(0.5,h));"
            "float band=clamp((h-0.29411765)*2.86516854,0.0,1.0);"
            "float edges=1.0-smoothstep(0.06,0.26,abs(band-0.59));"
            "float value=clamp(chroma*smoothstep(0.025,0.15,y)*(0.8+0.2*edges),0.0,1.0);"
            "return vec4(value,value,value,1.0); }");
        k[@"mask"] = PGKernel(@
            "kernel vec4 pgMask(__sample raw,__sample feather,__sample p,__sample b,__sample eyes,__sample teeth,"
            "float threshold,float softness,float edge,float protection,float invert) {"
            "float m=clamp(mix(raw.r,feather.r,softness),0.0,1.0);"
            "float width=0.025+0.24*softness;"
            "m=smoothstep(max(0.0,threshold-width),min(1.0,threshold+width),m);"
            "m=mix(m,1.0-m,invert);"
            "vec3 c=unpremultiply(p).rgb; vec3 l=unpremultiply(b).rgb;"
            "float structure=length(c-l);"
            "m*=1.0-edge*smoothstep(0.025,0.19,structure);"
            "float features=clamp(max(eyes.r,teeth.r),0.0,1.0);"
            "m*=1.0-protection*features;"
            "return vec4(m,m,m,1.0); }");
        // Independent frequency separation: texture and structure bands are compressed
        // in luminance, with feature/edge attenuation, keeping chroma and alpha stable.
        k[@"detail"] = PGKernel(@
            "kernel vec4 pgDetail(__sample p,__sample fine,__sample broad,float strength,float protect) {"
            "vec4 src=unpremultiply(p); vec3 c=src.rgb;"
            "vec3 t=unpremultiply(fine).rgb; vec3 b=unpremultiply(broad).rgb;"
            "vec3 w=vec3(0.299,0.587,0.114);"
            "float y=dot(c,w); float yf=dot(t,w); float yb=dot(b,w);"
            "float f=y-yf; float mid=yf-yb; float structure=length(c-b);"
            "float middle=smoothstep(0.04,0.22,y)*(1.0-smoothstep(0.82,0.98,y));"
            "float texture=smoothstep(0.001,0.010,abs(f));"
            "float edge=1.0-smoothstep(0.08,0.26,structure);"
            "float dark=(1.0-smoothstep(0.16,0.42,y))*smoothstep(0.0015,0.018,abs(f)+0.35*abs(y-yb));"
            "float light=smoothstep(0.70,0.96,y)*smoothstep(0.0025,0.024,abs(f));"
            "float ridge=smoothstep(0.10,0.30,structure)*smoothstep(0.002,0.020,abs(f)+0.85*abs(y-yb));"
            "float feature=max(dark*0.96,max(light*0.52,ridge*0.84));"
            "float gain=clamp(strength*middle*mix(0.56,0.88,texture),0.0,1.05);"
            "gain*=1.0-protect*feature*mix(0.42,0.82,texture);"
            "float delta=-gain*(f*mix(0.18,0.76,edge)+mid*mix(0.08,0.30,edge));"
            "float target=clamp(y+delta,0.0,1.0); float ratio=clamp(target/max(y,0.001),0.82,1.18);"
            "vec3 outColor=c*mix(1.0,ratio,0.88);"
            "outColor+=vec3((target-dot(outColor,w))*0.08);"
            "return premultiply(vec4(clamp(outColor,0.0,1.0),src.a)); }");
        k[@"maskedMix"] = PGKernel(@
            "kernel vec4 pgMaskedMix(__sample source,__sample effect,__sample mask,float amount) {"
            "vec4 s=unpremultiply(source); vec4 e=unpremultiply(effect);"
            "return premultiply(vec4(mix(s.rgb,e.rgb,clamp(mask.r*amount,0.0,1.0)),s.a)); }");
        k[@"even"] = PGKernel(@
            "kernel vec4 pgEven(__sample source,__sample broad,float amount) {"
            "vec4 s=unpremultiply(source); vec3 b=unpremultiply(broad).rgb;"
            "vec3 w=vec3(0.299,0.587,0.114); float y=dot(s.rgb,w); float yb=dot(b,w);"
            "vec3 baseChroma=s.rgb-vec3(y); vec3 smoothChroma=b-vec3(yb);"
            "float guard=1.0-smoothstep(0.12,0.35,length(s.rgb-b));"
            "vec3 c=vec3(y)+mix(baseChroma,smoothChroma,amount*0.78*guard);"
            "return premultiply(vec4(clamp(c,0.0,1.0),s.a)); }");
        // These six looks are newly authored color transforms, not the shipped LUTs.
        k[@"preset"] = PGKernel(@
            "kernel vec4 pgPreset(__sample source,float preset) {"
            "vec4 s=unpremultiply(source); vec3 c=s.rgb; float y=dot(c,vec3(0.299,0.587,0.114));"
            "if(preset<1.5){c=mix(vec3(y),c,0.91);c+=vec3(0.038,0.027,0.012)*(1.0-y);}"
            "else if(preset<2.5){c=mix(vec3(y),c,0.89);c+=vec3(0.003,0.020,0.038)*(1.0-y);}"
            "else if(preset<3.5){c=mix(vec3(y),c,1.04);c+=vec3(0.037,0.011,-0.018)*(1.0-y);}"
            "else if(preset<4.5){c=mix(vec3(y),c,0.94);c+=vec3(0.032,0.001,0.018)*(1.0-y);}"
            "else if(preset<5.5){c=pow(max(c,vec3(0.0)),vec3(1.08));c+=vec3(0.024,0.003,-0.018)*(1.0-y);}"
            "else{c=pow(max(c,vec3(0.0)),vec3(1.20));c=mix(vec3(dot(c,vec3(0.299,0.587,0.114))),c,1.06);"
            "c+=vec3(0.030,0.007,-0.022)*(1.0-y);}"
            "return premultiply(vec4(clamp(c,0.0,1.0),s.a)); }");
        k[@"teeth"] = PGKernel(@
            "kernel vec4 pgTeeth(__sample source,__sample mask,float amount) {"
            "vec4 s=unpremultiply(source);vec3 c=clamp(s.rgb,0.0,1.0);"
            "float y=dot(c,vec3(0.299,0.587,0.114));float hi=max(c.r,max(c.g,c.b));float lo=min(c.r,min(c.g,c.b));"
            "float sat=(hi-lo)/max(hi,0.0001);"
            "float gate=smoothstep(0.26,0.56,max(y,hi*0.86))*(1.0-smoothstep(0.52,0.86,sat));"
            "float weight=clamp(pow(max(0.0,smoothstep(0.08,0.92,mask.r)*gate*amount),0.90)*(1.02+0.18*amount),0.0,0.88);"
            "float yellow=max(0.0,(c.r+c.g)*0.5-c.b);"
            "vec3 neutral=mix(c,vec3(y),0.16+0.22*amount);"
            "neutral+=yellow*vec3(-0.070*amount,-0.028*amount,0.18+0.28*amount);"
            "neutral+=(vec3(1.0)-neutral)*(0.045+0.155*amount);"
            "return premultiply(vec4(mix(c,clamp(neutral,0.0,1.0),weight),s.a)); }");
        k[@"eyes"] = PGKernel(@
            "kernel vec4 pgEyes(__sample source,__sample mask,float amount) {"
            "vec4 s=unpremultiply(source);float y=dot(s.rgb,vec3(0.299,0.587,0.114));"
            "float weight=clamp(mask.r,0.0,1.0)*amount*smoothstep(0.08,0.32,y);"
            "vec3 c=s.rgb+(vec3(1.0)-s.rgb)*(0.18*weight);"
            "return premultiply(vec4(clamp(c,0.0,1.0),s.a)); }");
        k[@"debug"] = PGKernel(@
            "kernel vec4 pgDebug(__sample source,__sample mask,float invert) {"
            "vec4 s=unpremultiply(source);float m=clamp(mask.r,0.0,1.0);"
            "m=mix(m,1.0-m,invert);return premultiply(vec4(vec3(m),s.a)); }");
        kernels = [k copy];
    });
    return kernels;
}

@implementation PGBeautyRenderer
- (CIImage *)processImage:(CIImage *)image settings:(PGBeautySettings)s
                 skinMask:(CIImage *)skinMask teethMask:(CIImage *)teethMask
                  eyeMask:(CIImage *)eyeMask error:(NSError **)error {
    if (error) *error = nil;
    CGRect extent = image.extent;
    if (!image || CGRectIsEmpty(extent) || CGRectIsInfinite(extent) ||
        !isfinite(extent.origin.x) || !isfinite(extent.origin.y) ||
        !isfinite(extent.size.width) || !isfinite(extent.size.height)) {
        if (error) *error = [NSError errorWithDomain:@"PGBeautyRenderer" code:1
                       userInfo:@{NSLocalizedDescriptionKey:@"The source image needs a finite nonempty extent."}];
        return nil;
    }
    float mix = PGClamp(s.mix, 0, 1);
    if (mix == 0 && !s.showMask) return image;
    NSDictionary *k = PGKernels();
    if (k.count != 10) {
        if (error) *error = [NSError errorWithDomain:@"PGBeautyRenderer" code:2
                       userInfo:@{NSLocalizedDescriptionKey:@"The beauty image kernels could not be compiled."}];
        return nil;
    }
    @try {
        float amount = PGClamp(s.amount,0,1);
        float local = PGClamp(s.midtoneDetail,0,2)*0.5f;
        float global = PGClamp(s.highPassDetail,0,1);
        float brightness = PGClamp(s.skinBrightness,0,1);
        float hue = PGClamp(s.skinHue,-30,30);
        float saturation = PGClamp(s.skinSaturation,-100,100);
        float even = PGClamp(s.skinEvenTone,0,1);
        float sharpness = PGClamp(s.sharpness,0,2);
        float teeth = PGClamp(s.teethWhitening,0,1);
        float eyes = PGClamp(s.eyeBrightening,0,1);
        BOOL needsSkin = local*amount>0 || brightness>0 || hue!=0 || saturation!=0 || even>0 ||
                         (s.skinTonePreset>0 && s.skinTonePreset<=6) || (s.showMask && s.debugChannel==0);
        CIImage *black = [[CIImage imageWithColor:[CIColor colorWithRed:0 green:0 blue:0 alpha:1]] imageByCroppingToRect:extent];
        CIImage *teethInput = teethMask ? [teethMask imageByCroppingToRect:extent] : black;
        CIImage *eyeInput = eyeMask ? [eyeMask imageByCroppingToRect:extent] : black;
        CIImage *raw = skinMask ? [skinMask imageByCroppingToRect:extent] : black;
        CIImage *mask = black;
        CGFloat radius = PGClamp(s.radius,1,40);
        if (needsSkin) {
            if (!skinMask) {
                CIImage *gb = PGApply(k[@"overlay"],extent,@[image]);
                raw = PGApply(k[@"candidate"],extent,@[image,gb,PGBlur(gb,radius,extent)]);
            }
            float soft = PGClamp(s.maskSoftness,0,1);
            float threshold = PGClamp(s.maskThreshold,0,255)/255.f;
            mask = PGApply(k[@"mask"],extent,@[raw,PGBlur(raw,0.35+soft*radius*0.35,extent),
                          image,PGBlur(image,1.5,extent),eyeInput,teethInput,
                          @(threshold),@(soft),@(PGClamp(s.maskEdgeProtect,0,1)),
                          @(s.featureProtection ? 1 : 0),@(s.invertMask ? 1 : 0)]);
        }
        if (s.showMask) {
            // Popup values select coverage source; changing the popup alone must
            // never enable a preview. Feature masks retain their supplied coverage.
            CIImage *preview = s.debugChannel==1 ? teethInput : (s.debugChannel==2 ? eyeInput : mask);
            float invert = s.debugChannel==1 || s.debugChannel==2 ? (s.invertMask ? 1 : 0) : 0;
            return PGApply(k[@"debug"],extent,@[image,preview,@(invert)]);
        }
        CIImage *result = image;
        if (local*amount>0) {
            // The shipped helper derives both blur scales from the detail strength.
            CGFloat fine = fmin(7.4,2.275+3.15*pow(local,0.72)+0.95*local);
            CGFloat broad = fmin(16,(2.55+0.45*local)*fine+1.1+1.3*local);
            float compression = 0.12+2.4*powf(local,2.15)+1.25*local;
            CIImage *detail = PGApply(k[@"detail"],extent,@[result,PGBlur(result,fine,extent),
                            PGBlur(result,broad,extent),@(compression),@(s.featureProtection ? 1 : 0)]);
            result = PGApply(k[@"maskedMix"],extent,@[result,detail,mask,@(amount)]);
        }
        CIImage *color = result;
        if (brightness>0) {
            float shoulder = PGClamp((brightness-0.56f)/0.44f,0,1);
            float gain = 0.88f*powf(brightness,1.24f)+0.12f*shoulder*shoulder*(3-2*shoulder);
            color = [color imageByApplyingFilter:@"CIExposureAdjust" withInputParameters:@{kCIInputEVKey:@(gain*0.95f)}];
        }
        if (hue!=0) color = [color imageByApplyingFilter:@"CIHueAdjust" withInputParameters:@{kCIInputAngleKey:@(hue*M_PI/180.0)}];
        if (saturation!=0) color = [color imageByApplyingFilter:@"CIColorControls" withInputParameters:@{kCIInputSaturationKey:@(1+saturation/100.f)}];
        if (even>0) color = PGApply(k[@"even"],extent,@[color,PGBlur(color,radius*1.8,extent),@(even)]);
        if (color!=result) result = PGApply(k[@"maskedMix"],extent,@[result,color,mask,@1]);
        if (sharpness*amount>0) result = [result imageByApplyingFilter:@"CISharpenLuminance"
                                    withInputParameters:@{kCIInputSharpnessKey:@(sharpness*amount)}];
        if (s.skinTonePreset>0 && s.skinTonePreset<=6) {
            CIImage *preset = PGApply(k[@"preset"],extent,@[result,@(s.skinTonePreset)]);
            result = PGApply(k[@"maskedMix"],extent,@[result,preset,mask,@1]);
        }
        if (global>0) {
            CGFloat fine = fmin(7.4,2.275+3.15*pow(global,0.72)+0.95*global);
            CGFloat broad = fmin(16,(2.55+0.45*global)*fine+1.1+1.3*global);
            float compression = 0.12+2.4*powf(global,2.15)+1.25*global;
            result = PGApply(k[@"detail"],extent,@[result,PGBlur(result,fine,extent),
                             PGBlur(result,broad,extent),@(compression),@0]);
        }
        if (teeth>0 && teethMask) result = PGApply(k[@"teeth"],extent,@[result,teethInput,@(teeth)]);
        if (eyes>0 && eyeMask) result = PGApply(k[@"eyes"],extent,@[result,eyeInput,@(eyes)]);
        if (mix<1) {
            CIImage *white = [[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]] imageByCroppingToRect:extent];
            result = PGApply(k[@"maskedMix"],extent,@[image,result,white,@(mix)]);
        }
        if (!result) {
            if (error) *error = [NSError errorWithDomain:@"PGBeautyRenderer" code:3
                       userInfo:@{NSLocalizedDescriptionKey:@"Core Image could not construct the beauty render graph."}];
            return nil;
        }
        return [result imageByCroppingToRect:extent];
    } @catch (NSException *exception) {
        if (error) *error = [NSError errorWithDomain:@"PGBeautyRenderer" code:4
                       userInfo:@{NSLocalizedDescriptionKey:exception.reason ?: @"Invalid Core Image render state."}];
        return nil;
    }
}
@end
