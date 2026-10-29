#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface AudioBridge : NSObject
- (BOOL)startWithHost:(NSString *)host port:(uint16_t)port token:(uint64_t)token error:(NSError **)error;
- (void)stop;
- (NSDictionary<NSString *, NSNumber *> *)snapshot;
@end
NS_ASSUME_NONNULL_END
