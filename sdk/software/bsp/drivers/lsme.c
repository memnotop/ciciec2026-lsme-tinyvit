#include "lsme.h"

static volatile uint32_t *const lsme_regs =
    (volatile uint32_t *)(uintptr_t)LSME_BASE_ADDR;

// dbar 用于约束 CPU 的内存访问顺序，避免描述符尚未写完就启动加速器。
static inline void lsme_barrier(void)
{
    __asm__ volatile ("dbar 0" ::: "memory");
}

void lsme_descriptor_clear(volatile lsme_descriptor_t *descriptor)
{
    volatile uint32_t *word = (volatile uint32_t *)descriptor;
    unsigned int index;

    for (index = 0; index < 16; ++index)
        word[index] = 0;
}

uint32_t lsme_read(uint32_t offset)
{
    lsme_barrier();
    return lsme_regs[offset >> 2];
}

void lsme_write(uint32_t offset, uint32_t value)
{
    lsme_regs[offset >> 2] = value;
    lsme_barrier();
}

int lsme_wait_mmio(uint32_t timeout)
{
    uint32_t status;

    do {
        status = lsme_read(LSME_REG_STATUS);
        if ((status & LSME_STATUS_DONE) != 0)
            return (status & LSME_STATUS_ERROR) != 0
                 ? -(int)((status >> 8) & 0xffu) : 0;
    } while (timeout-- != 0);

    return -1;
}

int lsme_submit_mmio(volatile lsme_descriptor_t *descriptor,
                     uint32_t timeout)
{
    // 除自定义 EXEC/WAIT 指令外，也可以通过 AXI MMIO 寄存器提交描述符。
    if (sizeof(lsme_descriptor_t) != 64)
        return -2;
    if ((lsme_read(LSME_REG_STATUS) & LSME_STATUS_BUSY) != 0)
        return -3;

    lsme_write(LSME_REG_CONTROL, 2u);
    lsme_write(LSME_REG_DESCRIPTOR, (uint32_t)(uintptr_t)descriptor);
    lsme_write(LSME_REG_CONTROL, 1u);
    return lsme_wait_mmio(timeout);
}
