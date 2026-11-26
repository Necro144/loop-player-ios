#import "ObjCTry.h"

BOOL LPTry(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error) {
    @try {
        block();
        return YES;
    } @catch (NSException *e) {
        if (error) {
            NSString *text = [NSString stringWithFormat:@"%@: %@", e.name, e.reason ?: @""];
            *error = [NSError errorWithDomain:@"LoopPlayer.ObjC" code:9 userInfo:@{NSLocalizedDescriptionKey: text}];
        }
        return NO;
    }
}
