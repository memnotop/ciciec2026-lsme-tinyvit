#include <stdint.h>
#include <stdio.h>

#include "common_func.h"
#include "confreg_time.h"
#include "led.h"

/* 启动汇编在进入 main 前使用这些全局变量初始化 UART 与计时器。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SIMULATION 0xbf20f500u

/*
 * 这是板级启动诊断固件，而不是加速器测试。
 *
 * LED 在第一条串口输出之前写入：若 LED 不停移动，说明处理器已经越过
 * 启动汇编并能访问 CONFREG；若 UART 仍无文字，可单独检查串口连接。
 * 本程序刻意不包含 TinyViT 权重，也不读 LSME 寄存器或执行自定义指令。
 */
static void delay_cycles(uint32_t cycles)
{
    volatile uint32_t index;

    for (index = 0; index < cycles; ++index)
        __asm__ volatile("" ::: "memory");
}

int main(void)
{
    uint32_t pattern = 0x0001u;
    unsigned int step;

    /* 这个固定图案是“已进入 main”的第一个可见证据。 */
    setLedPin(0xa55au);
    printf("LSME_BOOT_HEARTBEAT_START\n");
    printf("BOOT_SCOPE=CPU+CONFREG+UART; LSME=NOT_TOUCHED\n");

    /* 仿真只输出一次并正常退出，避免 make sim 因硬件心跳循环而挂起。 */
    if (RegRead(CONFREG_SIMULATION) != 0u) {
        printf("LSME_BOOT_HEARTBEAT_SIM_PASS\n");
        return 0;
    }

    for (;;) {
        setLedPin(pattern);
        printf("LSME_BOOT_HEARTBEAT step=%u led=%04x\n", step, pattern);
        delay_cycles(12000000u);
        pattern = (pattern << 1) | (pattern >> 15);
        ++step;
    }
}
