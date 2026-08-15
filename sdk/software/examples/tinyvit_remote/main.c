#include <stdint.h>
#include <stdio.h>

#include "common_func.h"
#include "confreg_time.h"
#include "dvi.h"
#include "led.h"
#include "lsme.h"
#include "seg7.h"
#include "../tinyvit_demo/tinyvit_runtime.h"

/* 启动代码使用这四个全局变量初始化串口、计时器和 CPU 时钟。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SWITCH     0xbf20f400u
#define CONFREG_SIMULATION 0xbf20f500u
#define DEMO_AUTOPLAY_MS   1800u
#define DEMO_ACCURACY_X10000 8564u

static tinyvit_result_t result;

/* SW[3:0] 选真实样例；SW[15] 打开后以固定节奏自动轮播。 */
static unsigned int select_sample(uint32_t switches, uint32_t now_ms)
{
    unsigned int sample;

    if ((switches & (1u << 15)) != 0u)
        sample = (unsigned int)((now_ms / DEMO_AUTOPLAY_MS) % 10u);
    else
        sample = switches & 0xfu;
    return sample < 10u ? sample : 0u;
}

/*
 * 一次推理后把真实输入、注意力图、分类柱状图和性能计数原子发布给 DVI。
 * status=0 表示“分类正确且与整数参考逐位一致”。
 */
static int run_and_publish(unsigned int sample)
{
    uint32_t status;
    int rc;

    printf("V2_RUN %u\n", sample);
    rc = tinyvit_infer(sample, &result);
    if (rc != 0) {
        printf("V2_ACCEL_FAIL %d\n", rc);
        setLedPin(0xffffu);
        return rc;
    }

    status = result.bit_exact ? 0u : 2u;
    if (result.predicted != result.expected)
        status |= 1u;
    DVI_XAI_Publish(tinyvit_sample_image(sample), result.attention_map,
                    result.class_scores, result.predicted, result.expected,
                    sample, result.lanes, result.cycles, result.mopa_count,
                    result.gemm_tiles, result.descriptors,
                    DEMO_ACCURACY_X10000, result.test_index, status);
    setLedPin(1u << result.predicted);
    setSegNum(0, result.expected, 1, result.predicted);

    printf("V2_METRIC c=%u d=%u m=%u t=%u s=%u r=%u\n",
           result.cycles, result.descriptors, result.mopa_count,
           result.gemm_tiles, result.softmax_rows, result.rmsnorm_rows);
    if (status == 0u) {
        printf("TINYVIT_V2_PASS\n");
        return 0;
    }
    printf("TINYVIT_V2_FAIL %u\n", status);
    return -(int)status;
}

int main(void)
{
    uint32_t query;
    uint32_t capability;
    uint32_t switches;
    unsigned int sample;
    unsigned int previous;
    int rc;

    /* 该标记位于所有自定义指令、AXI 外设访问和推理之前。 */
    printf("TINYVIT_BOOT_V2_COMPACT\n");
    query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    printf("V2_CAP %08x %08x\n", query, capability);

    switches = RegRead(CONFREG_SWITCH);
    sample = select_sample(switches, (uint32_t)get_us() / 1000u);
    rc = run_and_publish(sample);
    if (RegRead(CONFREG_SIMULATION) != 0u)
        return rc == 0 ? 0 : 1;

    previous = sample;
    for (;;) {
        switches = RegRead(CONFREG_SWITCH);
        sample = select_sample(switches, (uint32_t)get_us() / 1000u);
        if (sample != previous) {
            previous = sample;
            run_and_publish(sample);
        }
    }
}
