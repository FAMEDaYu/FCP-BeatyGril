#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import "PGBeautyRenderer.h"
#include <math.h>

static const int W=96,H=64;
static int failures=0,checks=0;
static void Check(BOOL pass,NSString *message) {
    checks++;
    if (!pass) { failures++; fprintf(stderr,"FAIL: %s\n",message.UTF8String); }
}
static CIImage *Image(const float *pixels,CGRect extent) {
    NSData *data=[NSData dataWithBytes:pixels length:W*H*4*sizeof(float)];
    return [[CIImage imageWithBitmapData:data bytesPerRow:W*4*sizeof(float)
                    size:CGSizeMake(W,H) format:kCIFormatRGBAf colorSpace:nil]
                    imageByApplyingTransform:CGAffineTransformMakeTranslation(extent.origin.x,extent.origin.y)];
}
static float *Render(CIContext *context,CIImage *image,CGRect extent) {
    float *p=calloc(W*H*4,sizeof(float));
    if (image) [context render:image toBitmap:p rowBytes:W*4*sizeof(float)
                         bounds:extent format:kCIFormatRGBAf colorSpace:nil];
    return p;
}
static float Difference(float *a,float *b,int x0,int x1) {
    float sum=0;int n=0;
    for(int y=8;y<H-8;y++) for(int x=x0;x<x1;x++) for(int c=0;c<3;c++) {
        sum+=fabsf(a[(y*W+x)*4+c]-b[(y*W+x)*4+c]); n++;
    }
    return sum/MAX(1,n);
}
static float Texture(float *a,int x0,int x1) {
    float sum=0;int n=0;
    for(int y=8;y<H-8;y++) for(int x=x0+1;x<x1;x++) {
        sum+=fabsf(a[(y*W+x)*4]-a[(y*W+x-1)*4]);n++;
    }
    return sum/MAX(1,n);
}
int main(void) { @autoreleasepool {
    NSDictionary *options=@{kCIContextWorkingColorSpace:[NSNull null],kCIContextOutputColorSpace:[NSNull null]};
    id<MTLDevice> device=MTLCreateSystemDefaultDevice();
    CIContext *context=device ? [CIContext contextWithMTLDevice:device options:options] : [CIContext contextWithOptions:options];
    PGBeautyRenderer *renderer=[PGBeautyRenderer new];
    CGRect extent=CGRectMake(13,-9,W,H);
    float *p=calloc(W*H*4,sizeof(float)),*mask=calloc(W*H*4,sizeof(float));
    for(int y=0;y<H;y++) for(int x=0;x<W;x++) {
        int i=(y*W+x)*4;float noise=((x+y)%2 ? 1 : -1)*0.045;
        p[i]=0.56+noise;p[i+1]=0.40+noise;p[i+2]=0.31+noise;p[i+3]=1;
        mask[i]=mask[i+1]=mask[i+2]=(x<W/2 ? 1:0);mask[i+3]=1;
    }
    CIImage *source=Image(p,extent),*half=Image(mask,extent);
    CIImage *white=[[CIImage imageWithColor:[CIColor colorWithRed:1 green:1 blue:1 alpha:1]] imageByCroppingToRect:extent];
    PGBeautySettings s=PGBeautyDefaults();NSError *error=nil;
    CIImage *output=[renderer processImage:source settings:s skinMask:white teethMask:nil eyeMask:nil error:&error];
    Check(output!=nil && error==nil,@"All custom kernels compile and construct a graph");
    Check(CGRectEqualToRect(output.extent,extent),@"Nonzero/negative source origin and finite extent survive");
    float *base=Render(context,source,extent),*neutral=Render(context,output,extent);
    Check(Difference(base,neutral,4,W-4)<0.00001,@"Neutral controls produce identity");free(neutral);
    s.midtoneDetail=1;s.maskEdgeProtect=0;s.featureProtection=0;
    output=[renderer processImage:source settings:s skinMask:white teethMask:nil eyeMask:nil error:&error];
    float *smooth=Render(context,output,extent);
    Check(Texture(smooth,8,W-8)<Texture(base,8,W-8)*0.82,@"Midtone compression reduces fine texture");
    s.mix=0;
    float *bypass=Render(context,[renderer processImage:source settings:s skinMask:white teethMask:nil eyeMask:nil error:&error],extent);
    Check(Difference(base,bypass,4,W-4)<0.00001,@"Mix zero is exact bypass");free(bypass);
    s=PGBeautyDefaults();s.skinBrightness=1;s.maskSoftness=0;s.maskEdgeProtect=0;
    float *bright=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    Check(Difference(base,bright,6,40)>0.08,@"Skin brightness has a substantial visible effect");
    Check(Difference(base,bright,56,88)<0.00001,@"Skin-only color change respects the supplied mask");
    s.invertMask=1;
    float *inverse=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    Check(Difference(base,inverse,6,40)<0.00001 && Difference(base,inverse,56,88)>0.08,@"Invert mask selects the complementary region");
    free(bright);free(inverse);
    s=PGBeautyDefaults();s.showMask=1;s.maskSoftness=0;s.maskEdgeProtect=0;
    float *preview=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    Check(preview[(32*W+20)*4]>0.99 && preview[(32*W+72)*4]<0.01,@"Mask preview exposes actual coverage");free(preview);
    s=PGBeautyDefaults();s.highPassDetail=1;
    float *global=Render(context,[renderer processImage:source settings:s skinMask:nil teethMask:nil eyeMask:nil error:&error],extent);
    Check(Texture(global,8,W-8)<Texture(base,8,W-8)*0.72,@"Global high-frequency compression works without a skin mask");free(global);
    s=PGBeautyDefaults();s.teethWhitening=1;
    float *whiten=Render(context,[renderer processImage:source settings:s skinMask:nil teethMask:half eyeMask:nil error:&error],extent);
    Check(whiten[(32*W+20)*4+2]>base[(32*W+20)*4+2]+0.035,@"Teeth whitening neutralizes yellow and lifts blue");
    Check(Difference(base,whiten,56,88)<0.00001,@"Teeth whitening is spatially confined");free(whiten);
    s=PGBeautyDefaults();s.eyeBrightening=1;
    float *eyes=Render(context,[renderer processImage:source settings:s skinMask:nil teethMask:nil eyeMask:half error:&error],extent);
    Check(Difference(base,eyes,6,40)>0.04 && Difference(base,eyes,56,88)<0.00001,@"Eye brightening is visible and spatially confined");free(eyes);
    for(int preset=1;preset<=6;preset++) {
        s=PGBeautyDefaults();s.skinTonePreset=preset;s.maskSoftness=0;s.maskEdgeProtect=0;
        float *look=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
        Check(Difference(base,look,6,40)>0.002 && Difference(base,look,56,88)<0.00001,
              [NSString stringWithFormat:@"Independent skin preset %d changes only skin",preset]);free(look);
    }
    s=PGBeautyDefaults();s.skinHue=30;s.maskSoftness=0;s.maskEdgeProtect=0;
    float *hue=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    Check(Difference(base,hue,6,40)>0.025 && Difference(base,hue,56,88)<0.00001,@"Hue rotates selected skin without changing the rest");free(hue);
    s.skinHue=0;s.skinSaturation=-100;
    float *desaturated=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    int center=(32*W+20)*4;
    Check(fabsf(desaturated[center]-desaturated[center+1])<0.0002 && fabsf(desaturated[center+1]-desaturated[center+2])<0.0002,@"Minus 100 saturation produces neutral gray skin");free(desaturated);
    s=PGBeautyDefaults();s.sharpness=1;
    float *sharp=Render(context,[renderer processImage:source settings:s skinMask:nil teethMask:nil eyeMask:nil error:&error],extent);
    Check(Texture(sharp,8,W-8)>Texture(base,8,W-8)*1.05,@"Sharpening increases local edge contrast");free(sharp);
    s=PGBeautyDefaults();s.midtoneDetail=1;s.maskSoftness=0;s.maskEdgeProtect=0;s.featureProtection=1;
    float *protected=Render(context,[renderer processImage:source settings:s skinMask:white teethMask:nil eyeMask:half error:&error],extent);
    Check(Difference(base,protected,6,40)<0.00001 && Texture(protected,56,88)<Texture(base,56,88)*0.82,@"Feature protection retains eye detail while smoothing nearby skin");free(protected);
    s=PGBeautyDefaults();s.showMask=1;s.maskSoftness=0;s.maskEdgeProtect=0;s.maskThreshold=255;
    float *strictMask=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    s.maskThreshold=0;
    float *looseMask=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    Check(looseMask[(32*W+20)*4]>=strictMask[(32*W+20)*4] && looseMask[(32*W+72)*4]==0,@"Mask threshold keeps zero coverage empty");free(strictMask);free(looseMask);
    CIImage *grayMask=[[CIImage imageWithColor:[CIColor colorWithRed:0.5 green:0.5 blue:0.5 alpha:1]] imageByCroppingToRect:extent];
    s.maskThreshold=220;
    float *highThreshold=Render(context,[renderer processImage:source settings:s skinMask:grayMask teethMask:nil eyeMask:nil error:&error],extent);
    s.maskThreshold=60;
    float *lowThreshold=Render(context,[renderer processImage:source settings:s skinMask:grayMask teethMask:nil eyeMask:nil error:&error],extent);
    Check(highThreshold[(32*W+20)*4]<0.01 && lowThreshold[(32*W+20)*4]>0.99,@"Mask threshold materially changes intermediate confidence coverage");free(highThreshold);free(lowThreshold);
    // Chroma-only speckle should be reduced while its luminance stays stable.
    float *colorNoise=calloc(W*H*4,sizeof(float));
    for(int y=0;y<H;y++)for(int x=0;x<W;x++){
        int i=(y*W+x)*4;float n=((x+y)%2 ? 1:-1)*0.055;
        colorNoise[i]=0.56+n;colorNoise[i+1]=0.40-n*0.299/0.587;colorNoise[i+2]=0.31;colorNoise[i+3]=1;
    }
    CIImage *speckle=Image(colorNoise,extent);s=PGBeautyDefaults();s.skinEvenTone=1;s.maskEdgeProtect=0;
    float *evenColor=Render(context,[renderer processImage:speckle settings:s skinMask:white teethMask:nil eyeMask:nil error:&error],extent);
    float before=Texture(colorNoise,8,W-8),after=Texture(evenColor,8,W-8);
    Check(after<before*0.5,@"Even tone reduces chromatic skin mottling");
    float oldY=colorNoise[center]*0.299+colorNoise[center+1]*0.587+colorNoise[center+2]*0.114;
    float newY=evenColor[center]*0.299+evenColor[center+1]*0.587+evenColor[center+2]*0.114;
    Check(fabsf(oldY-newY)<0.001,@"Even tone preserves local luminance");free(colorNoise);free(evenColor);
    // Mask channel selection remains dormant until the preview checkbox is enabled.
    CIImage *quarterMask=[[CIImage imageWithColor:[CIColor colorWithRed:0.25 green:0.25 blue:0.25 alpha:1]] imageByCroppingToRect:extent];
    CIImage *eyeCoverage=[[CIImage imageWithColor:[CIColor colorWithRed:0.8 green:0.8 blue:0.8 alpha:1]] imageByCroppingToRect:extent];
    for(int channel=0;channel<3;channel++){
        s=PGBeautyDefaults();s.debugChannel=channel;
        float *normal=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:quarterMask eyeMask:eyeCoverage error:&error],extent);
        Check(Difference(base,normal,4,W-4)<0.00001,[NSString stringWithFormat:@"Channel %d does not enable preview by itself",channel]);free(normal);
        s.showMask=1;s.maskSoftness=0;s.maskEdgeProtect=0;s.featureProtection=0;
        for(int invert=0;invert<2;invert++){
            s.invertMask=invert;
            float *shown=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:quarterMask eyeMask:eyeCoverage error:&error],extent);
            float expected=channel==0 ? 1 : (channel==1 ? 0.25 : 0.8);
            if(invert)expected=1-expected;
            Check(fabsf(shown[(32*W+20)*4]-expected)<0.0002,[NSString stringWithFormat:@"Preview channel %d uses its supplied mask (invert %d)",channel,invert]);free(shown);
        }
    }
    float *looks[7]={0};
    for(int preset=0;preset<=6;preset++){
        s=PGBeautyDefaults();s.skinTonePreset=preset;s.maskSoftness=0;s.maskEdgeProtect=0;
        looks[preset]=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    }
    Check(Difference(base,looks[0],4,W-4)<0.00001,@"Original color preset is exact identity");
    Check(looks[2][center+2]-looks[2][center]>looks[3][center+2]-looks[3][center]+0.04,@"Cool white and warm white follow popup order");
    Check(looks[4][center]-looks[4][center+1]>looks[1][center]-looks[1][center+1],@"Rosy white has stronger rosy chroma than natural white");
    float bronzeY=looks[6][center]*0.299+looks[6][center+1]*0.587+looks[6][center+2]*0.114;
    float wheatY=looks[5][center]*0.299+looks[5][center+1]*0.587+looks[5][center+2]*0.114;
    float sourceY=base[center]*0.299+base[center+1]*0.587+base[center+2]*0.114;
    Check(bronzeY<wheatY && bronzeY<sourceY-0.025 && looks[6][center]>looks[6][center+2],@"Bronze is a darker warm brown than wheat");
    for(int preset=0;preset<=6;preset++)free(looks[preset]);
    // The renderer's optional blend is linear once; a host that also blends must
    // pass mix=1 and blend the complete processed image against the original.
    s=PGBeautyDefaults();s.skinBrightness=1;s.skinHue=14;s.skinSaturation=20;s.maskSoftness=0;s.maskEdgeProtect=0;
    float *fullEffect=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    s.mix=0.5;
    float *halfEffect=Render(context,[renderer processImage:source settings:s skinMask:half teethMask:nil eyeMask:nil error:&error],extent);
    BOOL linearMix=YES;
    for(int i=0;i<W*H*4;i++)if(fabsf(halfEffect[i]-(base[i]+fullEffect[i])*0.5f)>0.0002)linearMix=NO;
    Check(linearMix,@"Combined color controls receive exactly one linear global blend");free(fullEffect);free(halfEffect);
    // Every operation must preserve transparency rather than creating halos/opaque pixels.
    for(int i=0;i<W*H;i++){p[i*4]*=0.4;p[i*4+1]*=0.4;p[i*4+2]*=0.4;p[i*4+3]=0.4;}
    CIImage *transparent=Image(p,extent);s=PGBeautyDefaults();s.midtoneDetail=1;s.skinBrightness=1;s.teethWhitening=1;s.eyeBrightening=1;s.skinTonePreset=3;s.highPassDetail=1;
    float *alpha=Render(context,[renderer processImage:transparent settings:s skinMask:white teethMask:half eyeMask:half error:&error],extent);
    BOOL alphaOK=YES,finite=YES;
    for(int i=0;i<W*H;i++){if(fabsf(alpha[i*4+3]-0.4f)>0.0002)alphaOK=NO;for(int c=0;c<4;c++)if(!isfinite(alpha[i*4+c]))finite=NO;}
    Check(alphaOK,@"Combined beauty pipeline preserves fractional alpha");Check(finite,@"Combined beauty pipeline produces finite pixels");free(alpha);
    // Explicit failure path for unbounded images.
    CIImage *invalid=[renderer processImage:[CIImage imageWithColor:[CIColor whiteColor]] settings:s skinMask:nil teethMask:nil eyeMask:nil error:&error];
    Check(invalid==nil && error!=nil,@"Unbounded input produces a useful error");
    free(base);free(smooth);free(mask);free(p);
    printf("Beauty renderer: %d checks, %d failures (%s).\n",checks,failures,device ? "Metal" : "default Core Image");
    return failures ? 1:0;
}}
