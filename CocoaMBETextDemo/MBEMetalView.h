@import Cocoa;
@import QuartzCore.CAMetalLayer;

@interface MBEMetalView : UIView

@property (nonatomic, readonly) CAMetalLayer *metalLayer;

@end
