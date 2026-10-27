#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface TimeMapperBridge : NSObject

// Returns nil on success, or a description of the failure.
+ (nullable NSString *)mapVideoAtPath:(NSString *)videoPath
                       outputJSONPath:(NSString *)outputPath
                                    x:(NSInteger)x
                                    y:(NSInteger)y
                                width:(NSInteger)width
                               height:(NSInteger)height;

@end

NS_ASSUME_NONNULL_END
