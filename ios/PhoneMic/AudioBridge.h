#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN
@interface AudioBridge : NSObject
// Call all methods from one non-main serial executor. The capture and UDP
// callbacks have their own threads; session lifecycle and snapshots do not.
- (BOOL)startWithHost:(NSString *)host port:(uint16_t)port token:(uint64_t)token error:(NSError **)error;
- (void)stop;
- (NSDictionary<NSString *, NSNumber *> *)snapshot;
- (BOOL)captureRouteIsValid;
@end
NS_ASSUME_NONNULL_END
