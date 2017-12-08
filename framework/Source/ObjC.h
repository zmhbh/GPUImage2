//
//  ObjC.h
//  GPUImage2
//
//  Created by Josh Bernfeld on 11/23/17.
//

#import <Foundation/Foundation.h>

@interface ObjC : NSObject

+ (BOOL)catchException:(void(^)(void))tryBlock error:(__autoreleasing NSError **)error;

@end
