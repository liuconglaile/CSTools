//
//  CSAlertView.m
//  CSCategory
//
//  Created by mac on 2017/6/21.
//  Copyright © 2017年 mac. All rights reserved.
//

#import "CSAlertView.h"
#import "UIView+Extended.h"
#import "NSObject+Extended.h"
#import "CALayer+Extended.h"
#define ACTION_HEIGHT 49.0

@interface CSAlertButton()

@property (nonatomic, copy) void (^buttonClickedBlock)(CSAlertButton *alertButton);

@end
@implementation CSAlertButton

+ (instancetype)buttonWithTitle:(NSString *)title handler:(void (^)(CSAlertButton * _Nonnull))handler {
    return [[self alloc] initWithTitle:title handler:handler];
}

- (instancetype)initWithTitle:(NSString *)title handler:(void (^)(CSAlertButton * _Nonnull))handler {
    if (self = [super init]) {
        self.titleLabel.font = [UIFont systemFontOfSize:18];
        self.titleLabel.adjustsFontSizeToFitWidth = YES;
        [self setTitleColor:[UIColor blackColor] forState:UIControlStateNormal];
        [self setTitleColor:[UIColor darkGrayColor] forState:UIControlStateHighlighted];
        [self setTitle:title forState:UIControlStateNormal];
        [self addTarget:self action:@selector(handlerClicked) forControlEvents:UIControlEventTouchUpInside];
        self.buttonClickedBlock = handler;
    }
    return self;
}

- (void)handlerClicked {
    if (nil != self && nil != self.buttonClickedBlock) {
        self.buttonClickedBlock(self);
    }
}

@end





@interface CSAlertView(){
    CGSize  _contentSize;
    CGFloat _paddingTop, _paddingBottom, _paddingLeft; // paddingRight = paddingLeft
    CGFloat _spacing;
}

@property (nonatomic, strong) NSMutableSet *subActions;
@property (nonatomic, strong) NSMutableSet *adjoinActions;

@end

static void *CSAlertViewActionKey = &CSAlertViewActionKey;
@implementation CSAlertView

- (NSMutableSet *)subActions {
    if (!_subActions) {
        _subActions = [NSMutableSet set];
    }
    return _subActions;
}

- (BOOL)isEmptyString:(NSString *)string {
    if (!string) return YES;
    if ([string isKindOfClass:[NSNull class]]) return YES;
    if ([[string stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]] length] == 0) return YES;
    return NO;
}

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message width:(CGFloat)width {
    if (self = [super init]) {
        self.backgroundColor = [UIColor whiteColor];
        self.layer.cornerRadius = 10;
        self.clipsToBounds = NO;
        
        _contentSize.width = 200; // default width = 200
        if (width > 0) _contentSize.width = width;
        _paddingTop = 15, _paddingBottom = 15, _paddingLeft = 20, _spacing = 15;
        
        if (![self isEmptyString:title]) {
            _titleLabel = [[UILabel alloc] init];
            _titleLabel.text = title;
            _titleLabel.numberOfLines = 0;
            _titleLabel.textAlignment = NSTextAlignmentCenter;
            _titleLabel.font = [UIFont systemFontOfSize:22];
            [self addSubview:_titleLabel];
            
            _titleLabel.size = [_titleLabel sizeThatFits:CGSizeMake(_contentSize.width-2*_paddingLeft, MAXFLOAT)];
            _titleLabel.top = _paddingTop;
            _titleLabel.centerX = _contentSize.width / 2;
            _contentSize.height = _titleLabel.bottom;
        }
        
        if (![self isEmptyString:message]) {
            _messageLabel = [[UILabel alloc] init];
            _messageLabel.numberOfLines = 0;
            _messageLabel.font = [UIFont systemFontOfSize:16];
            _messageLabel.textColor = [UIColor grayColor];
            [self addSubview:_messageLabel];
            NSMutableAttributedString *string = [[NSMutableAttributedString alloc] initWithString:message];
            NSMutableParagraphStyle *paragraphStyle = [[NSMutableParagraphStyle alloc] init];
            paragraphStyle.lineSpacing = 5;
            [string addAttribute:NSParagraphStyleAttributeName value:paragraphStyle range:NSMakeRange(0, message.length)];
            _messageLabel.attributedText = string;
            
            _messageLabel.size = [_messageLabel sizeThatFits:CGSizeMake(_contentSize.width - 2*_paddingLeft, MAXFLOAT)];
            _messageLabel.top = _titleLabel.bottom + _spacing;
            _messageLabel.centerX = _contentSize.width / 2;
            _contentSize.height = _messageLabel.bottom;
        }
        
        self.size = CGSizeMake(_contentSize.width, _contentSize.height + _paddingBottom);
        if ([self isEmptyString:title] && [self isEmptyString:message]) {
            self.size = CGSizeZero;
        }
    }
    return self;
}

- (instancetype)initWithTitle:(NSString *)title message:(NSString *)message {
    return [self initWithTitle:title message:message width:0];
}

- (void)clearActions:(NSMutableSet *)actions {
    NSEnumerator *enumerator = [actions objectEnumerator];
    NSString *value;
    while (value = [enumerator nextObject]) {
        if ([value isKindOfClass:[CALayer class]]) {
            [((CALayer *)value) removeFromSuperlayer];
        }
        if ([value isKindOfClass:[CSAlertButton class]]) {
            [((CSAlertButton *)value) removeFromSuperview];
        }
    }
    [actions removeAllObjects];
}

- (CALayer *)lineWithTop:(CGFloat)top horizontal:(BOOL)isHorizontalLine {
    UIColor *color = _linesColor ? _linesColor : [UIColor grayColor];
    CALayer *layer = [CALayer layer];
    layer.backgroundColor = color.CGColor;
    CGRect rect = (CGRect){.origin = CGPointMake(0, top), .size = CGSizeZero};;
    if (isHorizontalLine) { // horizontal line
        rect.size = CGSizeMake(_contentSize.width, 1 / [UIScreen mainScreen].scale);
    } else {
        rect.size = CGSizeMake(1 / [UIScreen mainScreen].scale, ACTION_HEIGHT);
    }
    layer.frame = rect;
    return layer;
}

// Horizontal two views
- (void)addAdjoinWithCancelAction:(CSAlertButton *)cancelAction okAction:(CSAlertButton *)okAction {
    
    NSAssert(cancelAction != nil, @"cancelAction cannot be nil.");
    NSAssert(okAction != nil, @"okAction cannot be nil.");
    
    [self clearActions:self.subActions];
    [self setAssociateValue:nil withKey:CSAlertViewActionKey];
    
    // horizontal layout
    cancelAction.size = CGSizeMake(_contentSize.width / 2, ACTION_HEIGHT);
    cancelAction.top = _contentSize.height;
    if (!CGSizeEqualToSize(self.size, CGSizeZero)) {
        cancelAction.top += _spacing;
    }
    okAction.size = CGSizeMake(_contentSize.width / 2, ACTION_HEIGHT);
    okAction.origin = CGPointMake(cancelAction.right, cancelAction.top);
    CALayer *line1 = [self lineWithTop:okAction.top horizontal:YES];
    CALayer *line2 = [self lineWithTop:okAction.top horizontal:NO];
    line2.centerX = _contentSize.width / 2;
    
    [self addSubview:cancelAction];
    [self addSubview:okAction];
    [self.layer addSublayer:line1];
    [self.layer addSublayer:line2];
    self.adjoinActions = [NSMutableSet setWithObjects:cancelAction, okAction, line1, line2, nil];
    self.size = CGSizeMake(_contentSize.width, okAction.bottom);
}

- (void)addAction:(CSAlertButton *)action {
    
    NSAssert(action != nil, @"action cannot be nil.");
    
    [self clearActions:self.adjoinActions];
    
    id value = [self getAssociatedValueForKey:CSAlertViewActionKey];
    if (nil != value && [value isKindOfClass:[CSAlertButton class]]) {
        
        CSAlertButton *lastAction = (CSAlertButton *)value; // last
        if (![action isEqual:lastAction]) { // current
            
            CGFloat w = _contentSize.width - action.edgeInset.left - action.edgeInset.right;
            action.size = CGSizeMake(w, ACTION_HEIGHT);
            action.top = lastAction.bottom + action.edgeInset.top;
            action.centerX = _contentSize.width / 2;
            if (!_linesHidden) {
                CALayer *line = [self lineWithTop:action.top horizontal:YES];
                [self.layer addSublayer:line];
                [self.subActions addObject:line];
            }
        }
        
    } else { // first
        
        CGFloat w = _contentSize.width - action.edgeInset.left - action.edgeInset.right;
        action.size = CGSizeMake(w, ACTION_HEIGHT);
        action.top = _contentSize.height + action.edgeInset.top;
        action.centerX = _contentSize.width / 2;
        if (!CGSizeEqualToSize(self.size, CGSizeZero)) {
            action.top += _spacing;
        }
        if (!_linesHidden) {
            CALayer *line = [self lineWithTop:action.top horizontal:YES];
            [self.layer addSublayer:line];
            [self.subActions addObject:line];
        }
    }
    [self insertSubview:action atIndex:0];
    [self.subActions addObject:action];
    self.size = CGSizeMake(_contentSize.width, action.bottom + action.edgeInset.bottom);
    [self setAssociateValue:action withKey:CSAlertViewActionKey];
}

#pragma mark - Setter

- (void)setLinesColor:(UIColor *)linesColor {
    _linesColor = linesColor;
    for (id value in self.adjoinActions) {
        if ([value isKindOfClass:[CALayer class]]) {
            ((CALayer *)value).backgroundColor = linesColor.CGColor;
        }
    }
    for (id value in self.subActions) {
        if ([value isKindOfClass:[CALayer class]]) {
            ((CALayer *)value).backgroundColor = linesColor.CGColor;
        }
    }
}

- (void)setLinesHidden:(BOOL)linesHidden {
    _linesHidden = linesHidden;
    if (_linesHidden) {
        for (id value in self.adjoinActions) {
            if ([value isKindOfClass:[CALayer class]]) {
                [((CALayer *)value) removeFromSuperlayer];
            }
        }
        for (id value in self.subActions) {
            if ([value isKindOfClass:[CALayer class]]) {
                [((CALayer *)value) removeFromSuperlayer];
            }
        }
    }
}

@end
