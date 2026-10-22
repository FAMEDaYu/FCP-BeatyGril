// Entirely authored geometry in the public Vision76 index layout. No image or
// landmark coordinates from a person or the reference plug-in are embedded.
static NSDictionary *PGTrackingTestGeometry(CGRect box, double horizontalShift) {
    NSMutableArray *points=[NSMutableArray new];
    for(NSUInteger i=0;i<76;i++)[points addObject:@[@.5,@.5]];
    const NSUInteger leftEye[]={0,4,5,1,3,2},rightEye[]={7,11,12,8,10,9};
    for(NSUInteger i=0;i<6;i++) {
        double a=2*M_PI*i/6;
        points[leftEye[i]]=@[@(.30+.09*cos(a)),@(.70+.035*sin(a))];
        points[rightEye[i]]=@[@(.70+.09*cos(a)),@(.70+.035*sin(a))];
    }
    points[6]=@[@.30,@.70];points[13]=@[@.70,@.70];
    for(NSUInteger i=14;i<20;i++)points[i]=@[@(.20+.04*(i-14)),@(.82+.025*sin(M_PI*(i-14)/5))];
    for(NSUInteger i=20;i<26;i++)points[i]=@[@(.60+.04*(i-20)),@(.82+.025*sin(M_PI*(i-20)/5))];
    const NSUInteger outer[]={27,28,29,30,31,32,33,34,35,36,37,38,39,26};
    for(NSUInteger i=0;i<14;i++){double a=M_PI-2*M_PI*i/14;points[outer[i]]=@[@(.5+.17*cos(a)),@(.33+.055*sin(a))];}
    const NSUInteger inner[]={42,40,43,45,41,44};
    for(NSUInteger i=0;i<6;i++){double a=M_PI-2*M_PI*i/6;points[inner[i]]=@[@(.5+.10*cos(a)),@(.33+.025*sin(a))];}
    points[46]=@[@.5,@.71];points[47]=@[@.5,@.61];points[48]=@[@.5,@.55];points[49]=@[@.5,@.49];
    points[50]=@[@.58,@.49];points[51]=@[@.55,@.46];points[52]=@[@.5,@.45];points[53]=@[@.45,@.46];
    points[54]=@[@.42,@.49];points[55]=@[@.46,@.51];points[56]=@[@.54,@.51];points[57]=@[@.5,@.46];points[58]=@[@.5,@.47];
    for(NSUInteger i=0;i<17;i++){double a=M_PI+M_PI*i/16;points[59+i]=@[@(.5+.46*cos(a)),@(.73+.69*sin(a))];}
    for(NSUInteger i=0;i<76;i++)points[i]=@[@(box.origin.x+([points[i][0] doubleValue]+horizontalShift)*box.size.width),@(box.origin.y+[points[i][1] doubleValue]*box.size.height)];
    NSMutableDictionary *g=[@{@"box":@[@(box.origin.x),@(box.origin.y),@(box.size.width),@(box.size.height)],@"points76":points,@"landmarkConfidence":@.99} mutableCopy];
    NSArray *names=@[@"leftEye",@"rightEye",@"leftBrow",@"rightBrow",@"nose",@"lips",@"mouth",@"contour"];
    NSArray *indices=@[@[@0,@4,@5,@1,@3,@2],@[@7,@11,@12,@8,@10,@9],@[@14,@15,@16,@17,@18,@19],@[@20,@21,@22,@23,@24,@25],@[@47,@56,@54,@53,@52,@51,@50,@55],@[@27,@28,@29,@30,@31,@32,@33,@34,@35,@36,@37,@38,@39,@26],@[@42,@40,@43,@45,@41,@44],@[@59,@60,@61,@62,@63,@64,@65,@66,@67,@68,@69,@70,@71,@72,@73,@74,@75]];
    for(NSUInteger i=0;i<names.count;i++){NSMutableArray *region=[NSMutableArray new];for(NSNumber *n in indices[i])[region addObject:points[n.unsignedIntegerValue]];g[names[i]]=region;}
    return [g copy];
}
