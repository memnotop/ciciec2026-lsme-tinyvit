#include <stdint.h>
#include <stdio.h>

#include "lsme.h"

/* 启动汇编会从这里读取串口和时间基准地址。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

int main(void)
{
    uint32_t lacc_capability;
    uint32_t csr_capability;

    /* 若这一行都未出现，问题在固件加载、复位或当前 bitstream 的板级启动。 */
    printf("LSME_V2_BOOT_PROBE\n");

    /* 两种访问路径共同验证：LoongArch 自定义 LACC 指令和 AXI CSR。 */
    lacc_capability = lsme_lacc_ctrl_query();
    csr_capability = lsme_read(LSME_REG_CAPABILITY);
    printf("LACC=%08x CSR=%08x\n", lacc_capability, csr_capability);

    if (lacc_capability == csr_capability && (lacc_capability >> 24) == 2u) {
        printf("LSME_V2_BOOT_PROBE_PASS\n");
        return 0;
    }

    printf("LSME_V2_BOOT_PROBE_FAIL\n");
    return 1;
}
