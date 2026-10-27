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
    try {
        const time_mapper::Region region{
            static_cast<int>(x), static_cast<int>(y),
            static_cast<int>(width), static_cast<int>(height)
        };
        time_mapper::map_gametime_to_videotime(
            std::filesystem::path(videoPath.fileSystemRepresentation), region,
            std::filesystem::path(outputPath.fileSystemRepresentation));
        return nil;
    } catch (const std::exception& error) {
        return [NSString stringWithUTF8String:error.what()];
    }
}

@end
