#include <stdint.h>
#include <stdio.h>

#include "common_func.h"
#include "confreg_time.h"
#include "dvi.h"
#include "led.h"
#include "lsme.h"
#include "seg7.h"
#include "cifar_tinyvit_model.h"
#include "cifar_tinyvit_runtime.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SWITCH       0xbf20f400u
#define CONFREG_SIMULATION   0xbf20f500u
#define DEMO_AUTOPLAY_MS     1800u
#define CIFAR_MACS_PER_IMAGE 1672704u

static cifar_tinyvit_result_t result;

/* SW[3:0] 选择样例；SW[15] 以固定节奏自动轮播，录屏时无需频繁操作网页。 */
static unsigned int select_sample(uint32_t switches, uint32_t now_ms)
{
    unsigned int sample;

    if ((switches & (1u << 15)) != 0u)
        sample = (unsigned int)((now_ms / DEMO_AUTOPLAY_MS) % 10u);
    else
        sample = switches & 0xfu;
    return sample < 10u ? sample : 0u;
}

static void print_logits(const cifar_tinyvit_result_t *current)
{
    unsigned int index;

    printf("CIFAR32_LOGITS");
    for (index = 0; index < 10u; ++index)
        printf(" %d", current->logits[index]);
    printf("\n");
}

/*
 * 完成推理后一次性发布输入预览、第二个 Transformer block 的 attention、
 * 分类柱状图和硬件计数器。status 为零才会点亮 DVI 的 PASS 状态。
 */
static int run_and_publish(unsigned int sample)
{
    uint32_t status;
    int rc;

    printf("CIFAR32_STAGE=1 INPUT sample=%u rgb=32x32x3\n", sample);
    printf("CIFAR32_STAGE=2 EXEC blocks=2 tokens=64 heads=4 Kpatch=48 attention=%s\n",
           TINYVIT_USE_FUSED_ATTENTION ? "FUSED_QK_SOFTMAX_PV" : "DECOMPOSED");
    rc = cifar_tinyvit_infer(sample, &result);
    if (rc != 0) {
        printf("CIFAR32_ACCEL_FAIL %d\n", rc);
        setLedPin(0xffffu);
        return rc;
    }

    status = result.bit_exact ? 0u : 2u;
    if (result.predicted != result.expected)
        status |= 1u;
    DVI_XAI_PublishRGB332(cifar_tinyvit_sample_preview_rgb332(sample),
                          result.attention_map, result.class_scores,
                          result.predicted, result.expected, sample,
                          result.lanes, result.cycles, result.mopa_count,
                          result.gemm_tiles, result.descriptors,
                          TINYVIT_INTEGER_TEST_ACCURACY_X10000,
                          result.test_index, status);
    setLedPin(1u << result.predicted);
    setSegNum(0, result.expected, 1, result.predicted);

    printf("CIFAR32_STAGE=3 XAI DVI=published preview=32x32 RGB332 heatmap=8x8\n");
    printf("CIFAR32_RESULT expected=%u(%s) predicted=%u(%s) exact=%u\n",
           result.expected, cifar_tinyvit_class_name(result.expected),
           result.predicted, cifar_tinyvit_class_name(result.predicted),
           result.bit_exact);
    print_logits(&result);
    printf("CIFAR32_METRIC macs=%u cycles=%u desc=%u mopa=%u tiles=%u "
           "softmax_rows=%u hw_rms_rows=%u fused_attention=%u\n",
           CIFAR_MACS_PER_IMAGE, result.cycles, result.descriptors,
           result.mopa_count, result.gemm_tiles, result.softmax_rows,
           result.rmsnorm_rows, result.fused_attention);
    if (status == 0u) {
        printf("CIFAR32_TINYVIT_%s_PASS\n",
               result.fused_attention ? "FUSED_ATTENTION" : "STREAM");
        return 0;
    }
    printf("CIFAR32_TINYVIT_%s_FAIL %u\n",
           result.fused_attention ? "FUSED_ATTENTION" : "STREAM", status);
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

#if TINYVIT_USE_FUSED_ATTENTION
    printf("CIFAR32_TINYVIT_BOOT_FUSED_ATTENTION\n");
#else
    printf("CIFAR32_TINYVIT_BOOT_V1_STREAM\n");
#endif
    query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    printf("CIFAR32_CAP lacc=%08x csr=%08x\n", query, capability);
    printf("CIFAR32_MODEL rgb=32x32 tokens=64 blocks=2 dim=32 heads=4 macs=%u\n",
           CIFAR_MACS_PER_IMAGE);
#if TINYVIT_USE_FUSED_ATTENTION
    printf("CIFAR32_ENGINE fused_qk_softmax_pv=1 onchip_score_prob=1 "
           "mopa64=1 softmax=1 hw_rmsnorm=0\n");
#else
    printf("CIFAR32_ENGINE v1_stream=1 mopa64=1 softmax=1 vadd=1 hw_rmsnorm=0\n");
#endif
    printf("CIFAR32_CONTROL manual=SW[3:0] carousel=SW[15]\n");

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
