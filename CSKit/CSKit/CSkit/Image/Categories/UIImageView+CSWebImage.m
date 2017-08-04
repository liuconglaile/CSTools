//
//  UIImageView+CSWebImage.m
//  CSCategory
//
//  Created by mac on 2017/7/21.
//  Copyright © 2017年 mac. All rights reserved.
//

#import "UIImageView+CSWebImage.h"
#import <objc/runtime.h>

#import "_CSWebImageSetter.h"
#import "CSWebImageOperation.h"
#import "CSKitMacro.h"


CSSYNTH_DUMMY_CLASS(UIImageView_CSWebImage)

static int _CSWebImageSetterKey;
static int _CSWebImageHighlightedSetterKey;

@implementation UIImageView (CSWebImage)

- (NSURL *)imageURL {
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageSetterKey);
    return setter.imageURL;
}

/*
 "setImageWithURL" is conflict to AFNetworking and SDWebImage...WTF!
 So.. We use "setImageURL:" instead.
 */
- (void)setImageURL:(NSURL *)imageURL {
    [self setImageWithURL:imageURL
              placeholder:nil
                  options:kNilOptions
                  manager:nil
                 progress:nil
                transform:nil
               completion:nil];
}

- (void)setImageWithURL:(NSURL *)imageURL placeholder:(UIImage *)placeholder {
    [self setImageWithURL:imageURL
              placeholder:placeholder
                  options:kNilOptions
                  manager:nil
                 progress:nil
                transform:nil
               completion:nil];
}

- (void)setImageWithURL:(NSURL *)imageURL options:(CSWebImageOptions)options {
    [self setImageWithURL:imageURL
              placeholder:nil
                  options:options
                  manager:nil
                 progress:nil
                transform:nil
               completion:nil];
}

- (void)setImageWithURL:(NSURL *)imageURL
            placeholder:(UIImage *)placeholder
                options:(CSWebImageOptions)options
             completion:(CSWebImageCompletionBlock)completion {
    [self setImageWithURL:imageURL
              placeholder:placeholder
                  options:options
                  manager:nil
                 progress:nil
                transform:nil
               completion:completion];
}

- (void)setImageWithURL:(NSURL *)imageURL
            placeholder:(UIImage *)placeholder
                options:(CSWebImageOptions)options
               progress:(CSWebImageProgressBlock)progress
              transform:(CSWebImageTransformBlock)transform
             completion:(CSWebImageCompletionBlock)completion {
    [self setImageWithURL:imageURL
              placeholder:placeholder
                  options:options
                  manager:nil
                 progress:progress
                transform:transform
               completion:completion];
}

- (void)setImageWithURL:(NSURL *)imageURL
            placeholder:(UIImage *)placeholder
                options:(CSWebImageOptions)options
                manager:(CSWebImageManager *)manager
               progress:(CSWebImageProgressBlock)progress
              transform:(CSWebImageTransformBlock)transform
             completion:(CSWebImageCompletionBlock)completion {
    
    if ([imageURL isKindOfClass:[NSString class]]) imageURL = [NSURL URLWithString:(id)imageURL];
    manager = manager ? manager : [CSWebImageManager sharedManager];
    
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageSetterKey);
    if (!setter) {
        setter = [_CSWebImageSetter new];
        objc_setAssociatedObject(self, &_CSWebImageSetterKey, setter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    int32_t sentinel = [setter cancelWithNewURL:imageURL];
    
    dispatch_async_on_main_queue(^{
        if ((options & CSWebImageOptionSetImageWithFadeAnimation) &&
            !(options & CSWebImageOptionAvoidSetImage)) {
            if (!self.highlighted) {
                [self.layer removeAnimationForKey:_CSWebImageFadeAnimationKey];
            }
        }
        
        if (!imageURL) {
            if (!(options & CSWebImageOptionIgnorePlaceHolder)) {
                self.image = placeholder;
            }
            return;
        }
        
        // get the image from memory as quickly as possible
        UIImage *imageFromMemory = nil;
        if (manager.cache &&
            !(options & CSWebImageOptionUseNSURLCache) &&
            !(options & CSWebImageOptionRefreshImageCache)) {
            imageFromMemory = [manager.cache getImageForKey:[manager cacheKeyForURL:imageURL] withType:CSImageCacheTypeMemory];
        }
        if (imageFromMemory) {
            if (!(options & CSWebImageOptionAvoidSetImage)) {
                self.image = imageFromMemory;
            }
            if(completion) completion(imageFromMemory, imageURL, CSWebImageFromMemoryCacheFast, CSWebImageStageFinished, nil);
            return;
        }
        
        if (!(options & CSWebImageOptionIgnorePlaceHolder)) {
            self.image = placeholder;
        }
        
        __weak typeof(self) _self = self;
        dispatch_async([_CSWebImageSetter setterQueue], ^{
            CSWebImageProgressBlock _progress = nil;
            if (progress) _progress = ^(NSInteger receivedSize, NSInteger expectedSize) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(receivedSize, expectedSize);
                });
            };
            
            __block int32_t newSentinel = 0;
            __block __weak typeof(setter) weakSetter = nil;
            CSWebImageCompletionBlock _completion = ^(UIImage *image, NSURL *url, CSWebImageFromType from, CSWebImageStage stage, NSError *error) {
                __strong typeof(_self) self = _self;
                BOOL setImage = (stage == CSWebImageStageFinished || stage == CSWebImageStageProgress) && image && !(options & CSWebImageOptionAvoidSetImage);
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL sentinelChanged = weakSetter && weakSetter.sentinel != newSentinel;
                    if (setImage && self && !sentinelChanged) {
                        BOOL showFade = ((options & CSWebImageOptionSetImageWithFadeAnimation) && !self.highlighted);
                        if (showFade) {
                            CATransition *transition = [CATransition animation];
                            transition.duration = stage == CSWebImageStageFinished ? _CSWebImageFadeTime : _CSWebImageProgressiveFadeTime;
                            transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                            transition.type = kCATransitionFade;
                            [self.layer addAnimation:transition forKey:_CSWebImageFadeAnimationKey];
                        }
                        self.image = image;
                    }
                    if (completion) {
                        if (sentinelChanged) {
                            completion(nil, url, CSWebImageFromNone, CSWebImageStageCancelled, nil);
                        } else {
                            completion(image, url, from, stage, error);
                        }
                    }
                });
            };
            
            newSentinel = [setter setOperationWithSentinel:sentinel url:imageURL options:options manager:manager progress:_progress transform:transform completion:_completion];
            weakSetter = setter;
        });
    });
}

- (void)cancelCurrentImageRequest {
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageSetterKey);
    if (setter) [setter cancel];
}


#pragma mark - highlighted image

- (NSURL *)highlightedImageURL {
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageHighlightedSetterKey);
    return setter.imageURL;
}

- (void)setHighlightedImageURL:(NSURL *)imageURL {
    [self setHighlightedImageWithURL:imageURL
                         placeholder:nil
                             options:kNilOptions
                             manager:nil
                            progress:nil
                           transform:nil
                          completion:nil];
}

- (void)setHighlightedImageWithURL:(NSURL *)imageURL placeholder:(UIImage *)placeholder {
    [self setHighlightedImageWithURL:imageURL
                         placeholder:placeholder
                             options:kNilOptions
                             manager:nil
                            progress:nil
                           transform:nil
                          completion:nil];
}

- (void)setHighlightedImageWithURL:(NSURL *)imageURL options:(CSWebImageOptions)options {
    [self setHighlightedImageWithURL:imageURL
                         placeholder:nil
                             options:options
                             manager:nil
                            progress:nil
                           transform:nil
                          completion:nil];
}

- (void)setHighlightedImageWithURL:(NSURL *)imageURL
                       placeholder:(UIImage *)placeholder
                           options:(CSWebImageOptions)options
                        completion:(CSWebImageCompletionBlock)completion {
    [self setHighlightedImageWithURL:imageURL
                         placeholder:placeholder
                             options:options
                             manager:nil
                            progress:nil
                           transform:nil
                          completion:completion];
}

- (void)setHighlightedImageWithURL:(NSURL *)imageURL
                       placeholder:(UIImage *)placeholder
                           options:(CSWebImageOptions)options
                          progress:(CSWebImageProgressBlock)progress
                         transform:(CSWebImageTransformBlock)transform
                        completion:(CSWebImageCompletionBlock)completion {
    [self setHighlightedImageWithURL:imageURL
                         placeholder:placeholder
                             options:options
                             manager:nil
                            progress:progress
                           transform:nil
                          completion:completion];
}

- (void)setHighlightedImageWithURL:(NSURL *)imageURL
                       placeholder:(UIImage *)placeholder
                           options:(CSWebImageOptions)options
                           manager:(CSWebImageManager *)manager
                          progress:(CSWebImageProgressBlock)progress
                         transform:(CSWebImageTransformBlock)transform
                        completion:(CSWebImageCompletionBlock)completion {
    if ([imageURL isKindOfClass:[NSString class]]) imageURL = [NSURL URLWithString:(id)imageURL];
    manager = manager ? manager : [CSWebImageManager sharedManager];
    
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageHighlightedSetterKey);
    if (!setter) {
        setter = [_CSWebImageSetter new];
        objc_setAssociatedObject(self, &_CSWebImageHighlightedSetterKey, setter, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    int32_t sentinel = [setter cancelWithNewURL:imageURL];
    
    dispatch_async_on_main_queue(^{
        if ((options & CSWebImageOptionSetImageWithFadeAnimation) &&
            !(options & CSWebImageOptionAvoidSetImage)) {
            if (self.highlighted) {
                [self.layer removeAnimationForKey:_CSWebImageFadeAnimationKey];
            }
        }
        if (!imageURL) {
            if (!(options & CSWebImageOptionIgnorePlaceHolder)) {
                self.highlightedImage = placeholder;
            }
            return;
        }
        
        // get the image from memory as quickly as possible
        UIImage *imageFromMemory = nil;
        if (manager.cache &&
            !(options & CSWebImageOptionUseNSURLCache) &&
            !(options & CSWebImageOptionRefreshImageCache)) {
            imageFromMemory = [manager.cache getImageForKey:[manager cacheKeyForURL:imageURL] withType:CSImageCacheTypeMemory];
        }
        if (imageFromMemory) {
            if (!(options & CSWebImageOptionAvoidSetImage)) {
                self.highlightedImage = imageFromMemory;
            }
            if(completion) completion(imageFromMemory, imageURL, CSWebImageFromMemoryCacheFast, CSWebImageStageFinished, nil);
            return;
        }
        
        if (!(options & CSWebImageOptionIgnorePlaceHolder)) {
            self.highlightedImage = placeholder;
        }
        
        __weak typeof(self) _self = self;
        dispatch_async([_CSWebImageSetter setterQueue], ^{
            CSWebImageProgressBlock _progress = nil;
            if (progress) _progress = ^(NSInteger receivedSize, NSInteger expectedSize) {
                dispatch_async(dispatch_get_main_queue(), ^{
                    progress(receivedSize, expectedSize);
                });
            };
            
            __block int32_t newSentinel = 0;
            __block __weak typeof(setter) weakSetter = nil;
            CSWebImageCompletionBlock _completion = ^(UIImage *image, NSURL *url, CSWebImageFromType from, CSWebImageStage stage, NSError *error) {
                __strong typeof(_self) self = _self;
                BOOL setImage = (stage == CSWebImageStageFinished || stage == CSWebImageStageProgress) && image && !(options & CSWebImageOptionAvoidSetImage);
                BOOL showFade = ((options & CSWebImageOptionSetImageWithFadeAnimation) && self.highlighted);
                dispatch_async(dispatch_get_main_queue(), ^{
                    BOOL sentinelChanged = weakSetter && weakSetter.sentinel != newSentinel;
                    if (setImage && self && !sentinelChanged) {
                        if (showFade) {
                            CATransition *transition = [CATransition animation];
                            transition.duration = stage == CSWebImageStageFinished ? _CSWebImageFadeTime : _CSWebImageProgressiveFadeTime;
                            transition.timingFunction = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseInEaseOut];
                            transition.type = kCATransitionFade;
                            [self.layer addAnimation:transition forKey:_CSWebImageFadeAnimationKey];
                        }
                        self.highlightedImage = image;
                    }
                    if (completion) {
                        if (sentinelChanged) {
                            completion(nil, url, CSWebImageFromNone, CSWebImageStageCancelled, nil);
                        } else {
                            completion(image, url, from, stage, error);
                        }
                    }
                });
            };
            
            newSentinel = [setter setOperationWithSentinel:sentinel url:imageURL options:options manager:manager progress:_progress transform:transform completion:_completion];
            weakSetter = setter;
        });
    });
}

- (void)cancelCurrentHighlightedImageRequest {
    _CSWebImageSetter *setter = objc_getAssociatedObject(self, &_CSWebImageHighlightedSetterKey);
    if (setter) [setter cancel];
}

@end
