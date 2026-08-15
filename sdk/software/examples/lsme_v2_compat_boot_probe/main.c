#include <stdint.h>
#include <stdio.h>

#include "lsme.h"

/* 启动汇编从这四个全局变量获得串口和计时器地址。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

int main(void)
{
    uint32_t lacc_capability;
    uint32_t csr_capability;

    /* 若此行没有出现，应先检查 bitstream、BaseRAM 写入、复位和 UART。 */
    printf("LSME_V2_COMPAT_BOOT_PROBE\n");
    lacc_capability = lsme_lacc_ctrl_query();
    csr_capability = lsme_read(LSME_REG_CAPABILITY);
    printf("V2C_PROBE lacc=%08x csr=%08x\n",
           lacc_capability, csr_capability);

    /* 旧 V2 cached 硬件使用 0x9f 功能位，不具备硬件 RMSNorm。 */
    if (lacc_capability == 0x02404088u &&
        csr_capability == 0x0240409fu) {
        printf("LSME_V2_COMPAT_BOOT_PROBE_PASS\n");
        return 0;
    }

    printf("LSME_V2_COMPAT_BOOT_PROBE_FAIL\n");
    return 1;
}
