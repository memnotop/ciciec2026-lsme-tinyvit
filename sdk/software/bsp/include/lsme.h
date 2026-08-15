#ifndef LSME_H
#define LSME_H

#include <stdint.h>
#include <stddef.h>

#define LSME_BASE_ADDR          0xbf300000u
#define LSME_REG_ID             0x00u
#define LSME_REG_CAPABILITY     0x04u
#define LSME_REG_CONTROL        0x08u
#define LSME_REG_STATUS         0x0cu
#define LSME_REG_DESCRIPTOR     0x10u
#define LSME_REG_USER_TAG       0x14u
#define LSME_REG_PERF_DESC      0x18u
#define LSME_REG_PERF_MOPA      0x1cu
#define LSME_REG_PERF_ACTIVE    0x20u
#define LSME_REG_PERF_MEMORY    0x24u
#define LSME_REG_PERF_TILES     0x28u
#define LSME_REG_PERF_SOFTMAX   0x2cu
#define LSME_REG_DEBUG_CONTROL  0x30u
#define LSME_REG_DEBUG_DATA     0x34u
#define LSME_REG_PERF_ENGINE     0x38u
#define LSME_REG_PERF_AXI_READ   0x3cu
#define LSME_REG_PERF_AXI_WRITE  0x40u
#define LSME_REG_PERF_COMPUTE    0x44u
#define LSME_REG_PERF_STALL      0x48u
#define LSME_REG_PERF_OVERLAP    0x4cu
#define LSME_REG_LAST_DESC       0x50u
#define LSME_REG_PERF_RMSNORM    0x54u

#define LSME_STATUS_BUSY        (1u << 0)
#define LSME_STATUS_DONE        (1u << 1)
#define LSME_STATUS_ERROR       (1u << 2)

#define LSME_OP_GEMM            1u
#define LSME_OP_SOFTMAX         2u
#define LSME_OP_VECTOR_ADD      3u
#define LSME_OP_RMSNORM         4u
#define LSME_OP_FUSED_ATTENTION 5u

#define LSME_FLAG_TRANS_B           (1u << 0)
#define LSME_FLAG_OUTPUT_INT8       (1u << 1)
#define LSME_FLAG_BIAS              (1u << 2)
#define LSME_FLAG_RELU              (1u << 3)
#define LSME_FLAG_ACCUMULATE        (1u << 4)
#define LSME_FLAG_HEAD4             (1u << 5)
#define LSME_FLAG_PER_CHANNEL_SHIFT (1u << 6)

#define LSME_V2_AUX_MAGIC       0x56320000u
#define LSME_V2_MODE_AUTO       0u  // 自动选择；当前会进入 V2 cached GEMM
#define LSME_V2_MODE_CACHED     1u  // 明确要求使用 V2 cached GEMM
#define LSME_V2_MODE_STREAM     2u  // 强制退回 V1 4×4 流式 GEMM

// 硬件描述符固定为 64 字节，即 16 个 32 位 word，并要求 64 字节对齐。
// M/N、K/batch 使用 low16/high16 打包；word13 打包四个 8 位控制字段。
typedef struct __attribute__((aligned(64))) {
    uint32_t op_flags;          // word0：operation + flags
    uint32_t src0;              // word1：矩阵 A / 第一个输入地址
    uint32_t src1;              // word2：矩阵 B / 第二个输入地址
    uint32_t dst;               // word3：输出地址
    uint32_t bias;              // word4：S32 bias；融合 Attention 中为 V 地址
    uint32_t m_n;               // word5：low16=M，high16=N
    uint32_t k_batch;           // word6：low16=K，high16=batch
    uint32_t src0_row_stride;   // word7：src0 相邻两行的字节间隔
    uint32_t src1_row_stride;   // word8：src1 相邻两行的字节间隔
    uint32_t dst_row_stride;    // word9：dst 相邻两行的字节间隔
    uint32_t src0_batch_stride; // word10：src0 相邻 batch 的字节间隔
    uint32_t src1_batch_stride; // word11：src1 相邻 batch 的字节间隔
    uint32_t dst_batch_stride;  // word12：dst batch 间隔；融合 Attention 中为 head 偏移
    uint32_t quant_head;        // word13：shift、head_count、head_dim
    uint32_t user_tag;          // word14：软件标签，便于调试识别算子
    uint32_t aux0;              // word15：V2 magic/mode；融合 Attention 中为热图摘要地址
} lsme_descriptor_t;

// 把普通 CPU 指针转换成 DMW 非缓存别名。CPU 通过该别名访问共享缓冲区，
// 可以绕过 D-cache，保证 CPU 与 LSME AXI Master 看到相同的内存内容。
static inline void *lsme_uncached_ptr(const void *pointer)
{
    return (void *)((uintptr_t)pointer | (uintptr_t)0xa0000000u);
}

/* 保证 CPU 的共享内存访问在 LSME 作为 AXI 主设备访问之前已经完成。 */
static inline void lsme_memory_barrier(void)
{
    __asm__ volatile ("dbar 0" ::: "memory");
}

static inline uint32_t lsme_descriptor_op_flags(uint32_t operation,
                                                uint32_t flags)
{
    return (operation & 0xffu) | ((flags & 0x00ffffffu) << 8);
}

static inline uint32_t lsme_pack_u16(uint32_t low, uint32_t high)
{
    return (low & 0xffffu) | ((high & 0xffffu) << 16);
}

static inline uint32_t lsme_pack_quant_head(uint32_t out_shift,
                                            uint32_t score_shift,
                                            uint32_t head_count,
                                            uint32_t head_dim)
{
    return (out_shift & 0xffu) | ((score_shift & 0xffu) << 8)
         | ((head_count & 0xffu) << 16) | ((head_dim & 0xffu) << 24);
}

static inline uint32_t lsme_descriptor_v2_aux(uint32_t mode)
{
    // bits[31:16]=0x5632 表示 V2；bits[15:8] 当前保留为 0；
    // bits[7:0]=mode。mode=0/1 进入 V2，mode=2 强制使用 V1。
    return LSME_V2_AUX_MAGIC | (mode & 0xffu);
}

void lsme_descriptor_clear(volatile lsme_descriptor_t *descriptor);
uint32_t lsme_read(uint32_t offset);
void lsme_write(uint32_t offset, uint32_t value);
int lsme_submit_mmio(volatile lsme_descriptor_t *descriptor,
                     uint32_t timeout);
int lsme_wait_mmio(uint32_t timeout);

// 原始自定义指令 ABI。参数使用标准 a0/a1 寄存器；每个函数都把指令 rd
// 的返回值放回 a0。函数体并不在 C 文件中，而是在 lsme_lacc.S 中用
// “.word 机器码 + jirl 返回”定义。
uint32_t lsme_lacc_ctrl_query(void);
uint32_t lsme_lacc_ctrl_start(void);
uint32_t lsme_lacc_ctrl_clear(void);
uint32_t lsme_lacc_ldz_z0(const void *address, uint32_t row_stride);
uint32_t lsme_lacc_ldzt_z1(const void *address, uint32_t row_stride);
uint32_t lsme_lacc_pset_p0(uint32_t predicate);
uint32_t lsme_lacc_pset_p1(uint32_t predicate);
uint32_t lsme_lacc_zero_za0(void);
uint32_t lsme_lacc_bias_za0(const void *bias);
uint32_t lsme_lacc_smopa(uint32_t selector);
uint32_t lsme_lacc_stza_s32(void *address, uint32_t row_stride);
uint32_t lsme_lacc_stza_i8(void *address, uint32_t stride_shift);
uint32_t lsme_lacc_stza_i8_relu(void *address, uint32_t stride_shift);
uint32_t lsme_lacc_exec(volatile lsme_descriptor_t *descriptor);
uint32_t lsme_lacc_wait(void);

#endif
