//
//  CSTestTableCell.h
//  CSCategory
//
//  Created by mac on 2017/7/28.
//  Copyright © 2017年 mac. All rights reserved.
//

#import "CSBaseCell.h"


@interface CSTestTableCell : CSBaseCell

@property (nonatomic, copy) void (^imageTouchBlock)(CSControl *view, NSArray<CSControl*>*aImageArr);

@end







