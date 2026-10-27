#import "TimeMapperBridge.h"
#include "library.h"

#include <exception>
#include <filesystem>

@implementation TimeMapperBridge

+ (nullable NSString *)mapVideoAtPath:(NSString *)videoPath
                       outputJSONPath:(NSString *)outputPath
                                    x:(NSInteger)x
                                    y:(NSInteger)y
                                width:(NSInteger)width
                               height:(NSInteger)height {
    return [self mapVideoAtPath:videoPath outputJSONPath:outputPath x:x y:y
                         width:width height:height log:^(NSString *) {}];
}

+ (nullable NSString *)mapVideoAtPath:(NSString *)videoPath
                       outputJSONPath:(NSString *)outputPath
                                    x:(NSInteger)x
                                    y:(NSInteger)y
                                width:(NSInteger)width
                               height:(NSInteger)height
                                  log:(void (^)(NSString *message))log {
    try {
        const time_mapper::Region region{
            static_cast<int>(x), static_cast<int>(y),
            static_cast<int>(width), static_cast<int>(height)
        };
        time_mapper::map_gametime_to_videotime(
            std::filesystem::path(videoPath.fileSystemRepresentation), region,
            std::filesystem::path(outputPath.fileSystemRepresentation),
            [log](const std::string& message) {
                log([NSString stringWithUTF8String:message.c_str()]);
            });
        return nil;
    } catch (const std::exception& error) {
        return [NSString stringWithUTF8String:error.what()];
    }
}

@end
