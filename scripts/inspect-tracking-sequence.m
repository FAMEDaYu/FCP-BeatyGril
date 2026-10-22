// Offline diagnostics: actual detector/tracker, scalar statistics only.
// No image, full landmark array, host edit, or reference execution is produced.
#import <AVFoundation/AVFoundation.h>
#import "../FCP-BeautyGirl/FCP-BeautyGirl/Plugin/PGFaceProcessor.m"

static double ShapeRMS(NSDictionary *a, NSDictionary *b, NSUInteger first, NSUInteger last) {
    NSArray *x=a[@"points76"], *y=b[@"points76"];
    if(x.count!=76 || y.count!=76) return NAN;
    CGRect old=PGArrayRect(a[@"box"]), current=PGArrayRect(b[@"box"]);
    if(!PGValidRect(old)||!PGValidRect(current)) return NAN;
    double sum=0;
    for(NSUInteger i=first;i<=last;i++) {
        CGPoint p=PGRemapPoint(x[i],old,current);
        double dx=(p.x-[y[i][0] doubleValue])/current.size.width;
        double dy=(p.y-[y[i][1] doubleValue])/current.size.height;
        sum+=dx*dx+dy*dy;
    }
    return sqrt(sum/(last-first+1));
}
static id NumberOrNull(double x) {return isfinite(x)?@(x):NSNull.null;}
static double EyeRMS(NSDictionary *a, NSDictionary *b) {
    CGRect old=PGArrayRect(a[@"box"]), current=PGArrayRect(b[@"box"]);
    if(!PGValidRect(old)||!PGValidRect(current))return NAN;
    double sum=0;NSUInteger n=0;
    for(NSString *key in @[@"leftEye",@"rightEye"]) {
        NSArray *x=a[key],*y=b[key];if(!x.count||x.count!=y.count)return NAN;
        for(NSUInteger i=0;i<x.count;i++) {
            CGPoint p=PGRemapPoint(x[i],old,current);
            double dx=(p.x-[y[i][0] doubleValue])/current.size.width;
            double dy=(p.y-[y[i][1] doubleValue])/current.size.height;
            sum+=dx*dx+dy*dy;n++;
        }
    }
    return n?sqrt(sum/n):NAN;
}

int main(int argc,const char *argv[]) {@autoreleasepool {
    if(argc!=6) {fprintf(stderr,"usage: inspect-tracking-sequence <video> <output.json> <fps> <decode-longest> <timeline-offset-seconds>\n");return 2;}
    NSString *path=@(argv[1]), *output=@(argv[2]);
    int fps=atoi(argv[3]), longest=atoi(argv[4]);double offset=atof(argv[5]);
    if(fps<1||fps>120||longest<128||longest>4096||!isfinite(offset))return 2;
    AVURLAsset *asset=[AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:path] options:nil];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    double duration=CMTimeGetSeconds(asset.duration);
    AVAssetTrack *video=[[asset tracksWithMediaType:AVMediaTypeVideo] firstObject];
    if(!video||!isfinite(duration)||duration<=0)return 2;
    double nominal=video.nominalFrameRate;
    AVAssetImageGenerator *generator=[[AVAssetImageGenerator alloc] initWithAsset:asset];
    generator.appliesPreferredTrackTransform=YES;generator.maximumSize=CGSizeMake(longest,longest);
    generator.requestedTimeToleranceBefore=kCMTimeZero;generator.requestedTimeToleranceAfter=kCMTimeZero;
    PGFaceProcessor *detector=[PGFaceProcessor new];PGRealtimeFaceTracker *tracker=[PGRealtimeFaceTracker new];
    PGBeautySettings settings=PGBeautyDefaults();settings.singleFace=0;settings.trackingEnabled=0;
    settings.fastMultiFace=0;settings.faceThin=1;settings.faceBigEye=.9035486629353234;
    NSMutableArray *rows=[NSMutableArray new];NSDictionary *priorRaw=nil,*priorOutput=nil;
    NSUInteger empty=0,partial=0,held=0,low=0,errors=0,multiple=0,invalidOutput=0,duplicateSourceFrames=0;
    CMTime previousActual=kCMTimeInvalid;NSUInteger width=0,height=0;
    for(int frame=0;frame<(int)ceil(duration*fps);frame++) {@autoreleasepool {
        double requested=(double)frame/fps;if(requested>=duration)break;
        NSError *error=nil;CMTime actual=kCMTimeInvalid;
        CGImageRef cg=[generator copyCGImageAtTime:CMTimeMakeWithSeconds(requested,60000) actualTime:&actual error:&error];
        if(!cg){errors++;fprintf(stderr,"decode failed at %.3f: %s\n",requested,error.localizedDescription.UTF8String);continue;}
        if(CMTIME_IS_VALID(previousActual)&&CMTimeCompare(previousActual,actual)==0)duplicateSourceFrames++;
        previousActual=actual;width=CGImageGetWidth(cg);height=CGImageGetHeight(cg);
        CIImage *image=[CIImage imageWithCGImage:cg];
        NSArray<VNFaceObservation *> *observations=[detector observationsInImage:image settings:settings error:&error];
        if(!observations)errors++;
        NSMutableArray *raw=[NSMutableArray new],*faces=[NSMutableArray new];
        for(VNFaceObservation *face in observations)if(PGValidRect(face.boundingBox)&&raw.count<16){[raw addObject:PGGeometry(face)];[faces addObject:face];}
        CMTime time=CMTimeAdd(CMTimeMake(frame,fps),CMTimeMakeWithSeconds(offset,60000));
        NSDictionary *r=[tracker resultForGeometry:raw settings:settings time:time extent:image.extent image:image];
        NSInteger index=[r[@"index"] integerValue];NSDictionary *current=(index>=0&&(NSUInteger)index<raw.count)?raw[index]:nil;
        VNFaceObservation *face=(index>=0&&(NSUInteger)index<faces.count)?faces[index]:nil;
        NSDictionary *stable=[r[@"output"] firstObject];
        double confidence=face.landmarks?face.landmarks.confidence:NAN;
        if(!raw.count)empty++;if(raw.count>1)multiple++;
        if(current&&[current[@"points76"] count]!=76)partial++;
        if(stable&&[stable[@"points76"] count]!=76)invalidOutput++;
        if([r[@"held"] boolValue])held++;
        if(isfinite(confidence)&&confidence<.55)low++;
        CGRect old=PGArrayRect(priorRaw[@"box"]),box=PGArrayRect(current[@"box"]);
        double centerStep=NAN,sizeStep=NAN;
        if(PGValidRect(old)&&PGValidRect(box)){
            centerStep=hypot(CGRectGetMidX(old)-CGRectGetMidX(box),CGRectGetMidY(old)-CGRectGetMidY(box));
            sizeStep=MAX(fabs(box.size.width/old.size.width-1),fabs(box.size.height/old.size.height-1));
        }
        NSMutableDictionary *row=[@{@"frame":@(frame),@"requestedSeconds":@(requested),@"actualSeconds":@(CMTimeGetSeconds(actual)),
            @"faceCount":@(raw.count),@"points76Count":@([current[@"points76"] count]),@"held":r[@"held"],
            @"qualityReason":current?PGGeometryQualityReason(current):@"missingFace",@"resultReason":r[@"reason"]?:@"",@"trackedBoxAvailable":@([r[@"trackedBox"] count]==4),@"landmarkConfidence":NumberOrNull(confidence),@"faceConfidence":NumberOrNull(face?face.confidence:NAN),
            @"rawContourShapeStep":NumberOrNull(ShapeRMS(priorRaw,current,59,75)),
            @"outputContourShapeStep":NumberOrNull(ShapeRMS(priorOutput,stable,59,75)),
            @"rawAllShapeStep":NumberOrNull(ShapeRMS(priorRaw,current,0,75)),
            @"outputAllShapeStep":NumberOrNull(ShapeRMS(priorOutput,stable,0,75)),
            @"rawEyeShapeStep":NumberOrNull(EyeRMS(priorRaw,current)),
            @"bboxCenterStep":NumberOrNull(centerStep),@"bboxRelativeSizeStep":NumberOrNull(sizeStep)} mutableCopy];
        [rows addObject:row];priorRaw=current;priorOutput=stable;CGImageRelease(cg);
        if(frame%50==0)fprintf(stderr,"inspected %d/%d frames\n",frame,(int)ceil(duration*fps));
    }}
#pragma clang diagnostic pop
    NSArray *keys=@[@"rawContourShapeStep",@"outputContourShapeStep",@"rawAllShapeStep",@"outputAllShapeStep",@"rawEyeShapeStep",@"bboxCenterStep",@"bboxRelativeSizeStep",@"landmarkConfidence"];
    NSMutableDictionary *stats=[NSMutableDictionary new];
    for(NSString *key in keys){NSMutableArray *values=[NSMutableArray new];for(NSDictionary *row in rows)if([row[key] isKindOfClass:NSNumber.class])[values addObject:row[key]];[values sortUsingSelector:@selector(compare:)];if(values.count){stats[key]=@{@"n":@(values.count),@"min":values.firstObject,@"median":values[values.count/2],@"p95":values[(NSUInteger)floor((values.count-1)*.95)],@"max":values.lastObject};}}
    NSArray *ranked=[rows sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){double x=[a[@"rawContourShapeStep"] isKindOfClass:NSNumber.class]?[a[@"rawContourShapeStep"] doubleValue]:-1;double y=[b[@"rawContourShapeStep"] isKindOfClass:NSNumber.class]?[b[@"rawContourShapeStep"] doubleValue]:-1;return x>y?NSOrderedAscending:(x<y?NSOrderedDescending:NSOrderedSame);}];
    NSDictionary *summary=@{@"sourceBasename":path.lastPathComponent,@"durationSeconds":@(duration),@"nominalSourceFPS":@(nominal),@"samplingFPS":@(fps),@"decodedSize":@[@(width),@(height)],@"timelineOffsetSeconds":@(offset),@"frames":@(rows.count),@"emptyDetectionFrames":@(empty),@"partial76Frames":@(partial),@"heldFrames":@(held),@"outputWithout76Frames":@(invalidOutput),@"landmarkConfidenceBelow055Frames":@(low),@"multipleFaceFrames":@(multiple),@"decodeOrVisionErrors":@(errors),@"duplicateSourceFramePairs":@(duplicateSourceFrames),@"statistics":stats,@"largestContourChanges":[ranked subarrayWithRange:NSMakeRange(0,MIN(12,ranked.count))],@"scope":@"Independent offline decoding and the current production detector/tracker; not FCP render logs or target execution. Shape steps remove previous bbox translation/scale, but still include actual pose/expression changes."};
    NSDictionary *report=@{@"summary":summary,@"scalarFrames":rows};NSData *data=[NSJSONSerialization dataWithJSONObject:report options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];
    if(!data||![data writeToFile:output atomically:YES])return 1;
    NSData *print=[NSJSONSerialization dataWithJSONObject:summary options:NSJSONWritingPrettyPrinted|NSJSONWritingSortedKeys error:nil];fwrite(print.bytes,1,print.length,stdout);fputc('\n',stdout);
    return 0;
}}
