//
//  CSImageDecoder.m
//  CSCategory
//
//  Created by mac on 2017/7/20.
//  Copyright © 2017年 mac. All rights reserved.
//

#import "CSImageDecoder.h"
#import <CoreFoundation/CoreFoundation.h>
#import <ImageIO/ImageIO.h>
#import <Accelerate/Accelerate.h>
#import <QuartzCore/QuartzCore.h>
#import <MobileCoreServices/MobileCoreServices.h>
#import <AssetsLibrary/AssetsLibrary.h>
#import <objc/runtime.h>
#import <pthread.h>
#import <zlib.h>

#import "CSImage.h"
#import "CSKitMacro.h"



#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wunused-variable"

/**
 如果要出来 webp 图片就直接导入
 这里只是判断是否有导入 webp 框架
 
 @param <webp/decode.h> 框架头文件
 @return <#return value description#>
 */
#ifndef CSIMAGE_WEBP_ENABLED
#if __has_include(<webp/decode.h>) && __has_include(<webp/encode.h>) && \
__has_include(<webp/demux.h>)  && __has_include(<webp/mux.h>)
#define CSIMAGE_WEBP_ENABLED 1
#import <webp/decode.h>
#import <webp/encode.h>
#import <webp/demux.h>
#import <webp/mux.h>
#elif __has_include("webp/decode.h") && __has_include("webp/encode.h") && \
__has_include("webp/demux.h")  && __has_include("webp/mux.h")
#define CSIMAGE_WEBP_ENABLED 1
#import "webp/decode.h"
#import "webp/encode.h"
#import "webp/demux.h"
#import "webp/mux.h"
#else
#define CSIMAGE_WEBP_ENABLED 0
#endif
#endif



///MARK: ===================================================
///MARK: 通用
///MARK: ===================================================
#pragma mark - Utility (for little endian platform)

#define CS_FOUR_CC(c1,c2,c3,c4) ((uint32_t)(((c4) << 24) | ((c3) << 16) | ((c2) << 8) | (c1)))
#define CS_TWO_CC(c1,c2) ((uint16_t)(((c2) << 8) | (c1)))
/** 帧节数交换 */
static inline uint16_t cs_swap_endian_uint16(uint16_t value) {
    return
    (uint16_t) ((value & 0x00FF) << 8) |
    (uint16_t) ((value & 0xFF00) >> 8) ;
}
/** 帧节数交换 */
static inline uint32_t cs_swap_endian_uint32(uint32_t value) {
    return
    (uint32_t)((value & 0x000000FFU) << 24) |
    (uint32_t)((value & 0x0000FF00U) <<  8) |
    (uint32_t)((value & 0x00FF0000U) >>  8) |
    (uint32_t)((value & 0xFF000000U) >> 24) ;
}



///MARK: ===================================================
///MARK: APNG规范文档
///MARK: ===================================================
/*
 PNG  规范: http://www.libpng.org/pub/png/spec/1.2/PNG-Structure.html
 APNG 规范: https://wiki.mozilla.org/APNG_Specification
 
 ===============================================================================
 PNG 格式:
 头部 (8): 89 50 4e 47 0d 0a 1a 0a
 chunk, chunk, chunk, ...
 
 ===============================================================================
 chunk 格式:
 length (4): uint32_t big endian
 fourcc (4): chunk type code
 data   (length): data
 crc32  (4): uint32_t big endian crc32(fourcc + data)
 
 ===============================================================================
 PNG 块定义:
 
 IHDR (Image Header) 必须先出现13个字节
 width              (4) 像素数,不应该为0
 height             (4) 像素数,不应该为0
 bit depth          (1) expected: 1, 2, 4, 8, 16
 color type         (1) 1<<0 (palette used), 1<<1 (color used), 1<<2 (alpha channel used)
 compression method (1) 0 (deflate/inflate)
 filter method      (1) 0 (具有五种基本过滤类型的自适应过滤)
 interlace method   (1) 0 (没有隔行) or 1 (Adam7 交错隔行)
 
 IDAT (Image Data) 如果有多个'IDAT'块，则必须连续出现
 
 IEND (End) 必要, 必须在最后出现, 0 bytes
 
 ===============================================================================
 APNG 块定义:
 
 acTL (Animation Control) 必须出现在'IDAT'之前, 8 bytes
 num frames     (4) 帧数
 num plays      (4) 循环次数,0表示无限循环
 
 fcTL (Frame Control) 必须出现在它所适用的帧的'IDAT'或'fdAT'块之前, 26 bytes
 sequence number   (4) 动画块的序列号，从0开始
 width             (4) width of the following frame
 height            (4) height of the following frame
 x offset          (4) x position at which to render the following frame
 y offset          (4) y position at which to render the following frame
 delay num         (2) 帧延迟分数分子
 delay den         (2) 帧延迟分数分母
 dispose op        (1) 在渲染此框架后要进行的框架区域处理类型 (0:none, 1:background 2:previous)
 blend op          (1) 该帧的帧区域渲染类型 (0:source, 1:over)
 
 fdAT (Frame Data) required
 sequence number   (4) 动画块的序列号
 frame data        (x) 该帧的帧数据 (与..'IDAT'..一样 )
 
 ===============================================================================
 'dispose_op'指定在延迟结束时如何更改输出缓冲区
 (呈现下一帧之前).
 
 * NONE:       在渲染下一帧之前,不要对此框架进行处理,输出缓冲区的内容保持原样.
 * BACKGROUND: 在渲染下一帧之前,输出缓冲区的帧的区域将被清除为完全透明的黑色.
 * PREVIOUS:   在渲染下一帧之前,输出缓冲区的帧的区域将被还原到先前的内容.
 
 'blend_op'指定框架是将alpha混合到当前输出缓冲区内容中,还是应该完全替换输出缓冲区中的区域.
 
 * SOURCE: 帧的所有颜色分量,包括alpha,覆盖帧的输出缓冲区的当前内容.
 * OVER: 应使用PNG规范的'Alpha通道处理'部分所述的简单OVER操作,将框架基于其alpha复合到输出缓冲区上
 */




typedef NS_OPTIONS(NSUInteger, CS_PNG_ALPHA_TYPE) {
    CS_PNG_ALPHA_TYPE_PALEETE = 1 << 0,
    CS_PNG_ALPHA_TYPE_COLOR   = 1 << 1,
    CS_PNG_ALPHA_TYPE_ALPHA   = 1 << 2,
};

typedef NS_OPTIONS(NSUInteger, CS_PNG_DISPOSE_OP) {
    CS_PNG_DISPOSE_OP_NONE       = 1 << 0,
    CS_PNG_DISPOSE_OP_BACKGROUND = 1 << 1,
    CS_PNG_DISPOSE_OP_PREVIOUS   = 1 << 2,
};

typedef NS_OPTIONS(NSUInteger, CS_PNG_BLEND_OP) {
    CS_PNG_BLEND_OP_SOURCE = 1 << 0,
    CS_PNG_BLEND_OP_OVER = 1 << 1
};



typedef struct {
    uint32_t width;             ///< pixel count, should not be zero
    uint32_t height;            ///< pixel count, should not be zero
    uint8_t bit_depth;          ///< expected: 1, 2, 4, 8, 16
    uint8_t color_type;         ///< see yy_png_alpha_type
    uint8_t compression_method; ///< 0 (deflate/inflate)
    uint8_t filter_method;      ///< 0 (adaptive filtering with five basic filter types)
    uint8_t interlace_method;   ///< 0 (no interlace) or 1 (Adam7 interlace)
} cs_png_chunk_IHDR;

typedef struct {
    uint32_t sequence_number;  ///< sequence number of the animation chunk, starting from 0
    uint32_t width;            ///< width of the following frame
    uint32_t height;           ///< height of the following frame
    uint32_t x_offset;         ///< x position at which to render the following frame
    uint32_t y_offset;         ///< y position at which to render the following frame
    uint16_t delay_num;        ///< frame delay fraction numerator
    uint16_t delay_den;        ///< frame delay fraction denominator
    uint8_t dispose_op;        ///< see cs_png_dispose_op
    uint8_t blend_op;          ///< see cs_png_blend_op
} cs_png_chunk_fcTL;

typedef struct {
    uint32_t offset; ///< chunk offset in PNG data
    uint32_t fourcc; ///< chunk fourcc
    uint32_t length; ///< chunk data length
    uint32_t crc32;  ///< chunk crc32
} cs_png_chunk_info;

typedef struct {
    uint32_t chunk_index; ///< the first `fdAT`/`IDAT` chunk index
    uint32_t chunk_num;   ///< the `fdAT`/`IDAT` chunk count
    uint32_t chunk_size;  ///< the `fdAT`/`IDAT` chunk bytes
    cs_png_chunk_fcTL frame_control;
} cs_png_frame_info;

typedef struct {
    cs_png_chunk_IHDR header;   ///< png header
    cs_png_chunk_info *chunks;      ///< chunks
    uint32_t chunk_num;          ///< count of chunks
    
    cs_png_frame_info *apng_frames; ///< frame info, NULL if not apng
    uint32_t apng_frame_num;     ///< 0 if not apng
    uint32_t apng_loop_num;      ///< 0 indicates infinite looping
    
    uint32_t *apng_shared_chunk_indexs; ///< shared chunk index
    uint32_t apng_shared_chunk_num;     ///< shared chunk count
    uint32_t apng_shared_chunk_size;    ///< shared chunk bytes
    uint32_t apng_shared_insert_index;  ///< shared chunk insert index
    bool apng_first_frame_is_cover;     ///< the first frame is same as png (cover)
} cs_png_info;




static void cs_png_chunk_IHDR_read(cs_png_chunk_IHDR *IHDR, const uint8_t *data) {
    IHDR->width = cs_swap_endian_uint32(*((uint32_t *)(data)));
    IHDR->height = cs_swap_endian_uint32(*((uint32_t *)(data + 4)));
    IHDR->bit_depth = data[8];
    IHDR->color_type = data[9];
    IHDR->compression_method = data[10];
    IHDR->filter_method = data[11];
    IHDR->interlace_method = data[12];
}

static void cs_png_chunk_IHDR_write(cs_png_chunk_IHDR *IHDR, uint8_t *data) {
    *((uint32_t *)(data)) = cs_swap_endian_uint32(IHDR->width);
    *((uint32_t *)(data + 4)) = cs_swap_endian_uint32(IHDR->height);
    data[8] = IHDR->bit_depth;
    data[9] = IHDR->color_type;
    data[10] = IHDR->compression_method;
    data[11] = IHDR->filter_method;
    data[12] = IHDR->interlace_method;
}

static void cs_png_chunk_fcTL_read(cs_png_chunk_fcTL *fcTL, const uint8_t *data) {
    fcTL->sequence_number = cs_swap_endian_uint32(*((uint32_t *)(data)));
    fcTL->width = cs_swap_endian_uint32(*((uint32_t *)(data + 4)));
    fcTL->height = cs_swap_endian_uint32(*((uint32_t *)(data + 8)));
    fcTL->x_offset = cs_swap_endian_uint32(*((uint32_t *)(data + 12)));
    fcTL->y_offset = cs_swap_endian_uint32(*((uint32_t *)(data + 16)));
    fcTL->delay_num = cs_swap_endian_uint16(*((uint16_t *)(data + 20)));
    fcTL->delay_den = cs_swap_endian_uint16(*((uint16_t *)(data + 22)));
    fcTL->dispose_op = data[24];
    fcTL->blend_op = data[25];
}

static void cs_png_chunk_fcTL_write(cs_png_chunk_fcTL *fcTL, uint8_t *data) {
    *((uint32_t *)(data)) = cs_swap_endian_uint32(fcTL->sequence_number);
    *((uint32_t *)(data + 4)) = cs_swap_endian_uint32(fcTL->width);
    *((uint32_t *)(data + 8)) = cs_swap_endian_uint32(fcTL->height);
    *((uint32_t *)(data + 12)) = cs_swap_endian_uint32(fcTL->x_offset);
    *((uint32_t *)(data + 16)) = cs_swap_endian_uint32(fcTL->y_offset);
    *((uint16_t *)(data + 20)) = cs_swap_endian_uint16(fcTL->delay_num);
    *((uint16_t *)(data + 22)) = cs_swap_endian_uint16(fcTL->delay_den);
    data[24] = fcTL->dispose_op;
    data[25] = fcTL->blend_op;
}

// 将double值转换为分数
static void cs_png_delay_to_fraction(double duration, uint16_t *num, uint16_t *den) {
    if (duration >= 0xFF) {
        *num = 0xFF;
        *den = 1;
    } else if (duration <= 1.0 / (double)0xFF) {
        *num = 1;
        *den = 0xFF;
    } else {
        // 使用连续分数来计算num和den.
        long MAX = 10;
        double eps = (0.5 / (double)0xFF);
        long p[MAX], q[MAX], a[MAX], i, numl = 0, denl = 0;
        // 前两个渐近的0/1和1/0
        p[0] = 0; q[0] = 1;
        p[1] = 1; q[1] = 0;
        // 在渐近的其余部分(和连分数)
        for (i = 2; i < MAX; i++) {
            a[i] = lrint(floor(duration));
            p[i] = a[i] * p[i - 1] + p[i - 2];
            q[i] = a[i] * q[i - 1] + q[i - 2];
            if (p[i] <= 0xFF && q[i] <= 0xFF) { // uint16_t
                numl = p[i];
                denl = q[i];
            } else break;
            if (fabs(duration - a[i]) < eps) break;
            duration = 1.0 / (duration - a[i]);
        }
        
        if (numl != 0 && denl != 0) {
            *num = numl;
            *den = denl;
        } else {
            *num = 1;
            *den = 100;
        }
    }
}

// 将分数转换为双精度值
static double cs_png_delay_to_seconds(uint16_t num, uint16_t den) {
    if (den == 0) {
        return num / 100.0;
    } else {
        return (double)num / (double)den;
    }
}


static bool cs_png_validate_animation_chunk_order(cs_png_chunk_info *chunks,  /* input */
                                                  uint32_t chunk_num,         /* input */
                                                  uint32_t *first_idat_index, /* output */
                                                  bool *first_frame_is_cover  /* output */) {
    /*
     PNG at least contains 3 chunks: IHDR, IDAT, IEND.
     `IHDR` must appear first.
     `IDAT` must appear consecutively.
     `IEND` must appear end.
     
     APNG must contains one `acTL` and at least one 'fcTL' and `fdAT`.
     `fdAT` must appear consecutively.
     `fcTL` must appear before `IDAT` or `fdAT`.
     */
    if (chunk_num <= 2) return false;
    if (chunks->fourcc != CS_FOUR_CC('I', 'H', 'D', 'R')) return false;
    if ((chunks + chunk_num - 1)->fourcc != CS_FOUR_CC('I', 'E', 'N', 'D')) return false;
    
    uint32_t prev_fourcc = 0;
    uint32_t IHDR_num = 0;
    uint32_t IDAT_num = 0;
    uint32_t acTL_num = 0;
    uint32_t fcTL_num = 0;
    uint32_t first_IDAT = 0;
    bool first_frame_cover = false;
    for (uint32_t i = 0; i < chunk_num; i++) {
        cs_png_chunk_info *chunk = chunks + i;
        switch (chunk->fourcc) {
            case CS_FOUR_CC('I', 'H', 'D', 'R'): {  // png header
                if (i != 0) return false;
                if (IHDR_num > 0) return false;
                IHDR_num++;
            } break;
            case CS_FOUR_CC('I', 'D', 'A', 'T'): {  // png data
                if (prev_fourcc != CS_FOUR_CC('I', 'D', 'A', 'T')) {
                    if (IDAT_num == 0)
                        first_IDAT = i;
                    else
                        return false;
                }
                IDAT_num++;
            } break;
            case CS_FOUR_CC('a', 'c', 'T', 'L'): {  // apng control
                if (acTL_num > 0) return false;
                acTL_num++;
            } break;
            case CS_FOUR_CC('f', 'c', 'T', 'L'): {  // apng frame control
                if (i + 1 == chunk_num) return false;
                if ((chunk + 1)->fourcc != CS_FOUR_CC('f', 'd', 'A', 'T') &&
                    (chunk + 1)->fourcc != CS_FOUR_CC('I', 'D', 'A', 'T')) {
                    return false;
                }
                if (fcTL_num == 0) {
                    if ((chunk + 1)->fourcc == CS_FOUR_CC('I', 'D', 'A', 'T')) {
                        first_frame_cover = true;
                    }
                }
                fcTL_num++;
            } break;
            case CS_FOUR_CC('f', 'd', 'A', 'T'): {  // apng data
                if (prev_fourcc != CS_FOUR_CC('f', 'd', 'A', 'T') && prev_fourcc != CS_FOUR_CC('f', 'c', 'T', 'L')) {
                    return false;
                }
            } break;
        }
        prev_fourcc = chunk->fourcc;
    }
    if (IHDR_num != 1) return false;
    if (IDAT_num == 0) return false;
    if (acTL_num != 1) return false;
    if (fcTL_num < acTL_num) return false;
    *first_idat_index = first_IDAT;
    *first_frame_is_cover = first_frame_cover;
    return true;
}

static void cs_png_info_release(cs_png_info *info) {
    if (info) {
        if (info->chunks) free(info->chunks);
        if (info->apng_frames) free(info->apng_frames);
        if (info->apng_shared_chunk_indexs) free(info->apng_shared_chunk_indexs);
        free(info);
    }
}


/**
 Create a png info from a png file. See struct png_info for more information.
 
 @param data   png/apng file data.
 @param length the data's length in bytes.
 @return A png info object, you may call cs_png_info_release() to release it.
 Returns NULL if an error occurs.
 */
static cs_png_info *cs_png_info_create(const uint8_t *data, uint32_t length) {
    if (length < 32) return NULL;
    if (*((uint32_t *)data) != CS_FOUR_CC(0x89, 0x50, 0x4E, 0x47)) return NULL;
    if (*((uint32_t *)(data + 4)) != CS_FOUR_CC(0x0D, 0x0A, 0x1A, 0x0A)) return NULL;
    
    uint32_t chunk_realloc_num = 16;
    cs_png_chunk_info *chunks = malloc(sizeof(cs_png_chunk_info) * chunk_realloc_num);
    if (!chunks) return NULL;
    
    // parse png chunks
    uint32_t offset = 8;
    uint32_t chunk_num = 0;
    uint32_t chunk_capacity = chunk_realloc_num;
    uint32_t apng_loop_num = 0;
    int32_t apng_sequence_index = -1;
    int32_t apng_frame_index = 0;
    int32_t apng_frame_number = -1;
    bool apng_chunk_error = false;
    do {
        if (chunk_num >= chunk_capacity) {
            cs_png_chunk_info *new_chunks = realloc(chunks, sizeof(cs_png_chunk_info) * (chunk_capacity + chunk_realloc_num));
            if (!new_chunks) {
                free(chunks);
                return NULL;
            }
            chunks = new_chunks;
            chunk_capacity += chunk_realloc_num;
        }
        cs_png_chunk_info *chunk = chunks + chunk_num;
        const uint8_t *chunk_data = data + offset;
        chunk->offset = offset;
        chunk->length = cs_swap_endian_uint32(*((uint32_t *)chunk_data));
        if ((uint64_t)chunk->offset + (uint64_t)chunk->length + 12 > length) {
            free(chunks);
            return NULL;
        }
        
        chunk->fourcc = *((uint32_t *)(chunk_data + 4));
        if ((uint64_t)chunk->offset + 4 + chunk->length + 4 > (uint64_t)length) break;
        chunk->crc32 = cs_swap_endian_uint32(*((uint32_t *)(chunk_data + 8 + chunk->length)));
        chunk_num++;
        offset += 12 + chunk->length;
        
        switch (chunk->fourcc) {
            case CS_FOUR_CC('a', 'c', 'T', 'L') : {
                if (chunk->length == 8) {
                    apng_frame_number = cs_swap_endian_uint32(*((uint32_t *)(chunk_data + 8)));
                    apng_loop_num = cs_swap_endian_uint32(*((uint32_t *)(chunk_data + 12)));
                } else {
                    apng_chunk_error = true;
                }
            } break;
            case CS_FOUR_CC('f', 'c', 'T', 'L') :
            case CS_FOUR_CC('f', 'd', 'A', 'T') : {
                if (chunk->fourcc == CS_FOUR_CC('f', 'c', 'T', 'L')) {
                    if (chunk->length != 26) {
                        apng_chunk_error = true;
                    } else {
                        apng_frame_index++;
                    }
                }
                if (chunk->length > 4) {
                    uint32_t sequence = cs_swap_endian_uint32(*((uint32_t *)(chunk_data + 8)));
                    if (apng_sequence_index + 1 == sequence) {
                        apng_sequence_index++;
                    } else {
                        apng_chunk_error = true;
                    }
                } else {
                    apng_chunk_error = true;
                }
            } break;
            case CS_FOUR_CC('I', 'E', 'N', 'D') : {
                offset = length; // end, break do-while loop
            } break;
        }
    } while (offset + 12 <= length);
    
    if (chunk_num < 3 ||
        chunks->fourcc != CS_FOUR_CC('I', 'H', 'D', 'R') ||
        chunks->length != 13) {
        free(chunks);
        return NULL;
    }
    
    // png info
    cs_png_info *info = calloc(1, sizeof(cs_png_info));
    if (!info) {
        free(chunks);
        return NULL;
    }
    info->chunks = chunks;
    info->chunk_num = chunk_num;
    cs_png_chunk_IHDR_read(&info->header, data + chunks->offset + 8);
    
    // apng info
    if (!apng_chunk_error && apng_frame_number == apng_frame_index && apng_frame_number >= 1) {
        bool first_frame_is_cover = false;
        uint32_t first_IDAT_index = 0;
        if (!cs_png_validate_animation_chunk_order(info->chunks, info->chunk_num, &first_IDAT_index, &first_frame_is_cover)) {
            return info; // ignore apng chunk
        }
        
        info->apng_loop_num = apng_loop_num;
        info->apng_frame_num = apng_frame_number;
        info->apng_first_frame_is_cover = first_frame_is_cover;
        info->apng_shared_insert_index = first_IDAT_index;
        info->apng_frames = calloc(apng_frame_number, sizeof(cs_png_frame_info));
        if (!info->apng_frames) {
            cs_png_info_release(info);
            return NULL;
        }
        info->apng_shared_chunk_indexs = calloc(info->chunk_num, sizeof(uint32_t));
        if (!info->apng_shared_chunk_indexs) {
            cs_png_info_release(info);
            return NULL;
        }
        
        int32_t frame_index = -1;
        uint32_t *shared_chunk_index = info->apng_shared_chunk_indexs;
        for (int32_t i = 0; i < info->chunk_num; i++) {
            cs_png_chunk_info *chunk = info->chunks + i;
            switch (chunk->fourcc) {
                case CS_FOUR_CC('I', 'D', 'A', 'T'): {
                    if (info->apng_shared_insert_index == 0) {
                        info->apng_shared_insert_index = i;
                    }
                    if (first_frame_is_cover) {
                        cs_png_frame_info *frame = info->apng_frames + frame_index;
                        frame->chunk_num++;
                        frame->chunk_size += chunk->length + 12;
                    }
                } break;
                case CS_FOUR_CC('a', 'c', 'T', 'L'): {
                } break;
                case CS_FOUR_CC('f', 'c', 'T', 'L'): {
                    frame_index++;
                    cs_png_frame_info *frame = info->apng_frames + frame_index;
                    frame->chunk_index = i + 1;
                    cs_png_chunk_fcTL_read(&frame->frame_control, data + chunk->offset + 8);
                } break;
                case CS_FOUR_CC('f', 'd', 'A', 'T'): {
                    cs_png_frame_info *frame = info->apng_frames + frame_index;
                    frame->chunk_num++;
                    frame->chunk_size += chunk->length + 12;
                } break;
                default: {
                    *shared_chunk_index = i;
                    shared_chunk_index++;
                    info->apng_shared_chunk_size += chunk->length + 12;
                    info->apng_shared_chunk_num++;
                } break;
            }
        }
    }
    return info;
}

/**
 Copy a png frame data from an apng file.
 
 @param data  apng file data
 @param info  png info
 @param index frame index (zero-based)
 @param size  output, the size of the frame data
 @return A frame data (single-frame png file), call free() to release the data.
 Returns NULL if an error occurs.
 */
static uint8_t *cs_png_copy_frame_data_at_index(const uint8_t *data,
                                                const cs_png_info *info,
                                                const uint32_t index,
                                                uint32_t *size) {
    if (index >= info->apng_frame_num) return NULL;
    
    cs_png_frame_info *frame_info = info->apng_frames + index;
    uint32_t frame_remux_size = 8 /* PNG Header */ + info->apng_shared_chunk_size + frame_info->chunk_size;
    if (!(info->apng_first_frame_is_cover && index == 0)) {
        frame_remux_size -= frame_info->chunk_num * 4; // remove fdAT sequence number
    }
    uint8_t *frame_data = malloc(frame_remux_size);
    if (!frame_data) return NULL;
    *size = frame_remux_size;
    
    uint32_t data_offset = 0;
    bool inserted = false;
    memcpy(frame_data, data, 8); // PNG File Header
    data_offset += 8;
    for (uint32_t i = 0; i < info->apng_shared_chunk_num; i++) {
        uint32_t shared_chunk_index = info->apng_shared_chunk_indexs[i];
        cs_png_chunk_info *shared_chunk_info = info->chunks + shared_chunk_index;
        
        if (shared_chunk_index >= info->apng_shared_insert_index && !inserted) { // replace IDAT with fdAT
            inserted = true;
            for (uint32_t c = 0; c < frame_info->chunk_num; c++) {
                cs_png_chunk_info *insert_chunk_info = info->chunks + frame_info->chunk_index + c;
                if (insert_chunk_info->fourcc == CS_FOUR_CC('f', 'd', 'A', 'T')) {
                    *((uint32_t *)(frame_data + data_offset)) = cs_swap_endian_uint32(insert_chunk_info->length - 4);
                    *((uint32_t *)(frame_data + data_offset + 4)) = CS_FOUR_CC('I', 'D', 'A', 'T');
                    memcpy(frame_data + data_offset + 8, data + insert_chunk_info->offset + 12, insert_chunk_info->length - 4);
                    uint32_t crc = (uint32_t)crc32(0, frame_data + data_offset + 4, insert_chunk_info->length);
                    *((uint32_t *)(frame_data + data_offset + insert_chunk_info->length + 4)) = cs_swap_endian_uint32(crc);
                    data_offset += insert_chunk_info->length + 8;
                } else { // IDAT
                    memcpy(frame_data + data_offset, data + insert_chunk_info->offset, insert_chunk_info->length + 12);
                    data_offset += insert_chunk_info->length + 12;
                }
            }
        }
        
        if (shared_chunk_info->fourcc == CS_FOUR_CC('I', 'H', 'D', 'R')) {
            uint8_t tmp[25] = {0};
            memcpy(tmp, data + shared_chunk_info->offset, 25);
            cs_png_chunk_IHDR IHDR = info->header;
            IHDR.width = frame_info->frame_control.width;
            IHDR.height = frame_info->frame_control.height;
            cs_png_chunk_IHDR_write(&IHDR, tmp + 8);
            *((uint32_t *)(tmp + 21)) = cs_swap_endian_uint32((uint32_t)crc32(0, tmp + 4, 17));
            memcpy(frame_data + data_offset, tmp, 25);
            data_offset += 25;
        } else {
            memcpy(frame_data + data_offset, data + shared_chunk_info->offset, shared_chunk_info->length + 12);
            data_offset += shared_chunk_info->length + 12;
        }
    }
    return frame_data;
}






////////////////////////////////////////////////////////////////////////////////
#pragma mark - Helper

/// Returns byte-aligned size.
static inline size_t CSImageByteAlign(size_t size, size_t alignment) {
    return ((size + (alignment - 1)) / alignment) * alignment;
}

/// Convert degree to radians
static inline CGFloat CSImageDegreesToRadians(CGFloat degrees) {
    return degrees * M_PI / 180;
}

CGColorSpaceRef CSCGColorSpaceGetDeviceRGB() {
    static CGColorSpaceRef space;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        space = CGColorSpaceCreateDeviceRGB();
    });
    return space;
}

CGColorSpaceRef CSCGColorSpaceGetDeviceGray() {
    static CGColorSpaceRef space;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        space = CGColorSpaceCreateDeviceGray();
    });
    return space;
}

BOOL CSCGColorSpaceIsDeviceRGB(CGColorSpaceRef space) {
    return space && CFEqual(space, CSCGColorSpaceGetDeviceRGB());
}

BOOL CSCGColorSpaceIsDeviceGray(CGColorSpaceRef space) {
    return space && CFEqual(space, CSCGColorSpaceGetDeviceGray());
}

/**
 A callback used in CGDataProviderCreateWithData() to release data.
 
 Example:
 
 void *data = malloc(size);
 CGDataProviderRef provider = CGDataProviderCreateWithData(data, data, size, CSCGDataProviderReleaseDataCallback);
 */
static void CSCGDataProviderReleaseDataCallback(void *info, const void *data, size_t size) {
    if (info) free(info);
}

/**
 Decode an image to bitmap buffer with the specified format.
 
 @param srcImage   Source image.
 @param dest       Destination buffer. It should be zero before call this method.
 If decode succeed, you should release the dest->data using free().
 @param destFormat Destination bitmap format.
 
 @return Whether succeed.
 
 @warning This method support iOS7.0 and later. If call it on iOS6, it just returns NO.
 CG_AVAILABLE_STARTING(__MAC_10_9, __IPHONE_7_0)
 */
static BOOL CSCGImageDecodeToBitmapBufferWithAnyFormat(CGImageRef srcImage, vImage_Buffer *dest, vImage_CGImageFormat *destFormat) {
    if (!srcImage || (((long)vImageConvert_AnyToAny) + 1 == 1) || !destFormat || !dest) return NO;
    size_t width = CGImageGetWidth(srcImage);
    size_t height = CGImageGetHeight(srcImage);
    if (width == 0 || height == 0) return NO;
    dest->data = NULL;
    
    vImage_Error error = kvImageNoError;
    CFDataRef srcData = NULL;
    vImageConverterRef convertor = NULL;
    vImage_CGImageFormat srcFormat = {0};
    srcFormat.bitsPerComponent = (uint32_t)CGImageGetBitsPerComponent(srcImage);
    srcFormat.bitsPerPixel = (uint32_t)CGImageGetBitsPerPixel(srcImage);
    srcFormat.colorSpace = CGImageGetColorSpace(srcImage);
    srcFormat.bitmapInfo = CGImageGetBitmapInfo(srcImage) | CGImageGetAlphaInfo(srcImage);
    
    convertor = vImageConverter_CreateWithCGImageFormat(&srcFormat, destFormat, NULL, kvImageNoFlags, NULL);
    if (!convertor) goto fail;
    
    CGDataProviderRef srcProvider = CGImageGetDataProvider(srcImage);
    srcData = srcProvider ? CGDataProviderCopyData(srcProvider) : NULL; // decode
    size_t srcLength = srcData ? CFDataGetLength(srcData) : 0;
    const void *srcBytes = srcData ? CFDataGetBytePtr(srcData) : NULL;
    if (srcLength == 0 || !srcBytes) goto fail;
    
    vImage_Buffer src = {0};
    src.data = (void *)srcBytes;
    src.width = width;
    src.height = height;
    src.rowBytes = CGImageGetBytesPerRow(srcImage);
    
    error = vImageBuffer_Init(dest, height, width, 32, kvImageNoFlags);
    if (error != kvImageNoError) goto fail;
    
    error = vImageConvert_AnyToAny(convertor, &src, dest, NULL, kvImageNoFlags); // convert
    if (error != kvImageNoError) goto fail;
    
    CFRelease(convertor);
    CFRelease(srcData);
    return YES;
    
fail:
    if (convertor) CFRelease(convertor);
    if (srcData) CFRelease(srcData);
    if (dest->data) free(dest->data);
    dest->data = NULL;
    return NO;
}



/**
 Decode an image to bitmap buffer with the 32bit format (such as ARGB8888).
 
 @param srcImage   Source image.
 @param dest       Destination buffer. It should be zero before call this method.
 If decode succeed, you should release the dest->data using free().
 @param bitmapInfo Destination bitmap format.
 
 @return Whether succeed.
 */
static BOOL CSCGImageDecodeToBitmapBufferWith32BitFormat(CGImageRef srcImage, vImage_Buffer *dest, CGBitmapInfo bitmapInfo) {
    if (!srcImage || !dest) return NO;
    size_t width = CGImageGetWidth(srcImage);
    size_t height = CGImageGetHeight(srcImage);
    if (width == 0 || height == 0) return NO;
    
    BOOL hasAlpha = NO;
    BOOL alphaFirst = NO;
    BOOL alphaPremultiplied = NO;
    BOOL byteOrderNormal = NO;
    
    switch (bitmapInfo & kCGBitmapAlphaInfoMask) {
        case kCGImageAlphaPremultipliedLast: {
            hasAlpha = YES;
            alphaPremultiplied = YES;
        } break;
        case kCGImageAlphaPremultipliedFirst: {
            hasAlpha = YES;
            alphaPremultiplied = YES;
            alphaFirst = YES;
        } break;
        case kCGImageAlphaLast: {
            hasAlpha = YES;
        } break;
        case kCGImageAlphaFirst: {
            hasAlpha = YES;
            alphaFirst = YES;
        } break;
        case kCGImageAlphaNoneSkipLast: {
        } break;
        case kCGImageAlphaNoneSkipFirst: {
            alphaFirst = YES;
        } break;
        default: {
            return NO;
        } break;
    }
    
    switch (bitmapInfo & kCGBitmapByteOrderMask) {
        case kCGBitmapByteOrderDefault: {
            byteOrderNormal = YES;
        } break;
        case kCGBitmapByteOrder32Little: {
        } break;
        case kCGBitmapByteOrder32Big: {
            byteOrderNormal = YES;
        } break;
        default: {
            return NO;
        } break;
    }
    
    /*
     Try convert with vImageConvert_AnyToAny() (avaliable since iOS 7.0).
     If fail, try decode with CGContextDrawImage().
     CGBitmapContext use a premultiplied alpha format, unpremultiply may lose precision.
     */
    vImage_CGImageFormat destFormat = {0};
    destFormat.bitsPerComponent = 8;
    destFormat.bitsPerPixel = 32;
    destFormat.colorSpace = CSCGColorSpaceGetDeviceRGB();
    destFormat.bitmapInfo = bitmapInfo;
    dest->data = NULL;
    if (CSCGImageDecodeToBitmapBufferWithAnyFormat(srcImage, dest, &destFormat)) return YES;
    
    CGBitmapInfo contextBitmapInfo = bitmapInfo & kCGBitmapByteOrderMask;
    if (!hasAlpha || alphaPremultiplied) {
        contextBitmapInfo |= (bitmapInfo & kCGBitmapAlphaInfoMask);
    } else {
        contextBitmapInfo |= alphaFirst ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaPremultipliedLast;
    }
    CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, CSCGColorSpaceGetDeviceRGB(), contextBitmapInfo);
    if (!context) goto fail;
    
    CGContextDrawImage(context, CGRectMake(0, 0, width, height), srcImage); // decode and convert
    size_t bytesPerRow = CGBitmapContextGetBytesPerRow(context);
    size_t length = height * bytesPerRow;
    void *data = CGBitmapContextGetData(context);
    if (length == 0 || !data) goto fail;
    
    dest->data = malloc(length);
    dest->width = width;
    dest->height = height;
    dest->rowBytes = bytesPerRow;
    if (!dest->data) goto fail;
    
    if (hasAlpha && !alphaPremultiplied) {
        vImage_Buffer tmpSrc = {0};
        tmpSrc.data = data;
        tmpSrc.width = width;
        tmpSrc.height = height;
        tmpSrc.rowBytes = bytesPerRow;
        vImage_Error error;
        if (alphaFirst && byteOrderNormal) {
            error = vImageUnpremultiplyData_ARGB8888(&tmpSrc, dest, kvImageNoFlags);
        } else {
            error = vImageUnpremultiplyData_RGBA8888(&tmpSrc, dest, kvImageNoFlags);
        }
        if (error != kvImageNoError) goto fail;
    } else {
        memcpy(dest->data, data, length);
    }
    
    CFRelease(context);
    return YES;
    
fail:
    if (context) CFRelease(context);
    if (dest->data) free(dest->data);
    dest->data = NULL;
    return NO;
    return NO;
}

CGImageRef CSCGImageCreateDecodedCopy(CGImageRef imageRef, BOOL decodeForDisplay) {
    if (!imageRef) return NULL;
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    if (width == 0 || height == 0) return NULL;
    
    if (decodeForDisplay) { //decode with redraw (may lose some precision)
        CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(imageRef) & kCGBitmapAlphaInfoMask;
        BOOL hasAlpha = NO;
        if (alphaInfo == kCGImageAlphaPremultipliedLast ||
            alphaInfo == kCGImageAlphaPremultipliedFirst ||
            alphaInfo == kCGImageAlphaLast ||
            alphaInfo == kCGImageAlphaFirst) {
            hasAlpha = YES;
        }
        // BGRA8888 (premultiplied) or BGRX8888
        // same as UIGraphicsBeginImageContext() and -[UIView drawRect:]
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host;
        bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
        CGContextRef context = CGBitmapContextCreate(NULL, width, height, 8, 0, CSCGColorSpaceGetDeviceRGB(), bitmapInfo);
        if (!context) return NULL;
        CGContextDrawImage(context, CGRectMake(0, 0, width, height), imageRef); // decode
        CGImageRef newImage = CGBitmapContextCreateImage(context);
        CFRelease(context);
        return newImage;
        
    } else {
        CGColorSpaceRef space = CGImageGetColorSpace(imageRef);
        size_t bitsPerComponent = CGImageGetBitsPerComponent(imageRef);
        size_t bitsPerPixel = CGImageGetBitsPerPixel(imageRef);
        size_t bytesPerRow = CGImageGetBytesPerRow(imageRef);
        CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
        if (bytesPerRow == 0 || width == 0 || height == 0) return NULL;
        
        CGDataProviderRef dataProvider = CGImageGetDataProvider(imageRef);
        if (!dataProvider) return NULL;
        CFDataRef data = CGDataProviderCopyData(dataProvider); // decode
        if (!data) return NULL;
        
        CGDataProviderRef newProvider = CGDataProviderCreateWithCFData(data);
        CFRelease(data);
        if (!newProvider) return NULL;
        
        CGImageRef newImage = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, space, bitmapInfo, newProvider, NULL, false, kCGRenderingIntentDefault);
        CFRelease(newProvider);
        return newImage;
    }
}

CGImageRef CSCGImageCreateAffineTransformCopy(CGImageRef imageRef, CGAffineTransform transform, CGSize destSize, CGBitmapInfo destBitmapInfo) {
    if (!imageRef) return NULL;
    size_t srcWidth = CGImageGetWidth(imageRef);
    size_t srcHeight = CGImageGetHeight(imageRef);
    size_t destWidth = round(destSize.width);
    size_t destHeight = round(destSize.height);
    if (srcWidth == 0 || srcHeight == 0 || destWidth == 0 || destHeight == 0) return NULL;
    
    CGDataProviderRef tmpProvider = NULL, destProvider = NULL;
    CGImageRef tmpImage = NULL, destImage = NULL;
    vImage_Buffer src = {0}, tmp = {0}, dest = {0};
    if(!CSCGImageDecodeToBitmapBufferWith32BitFormat(imageRef, &src, kCGImageAlphaFirst | kCGBitmapByteOrderDefault)) return NULL;
    
    size_t destBytesPerRow = CSImageByteAlign(destWidth * 4, 32);
    tmp.data = malloc(destHeight * destBytesPerRow);
    if (!tmp.data) goto fail;
    
    tmp.width = destWidth;
    tmp.height = destHeight;
    tmp.rowBytes = destBytesPerRow;
    vImage_CGAffineTransform vTransform = *((vImage_CGAffineTransform *)&transform);
    uint8_t backColor[4] = {0};
    vImage_Error error = vImageAffineWarpCG_ARGB8888(&src, &tmp, NULL, &vTransform, backColor, kvImageBackgroundColorFill);
    if (error != kvImageNoError) goto fail;
    free(src.data);
    src.data = NULL;
    
    tmpProvider = CGDataProviderCreateWithData(tmp.data, tmp.data, destHeight * destBytesPerRow, CSCGDataProviderReleaseDataCallback);
    if (!tmpProvider) goto fail;
    tmp.data = NULL; // hold by provider
    tmpImage = CGImageCreate(destWidth, destHeight, 8, 32, destBytesPerRow, CSCGColorSpaceGetDeviceRGB(), kCGImageAlphaFirst | kCGBitmapByteOrderDefault, tmpProvider, NULL, false, kCGRenderingIntentDefault);
    if (!tmpImage) goto fail;
    CFRelease(tmpProvider);
    tmpProvider = NULL;
    
    if ((destBitmapInfo & kCGBitmapAlphaInfoMask) == kCGImageAlphaFirst &&
        (destBitmapInfo & kCGBitmapByteOrderMask) != kCGBitmapByteOrder32Little) {
        return tmpImage;
    }
    
    if (!CSCGImageDecodeToBitmapBufferWith32BitFormat(tmpImage, &dest, destBitmapInfo)) goto fail;
    CFRelease(tmpImage);
    tmpImage = NULL;
    
    destProvider = CGDataProviderCreateWithData(dest.data, dest.data, destHeight * destBytesPerRow, CSCGDataProviderReleaseDataCallback);
    if (!destProvider) goto fail;
    dest.data = NULL; // hold by provider
    destImage = CGImageCreate(destWidth, destHeight, 8, 32, destBytesPerRow, CSCGColorSpaceGetDeviceRGB(), destBitmapInfo, destProvider, NULL, false, kCGRenderingIntentDefault);
    if (!destImage) goto fail;
    CFRelease(destProvider);
    destProvider = NULL;
    
    return destImage;
    
fail:
    if (src.data) free(src.data);
    if (tmp.data) free(tmp.data);
    if (dest.data) free(dest.data);
    if (tmpProvider) CFRelease(tmpProvider);
    if (tmpImage) CFRelease(tmpImage);
    if (destProvider) CFRelease(destProvider);
    return NULL;
}


UIImageOrientation CSUIImageOrientationFromEXIFValue(NSInteger value) {
    switch (value) {
        case kCGImagePropertyOrientationUp: return UIImageOrientationUp;
        case kCGImagePropertyOrientationDown: return UIImageOrientationDown;
        case kCGImagePropertyOrientationLeft: return UIImageOrientationLeft;
        case kCGImagePropertyOrientationRight: return UIImageOrientationRight;
        case kCGImagePropertyOrientationUpMirrored: return UIImageOrientationUpMirrored;
        case kCGImagePropertyOrientationDownMirrored: return UIImageOrientationDownMirrored;
        case kCGImagePropertyOrientationLeftMirrored: return UIImageOrientationLeftMirrored;
        case kCGImagePropertyOrientationRightMirrored: return UIImageOrientationRightMirrored;
        default: return UIImageOrientationUp;
    }
}

NSInteger CSUIImageOrientationToEXIFValue(UIImageOrientation orientation) {
    switch (orientation) {
        case UIImageOrientationUp: return kCGImagePropertyOrientationUp;
        case UIImageOrientationDown: return kCGImagePropertyOrientationDown;
        case UIImageOrientationLeft: return kCGImagePropertyOrientationLeft;
        case UIImageOrientationRight: return kCGImagePropertyOrientationRight;
        case UIImageOrientationUpMirrored: return kCGImagePropertyOrientationUpMirrored;
        case UIImageOrientationDownMirrored: return kCGImagePropertyOrientationDownMirrored;
        case UIImageOrientationLeftMirrored: return kCGImagePropertyOrientationLeftMirrored;
        case UIImageOrientationRightMirrored: return kCGImagePropertyOrientationRightMirrored;
        default: return kCGImagePropertyOrientationUp;
    }
}

CGImageRef CSCGImageCreateCopyWithOrientation(CGImageRef imageRef, UIImageOrientation orientation, CGBitmapInfo destBitmapInfo) {
    if (!imageRef) return NULL;
    if (orientation == UIImageOrientationUp) return (CGImageRef)CFRetain(imageRef);
    
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    
    CGAffineTransform transform = CGAffineTransformIdentity;
    BOOL swapWidthAndHeight = NO;
    switch (orientation) {
        case UIImageOrientationDown: {
            transform = CGAffineTransformMakeRotation(CSImageDegreesToRadians(180));
            transform = CGAffineTransformTranslate(transform, -(CGFloat)width, -(CGFloat)height);
        } break;
        case UIImageOrientationLeft: {
            transform = CGAffineTransformMakeRotation(CSImageDegreesToRadians(90));
            transform = CGAffineTransformTranslate(transform, -(CGFloat)0, -(CGFloat)height);
            swapWidthAndHeight = YES;
        } break;
        case UIImageOrientationRight: {
            transform = CGAffineTransformMakeRotation(CSImageDegreesToRadians(-90));
            transform = CGAffineTransformTranslate(transform, -(CGFloat)width, (CGFloat)0);
            swapWidthAndHeight = YES;
        } break;
        case UIImageOrientationUpMirrored: {
            transform = CGAffineTransformTranslate(transform, (CGFloat)width, 0);
            transform = CGAffineTransformScale(transform, -1, 1);
        } break;
        case UIImageOrientationDownMirrored: {
            transform = CGAffineTransformTranslate(transform, 0, (CGFloat)height);
            transform = CGAffineTransformScale(transform, 1, -1);
        } break;
        case UIImageOrientationLeftMirrored: {
            transform = CGAffineTransformMakeRotation(CSImageDegreesToRadians(-90));
            transform = CGAffineTransformScale(transform, 1, -1);
            transform = CGAffineTransformTranslate(transform, -(CGFloat)width, -(CGFloat)height);
            swapWidthAndHeight = YES;
        } break;
        case UIImageOrientationRightMirrored: {
            transform = CGAffineTransformMakeRotation(CSImageDegreesToRadians(90));
            transform = CGAffineTransformScale(transform, 1, -1);
            swapWidthAndHeight = YES;
        } break;
        default: break;
    }
    if (CGAffineTransformIsIdentity(transform)) return (CGImageRef)CFRetain(imageRef);
    
    CGSize destSize = {width, height};
    if (swapWidthAndHeight) {
        destSize.width = height;
        destSize.height = width;
    }
    
    return CSCGImageCreateAffineTransformCopy(imageRef, transform, destSize, destBitmapInfo);
}

CSImageType CSImageDetectType(CFDataRef data) {
    if (!data) return CSImageTypeUnknown;
    uint64_t length = CFDataGetLength(data);
    if (length < 16) return CSImageTypeUnknown;
    
    const char *bytes = (char *)CFDataGetBytePtr(data);
    
    uint32_t magic4 = *((uint32_t *)bytes);
    switch (magic4) {
        case CS_FOUR_CC(0x4D, 0x4D, 0x00, 0x2A): { // big endian TIFF
            return CSImageTypeTIFF;
        } break;
            
        case CS_FOUR_CC(0x49, 0x49, 0x2A, 0x00): { // little endian TIFF
            return CSImageTypeTIFF;
        } break;
            
        case CS_FOUR_CC(0x00, 0x00, 0x01, 0x00): { // ICO
            return CSImageTypeICO;
        } break;
            
        case CS_FOUR_CC(0x00, 0x00, 0x02, 0x00): { // CUR
            return CSImageTypeICO;
        } break;
            
        case CS_FOUR_CC('i', 'c', 'n', 's'): { // ICNS
            return CSImageTypeICNS;
        } break;
            
        case CS_FOUR_CC('G', 'I', 'F', '8'): { // GIF
            return CSImageTypeGIF;
        } break;
            
        case CS_FOUR_CC(0x89, 'P', 'N', 'G'): {  // PNG
            uint32_t tmp = *((uint32_t *)(bytes + 4));
            if (tmp == CS_FOUR_CC('\r', '\n', 0x1A, '\n')) {
                return CSImageTypePNG;
            }
        } break;
            
        case CS_FOUR_CC('R', 'I', 'F', 'F'): { // WebP
            uint32_t tmp = *((uint32_t *)(bytes + 8));
            if (tmp == CS_FOUR_CC('W', 'E', 'B', 'P')) {
                return CSImageTypeWebP;
            }
        } break;
            /*
             case CS_FOUR_CC('B', 'P', 'G', 0xFB): { // BPG
             return CSImageTypeBPG;
             } break;
             */
    }
    
    uint16_t magic2 = *((uint16_t *)bytes);
    switch (magic2) {
        case CS_TWO_CC('B', 'A'):
        case CS_TWO_CC('B', 'M'):
        case CS_TWO_CC('I', 'C'):
        case CS_TWO_CC('P', 'I'):
        case CS_TWO_CC('C', 'I'):
        case CS_TWO_CC('C', 'P'): { // BMP
            return CSImageTypeBMP;
        }
        case CS_TWO_CC(0xFF, 0x4F): { // JPEG2000
            return CSImageTypeJPEG2000;
        }
    }
    
    // JPG             FF D8 FF
    if (memcmp(bytes,"\377\330\377",3) == 0) return CSImageTypeJPEG;
    
    // JP2
    if (memcmp(bytes + 4, "\152\120\040\040\015", 5) == 0) return CSImageTypeJPEG2000;
    
    return CSImageTypeUnknown;
}



CFStringRef CSImageTypeToUTType(CSImageType type) {
    switch (type) {
        case CSImageTypeJPEG: return kUTTypeJPEG;
        case CSImageTypeJPEG2000: return kUTTypeJPEG2000;
        case CSImageTypeTIFF: return kUTTypeTIFF;
        case CSImageTypeBMP: return kUTTypeBMP;
        case CSImageTypeICO: return kUTTypeICO;
        case CSImageTypeICNS: return kUTTypeAppleICNS;
        case CSImageTypeGIF: return kUTTypeGIF;
        case CSImageTypePNG: return kUTTypePNG;
        default: return NULL;
    }
}

CSImageType CSImageTypeFromUTType(CFStringRef uti) {
    static NSDictionary *dic;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        dic = @{(id)kUTTypeJPEG : @(CSImageTypeJPEG),
                (id)kUTTypeJPEG2000 : @(CSImageTypeJPEG2000),
                (id)kUTTypeTIFF : @(CSImageTypeTIFF),
                (id)kUTTypeBMP : @(CSImageTypeBMP),
                (id)kUTTypeICO : @(CSImageTypeICO),
                (id)kUTTypeAppleICNS : @(CSImageTypeICNS),
                (id)kUTTypeGIF : @(CSImageTypeGIF),
                (id)kUTTypePNG : @(CSImageTypePNG)};
    });
    if (!uti) return CSImageTypeUnknown;
    NSNumber *num = dic[(__bridge __strong id)(uti)];
    return num.unsignedIntegerValue;
}

NSString *CSImageTypeGetExtension(CSImageType type) {
    switch (type) {
        case CSImageTypeJPEG: return @"jpg";
        case CSImageTypeJPEG2000: return @"jp2";
        case CSImageTypeTIFF: return @"tiff";
        case CSImageTypeBMP: return @"bmp";
        case CSImageTypeICO: return @"ico";
        case CSImageTypeICNS: return @"icns";
        case CSImageTypeGIF: return @"gif";
        case CSImageTypePNG: return @"png";
        case CSImageTypeWebP: return @"webp";
        default: return nil;
    }
}

CFDataRef CSCGImageCreateEncodedData(CGImageRef imageRef, CSImageType type, CGFloat quality) {
    if (!imageRef) return nil;
    quality = quality < 0 ? 0 : quality > 1 ? 1 : quality;
    
    if (type == CSImageTypeWebP) {
#if CSIMAGE_WEBP_ENABLED
        if (quality == 1) {
            return CSCGImageCreateEncodedWebPData(imageRef, YES, quality, 4, CSImagePresetDefault);
        } else {
            return CSCGImageCreateEncodedWebPData(imageRef, NO, quality, 4, CSImagePresetDefault);
        }
#else
        return NULL;
#endif
    }
    
    CFStringRef uti = CSImageTypeToUTType(type);
    if (!uti) return nil;
    
    CFMutableDataRef data = CFDataCreateMutable(CFAllocatorGetDefault(), 0);
    if (!data) return NULL;
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, NULL);
    if (!dest) {
        CFRelease(data);
        return NULL;
    }
    NSDictionary *options = @{(id)kCGImageDestinationLossyCompressionQuality : @(quality) };
    CGImageDestinationAddImage(dest, imageRef, (CFDictionaryRef)options);
    if (!CGImageDestinationFinalize(dest)) {
        CFRelease(data);
        CFRelease(dest);
        return nil;
    }
    CFRelease(dest);
    
    if (CFDataGetLength(data) == 0) {
        CFRelease(data);
        return NULL;
    }
    return data;
}

#if CSIMAGE_WEBP_ENABLED

BOOL CSImageWebPAvailable() {
    return YES;
}

CFDataRef CSCGImageCreateEncodedWebPData(CGImageRef imageRef, BOOL lossless, CGFloat quality, int compressLevel, CSImagePreset preset) {
    if (!imageRef) return nil;
    size_t width = CGImageGetWidth(imageRef);
    size_t height = CGImageGetHeight(imageRef);
    if (width == 0 || width > WEBP_MAX_DIMENSION) return nil;
    if (height == 0 || height > WEBP_MAX_DIMENSION) return nil;
    
    vImage_Buffer buffer = {0};
    if(!CSCGImageDecodeToBitmapBufferWith32BitFormat(imageRef, &buffer, kCGImageAlphaLast | kCGBitmapByteOrderDefault)) return nil;
    
    WebPConfig config = {0};
    WebPPicture picture = {0};
    WebPMemoryWriter writer = {0};
    CFDataRef webpData = NULL;
    BOOL pictureNeedFree = NO;
    
    quality = quality < 0 ? 0 : quality > 1 ? 1 : quality;
    preset = preset > CSImagePresetText ? CSImagePresetDefault : preset;
    compressLevel = compressLevel < 0 ? 0 : compressLevel > 6 ? 6 : compressLevel;
    if (!WebPConfigPreset(&config, (WebPPreset)preset, quality)) goto fail;
    
    config.quality = round(quality * 100.0);
    config.lossless = lossless;
    config.method = compressLevel;
    switch ((WebPPreset)preset) {
        case WEBP_PRESET_DEFAULT: {
            config.image_hint = WEBP_HINT_DEFAULT;
        } break;
        case WEBP_PRESET_PICTURE: {
            config.image_hint = WEBP_HINT_PICTURE;
        } break;
        case WEBP_PRESET_PHOTO: {
            config.image_hint = WEBP_HINT_PHOTO;
        } break;
        case WEBP_PRESET_DRAWING:
        case WEBP_PRESET_ICON:
        case WEBP_PRESET_TEXT: {
            config.image_hint = WEBP_HINT_GRAPH;
        } break;
    }
    if (!WebPValidateConfig(&config)) goto fail;
    
    if (!WebPPictureInit(&picture)) goto fail;
    pictureNeedFree = YES;
    picture.width = (int)buffer.width;
    picture.height = (int)buffer.height;
    picture.use_argb = lossless;
    if(!WebPPictureImportRGBA(&picture, buffer.data, (int)buffer.rowBytes)) goto fail;
    
    WebPMemoryWriterInit(&writer);
    picture.writer = WebPMemoryWrite;
    picture.custom_ptr = &writer;
    if(!WebPEncode(&config, &picture)) goto fail;
    
    webpData = CFDataCreate(CFAllocatorGetDefault(), writer.mem, writer.size);
    free(writer.mem);
    WebPPictureFree(&picture);
    free(buffer.data);
    return webpData;
    
fail:
    if (buffer.data) free(buffer.data);
    if (pictureNeedFree) WebPPictureFree(&picture);
    return nil;
}

NSUInteger CSImageGetWebPFrameCount(CFDataRef webpData) {
    if (!webpData || CFDataGetLength(webpData) == 0) return 0;
    
    WebPData data = {CFDataGetBytePtr(webpData), CFDataGetLength(webpData)};
    WebPDemuxer *demuxer = WebPDemux(&data);
    if (!demuxer) return 0;
    NSUInteger webpFrameCount = WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT);
    WebPDemuxDelete(demuxer);
    return webpFrameCount;
}

CGImageRef CSCGImageCreateWithWebPData(CFDataRef webpData,
                                       BOOL decodeForDisplay,
                                       BOOL useThreads,
                                       BOOL bypassFiltering,
                                       BOOL noFancyUpsampling) {
    /*
     Call WebPDecode() on a multi-frame webp data will get an error (VP8_STATUS_UNSUPPORTED_FEATURE).
     Use WebPDemuxer to unpack it first.
     */
    WebPData data = {0};
    WebPDemuxer *demuxer = NULL;
    
    int frameCount = 0, canvasWidth = 0, canvasHeight = 0;
    WebPIterator iter = {0};
    BOOL iterInited = NO;
    const uint8_t *payload = NULL;
    size_t payloadSize = 0;
    WebPDecoderConfig config = {0};
    
    BOOL hasAlpha = NO;
    size_t bitsPerComponent = 0, bitsPerPixel = 0, bytesPerRow = 0, destLength = 0;
    CGBitmapInfo bitmapInfo = 0;
    WEBP_CSP_MODE colorspace = 0;
    void *destBytes = NULL;
    CGDataProviderRef provider = NULL;
    CGImageRef imageRef = NULL;
    
    if (!webpData || CFDataGetLength(webpData) == 0) return NULL;
    data.bytes = CFDataGetBytePtr(webpData);
    data.size = CFDataGetLength(webpData);
    demuxer = WebPDemux(&data);
    if (!demuxer) goto fail;
    
    frameCount = WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT);
    if (frameCount == 0) {
        goto fail;
        
    } else if (frameCount == 1) { // single-frame
        payload = data.bytes;
        payloadSize = data.size;
        if (!WebPInitDecoderConfig(&config)) goto fail;
        if (WebPGetFeatures(payload , payloadSize, &config.input) != VP8_STATUS_OK) goto fail;
        canvasWidth = config.input.width;
        canvasHeight = config.input.height;
        
    } else { // multi-frame
        canvasWidth = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH);
        canvasHeight = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT);
        if (canvasWidth < 1 || canvasHeight < 1) goto fail;
        
        if (!WebPDemuxGetFrame(demuxer, 1, &iter)) goto fail;
        iterInited = YES;
        
        if (iter.width > canvasWidth || iter.height > canvasHeight) goto fail;
        payload = iter.fragment.bytes;
        payloadSize = iter.fragment.size;
        
        if (!WebPInitDecoderConfig(&config)) goto fail;
        if (WebPGetFeatures(payload , payloadSize, &config.input) != VP8_STATUS_OK) goto fail;
    }
    if (payload == NULL || payloadSize == 0) goto fail;
    
    hasAlpha = config.input.has_alpha;
    bitsPerComponent = 8;
    bitsPerPixel = 32;
    bytesPerRow = CSImageByteAlign(bitsPerPixel / 8 * canvasWidth, 32);
    destLength = bytesPerRow * canvasHeight;
    if (decodeForDisplay) {
        bitmapInfo = kCGBitmapByteOrder32Host;
        bitmapInfo |= hasAlpha ? kCGImageAlphaPremultipliedFirst : kCGImageAlphaNoneSkipFirst;
        colorspace = MODE_bgrA; // small endian
    } else {
        bitmapInfo = kCGBitmapByteOrderDefault;
        bitmapInfo |= hasAlpha ? kCGImageAlphaLast : kCGImageAlphaNoneSkipLast;
        colorspace = MODE_RGBA;
    }
    destBytes = calloc(1, destLength);
    if (!destBytes) goto fail;
    
    config.options.use_threads = useThreads; //speed up 23%
    config.options.bypass_filtering = bypassFiltering; //speed up 11%, cause some banding
    config.options.no_fancy_upsampling = noFancyUpsampling; //speed down 16%, lose some details
    config.output.colorspace = colorspace;
    config.output.is_external_memory = 1;
    config.output.u.RGBA.rgba = destBytes;
    config.output.u.RGBA.stride = (int)bytesPerRow;
    config.output.u.RGBA.size = destLength;
    
    VP8StatusCode result = WebPDecode(payload, payloadSize, &config);
    if ((result != VP8_STATUS_OK) && (result != VP8_STATUS_NOT_ENOUGH_DATA)) goto fail;
    
    if (iter.x_offset != 0 || iter.y_offset != 0) {
        void *tmp = calloc(1, destLength);
        if (tmp) {
            vImage_Buffer src = {destBytes, canvasHeight, canvasWidth, bytesPerRow};
            vImage_Buffer dest = {tmp, canvasHeight, canvasWidth, bytesPerRow};
            vImage_CGAffineTransform transform = {1, 0, 0, 1, iter.x_offset, -iter.y_offset};
            uint8_t backColor[4] = {0};
            vImageAffineWarpCG_ARGB8888(&src, &dest, NULL, &transform, backColor, kvImageBackgroundColorFill);
            memcpy(destBytes, tmp, destLength);
            free(tmp);
        }
    }
    
    provider = CGDataProviderCreateWithData(destBytes, destBytes, destLength, CSCGDataProviderReleaseDataCallback);
    if (!provider) goto fail;
    destBytes = NULL; // hold by provider
    
    imageRef = CGImageCreate(canvasWidth, canvasHeight, bitsPerComponent, bitsPerPixel, bytesPerRow, CSCGColorSpaceGetDeviceRGB(), bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
    
    CFRelease(provider);
    if (iterInited) WebPDemuxReleaseIterator(&iter);
    WebPDemuxDelete(demuxer);
    
    return imageRef;
    
fail:
    if (destBytes) free(destBytes);
    if (provider) CFRelease(provider);
    if (iterInited) WebPDemuxReleaseIterator(&iter);
    if (demuxer) WebPDemuxDelete(demuxer);
    return NULL;
}

#else

BOOL CSImageWebPAvailable() {
    return NO;
}

CFDataRef CSCGImageCreateEncodedWebPData(CGImageRef imageRef, BOOL lossless, CGFloat quality, int compressLevel, CSImagePreset preset) {
    CSNSLog(@"WebP decoder is disabled");
    return NULL;
}

NSUInteger CSImageGetWebPFrameCount(CFDataRef webpData) {
    CSNSLog(@"WebP decoder is disabled");
    return 0;
}

CGImageRef CSCGImageCreateWithWebPData(CFDataRef webpData,
                                       BOOL decodeForDisplay,
                                       BOOL useThreads,
                                       BOOL bypassFiltering,
                                       BOOL noFancyUpsampling) {
    CSNSLog(@"WebP decoder is disabled");
    return NULL;
}

#endif









////////////////////////////////////////////////////////////////////////////////
#pragma mark - Decoder

@implementation CSImageFrame
+ (instancetype)frameWithImage:(UIImage *)image {
    CSImageFrame *frame = [self new];
    frame.image = image;
    return frame;
}
- (id)copyWithZone:(NSZone *)zone {
    CSImageFrame *frame = [self.class new];
    frame.index = _index;
    frame.width = _width;
    frame.height = _height;
    frame.offsetX = _offsetX;
    frame.offsetY = _offsetY;
    frame.duration = _duration;
    frame.dispose = _dispose;
    frame.blend = _blend;
    frame.image = _image.copy;
    return frame;
}
@end








// Internal frame object.
@interface _CSImageDecoderFrame : CSImageFrame
@property (nonatomic, assign) BOOL hasAlpha;                ///< Whether frame has alpha.
@property (nonatomic, assign) BOOL isFullSize;              ///< Whether frame fill the canvas.
@property (nonatomic, assign) NSUInteger blendFromIndex;    ///< Blend from frame index to current frame.
@end

@implementation _CSImageDecoderFrame
- (id)copyWithZone:(NSZone *)zone {
    _CSImageDecoderFrame *frame = [super copyWithZone:zone];
    frame.hasAlpha = _hasAlpha;
    frame.isFullSize = _isFullSize;
    frame.blendFromIndex = _blendFromIndex;
    return frame;
}
@end







@implementation CSImageDecoder{
    pthread_mutex_t _lock; // recursive lock
    
    BOOL _sourceTypeDetected;
    CGImageSourceRef _source;
    cs_png_info *_apngSource;
#if CSIMAGE_WEBP_ENABLED
    WebPDemuxer *_webpSource;
#endif
    
    UIImageOrientation _orientation;
    dispatch_semaphore_t _framesLock;
    NSArray *_frames; ///< Array<GGImageDecoderFrame>, without image
    BOOL _needBlend;
    NSUInteger _blendFrameIndex;
    CGContextRef _blendCanvas;
}

- (void)dealloc {
    if (_source) CFRelease(_source);
    if (_apngSource) cs_png_info_release(_apngSource);
#if CSIMAGE_WEBP_ENABLED
    if (_webpSource) WebPDemuxDelete(_webpSource);
#endif
    if (_blendCanvas) CFRelease(_blendCanvas);
    pthread_mutex_destroy(&_lock);
}

+ (instancetype)decoderWithData:(NSData *)data scale:(CGFloat)scale {
    if (!data) return nil;
    CSImageDecoder *decoder = [[CSImageDecoder alloc] initWithScale:scale];
    [decoder updateData:data final:YES];
    if (decoder.frameCount == 0) return nil;
    return decoder;
}

- (instancetype)init {
    return [self initWithScale:[UIScreen mainScreen].scale];
}

- (instancetype)initWithScale:(CGFloat)scale {
    self = [super init];
    if (scale <= 0) scale = 1;
    _scale = scale;
    _framesLock = dispatch_semaphore_create(1);
    pthread_mutex_init_recursive(&_lock, true);
    return self;
}

- (BOOL)updateData:(NSData *)data final:(BOOL)final {
    BOOL result = NO;
    pthread_mutex_lock(&_lock);
    result = [self _updateData:data final:final];
    pthread_mutex_unlock(&_lock);
    return result;
}

- (CSImageFrame *)frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay {
    CSImageFrame *result = nil;
    pthread_mutex_lock(&_lock);
    result = [self _frameAtIndex:index decodeForDisplay:decodeForDisplay];
    pthread_mutex_unlock(&_lock);
    return result;
}

- (NSTimeInterval)frameDurationAtIndex:(NSUInteger)index {
    NSTimeInterval result = 0;
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    if (index < _frames.count) {
        result = ((_CSImageDecoderFrame *)_frames[index]).duration;
    }
    dispatch_semaphore_signal(_framesLock);
    return result;
}

- (NSDictionary *)framePropertiesAtIndex:(NSUInteger)index {
    NSDictionary *result = nil;
    pthread_mutex_lock(&_lock);
    result = [self _framePropertiesAtIndex:index];
    pthread_mutex_unlock(&_lock);
    return result;
}

- (NSDictionary *)imageProperties {
    NSDictionary *result = nil;
    pthread_mutex_lock(&_lock);
    result = [self _imageProperties];
    pthread_mutex_unlock(&_lock);
    return result;
}


#pragma private (wrap)

- (BOOL)_updateData:(NSData *)data final:(BOOL)final {
    if (_finalized) return NO;
    if (data.length < _data.length) return NO;
    _finalized = final;
    _data = data;
    
    CSImageType type = CSImageDetectType((__bridge CFDataRef)data);
    if (_sourceTypeDetected) {
        if (_type != type) {
            return NO;
        } else {
            [self _updateSource];
        }
    } else {
        if (_data.length > 16) {
            _type = type;
            _sourceTypeDetected = YES;
            [self _updateSource];
        }
    }
    return YES;
}

- (CSImageFrame *)_frameAtIndex:(NSUInteger)index decodeForDisplay:(BOOL)decodeForDisplay {
    if (index >= _frames.count) return 0;
    _CSImageDecoderFrame *frame = [(_CSImageDecoderFrame *)_frames[index] copy];
    BOOL decoded = NO;
    BOOL extendToCanvas = NO;
    if (_type != CSImageTypeICO && decodeForDisplay) { // ICO contains multi-size frame and should not extend to canvas.
        extendToCanvas = YES;
    }
    
    if (!_needBlend) {
        CGImageRef imageRef = [self _newUnblendedImageAtIndex:index extendToCanvas:extendToCanvas decoded:&decoded];
        if (!imageRef) return nil;
        if (decodeForDisplay && !decoded) {
            CGImageRef imageRefDecoded = CSCGImageCreateDecodedCopy(imageRef, YES);
            if (imageRefDecoded) {
                CFRelease(imageRef);
                imageRef = imageRefDecoded;
                decoded = YES;
            }
        }
        UIImage *image = [UIImage imageWithCGImage:imageRef scale:_scale orientation:_orientation];
        CFRelease(imageRef);
        if (!image) return nil;
        image.isDecodedForDisplay = decoded;
        frame.image = image;
        return frame;
    }
    
    // blend
    if (![self _createBlendContextIfNeeded]) return nil;
    CGImageRef imageRef = NULL;
    
    if (_blendFrameIndex + 1 == frame.index) {
        imageRef = [self _newBlendedImageWithFrame:frame];
        _blendFrameIndex = index;
    } else { // should draw canvas from previous frame
        _blendFrameIndex = NSNotFound;
        CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
        
        if (frame.blendFromIndex == frame.index) {
            CGImageRef unblendedImage = [self _newUnblendedImageAtIndex:index extendToCanvas:NO decoded:NULL];
            if (unblendedImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendedImage);
                CFRelease(unblendedImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            if (frame.dispose == CSImageDisposeBackground) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
            }
            _blendFrameIndex = index;
        } else { // canvas is not ready
            for (uint32_t i = (uint32_t)frame.blendFromIndex; i <= (uint32_t)frame.index; i++) {
                if (i == frame.index) {
                    if (!imageRef) imageRef = [self _newBlendedImageWithFrame:frame];
                } else {
                    [self _blendImageWithFrame:_frames[i]];
                }
            }
            _blendFrameIndex = index;
        }
    }
    
    if (!imageRef) return nil;
    UIImage *image = [UIImage imageWithCGImage:imageRef scale:_scale orientation:_orientation];
    CFRelease(imageRef);
    if (!image) return nil;
    
    image.isDecodedForDisplay = YES;
    frame.image = image;
    if (extendToCanvas) {
        frame.width = _width;
        frame.height = _height;
        frame.offsetX = 0;
        frame.offsetY = 0;
        frame.dispose = CSImageDisposeNone;
        frame.blend = CSImageBlendNone;
    }
    return frame;
}

- (NSDictionary *)_framePropertiesAtIndex:(NSUInteger)index {
    if (index >= _frames.count) return nil;
    if (!_source) return nil;
    CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(_source, index, NULL);
    if (!properties) return nil;
    return CFBridgingRelease(properties);
}

- (NSDictionary *)_imageProperties {
    if (!_source) return nil;
    CFDictionaryRef properties = CGImageSourceCopyProperties(_source, NULL);
    if (!properties) return nil;
    return CFBridgingRelease(properties);
}


#pragma private

- (void)_updateSource {
    switch (_type) {
        case CSImageTypeWebP: {
            [self _updateSourceWebP];
        } break;
            
        case CSImageTypePNG: {
            [self _updateSourceAPNG];
        } break;
            
        default: {
            [self _updateSourceImageIO];
        } break;
    }
}

- (void)_updateSourceWebP {
#if CSIMAGE_WEBP_ENABLED
    _width = 0;
    _height = 0;
    _loopCount = 0;
    if (_webpSource) WebPDemuxDelete(_webpSource);
    _webpSource = NULL;
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    _frames = nil;
    dispatch_semaphore_signal(_framesLock);
    
    /*
     https://developers.google.com/speed/webp/docs/api
     The documentation said we can use WebPIDecoder to decode webp progressively,
     but currently it can only returns an empty image (not same as progressive jpegs),
     so we don't use progressive decoding.
     
     When using WebPDecode() to decode multi-frame webp, we will get the error
     "VP8_STATUS_UNSUPPORTED_FEATURE", so we first use WebPDemuxer to unpack it.
     */
    
    WebPData webPData = {0};
    webPData.bytes = _data.bytes;
    webPData.size = _data.length;
    WebPDemuxer *demuxer = WebPDemux(&webPData);
    if (!demuxer) return;
    
    uint32_t webpFrameCount = WebPDemuxGetI(demuxer, WEBP_FF_FRAME_COUNT);
    uint32_t webpLoopCount =  WebPDemuxGetI(demuxer, WEBP_FF_LOOP_COUNT);
    uint32_t canvasWidth = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH);
    uint32_t canvasHeight = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT);
    if (webpFrameCount == 0 || canvasWidth < 1 || canvasHeight < 1) {
        WebPDemuxDelete(demuxer);
        return;
    }
    
    NSMutableArray *frames = [NSMutableArray new];
    BOOL needBlend = NO;
    uint32_t iterIndex = 0;
    uint32_t lastBlendIndex = 0;
    WebPIterator iter = {0};
    if (WebPDemuxGetFrame(demuxer, 1, &iter)) { // one-based index...
        do {
            _CSImageDecoderFrame *frame = [_CSImageDecoderFrame new];
            [frames addObject:frame];
            if (iter.dispose_method == WEBP_MUX_DISPOSE_BACKGROUND) {
                frame.dispose = CSImageDisposeBackground;
            }
            if (iter.blend_method == WEBP_MUX_BLEND) {
                frame.blend = CSImageBlendOver;
            }
            
            int canvasWidth = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_WIDTH);
            int canvasHeight = WebPDemuxGetI(demuxer, WEBP_FF_CANVAS_HEIGHT);
            frame.index = iterIndex;
            frame.duration = iter.duration / 1000.0;
            frame.width = iter.width;
            frame.height = iter.height;
            frame.hasAlpha = iter.has_alpha;
            frame.blend = iter.blend_method == WEBP_MUX_BLEND;
            frame.offsetX = iter.x_offset;
            frame.offsetY = canvasHeight - iter.y_offset - iter.height;
            
            BOOL sizeEqualsToCanvas = (iter.width == canvasWidth && iter.height == canvasHeight);
            BOOL offsetIsZero = (iter.x_offset == 0 && iter.y_offset == 0);
            frame.isFullSize = (sizeEqualsToCanvas && offsetIsZero);
            
            if ((!frame.blend || !frame.hasAlpha) && frame.isFullSize) {
                frame.blendFromIndex = lastBlendIndex = iterIndex;
            } else {
                if (frame.dispose && frame.isFullSize) {
                    frame.blendFromIndex = lastBlendIndex;
                    lastBlendIndex = iterIndex + 1;
                } else {
                    frame.blendFromIndex = lastBlendIndex;
                }
            }
            if (frame.index != frame.blendFromIndex) needBlend = YES;
            iterIndex++;
        } while (WebPDemuxNextFrame(&iter));
        WebPDemuxReleaseIterator(&iter);
    }
    if (frames.count != webpFrameCount) {
        WebPDemuxDelete(demuxer);
        return;
    }
    
    _width = canvasWidth;
    _height = canvasHeight;
    _frameCount = frames.count;
    _loopCount = webpLoopCount;
    _needBlend = needBlend;
    _webpSource = demuxer;
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    _frames = frames;
    dispatch_semaphore_signal(_framesLock);
#else

    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        CSNSLog(@"[%s: %d] WebP is not available, check the documentation to see how to install WebP component: https://github.com/ibireme/CSImage#installation", __FUNCTION__, __LINE__);
    });
#endif
}

- (void)_updateSourceAPNG {
    /*
     APNG extends PNG format to support animation, it was supported by ImageIO
     since iOS 8.
     
     We use a custom APNG decoder to make APNG available in old system, so we
     ignore the ImageIO's APNG frame info. Typically the custom decoder is a bit
     faster than ImageIO.
     */
    
    cs_png_info_release(_apngSource);
    _apngSource = nil;
    
    [self _updateSourceImageIO]; // decode first frame
    if (_frameCount == 0) return; // png decode failed
    if (!_finalized) return; // ignore multi-frame before finalized
    
    cs_png_info *apng = cs_png_info_create(_data.bytes, (uint32_t)_data.length);
    if (!apng) return; // apng decode failed
    if (apng->apng_frame_num == 0 ||
        (apng->apng_frame_num == 1 && apng->apng_first_frame_is_cover)) {
        cs_png_info_release(apng);
        return; // no animation
    }
    if (_source) { // apng decode succeed, no longer need image souce
        CFRelease(_source);
        _source = NULL;
    }
    
    uint32_t canvasWidth = apng->header.width;
    uint32_t canvasHeight = apng->header.height;
    NSMutableArray *frames = [NSMutableArray new];
    BOOL needBlend = NO;
    uint32_t lastBlendIndex = 0;
    for (uint32_t i = 0; i < apng->apng_frame_num; i++) {
        _CSImageDecoderFrame *frame = [_CSImageDecoderFrame new];
        [frames addObject:frame];
        
        cs_png_frame_info *fi = apng->apng_frames + i;
        frame.index = i;
        frame.duration = cs_png_delay_to_seconds(fi->frame_control.delay_num, fi->frame_control.delay_den);
        frame.hasAlpha = YES;
        frame.width = fi->frame_control.width;
        frame.height = fi->frame_control.height;
        frame.offsetX = fi->frame_control.x_offset;
        frame.offsetY = canvasHeight - fi->frame_control.y_offset - fi->frame_control.height;
        
        BOOL sizeEqualsToCanvas = (frame.width == canvasWidth && frame.height == canvasHeight);
        BOOL offsetIsZero = (fi->frame_control.x_offset == 0 && fi->frame_control.y_offset == 0);
        frame.isFullSize = (sizeEqualsToCanvas && offsetIsZero);
        
        switch (fi->frame_control.dispose_op) {
            case CS_PNG_DISPOSE_OP_BACKGROUND: {
                frame.dispose = CSImageDisposeBackground;
            } break;
            case CS_PNG_DISPOSE_OP_PREVIOUS: {
                frame.dispose = CSImageDisposePrevious;
            } break;
            default: {
                frame.dispose = CSImageDisposeNone;
            } break;
        }
        switch (fi->frame_control.blend_op) {
            case CS_PNG_BLEND_OP_OVER: {
                frame.blend = CSImageBlendOver;
            } break;
                
            default: {
                frame.blend = CSImageBlendNone;
            } break;
        }
        
        if (frame.blend == CSImageBlendNone && frame.isFullSize) {
            frame.blendFromIndex  = i;
            if (frame.dispose != CSImageDisposePrevious) lastBlendIndex = i;
        } else {
            if (frame.dispose == CSImageDisposeBackground && frame.isFullSize) {
                frame.blendFromIndex = lastBlendIndex;
                lastBlendIndex = i + 1;
            } else {
                frame.blendFromIndex = lastBlendIndex;
            }
        }
        if (frame.index != frame.blendFromIndex) needBlend = YES;
    }
    
    _width = canvasWidth;
    _height = canvasHeight;
    _frameCount = frames.count;
    _loopCount = apng->apng_loop_num;
    _needBlend = needBlend;
    _apngSource = apng;
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    _frames = frames;
    dispatch_semaphore_signal(_framesLock);
}

- (void)_updateSourceImageIO {
    _width = 0;
    _height = 0;
    _orientation = UIImageOrientationUp;
    _loopCount = 0;
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    _frames = nil;
    dispatch_semaphore_signal(_framesLock);
    
    if (!_source) {
        if (_finalized) {
            _source = CGImageSourceCreateWithData((__bridge CFDataRef)_data, NULL);
        } else {
            _source = CGImageSourceCreateIncremental(NULL);
            if (_source) CGImageSourceUpdateData(_source, (__bridge CFDataRef)_data, false);
        }
    } else {
        CGImageSourceUpdateData(_source, (__bridge CFDataRef)_data, _finalized);
    }
    if (!_source) return;
    
    _frameCount = CGImageSourceGetCount(_source);
    if (_frameCount == 0) return;
    
    if (!_finalized) { // ignore multi-frame before finalized
        _frameCount = 1;
    } else {
        if (_type == CSImageTypePNG) { // use custom apng decoder and ignore multi-frame
            _frameCount = 1;
        }
        if (_type == CSImageTypeGIF) { // get gif loop count
            CFDictionaryRef properties = CGImageSourceCopyProperties(_source, NULL);
            if (properties) {
                CFDictionaryRef gif = CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary);
                if (gif) {
                    CFTypeRef loop = CFDictionaryGetValue(gif, kCGImagePropertyGIFLoopCount);
                    if (loop) CFNumberGetValue(loop, kCFNumberNSIntegerType, &_loopCount);
                }
                CFRelease(properties);
            }
        }
    }
    
    /*
     ICO, GIF, APNG may contains multi-frame.
     */
    NSMutableArray *frames = [NSMutableArray new];
    for (NSUInteger i = 0; i < _frameCount; i++) {
        _CSImageDecoderFrame *frame = [_CSImageDecoderFrame new];
        frame.index = i;
        frame.blendFromIndex = i;
        frame.hasAlpha = YES;
        frame.isFullSize = YES;
        [frames addObject:frame];
        
        CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(_source, i, NULL);
        if (properties) {
            NSTimeInterval duration = 0;
            NSInteger orientationValue = 0, width = 0, height = 0;
            CFTypeRef value = NULL;
            
            value = CFDictionaryGetValue(properties, kCGImagePropertyPixelWidth);
            if (value) CFNumberGetValue(value, kCFNumberNSIntegerType, &width);
            value = CFDictionaryGetValue(properties, kCGImagePropertyPixelHeight);
            if (value) CFNumberGetValue(value, kCFNumberNSIntegerType, &height);
            if (_type == CSImageTypeGIF) {
                CFDictionaryRef gif = CFDictionaryGetValue(properties, kCGImagePropertyGIFDictionary);
                if (gif) {
                    // Use the unclamped frame delay if it exists.
                    value = CFDictionaryGetValue(gif, kCGImagePropertyGIFUnclampedDelayTime);
                    if (!value) {
                        // Fall back to the clamped frame delay if the unclamped frame delay does not exist.
                        value = CFDictionaryGetValue(gif, kCGImagePropertyGIFDelayTime);
                    }
                    if (value) CFNumberGetValue(value, kCFNumberDoubleType, &duration);
                }
            }
            
            frame.width = width;
            frame.height = height;
            frame.duration = duration;
            
            if (i == 0 && _width + _height == 0) { // init first frame
                _width = width;
                _height = height;
                value = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
                if (value) {
                    CFNumberGetValue(value, kCFNumberNSIntegerType, &orientationValue);
                    _orientation = CSUIImageOrientationFromEXIFValue(orientationValue);
                }
            }
            CFRelease(properties);
        }
    }
    dispatch_semaphore_wait(_framesLock, DISPATCH_TIME_FOREVER);
    _frames = frames;
    dispatch_semaphore_signal(_framesLock);
}

- (CGImageRef)_newUnblendedImageAtIndex:(NSUInteger)index
                         extendToCanvas:(BOOL)extendToCanvas
                                decoded:(BOOL *)decoded CF_RETURNS_RETAINED {
    
    if (!_finalized && index > 0) return NULL;
    if (_frames.count <= index) return NULL;
    _CSImageDecoderFrame *frame = _frames[index];
    
    if (_source) {
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(_source, index, (CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@(YES)});
        if (imageRef && extendToCanvas) {
            size_t width = CGImageGetWidth(imageRef);
            size_t height = CGImageGetHeight(imageRef);
            if (width == _width && height == _height) {
                CGImageRef imageRefExtended = CSCGImageCreateDecodedCopy(imageRef, YES);
                if (imageRefExtended) {
                    CFRelease(imageRef);
                    imageRef = imageRefExtended;
                    if (decoded) *decoded = YES;
                }
            } else {
                CGContextRef context = CGBitmapContextCreate(NULL, _width, _height, 8, 0, CSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
                if (context) {
                    CGContextDrawImage(context, CGRectMake(0, _height - height, width, height), imageRef);
                    CGImageRef imageRefExtended = CGBitmapContextCreateImage(context);
                    CFRelease(context);
                    if (imageRefExtended) {
                        CFRelease(imageRef);
                        imageRef = imageRefExtended;
                        if (decoded) *decoded = YES;
                    }
                }
            }
        }
        return imageRef;
    }
    
    if (_apngSource) {
        uint32_t size = 0;
        uint8_t *bytes = cs_png_copy_frame_data_at_index(_data.bytes, _apngSource, (uint32_t)index, &size);
        if (!bytes) return NULL;
        CGDataProviderRef provider = CGDataProviderCreateWithData(bytes, bytes, size, CSCGDataProviderReleaseDataCallback);
        if (!provider) {
            free(bytes);
            return NULL;
        }
        bytes = NULL; // hold by provider
        
        CGImageSourceRef source = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (!source) {
            CFRelease(provider);
            return NULL;
        }
        CFRelease(provider);
        
        if(CGImageSourceGetCount(source) < 1) {
            CFRelease(source);
            return NULL;
        }
        
        CGImageRef imageRef = CGImageSourceCreateImageAtIndex(source, 0, (CFDictionaryRef)@{(id)kCGImageSourceShouldCache:@(YES)});
        CFRelease(source);
        if (!imageRef) return NULL;
        if (extendToCanvas) {
            CGContextRef context = CGBitmapContextCreate(NULL, _width, _height, 8, 0, CSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst); //bgrA
            if (context) {
                CGContextDrawImage(context, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), imageRef);
                CFRelease(imageRef);
                imageRef = CGBitmapContextCreateImage(context);
                CFRelease(context);
                if (decoded) *decoded = YES;
            }
        }
        return imageRef;
    }
    
#if CSIMAGE_WEBP_ENABLED
    if (_webpSource) {
        WebPIterator iter;
        if (!WebPDemuxGetFrame(_webpSource, (int)(index + 1), &iter)) return NULL; // demux webp frame data
        // frame numbers are one-based in webp -----------^
        
        int frameWidth = iter.width;
        int frameHeight = iter.height;
        if (frameWidth < 1 || frameHeight < 1) return NULL;
        
        int width = extendToCanvas ? (int)_width : frameWidth;
        int height = extendToCanvas ? (int)_height : frameHeight;
        if (width > _width || height > _height) return NULL;
        
        const uint8_t *payload = iter.fragment.bytes;
        size_t payloadSize = iter.fragment.size;
        
        WebPDecoderConfig config;
        if (!WebPInitDecoderConfig(&config)) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        if (WebPGetFeatures(payload , payloadSize, &config.input) != VP8_STATUS_OK) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        
        size_t bitsPerComponent = 8;
        size_t bitsPerPixel = 32;
        size_t bytesPerRow = CSImageByteAlign(bitsPerPixel / 8 * width, 32);
        size_t length = bytesPerRow * height;
        CGBitmapInfo bitmapInfo = kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst; //bgrA
        
        void *pixels = calloc(1, length);
        if (!pixels) {
            WebPDemuxReleaseIterator(&iter);
            return NULL;
        }
        
        config.output.colorspace = MODE_bgrA;
        config.output.is_external_memory = 1;
        config.output.u.RGBA.rgba = pixels;
        config.output.u.RGBA.stride = (int)bytesPerRow;
        config.output.u.RGBA.size = length;
        VP8StatusCode result = WebPDecode(payload, payloadSize, &config); // decode
        if ((result != VP8_STATUS_OK) && (result != VP8_STATUS_NOT_ENOUGH_DATA)) {
            WebPDemuxReleaseIterator(&iter);
            free(pixels);
            return NULL;
        }
        WebPDemuxReleaseIterator(&iter);
        
        if (extendToCanvas && (iter.x_offset != 0 || iter.y_offset != 0)) {
            void *tmp = calloc(1, length);
            if (tmp) {
                vImage_Buffer src = {pixels, height, width, bytesPerRow};
                vImage_Buffer dest = {tmp, height, width, bytesPerRow};
                vImage_CGAffineTransform transform = {1, 0, 0, 1, iter.x_offset, -iter.y_offset};
                uint8_t backColor[4] = {0};
                vImage_Error error = vImageAffineWarpCG_ARGB8888(&src, &dest, NULL, &transform, backColor, kvImageBackgroundColorFill);
                if (error == kvImageNoError) {
                    memcpy(pixels, tmp, length);
                }
                free(tmp);
            }
        }
        
        CGDataProviderRef provider = CGDataProviderCreateWithData(pixels, pixels, length, CSCGDataProviderReleaseDataCallback);
        if (!provider) {
            free(pixels);
            return NULL;
        }
        pixels = NULL; // hold by provider
        
        CGImageRef image = CGImageCreate(width, height, bitsPerComponent, bitsPerPixel, bytesPerRow, CSCGColorSpaceGetDeviceRGB(), bitmapInfo, provider, NULL, false, kCGRenderingIntentDefault);
        CFRelease(provider);
        if (decoded) *decoded = YES;
        return image;
    }
#endif
    
    return NULL;
}

- (BOOL)_createBlendContextIfNeeded {
    if (!_blendCanvas) {
        _blendFrameIndex = NSNotFound;
        _blendCanvas = CGBitmapContextCreate(NULL, _width, _height, 8, 0, CSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
    }
    BOOL suc = _blendCanvas != NULL;
    return suc;
}

- (void)_blendImageWithFrame:(_CSImageDecoderFrame *)frame {
    if (frame.dispose == CSImageDisposePrevious) {
        // nothing
    } else if (frame.dispose == CSImageDisposeBackground) {
        CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
    } else { // no dispose
        if (frame.blend == CSImageBlendOver) {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
        } else {
            CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
        }
    }
}

- (CGImageRef)_newBlendedImageWithFrame:(_CSImageDecoderFrame *)frame CF_RETURNS_RETAINED{
    CGImageRef imageRef = NULL;
    if (frame.dispose == CSImageDisposePrevious) {
        if (frame.blend == CSImageBlendOver) {
            CGImageRef previousImage = CGBitmapContextCreateImage(_blendCanvas);
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
            if (previousImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(0, 0, _width, _height), previousImage);
                CFRelease(previousImage);
            }
        } else {
            CGImageRef previousImage = CGBitmapContextCreateImage(_blendCanvas);
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(0, 0, _width, _height));
            if (previousImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(0, 0, _width, _height), previousImage);
                CFRelease(previousImage);
            }
        }
    } else if (frame.dispose == CSImageDisposeBackground) {
        if (frame.blend == CSImageBlendOver) {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
        } else {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
            CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
        }
    } else { // no dispose
        if (frame.blend == CSImageBlendOver) {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
        } else {
            CGImageRef unblendImage = [self _newUnblendedImageAtIndex:frame.index extendToCanvas:NO decoded:NULL];
            if (unblendImage) {
                CGContextClearRect(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height));
                CGContextDrawImage(_blendCanvas, CGRectMake(frame.offsetX, frame.offsetY, frame.width, frame.height), unblendImage);
                CFRelease(unblendImage);
            }
            imageRef = CGBitmapContextCreateImage(_blendCanvas);
        }
    }
    return imageRef;
}



@end










////////////////////////////////////////////////////////////////////////////////
#pragma mark - Encoder

@implementation CSImageEncoder {
    NSMutableArray *_images;
    NSMutableArray *_durations;
}

- (instancetype)init {
    @throw [NSException exceptionWithName:@"CSImageEncoder init error" reason:@"CSImageEncoder must be initialized with a type. Use 'initWithType:' instead." userInfo:nil];
    return [self initWithType:CSImageTypeUnknown];
}

- (instancetype)initWithType:(CSImageType)type {
    if (type == CSImageTypeUnknown || type >= CSImageTypeOther) {
        CSNSLog(@"[%s: %d] Unsupported image type:%d",__FUNCTION__, __LINE__, (int)type);
        return nil;
    }
    
#if !CSIMAGE_WEBP_ENABLED
    if (type == CSImageTypeWebP) {
        CSNSLog(@"[%s: %d] WebP is not available, check the documentation to see how to install WebP component: https://github.com/ibireme/CSImage#installation", __FUNCTION__, __LINE__);
        return nil;
    }
#endif
    
    self = [super init];
    if (!self) return nil;
    _type = type;
    _images = [NSMutableArray new];
    _durations = [NSMutableArray new];
    
    switch (type) {
        case CSImageTypeJPEG:
        case CSImageTypeJPEG2000: {
            _quality = 0.9;
        } break;
        case CSImageTypeTIFF:
        case CSImageTypeBMP:
        case CSImageTypeGIF:
        case CSImageTypeICO:
        case CSImageTypeICNS:
        case CSImageTypePNG: {
            _quality = 1;
            _lossless = YES;
        } break;
        case CSImageTypeWebP: {
            _quality = 0.8;
        } break;
        default:
            break;
    }
    
    return self;
}

- (void)setQuality:(CGFloat)quality {
    _quality = quality < 0 ? 0 : quality > 1 ? 1 : quality;
}

- (void)addImage:(UIImage *)image duration:(NSTimeInterval)duration {
    if (!image.CGImage) return;
    duration = duration < 0 ? 0 : duration;
    [_images addObject:image];
    [_durations addObject:@(duration)];
}

- (void)addImageWithData:(NSData *)data duration:(NSTimeInterval)duration {
    if (data.length == 0) return;
    duration = duration < 0 ? 0 : duration;
    [_images addObject:data];
    [_durations addObject:@(duration)];
}

- (void)addImageWithFile:(NSString *)path duration:(NSTimeInterval)duration {
    if (path.length == 0) return;
    duration = duration < 0 ? 0 : duration;
    NSURL *url = [NSURL URLWithString:path];
    if (!url) return;
    [_images addObject:url];
    [_durations addObject:@(duration)];
}

- (BOOL)_imageIOAvaliable {
    switch (_type) {
        case CSImageTypeJPEG:
        case CSImageTypeJPEG2000:
        case CSImageTypeTIFF:
        case CSImageTypeBMP:
        case CSImageTypeICO:
        case CSImageTypeICNS:
        case CSImageTypeGIF: {
            return _images.count > 0;
        } break;
        case CSImageTypePNG: {
            return _images.count == 1;
        } break;
        case CSImageTypeWebP: {
            return NO;
        } break;
        default: return NO;
    }
}

- (CGImageDestinationRef)_newImageDestination:(id)dest imageCount:(NSUInteger)count CF_RETURNS_RETAINED {
    if (!dest) return nil;
    CGImageDestinationRef destination = NULL;
    if ([dest isKindOfClass:[NSString class]]) {
        NSURL *url = [[NSURL alloc] initFileURLWithPath:dest];
        if (url) {
            destination = CGImageDestinationCreateWithURL((CFURLRef)url, CSImageTypeToUTType(_type), count, NULL);
        }
    } else if ([dest isKindOfClass:[NSMutableData class]]) {
        destination = CGImageDestinationCreateWithData((CFMutableDataRef)dest, CSImageTypeToUTType(_type), count, NULL);
    }
    return destination;
}

- (void)_encodeImageWithDestination:(CGImageDestinationRef)destination imageCount:(NSUInteger)count {
    if (_type == CSImageTypeGIF) {
        NSDictionary *gifProperty = @{(__bridge id)kCGImagePropertyGIFDictionary:
                                          @{(__bridge id)kCGImagePropertyGIFLoopCount: @(_loopCount)}};
        CGImageDestinationSetProperties(destination, (__bridge CFDictionaryRef)gifProperty);
    }
    
    for (int i = 0; i < count; i++) {
        @autoreleasepool {
            id imageSrc = _images[i];
            NSDictionary *frameProperty = NULL;
            if (_type == CSImageTypeGIF && count > 1) {
                frameProperty = @{(NSString *)kCGImagePropertyGIFDictionary : @{(NSString *) kCGImagePropertyGIFDelayTime:_durations[i]}};
            } else {
                frameProperty = @{(id)kCGImageDestinationLossyCompressionQuality : @(_quality)};
            }
            
            if ([imageSrc isKindOfClass:[UIImage class]]) {
                UIImage *image = imageSrc;
                if (image.imageOrientation != UIImageOrientationUp && image.CGImage) {
                    CGBitmapInfo info = CGImageGetBitmapInfo(image.CGImage) | CGImageGetAlphaInfo(image.CGImage);
                    CGImageRef rotated = CSCGImageCreateCopyWithOrientation(image.CGImage, image.imageOrientation, info);
                    if (rotated) {
                        image = [UIImage imageWithCGImage:rotated];
                        CFRelease(rotated);
                    }
                }
                if (image.CGImage) CGImageDestinationAddImage(destination, ((UIImage *)imageSrc).CGImage, (CFDictionaryRef)frameProperty);
            } else if ([imageSrc isKindOfClass:[NSURL class]]) {
                CGImageSourceRef source = CGImageSourceCreateWithURL((CFURLRef)imageSrc, NULL);
                if (source) {
                    CGImageDestinationAddImageFromSource(destination, source, 0, (CFDictionaryRef)frameProperty);
                    CFRelease(source);
                }
            } else if ([imageSrc isKindOfClass:[NSData class]]) {
                CGImageSourceRef source = CGImageSourceCreateWithData((CFDataRef)imageSrc, NULL);
                if (source) {
                    CGImageDestinationAddImageFromSource(destination, source, 0, (CFDictionaryRef)frameProperty);
                    CFRelease(source);
                }
            }
        }
    }
}

- (CGImageRef)_newCGImageFromIndex:(NSUInteger)index decoded:(BOOL)decoded CF_RETURNS_RETAINED {
    UIImage *image = nil;
    id imageSrc= _images[index];
    if ([imageSrc isKindOfClass:[UIImage class]]) {
        image = imageSrc;
    } else if ([imageSrc isKindOfClass:[NSURL class]]) {
        image = [UIImage imageWithContentsOfFile:((NSURL *)imageSrc).absoluteString];
    } else if ([imageSrc isKindOfClass:[NSData class]]) {
        image = [UIImage imageWithData:imageSrc];
    }
    if (!image) return NULL;
    CGImageRef imageRef = image.CGImage;
    if (!imageRef) return NULL;
    if (image.imageOrientation != UIImageOrientationUp) {
        return CSCGImageCreateCopyWithOrientation(imageRef, image.imageOrientation, kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
    }
    if (decoded) {
        return CSCGImageCreateDecodedCopy(imageRef, YES);
    }
    return (CGImageRef)CFRetain(imageRef);
}

- (NSData *)_encodeWithImageIO {
    NSMutableData *data = [NSMutableData new];
    NSUInteger count = _type == CSImageTypeGIF ? _images.count : 1;
    CGImageDestinationRef destination = [self _newImageDestination:data imageCount:count];
    BOOL suc = NO;
    if (destination) {
        [self _encodeImageWithDestination:destination imageCount:count];
        suc = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    if (suc && data.length > 0) {
        return data;
    } else {
        return nil;
    }
}

- (BOOL)_encodeWithImageIO:(NSString *)path {
    NSUInteger count = _type == CSImageTypeGIF ? _images.count : 1;
    CGImageDestinationRef destination = [self _newImageDestination:path imageCount:count];
    BOOL suc = NO;
    if (destination) {
        [self _encodeImageWithDestination:destination imageCount:count];
        suc = CGImageDestinationFinalize(destination);
        CFRelease(destination);
    }
    return suc;
}

- (NSData *)_encodeAPNG {
    // encode APNG (ImageIO doesn't support APNG encoding, so we use a custom encoder)
    NSMutableArray *pngDatas = [NSMutableArray new];
    NSMutableArray *pngSizes = [NSMutableArray new];
    NSUInteger canvasWidth = 0, canvasHeight = 0;
    for (int i = 0; i < _images.count; i++) {
        CGImageRef decoded = [self _newCGImageFromIndex:i decoded:YES];
        if (!decoded) return nil;
        CGSize size = CGSizeMake(CGImageGetWidth(decoded), CGImageGetHeight(decoded));
        [pngSizes addObject:[NSValue valueWithCGSize:size]];
        if (canvasWidth < size.width) canvasWidth = size.width;
        if (canvasHeight < size.height) canvasHeight = size.height;
        CFDataRef frameData = CSCGImageCreateEncodedData(decoded, CSImageTypePNG, 1);
        CFRelease(decoded);
        if (!frameData) return nil;
        [pngDatas addObject:(__bridge id)(frameData)];
        CFRelease(frameData);
        if (size.width < 1 || size.height < 1) return nil;
    }
    CGSize firstFrameSize = [(NSValue *)[pngSizes firstObject] CGSizeValue];
    if (firstFrameSize.width < canvasWidth || firstFrameSize.height < canvasHeight) {
        CGImageRef decoded = [self _newCGImageFromIndex:0 decoded:YES];
        if (!decoded) return nil;
        CGContextRef context = CGBitmapContextCreate(NULL, canvasWidth, canvasHeight, 8,
                                                     0, CSCGColorSpaceGetDeviceRGB(), kCGBitmapByteOrder32Host | kCGImageAlphaPremultipliedFirst);
        if (!context) {
            CFRelease(decoded);
            return nil;
        }
        CGContextDrawImage(context, CGRectMake(0, canvasHeight - firstFrameSize.height, firstFrameSize.width, firstFrameSize.height), decoded);
        CFRelease(decoded);
        CGImageRef extendedImage = CGBitmapContextCreateImage(context);
        CFRelease(context);
        if (!extendedImage) return nil;
        CFDataRef frameData = CSCGImageCreateEncodedData(extendedImage, CSImageTypePNG, 1);
        if (!frameData) {
            CFRelease(extendedImage);
            return nil;
        }
        pngDatas[0] = (__bridge id)(frameData);
        CFRelease(frameData);
    }
    
    NSData *firstFrameData = pngDatas[0];
    cs_png_info *info = cs_png_info_create(firstFrameData.bytes, (uint32_t)firstFrameData.length);
    if (!info) return nil;
    NSMutableData *result = [NSMutableData new];
    BOOL insertBefore = NO, insertAfter = NO;
    uint32_t apngSequenceIndex = 0;
    
    uint32_t png_header[2];
    png_header[0] = CS_FOUR_CC(0x89, 0x50, 0x4E, 0x47);
    png_header[1] = CS_FOUR_CC(0x0D, 0x0A, 0x1A, 0x0A);
    
    [result appendBytes:png_header length:8];
    
    for (int i = 0; i < info->chunk_num; i++) {
        cs_png_chunk_info *chunk = info->chunks + i;
        
        if (!insertBefore && chunk->fourcc == CS_FOUR_CC('I', 'D', 'A', 'T')) {
            insertBefore = YES;
            // insert acTL (APNG Control)
            uint32_t acTL[5] = {0};
            acTL[0] = cs_swap_endian_uint32(8); //length
            acTL[1] = CS_FOUR_CC('a', 'c', 'T', 'L'); // fourcc
            acTL[2] = cs_swap_endian_uint32((uint32_t)pngDatas.count); // num frames
            acTL[3] = cs_swap_endian_uint32((uint32_t)_loopCount); // num plays
            acTL[4] = cs_swap_endian_uint32((uint32_t)crc32(0, (const Bytef *)(acTL + 1), 12)); //crc32
            [result appendBytes:acTL length:20];
            
            // insert fcTL (first frame control)
            cs_png_chunk_fcTL chunk_fcTL = {0};
            chunk_fcTL.sequence_number = apngSequenceIndex;
            chunk_fcTL.width = (uint32_t)firstFrameSize.width;
            chunk_fcTL.height = (uint32_t)firstFrameSize.height;
            cs_png_delay_to_fraction([(NSNumber *)_durations[0] doubleValue], &chunk_fcTL.delay_num, &chunk_fcTL.delay_den);
            chunk_fcTL.delay_num = chunk_fcTL.delay_num;
            chunk_fcTL.delay_den = chunk_fcTL.delay_den;
            chunk_fcTL.dispose_op = CS_PNG_DISPOSE_OP_BACKGROUND;
            chunk_fcTL.blend_op = CS_PNG_BLEND_OP_SOURCE;
            
            uint8_t fcTL[38] = {0};
            *((uint32_t *)fcTL) = cs_swap_endian_uint32(26); //length
            *((uint32_t *)(fcTL + 4)) = CS_FOUR_CC('f', 'c', 'T', 'L'); // fourcc
            cs_png_chunk_fcTL_write(&chunk_fcTL, fcTL + 8);
            *((uint32_t *)(fcTL + 34)) = cs_swap_endian_uint32((uint32_t)crc32(0, (const Bytef *)(fcTL + 4), 30));
            [result appendBytes:fcTL length:38];
            
            apngSequenceIndex++;
        }
        
        if (!insertAfter && insertBefore && chunk->fourcc != CS_FOUR_CC('I', 'D', 'A', 'T')) {
            insertAfter = YES;
            // insert fcTL and fdAT (APNG frame control and data)
            
            for (int i = 1; i < pngDatas.count; i++) {
                NSData *frameData = pngDatas[i];
                cs_png_info *frame = cs_png_info_create(frameData.bytes, (uint32_t)frameData.length);
                if (!frame) {
                    cs_png_info_release(info);
                    return nil;
                }
                
                // insert fcTL (first frame control)
                cs_png_chunk_fcTL chunk_fcTL = {0};
                chunk_fcTL.sequence_number = apngSequenceIndex;
                chunk_fcTL.width = frame->header.width;
                chunk_fcTL.height = frame->header.height;
                cs_png_delay_to_fraction([(NSNumber *)_durations[i] doubleValue], &chunk_fcTL.delay_num, &chunk_fcTL.delay_den);
                chunk_fcTL.delay_num = chunk_fcTL.delay_num;
                chunk_fcTL.delay_den = chunk_fcTL.delay_den;
                chunk_fcTL.dispose_op = CS_PNG_DISPOSE_OP_BACKGROUND;
                chunk_fcTL.blend_op = CS_PNG_BLEND_OP_SOURCE;
                
                uint8_t fcTL[38] = {0};
                *((uint32_t *)fcTL) = cs_swap_endian_uint32(26); //length
                *((uint32_t *)(fcTL + 4)) = CS_FOUR_CC('f', 'c', 'T', 'L'); // fourcc
                cs_png_chunk_fcTL_write(&chunk_fcTL, fcTL + 8);
                *((uint32_t *)(fcTL + 34)) = cs_swap_endian_uint32((uint32_t)crc32(0, (const Bytef *)(fcTL + 4), 30));
                [result appendBytes:fcTL length:38];
                
                apngSequenceIndex++;
                
                // insert fdAT (frame data)
                for (int d = 0; d < frame->chunk_num; d++) {
                    cs_png_chunk_info *dchunk = frame->chunks + d;
                    if (dchunk->fourcc == CS_FOUR_CC('I', 'D', 'A', 'T')) {
                        uint32_t length = cs_swap_endian_uint32(dchunk->length + 4);
                        [result appendBytes:&length length:4]; //length
                        uint32_t fourcc = CS_FOUR_CC('f', 'd', 'A', 'T');
                        [result appendBytes:&fourcc length:4]; //fourcc
                        uint32_t sq = cs_swap_endian_uint32(apngSequenceIndex);
                        [result appendBytes:&sq length:4]; //data (sq)
                        [result appendBytes:(((uint8_t *)frameData.bytes) + dchunk->offset + 8) length:dchunk->length]; //data
                        uint8_t *bytes = ((uint8_t *)result.bytes) + result.length - dchunk->length - 8;
                        uint32_t crc = cs_swap_endian_uint32((uint32_t)crc32(0, bytes, dchunk->length + 8));
                        [result appendBytes:&crc length:4]; //crc
                        
                        apngSequenceIndex++;
                    }
                }
                cs_png_info_release(frame);
            }
        }
        
        [result appendBytes:((uint8_t *)firstFrameData.bytes) + chunk->offset length:chunk->length + 12];
    }
    cs_png_info_release(info);
    return result;
}

- (NSData *)_encodeWebP {
#if CSIMAGE_WEBP_ENABLED
    // encode webp
    NSMutableArray *webpDatas = [NSMutableArray new];
    for (NSUInteger i = 0; i < _images.count; i++) {
        CGImageRef image = [self _newCGImageFromIndex:i decoded:NO];
        if (!image) return nil;
        CFDataRef frameData = CSCGImageCreateEncodedWebPData(image, _lossless, _quality, 4, CSImagePresetDefault);
        CFRelease(image);
        if (!frameData) return nil;
        [webpDatas addObject:(__bridge id)frameData];
        CFRelease(frameData);
    }
    if (webpDatas.count == 1) {
        return webpDatas.firstObject;
    } else {
        // multi-frame webp
        WebPMux *mux = WebPMuxNew();
        if (!mux) return nil;
        for (NSUInteger i = 0; i < _images.count; i++) {
            NSData *data = webpDatas[i];
            NSNumber *duration = _durations[i];
            WebPMuxFrameInfo frame = {0};
            frame.bitstream.bytes = data.bytes;
            frame.bitstream.size = data.length;
            frame.duration = (int)(duration.floatValue * 1000.0);
            frame.id = WEBP_CHUNK_ANMF;
            frame.dispose_method = WEBP_MUX_DISPOSE_BACKGROUND;
            frame.blend_method = WEBP_MUX_NO_BLEND;
            if (WebPMuxPushFrame(mux, &frame, 0) != WEBP_MUX_OK) {
                WebPMuxDelete(mux);
                return nil;
            }
        }
        
        WebPMuxAnimParams params = {(uint32_t)0, (int)_loopCount};
        if (WebPMuxSetAnimationParams(mux, &params) != WEBP_MUX_OK) {
            WebPMuxDelete(mux);
            return nil;
        }
        
        WebPData output_data;
        WebPMuxError error = WebPMuxAssemble(mux, &output_data);
        WebPMuxDelete(mux);
        if (error != WEBP_MUX_OK) {
            return nil;
        }
        NSData *result = [NSData dataWithBytes:output_data.bytes length:output_data.size];
        WebPDataClear(&output_data);
        return result.length ? result : nil;
    }
#else
    return nil;
#endif
}
- (NSData *)encode {
    if (_images.count == 0) return nil;
    
    if ([self _imageIOAvaliable]) return [self _encodeWithImageIO];
    if (_type == CSImageTypePNG) return [self _encodeAPNG];
    if (_type == CSImageTypeWebP) return [self _encodeWebP];
    return nil;
}

- (BOOL)encodeToFile:(NSString *)path {
    if (_images.count == 0 || path.length == 0) return NO;
    
    if ([self _imageIOAvaliable]) return [self _encodeWithImageIO:path];
    NSData *data = [self encode];
    if (!data) return NO;
    return [data writeToFile:path atomically:YES];
}

+ (NSData *)encodeImage:(UIImage *)image type:(CSImageType)type quality:(CGFloat)quality {
    CSImageEncoder *encoder = [[CSImageEncoder alloc] initWithType:type];
    encoder.quality = quality;
    [encoder addImage:image duration:0];
    return [encoder encode];
}

+ (NSData *)encodeImageWithDecoder:(CSImageDecoder *)decoder type:(CSImageType)type quality:(CGFloat)quality {
    if (!decoder || decoder.frameCount == 0) return nil;
    CSImageEncoder *encoder = [[CSImageEncoder alloc] initWithType:type];
    encoder.quality = quality;
    for (int i = 0; i < decoder.frameCount; i++) {
        UIImage *frame = [decoder frameAtIndex:i decodeForDisplay:YES].image;
        [encoder addImageWithData:UIImagePNGRepresentation(frame) duration:[decoder frameDurationAtIndex:i]];
    }
    return encoder.encode;
}

@end








@implementation UIImage (CSImageCoder)

- (instancetype)imageByDecoded {
    if (self.isDecodedForDisplay) return self;
    CGImageRef imageRef = self.CGImage;
    if (!imageRef) return self;
    CGImageRef newImageRef = CSCGImageCreateDecodedCopy(imageRef, YES);
    if (!newImageRef) return self;
    UIImage *newImage = [[self.class alloc] initWithCGImage:newImageRef scale:self.scale orientation:self.imageOrientation];
    CGImageRelease(newImageRef);
    if (!newImage) newImage = self; // decode failed, return self.
    newImage.isDecodedForDisplay = YES;
    return newImage;
}

- (BOOL)isDecodedForDisplay {
    if (self.images.count > 1) return YES;
    NSNumber *num = objc_getAssociatedObject(self, @selector(isDecodedForDisplay));
    return [num boolValue];
}

- (void)setIsDecodedForDisplay:(BOOL)isDecodedForDisplay {
    objc_setAssociatedObject(self, @selector(isDecodedForDisplay), @(isDecodedForDisplay), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

- (void)saveToAlbumWithCompletionBlock:(void(^)(NSURL *assetURL, NSError *error))completionBlock {
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        NSData *data = [self _imageDataRepresentationForSystem:YES];
        ALAssetsLibrary *library = [[ALAssetsLibrary alloc] init];
        [library writeImageDataToSavedPhotosAlbum:data metadata:nil completionBlock:^(NSURL *assetURL, NSError *error){
            if (!completionBlock) return;
            if (pthread_main_np()) {
                completionBlock(assetURL, error);
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    completionBlock(assetURL, error);
                });
            }
        }];
    });
}

- (NSData *)imageDataRepresentation {
    return [self _imageDataRepresentationForSystem:NO];
}

/// @param forSystem YES: used for system album (PNG/JPEG/GIF), NO: used for YYImage (PNG/JPEG/GIF/WebP)
- (NSData *)_imageDataRepresentationForSystem:(BOOL)forSystem {
    NSData *data = nil;
    if ([self isKindOfClass:[CSImage class]]) {
        CSImage *image = (id)self;
        if (image.animatedImageData) {
            if (forSystem) { // system only support GIF and PNG
                if (image.animatedImageType == CSImageTypeGIF ||
                    image.animatedImageType == CSImageTypePNG) {
                    data = image.animatedImageData;
                }
            } else {
                data = image.animatedImageData;
            }
        }
    }
    if (!data) {
        CGImageRef imageRef = self.CGImage ? (CGImageRef)CFRetain(self.CGImage) : nil;
        if (imageRef) {
            CGBitmapInfo bitmapInfo = CGImageGetBitmapInfo(imageRef);
            CGImageAlphaInfo alphaInfo = CGImageGetAlphaInfo(imageRef) & kCGBitmapAlphaInfoMask;
            BOOL hasAlpha = NO;
            if (alphaInfo == kCGImageAlphaPremultipliedLast ||
                alphaInfo == kCGImageAlphaPremultipliedFirst ||
                alphaInfo == kCGImageAlphaLast ||
                alphaInfo == kCGImageAlphaFirst) {
                hasAlpha = YES;
            }
            if (self.imageOrientation != UIImageOrientationUp) {
                CGImageRef rotated = CSCGImageCreateCopyWithOrientation(imageRef, self.imageOrientation, bitmapInfo | alphaInfo);
                if (rotated) {
                    CFRelease(imageRef);
                    imageRef = rotated;
                }
            }
            @autoreleasepool {
                UIImage *newImage = [UIImage imageWithCGImage:imageRef];
                if (newImage) {
                    if (hasAlpha) {
                        data = UIImagePNGRepresentation([UIImage imageWithCGImage:imageRef]);
                    } else {
                        data = UIImageJPEGRepresentation([UIImage imageWithCGImage:imageRef], 0.9); // same as Apple's example
                    }
                }
            }
            CFRelease(imageRef);
        }
    }
    if (!data) {
        data = UIImagePNGRepresentation(self);
    }
    return data;
}

#pragma clang diagnostic pop

@end









