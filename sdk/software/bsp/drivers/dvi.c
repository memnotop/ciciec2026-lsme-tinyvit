#include "dvi.h"

// 设置坐标和颜色的绘图函数
void DVI_Draw_Rect(uint32_t x, uint32_t y, uint32_t l, uint32_t w)
{   
    // 创建坐标值，x 和 y 分别占用 12 位; width 和 height 用于定义范围
    uint32_t coordinates = ((x & 0xFFFF)<<16) | (y & 0xFFFF);

    uint32_t size = ((l & 0xFFFF)<<16) | (w & 0xFFFF);

    // 写入坐标和颜色寄存器
    RegWrite(DVI_RECT_DIR, coordinates);
    RegWrite(DVI_RECT_L_W, size);
}

// 在指定位置绘制一个点的函数
void DVI_Draw_SQU(uint32_t x, uint32_t y, uint32_t r)
{
    // 创建坐标值，x 和 y 分别占用 12 位; width 和 height 用于定义范围
    uint32_t coordinates = ((x & 0xFFFF)<<16) | (y & 0xFFFF);

    uint32_t size = ((r & 0xFFFF)<<16) | (r & 0xFFFF);

    // 写入坐标和颜色寄存器
    RegWrite(DVI_SQU_DIR, coordinates);
    RegWrite(DVI_SQU_R, size);
}

static void DVI_Write_Bytes(uint32_t address, const U8 *data,
                            uint32_t count)
{
    uint32_t offset;
    for (offset = 0; offset < count; offset += 4) {
        uint32_t word = data[offset];
        if (offset + 1 < count)
            word |= (uint32_t)data[offset + 1] << 8;
        if (offset + 2 < count)
            word |= (uint32_t)data[offset + 2] << 16;
        if (offset + 3 < count)
            word |= (uint32_t)data[offset + 3] << 24;
        RegWrite(address + offset, word);
    }
}

static void DVI_XAI_Publish_Frame(const U8 *image, uint32_t image_bytes,
                                  uint32_t image_mode, const U8 heatmap[64],
                                  const U8 class_scores[10], uint32_t predicted,
                                  uint32_t expected, uint32_t sample,
                                  uint32_t lanes, uint32_t cycles,
                                  uint32_t mopa, uint32_t tiles,
                                  uint32_t descriptors,
                                  uint32_t accuracy_x10000,
                                  uint32_t test_index, uint32_t status)
{
    uint32_t control;

    RegWrite(DVI_XAI_CONTROL, 0);
    DVI_Write_Bytes(DVI_XAI_IMAGE, image, image_bytes);
    DVI_Write_Bytes(DVI_XAI_HEATMAP, heatmap, 64);
    DVI_Write_Bytes(DVI_XAI_CLASS_SCORES, class_scores, 10);
    RegWrite(DVI_XAI_CYCLES, cycles);
    RegWrite(DVI_XAI_MOPA, mopa);
    RegWrite(DVI_XAI_TILES, tiles);
    RegWrite(DVI_XAI_DESCRIPTORS, descriptors);
    RegWrite(DVI_XAI_ACCURACY, accuracy_x10000);
    RegWrite(DVI_XAI_TEST_INDEX, test_index);
    control = 1u | image_mode | ((predicted & 0xfu) << 4)
            | ((expected & 0xfu) << 8) | ((sample & 0xfu) << 12)
            | ((lanes & 0xffu) << 16) | ((status & 0xffu) << 24);
    RegWrite(DVI_XAI_CONTROL, control);
}

void DVI_XAI_Publish(const U8 image[784], const U8 heatmap[64],
                     const U8 class_scores[10], uint32_t predicted,
                     uint32_t expected, uint32_t sample, uint32_t lanes,
                     uint32_t cycles, uint32_t mopa, uint32_t tiles,
                     uint32_t descriptors, uint32_t accuracy_x10000,
                     uint32_t test_index, uint32_t status)
{
    DVI_XAI_Publish_Frame(image, 784u, 0u, heatmap, class_scores, predicted,
                          expected, sample, lanes, cycles, mopa, tiles,
                          descriptors, accuracy_x10000, test_index, status);
}

void DVI_XAI_PublishRGB332(const U8 image[1024], const U8 heatmap[64],
                           const U8 class_scores[10], uint32_t predicted,
                           uint32_t expected, uint32_t sample, uint32_t lanes,
                           uint32_t cycles, uint32_t mopa, uint32_t tiles,
                           uint32_t descriptors, uint32_t accuracy_x10000,
                           uint32_t test_index, uint32_t status)
{
    DVI_XAI_Publish_Frame(image, 1024u, 2u, heatmap, class_scores, predicted,
                          expected, sample, lanes, cycles, mopa, tiles,
                          descriptors, accuracy_x10000, test_index, status);
}
