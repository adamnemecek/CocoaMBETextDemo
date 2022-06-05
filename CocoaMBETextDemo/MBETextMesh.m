#import "MBETextMesh.h"
#import "MBETypes.h"
@import CoreText;

typedef void (^MBEGlyphPositionEnumerationBlock)(CGGlyph glyph,
                                                 NSInteger glyphIndex,
                                                 CGRect glyphBounds);


CGContextRef SDGraphicsGetCurrentContext(void) {
#if SD_UIKIT || SD_WATCH
    return UIGraphicsGetCurrentContext();
#else
    return NSGraphicsContext.currentContext.CGContext;
#endif
}

static void *kNSGraphicsContextScaleFactorKey;

static CGContextRef SDCGContextCreateBitmapContext(CGSize size, BOOL opaque, CGFloat scale) {
    if (scale == 0) {
        // Match `UIGraphicsBeginImageContextWithOptions`, reset to the scale factor of the device’s main screen if scale is 0.
        scale = [NSScreen mainScreen].backingScaleFactor;
    }
    size_t width = ceil(size.width * scale);
    size_t height = ceil(size.height * scale);
    if (width < 1 || height < 1) return NULL;

    //pre-multiplied BGRA for non-opaque, BGRX for opaque, 8-bits per component, as Apple's doc
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGImageAlphaInfo alphaInfo = kCGBitmapByteOrder32Host | (opaque ? kCGImageAlphaNoneSkipFirst : kCGImageAlphaPremultipliedFirst);
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, space, kCGBitmapByteOrderDefault | alphaInfo);
    CGColorSpaceRelease(space);
    if (!context) {
        return NULL;
    }
    CGContextScaleCTM(context, scale, scale);

    return context;
}

@import ObjectiveC.runtime;

void SDGraphicsBeginImageContextWithOptions(CGSize size, BOOL opaque, CGFloat scale) {
#if SD_UIKIT || SD_WATCH
    UIGraphicsBeginImageContextWithOptions(size, opaque, scale);
#else
    CGContextRef context = SDCGContextCreateBitmapContext(size, opaque, scale);
    if (!context) {
        return;
    }
    NSGraphicsContext *graphicsContext = [NSGraphicsContext graphicsContextWithCGContext:context flipped:NO];
    objc_setAssociatedObject(graphicsContext, &kNSGraphicsContextScaleFactorKey, @(scale), OBJC_ASSOCIATION_RETAIN);
    CGContextRelease(context);
    [NSGraphicsContext saveGraphicsState];
    NSGraphicsContext.currentContext = graphicsContext;
#endif
}

void SDGraphicsEndImageContext(void) {
#if SD_UIKIT || SD_WATCH
    UIGraphicsEndImageContext();
#else
    [NSGraphicsContext restoreGraphicsState];
#endif
}

void SDGraphicsBeginImageContext(CGSize size) {
#if SD_UIKIT || SD_WATCH
    UIGraphicsBeginImageContext(size);
#else
    SDGraphicsBeginImageContextWithOptions(size, NO, 1.0);
#endif
}

@implementation MBETextMesh

@synthesize vertexBuffer=_vertexBuffer;
@synthesize indexBuffer=_indexBuffer;

- (instancetype)initWithString:(NSString *)string
                        inRect:(CGRect)rect
                      withFontAtlas:(MBEFontAtlas *)fontAtlas
                        atSize:(CGFloat)fontSize
                        device:(id<MTLDevice>)device
{
    if ((self = [super init]))
    {
        [self buildMeshWithString:string inRect:rect withFont:fontAtlas atSize:fontSize device:device];
    }
    return self;
}

- (void)buildMeshWithString:(NSString *)string
                     inRect:(CGRect)rect
                   withFont:(MBEFontAtlas *)fontAtlas
                     atSize:(CGFloat)fontSize
                     device:(id<MTLDevice>)device
{
    NSFont *font = [fontAtlas.parentFont fontWithSize:fontSize];
    NSDictionary *attributes = @{ NSFontAttributeName : font };
    NSAttributedString *attrString = [[NSAttributedString alloc] initWithString:string attributes:attributes];
    CFRange stringRange = CFRangeMake(0, attrString.length);
    CGPathRef rectPath = CGPathCreateWithRect(rect, NULL);
    CTFramesetterRef framesetter = CTFramesetterCreateWithAttributedString((__bridge CFAttributedStringRef)attrString);
    CTFrameRef frame = CTFramesetterCreateFrame(framesetter, stringRange, rectPath, NULL);

    __block CFIndex frameGlyphCount = 0;
    NSArray *lines = (__bridge id)CTFrameGetLines(frame);
    [lines enumerateObjectsUsingBlock:^(id lineObject, NSUInteger lineIndex, BOOL *stop) {
        frameGlyphCount += CTLineGetGlyphCount((__bridge CTLineRef)lineObject);
    }];

    const NSInteger vertexCount = frameGlyphCount * 4;
    const NSInteger indexCount = frameGlyphCount * 6;
    MBEVertex *vertices = malloc(vertexCount * sizeof(MBEVertex));
    MBEIndexType *indices = malloc(indexCount * sizeof(MBEIndexType));

    __block MBEIndexType v = 0, i = 0;
    [self enumerateGlyphsInFrame:frame block:^(CGGlyph glyph, NSInteger glyphIndex, CGRect glyphBounds) {
        if (glyph >= fontAtlas.glyphDescriptors.count)
        {
            NSLog(@"Font atlas has no entry corresponding to glyph #%d; Skipping...", glyph);
            return;
        }
        MBEGlyphDescriptor *glyphInfo = fontAtlas.glyphDescriptors[glyph];
        float minX = CGRectGetMinX(glyphBounds);
        float maxX = CGRectGetMaxX(glyphBounds);
        float minY = CGRectGetMinY(glyphBounds);
        float maxY = CGRectGetMaxY(glyphBounds);
        float minS = glyphInfo.topLeftTexCoord.x;
        float maxS = glyphInfo.bottomRightTexCoord.x;
        float minT = glyphInfo.topLeftTexCoord.y;
        float maxT = glyphInfo.bottomRightTexCoord.y;
        vertices[v++] = (MBEVertex){ { minX, maxY, 0, 1 }, { minS, maxT } };
        vertices[v++] = (MBEVertex){ { minX, minY, 0, 1 }, { minS, minT } };
        vertices[v++] = (MBEVertex){ { maxX, minY, 0, 1 }, { maxS, minT } };
        vertices[v++] = (MBEVertex){ { maxX, maxY, 0, 1 }, { maxS, maxT } };
        indices[i++] = glyphIndex * 4;
        indices[i++] = glyphIndex * 4 + 1;
        indices[i++] = glyphIndex * 4 + 2;
        indices[i++] = glyphIndex * 4 + 2;
        indices[i++] = glyphIndex * 4 + 3;
        indices[i++] = glyphIndex * 4;
    }];

    _vertexBuffer = [device newBufferWithBytes:vertices
                                        length:vertexCount * sizeof(MBEVertex)
                                       options:MTLResourceOptionCPUCacheModeDefault];
    [_vertexBuffer setLabel:@"Text Mesh Vertices"];
    _indexBuffer = [device newBufferWithBytes:indices
                                       length:indexCount * sizeof(MBEIndexType)
                                      options:MTLResourceOptionCPUCacheModeDefault];
    [_indexBuffer setLabel:@"Text Mesh Indices"];

    free(indices);
    free(vertices);
    CFRelease(frame);
    CFRelease(framesetter);
    CFRelease(rectPath);
}

- (void)enumerateGlyphsInFrame:(CTFrameRef)frame
                         block:(MBEGlyphPositionEnumerationBlock)block
{
    if (!block)
        return;

    CFRange entire = CFRangeMake(0, 0);

    CGPathRef framePath = CTFrameGetPath(frame);
    CGRect frameBoundingRect = CGPathGetPathBoundingBox(framePath);

    NSArray *lines = (__bridge id)CTFrameGetLines(frame);

    CGPoint *lineOriginBuffer = malloc(lines.count * sizeof(CGPoint));
    CTFrameGetLineOrigins(frame, entire, lineOriginBuffer);

    __block CFIndex glyphIndexInFrame = 0;

    SDGraphicsBeginImageContext(CGSizeMake(1, 1));
    CGContextRef context = SDGraphicsGetCurrentContext();

    [lines enumerateObjectsUsingBlock:^(id lineObject, NSUInteger lineIndex, BOOL *stop) {
        CTLineRef line = (__bridge CTLineRef)lineObject;
        CGPoint lineOrigin = lineOriginBuffer[lineIndex];

        NSArray *runs = (__bridge id)CTLineGetGlyphRuns(line);
        [runs enumerateObjectsUsingBlock:^(id runObject, NSUInteger rangeIndex, BOOL *stop) {
            CTRunRef run = (__bridge CTRunRef)runObject;

            NSInteger glyphCount = CTRunGetGlyphCount(run);

            CGGlyph *glyphBuffer = malloc(glyphCount * sizeof(CGGlyph));
            CTRunGetGlyphs(run, entire, glyphBuffer);

            CGPoint *positionBuffer = malloc(glyphCount * sizeof(CGPoint));
            CTRunGetPositions(run, entire, positionBuffer);

            for (NSInteger glyphIndex = 0; glyphIndex < glyphCount; ++glyphIndex)
            {
                CGGlyph glyph = glyphBuffer[glyphIndex];
                CGPoint glyphOrigin = positionBuffer[glyphIndex];
                CGRect glyphRect = CTRunGetImageBounds(run, context, CFRangeMake(glyphIndex, 1));
                CGFloat boundsTransX = frameBoundingRect.origin.x + lineOrigin.x;
                CGFloat boundsTransY = CGRectGetHeight(frameBoundingRect) + frameBoundingRect.origin.y - lineOrigin.y + glyphOrigin.y;
                CGAffineTransform pathTransform = CGAffineTransformMake(1, 0, 0, -1, boundsTransX, boundsTransY);
                glyphRect = CGRectApplyAffineTransform(glyphRect, pathTransform);
                block(glyph, glyphIndexInFrame, glyphRect);

                ++glyphIndexInFrame;
            }

            free(positionBuffer);
            free(glyphBuffer);
        }];
    }];

    SDGraphicsEndImageContext();
}

@end
