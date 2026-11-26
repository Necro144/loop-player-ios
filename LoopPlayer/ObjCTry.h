#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and turns an Objective-C exception (which Swift can't catch, so the app closed)
/// into an NSError. Used around AVFoundation calls that throw on some phones (1.5.3).
BOOL LPTry(NS_NOESCAPE void (^block)(void), NSError * _Nullable * _Nullable error);

NS_ASSUME_NONNULL_END
