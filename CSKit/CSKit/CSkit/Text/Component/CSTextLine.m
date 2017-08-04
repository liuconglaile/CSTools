//
//  CSTextLine.m
//  CSCategory
//
//  Created by mac on 17/4/8.
//  Copyright © 2017年 mac. All rights reserved.
//

#import "CSTextLine.h"
#import <objc/runtime.h>


#import "CSKitMacro.h"

@interface CSTextLine ()

//@property (nonatomic,copy) NSArray<CSTextGlyph *>* glyphs;

@end


@implementation CSTextLine
{
    CGFloat _firstGlyphPos; // first glyph position for baseline, typically 0.
}

+ (instancetype)lineWithCTLine:(CTLineRef)CTLine position:(CGPoint)position vertical:(BOOL)isVertical {
    if (!CTLine) return nil;
    CSTextLine *line = [self new];
    line->_position = position;
    line->_vertical = isVertical;
    [line setCTLine:CTLine];
    return line;
}

- (void)dealloc {
    if (_CTLine) CFRelease(_CTLine);
}

- (void)setCTLine:(_Nonnull CTLineRef)CTLine {
    if (_CTLine != CTLine) {
        if (CTLine) CFRetain(CTLine);
        if (_CTLine) CFRelease(_CTLine);
        _CTLine = CTLine;
        if (_CTLine) {
            _lineWidth = CTLineGetTypographicBounds(_CTLine, &_ascent, &_descent, &_leading);
            CFRange range = CTLineGetStringRange(_CTLine);
            _range = NSMakeRange(range.location, range.length);
            if (CTLineGetGlyphCount(_CTLine) > 0) {
                CFArrayRef runs = CTLineGetGlyphRuns(_CTLine);
                CTRunRef run = CFArrayGetValueAtIndex(runs, 0);
                CGPoint pos;
                CTRunGetPositions(run, CFRangeMake(0, 1), &pos);
                _firstGlyphPos = pos.x;
            } else {
                _firstGlyphPos = 0;
            }
            _trailingWhitespaceWidth = CTLineGetTrailingWhitespaceWidth(_CTLine);
        } else {
            _lineWidth = _ascent = _descent = _leading = _firstGlyphPos = _trailingWhitespaceWidth = 0;
            _range = NSMakeRange(0, 0);
        }
        [self reloadBounds];
    }
}

- (void)setPosition:(CGPoint)position {
    _position = position;
    [self reloadBounds];
}

- (void)reloadBounds {
    if (_vertical) {
        _bounds = CGRectMake(_position.x - _descent, _position.y, _ascent + _descent, _lineWidth);
        _bounds.origin.y += _firstGlyphPos;
    } else {
        _bounds = CGRectMake(_position.x, _position.y - _ascent, _lineWidth, _ascent + _descent);
        _bounds.origin.x += _firstGlyphPos;
    }
    
    _attachments = nil;
    _attachmentRanges = nil;
    _attachmentRects = nil;
    if (!_CTLine) return;
    CFArrayRef runs = CTLineGetGlyphRuns(_CTLine);
    NSUInteger runCount = CFArrayGetCount(runs);
    if (runCount == 0) return;
    
    NSMutableArray *attachments = [NSMutableArray new];
    NSMutableArray *attachmentRanges = [NSMutableArray new];
    NSMutableArray *attachmentRects = [NSMutableArray new];
    //NSMutableArray<CSTextGlyph *> *glyphsArray = [[NSMutableArray alloc] init];
    
    for (NSUInteger r = 0; r < runCount; r++) {
        
        CTRunRef run = CFArrayGetValueAtIndex(runs, r);
        CFIndex glyphCount = CTRunGetGlyphCount(run);
        if (glyphCount == 0) continue;
        NSDictionary *attrs = (id)CTRunGetAttributes(run);
        CSTextAttachment *attachment = attrs[CSTextAttachmentAttributeName];
        if (attachment) {
            CGPoint runPosition = CGPointZero;
            CTRunGetPositions(run, CFRangeMake(0, 1), &runPosition);
            
            CGFloat ascent, descent, leading, runWidth;
            CGRect runTypoBounds;
            runWidth = CTRunGetTypographicBounds(run, CFRangeMake(0, 0), &ascent, &descent, &leading);
            
            if (_vertical) {
                CS_SWAP(runPosition.x, runPosition.y);
                runPosition.y = _position.y + runPosition.y;
                runTypoBounds = CGRectMake(_position.x + runPosition.x - descent, runPosition.y , ascent + descent, runWidth);
            } else {
                runPosition.x += _position.x;
                runPosition.y = _position.y - runPosition.y;
                runTypoBounds = CGRectMake(runPosition.x, runPosition.y - ascent, runWidth, ascent + descent);
            }
            
            NSRange runRange = CSNSRangeFromCFRange(CTRunGetStringRange(run));
            [attachments addObject:attachment];
            [attachmentRanges addObject:[NSValue valueWithRange:runRange]];
            [attachmentRects addObject:[NSValue valueWithCGRect:runTypoBounds]];
        }
        
        
        
        
        ///以下代码仅供 glyphsArray使用
//        {
//            CGGlyph glyphs[glyphCount];
//            CTRunGetGlyphs(run, CFRangeMake(0, 0),glyphs);
//            
//            CGPoint glyphPositions[glyphCount];
//            CTRunGetPositions(run, CFRangeMake(0, 0), glyphPositions);
//            
//            CGSize glyphAdvances[glyphCount];
//            CTRunGetAdvances(run, CFRangeMake(0, glyphCount), glyphAdvances);
//            
//            for (NSInteger i = 0; i < glyphCount; i ++) {
//                CSTextGlyph* glyph = [[CSTextGlyph alloc] init];
//                glyph.glyph = glyphs[i];
//                glyph.position = glyphPositions[i];
//                glyph.leading = _leading;
//                glyph.ascent = _ascent;
//                glyph.descent = _descent;
//                glyph.width = glyphAdvances[i].width;
//                glyph.height = glyphAdvances[i].height;
//                [glyphsArray addObject:glyph];
//            }
//        }
        
        
    }
    _attachments = attachments.count ? attachments : nil;
    _attachmentRanges = attachmentRanges.count ? attachmentRanges : nil;
    _attachmentRects = attachmentRects.count ? attachmentRects : nil;
    //self.glyphs = [glyphsArray copy];
}

- (CGSize)size {
    return _bounds.size;
}

- (CGFloat)width {
    return CGRectGetWidth(_bounds);
}

- (CGFloat)height {
    return CGRectGetHeight(_bounds);
}

- (CGFloat)top {
    return CGRectGetMinY(_bounds);
}

- (CGFloat)bottom {
    return CGRectGetMaxY(_bounds);
}

- (CGFloat)left {
    return CGRectGetMinX(_bounds);
}

- (CGFloat)right {
    return CGRectGetMaxX(_bounds);
}

-(CGRect)frame{
    return CGRectMake(_position.x, _position.y, self.size.width, self.size.height);
}

- (NSString *)description {
    NSMutableString *desc = @"".mutableCopy;
    NSRange range = self.range;
    [desc appendFormat:@"<CSTextLine: %p> row:%zd range:%tu,%tu",self, self.row, range.location, range.length];
    [desc appendFormat:@" position:%@",NSStringFromCGPoint(self.position)];
    [desc appendFormat:@" bounds:%@",NSStringFromCGRect(self.bounds)];
    return desc;
}

@end



@implementation CSTextRunGlyphRange
+ (instancetype)rangeWithRange:(NSRange)range drawMode:(CSTextRunGlyphDrawMode)mode {
    CSTextRunGlyphRange *one = [self new];
    one.glyphRangeInRun = range;
    one.drawMode = mode;
    return one;
}
@end





