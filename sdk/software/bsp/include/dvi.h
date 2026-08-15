#ifndef DVI_H
#define DVI_H
#include "common_func.h"

#define DVI_BASEADDR 0xbf100000

#define DVI_RECT_DIR (DVI_BASEADDR + 0x0)

#define DVI_RECT_L_W (DVI_BASEADDR + 0x4)

#define DVI_SQU_DIR (DVI_BASEADDR + 0x8)

#define DVI_SQU_R (DVI_BASEADDR + 0xC)

#define DVI_XAI_CONTROL      (DVI_BASEADDR + 0x010)
#define DVI_XAI_CYCLES       (DVI_BASEADDR + 0x014)
#define DVI_XAI_MOPA         (DVI_BASEADDR + 0x018)
#define DVI_XAI_TILES        (DVI_BASEADDR + 0x01C)
#define DVI_XAI_DESCRIPTORS  (DVI_BASEADDR + 0x020)
#define DVI_XAI_ACCURACY     (DVI_BASEADDR + 0x024)
#define DVI_XAI_TEST_INDEX   (DVI_BASEADDR + 0x028)
#define DVI_XAI_IMAGE        (DVI_BASEADDR + 0x100)
#define DVI_XAI_HEATMAP      (DVI_BASEADDR + 0x500)
#define DVI_XAI_CLASS_SCORES (DVI_BASEADDR + 0x600)

// draw rect on DVI to x y 
void DVI_Draw_Rect(uint32_t x, uint32_t y, uint32_t l, uint32_t w);

// draw squ on DVI to x y r
void DVI_Draw_SQU(uint32_t x, uint32_t y, uint32_t r);

// 发布历史 28x28 灰度预览。control bit0 最后写入，避免显示半帧。
void DVI_XAI_Publish(const U8 image[784], const U8 heatmap[64],
                     const U8 class_scores[10], uint32_t predicted,
                     uint32_t expected, uint32_t sample, uint32_t lanes,
                     uint32_t cycles, uint32_t mopa, uint32_t tiles,
                     uint32_t descriptors, uint32_t accuracy_x10000,
                     uint32_t test_index, uint32_t status);

// 发布 32x32 RGB332 预览。一个字节就是 DVI 的 {R[2:0],G[2:0],B[1:0]}，
// 既保留 CIFAR 的颜色线索，也不增加视频总线或显示缓存的位宽。
void DVI_XAI_PublishRGB332(const U8 image[1024], const U8 heatmap[64],
                           const U8 class_scores[10], uint32_t predicted,
                           uint32_t expected, uint32_t sample, uint32_t lanes,
                           uint32_t cycles, uint32_t mopa, uint32_t tiles,
                           uint32_t descriptors, uint32_t accuracy_x10000,
                           uint32_t test_index, uint32_t status);

#endif // DVI
