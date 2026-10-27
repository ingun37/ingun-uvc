#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TimeMapperLogHandler)(double videoSeconds, NSString *recognizedText,
                                     NSNumber * _Nullable gameSecond, double ocrSeconds);

@interface TimeMapperBridge : NSObject

// Returns nil on success, or a description of the failure.
+ (nullable NSString *)mapVideoAtPath:(NSString *)videoPath
                       outputJSONPath:(NSString *)outputPath
                                    x:(NSInteger)x
                                    y:(NSInteger)y
                                width:(NSInteger)width
                               height:(NSInteger)height
                                  log:(TimeMapperLogHandler)log;

@end

NS_ASSUME_NONNULL_END
