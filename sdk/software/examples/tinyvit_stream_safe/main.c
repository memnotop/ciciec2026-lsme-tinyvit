#include <stdint.h>
#include <stdio.h>

#include "common_func.h"
#include "confreg_time.h"
#include "dvi.h"
#include "led.h"
#include "lsme.h"
#include "seg7.h"
#include "../tinyvit_demo/tinyvit_runtime.h"

/* 启动代码通过这些全局变量初始化串口、时钟和计时器。 */
unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SWITCH          0xbf20f400u
#define CONFREG_SIMULATION      0xbf20f500u
#define DEMO_AUTOPLAY_MS        1800u
#define DEMO_ACCURACY_X10000    8564u

static tinyvit_result_t result;

/* SW[3:0] 选择真实样例；SW[15] 打开后每 1.8 秒自动轮播十个样例。 */
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
 * 发生失配时仍打印全部十个 logits，远程端可以据此判断是模型量化误差，
 * 还是某一个矩阵搬运/计算阶段返回了错误数据。
 */
static void print_logits(const tinyvit_result_t *current)
{
    unsigned int index;

    printf("STREAM_SAFE_LOGITS");
    for (index = 0; index < 10u; ++index)
        printf(" %d", current->logits[index]);
    printf("\n");
}

/*
 * 每次推理结束后原子发布真实输入、注意力热图、类别条和性能计数。
 * status=0 表示十个 logits 与整数参考逐位一致，且预测类别正确。
 */
static int run_and_publish(unsigned int sample)
{
    uint32_t status;
    int rc;

    printf("STREAM_SAFE_STAGE=1 INPUT sample=%u\n", sample);
    printf("STREAM_SAFE_STAGE=2 EXEC path=V1_stream+Softmax+VADD+SW_RMSNorm\n");
    rc = tinyvit_infer(sample, &result);
    if (rc != 0) {
        printf("STREAM_SAFE_ACCEL_FAIL %d\n", rc);
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

    printf("STREAM_SAFE_STAGE=3 XAI DVI=published heatmap=8x8 classes=10\n");
    printf("STREAM_SAFE_RESULT expected=%u predicted=%u exact=%u\n",
           result.expected, result.predicted, result.bit_exact);
    print_logits(&result);
    printf("STREAM_SAFE_METRIC cycles=%u desc=%u mopa=%u tiles=%u softmax=%u "
           "hw_rms_rows=%u\n",
           result.cycles, result.descriptors, result.mopa_count,
           result.gemm_tiles, result.softmax_rows, result.rmsnorm_rows);
    if (status == 0u) {
        printf("TINYVIT_STREAM_SAFE_PASS\n");
        return 0;
    }
    printf("TINYVIT_STREAM_SAFE_FAIL %u\n", status);
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

    /* 首行在任何 LACC、AXI 或 DVI 访问之前输出，便于远程平台检查启动。 */
    printf("TINYVIT_BOOT_STREAM_SAFE_SW_RMSNORM\n");
    query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    printf("STREAM_SAFE_CAP lacc=%08x csr=%08x\n", query, capability);
    printf("STREAM_SAFE_ENGINE v1_stream=1 mopa64=1 softmax=1 vadd=1 "
           "hw_rmsnorm=0\n");
    printf("STREAM_SAFE_CONTROL manual=SW[3:0] carousel=SW[15]\n");

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
