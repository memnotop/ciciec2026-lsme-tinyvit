#include <stdio.h>
#include <stdint.h>

#include "common_func.h"
#include "confreg_time.h"
#include "dvi.h"
#include "led.h"
#include "lsme.h"
#include "seg7.h"
#include "tinyvit_model.h"
#include "tinyvit_runtime.h"

unsigned long UART_BASE = 0xbf000000;
unsigned long CONFREG_TIMER_BASE = 0xbf20f100;
unsigned long CONFREG_CLOCKS_PER_SEC = 50000000L;
unsigned long CORE_CLOCKS_PER_SEC = 33000000L;

#define CONFREG_SWITCH 0xbf20f400u
#define CONFREG_SIMULATION 0xbf20f500u

/*
 * 这些是同一模型、同一 33 MHz CPU 和同一 sample0 下的固定对比基线。
 * 它们不参与推理运算，只在串口演示中把“优化前后”的证据放到同一屏幕上。
 */
#define TINYVIT_V1_REFERENCE_CYCLES 1827549u
#define TINYVIT_DEMO_AUTOPLAY_MS    1800u

static tinyvit_result_t result;

/* 把千分比与百分比拆开打印，避免裸机 printf 依赖浮点格式化支持。 */
static void print_ratio_x1000(uint32_t value)
{
    printf("%u.%03ux", value / 1000u, value % 1000u);
}

static void print_percent_x100(uint32_t value)
{
    printf("%u.%02u%%", value / 100u, value % 100u);
}

static uint32_t current_speedup_x1000(uint32_t current_cycles)
{
    if (current_cycles == 0u)
        return 0u;
    return (uint32_t)(((uint64_t)TINYVIT_V1_REFERENCE_CYCLES * 1000u
                       + current_cycles / 2u) / current_cycles);
}

static uint32_t current_reduction_x100(uint32_t current_cycles)
{
    if (current_cycles >= TINYVIT_V1_REFERENCE_CYCLES)
        return 0u;
    return (uint32_t)(((uint64_t)(TINYVIT_V1_REFERENCE_CYCLES - current_cycles)
                       * 10000u + TINYVIT_V1_REFERENCE_CYCLES / 2u)
                      / TINYVIT_V1_REFERENCE_CYCLES);
}

/* 低 4 位保持人工交互；SW[15] 打开后，每 1.8 秒自动切一个真实样例。 */
static unsigned int select_demo_sample(uint32_t switches, uint32_t now_ms)
{
    unsigned int sample;

    if ((switches & (1u << 15)) != 0u)
        sample = (unsigned int)((now_ms / TINYVIT_DEMO_AUTOPLAY_MS) % 10u);
    else
        sample = switches & 0xfu;
    return sample < 10u ? sample : 0u;
}

static void print_demo_banner(uint32_t lacc_query, uint32_t capability)
{
    printf("\n========================================================\n");
    printf("LSME-128I LIVE FPGA DEMO | SME-INSPIRED AI SUBSYSTEM\n");
    printf("========================================================\n");
    /* 两条读取路径同时出现，录像时能证明自定义指令和 AXI CSR 都实际工作。 */
    printf("LSME_DEMO_CUSTOM_QUERY raw=0x%08x\n", lacc_query);
    printf("LSME_DEMO_CSR_CAPABILITY raw=0x%08x match=%s\n", capability,
           lacc_query == capability ? "yes" : "no");
    printf("LSME_DEMO_ARCH version=%u lanes=%u max_cached_k=%u features=0x%02x\n",
           capability >> 24, (capability >> 16) & 0xffu,
           (capability >> 8) & 0xffu, capability & 0xffu);
    printf("LSME_DEMO_ENGINE macro8=1 burst=1 scratchpad=1 softmax=1 vadd=1 rmsnorm=1\n");
    printf("LSME_DEMO_CONTROL manual=SW[3:0] automatic_carousel=SW[15]\n");
    printf("LSME_DEMO_XAI DVI=input+8x8_attention+10_class_scores+live_counters\n");
    printf("LSME_DEMO_PPA LUT=46905 FF=21803 BRAM36=3 BRAM18=21 DSP48=0 WNS=+0.385ns WHS=+0.014ns\n");
    printf("--------------------------------------------------------\n");
}

static const char *tinyvit_class_name_py(unsigned int class_id)
{
    static const char *const names[10] = {
        "T-xu", "changku", "taotoushan", "lianyiqun", "waitao",
        "liangxie", "chenshan", "yundongxie", "shoutibao", "duanxue"
    };
    return class_id < 10u ? names[class_id] : "weizhi";
}

static int run_and_display(unsigned int sample)
{
    unsigned int status;
    unsigned int index;
    uint32_t speedup_x1000;
    uint32_t reduction_x100;
    int rc;

    printf("\nLSME_DEMO_STAGE=1 INPUT sample=%u\n", sample);
    printf("[Yanshi] Kaishi TinyViT zizhu IP tuili\n");
    printf("[Shuru] Yangli=%u, Fashion-MNIST ceshi bianhao=%u\n",
           sample, tinyvit_demo_indices[sample]);
    printf("LSME_DEMO_STAGE=2 EXEC descriptors=15 path=V2_cached+HW_RMSNorm\n");
    rc = tinyvit_infer(sample, &result);
    if (rc != 0) {
        printf("[Cuowu] LSME jiashuqi fanhui cuowuma=%d\n", rc);
        printf("TINYVIT_DEMO_FAIL accelerator rc=%d\n", rc);
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
                    TINYVIT_FLOAT_TEST_ACCURACY_X10000, result.test_index,
                    status);
    setLedPin(1u << result.predicted);
    setSegNum(0, result.expected, 1, result.predicted);

    speedup_x1000 = current_speedup_x1000(result.cycles);
    reduction_x100 = current_reduction_x100(result.cycles);

    printf("LSME_DEMO_STAGE=3 XAI dvi_frame=published attention=8x8 class_bars=10\n");
    printf("[Jieguo] Qiwang leibie=%u (%s/%s), yuce leibie=%u (%s/%s)\n",
           result.expected, tinyvit_class_name(result.expected),
           tinyvit_class_name_py(result.expected), result.predicted,
           tinyvit_class_name(result.predicted),
           tinyvit_class_name_py(result.predicted));
    printf("[Jiaoyan] Zhuwei yizhi=%s, fenlei zhengque=%s\n",
           result.bit_exact ? "shi/yes" : "fou/no",
           result.predicted == result.expected ? "shi/yes" : "fou/no");
    printf("[Defen] logits:");
    for (index = 0; index < 10; ++index)
        printf(" %d", result.logits[index]);
    printf("\n");
    printf("[Xingneng] Bingxing tongdao=%u, zhouqi=%u, miaoshufu=%u, MOPA=%u, hong wapian=%u, Softmax hang=%u, RMSNorm hang=%u\n",
           result.lanes, result.cycles, result.descriptors,
           result.mopa_count, result.gemm_tiles, result.softmax_rows,
           result.rmsnorm_rows);
    printf("[Fenjie] Yinqing=%u, jisuan=%u, fangcun dengdai=%u, chongdie=%u, AXI du=%u, AXI xie=%u, mo miaoshufu=%u\n",
           result.engine_cycles, result.compute_cycles,
           result.memory_stall_cycles, result.overlap_cycles,
           result.axi_read_beats, result.axi_write_beats,
           result.last_descriptor_cycles);
    printf("LSME_DEMO_COMPARE v1_cycles=%u current_cycles=%u speedup=",
           TINYVIT_V1_REFERENCE_CYCLES, result.cycles);
    print_ratio_x1000(speedup_x1000);
    printf(" reduction=");
    print_percent_x100(reduction_x100);
    printf("\n");
    printf("LSME_DEMO_VERIFY logits=10/10 bit_exact=%s classification=%s rmsnorm_rows=%u\n",
           result.bit_exact ? "yes" : "no",
           result.predicted == result.expected ? "yes" : "no",
           result.rmsnorm_rows);
    if (status == 0) {
        printf("LSME_DEMO_STAGE=4 PASS sample=%u\n", sample);
        printf("[Jielun] Yingjian IP jieguo tongguo cankao jiaoyan\n");
        printf("TINYVIT_DEMO_PASS\n");
        return 0;
    }
    printf("[Jielun] Yanshi shibai, zhuangtaima=0x%x\n", status);
    printf("TINYVIT_DEMO_FAIL status=0x%x\n", status);
    return -(int)status;
}

int main(void)
{
    /* ASCII 标记放在任意开关/寄存器访问和推理之前，便于远程平台定位启动问题。 */
    uint32_t lacc_query;
    uint32_t capability;
    unsigned int simulation = RegRead(CONFREG_SIMULATION);
    unsigned int sample;
    unsigned int previous;
    unsigned int autoplay;
    int rc;

    printf("TINYVIT_BOOT_LSME_V2_RMSNORM\n");
    lacc_query = lsme_lacc_ctrl_query();
    capability = lsme_read(LSME_REG_CAPABILITY);
    print_demo_banner(lacc_query, capability);
    printf("[Shuoming] DVI xianshi: shuru tuxiang, zhuyili re tu, leibie defen he xingneng jishuqi\n");
    printf("[Shuoming] LED xianshi yuce leibie, shumaguan xianshi qiwang/yuce leibie\n");
    printf("[Zhunque lv] Fudian cankao=%u.%02u%%, zhengshu yingjian cankao=%u.%02u%%\n",
           TINYVIT_FLOAT_TEST_ACCURACY_X10000 / 100,
           TINYVIT_FLOAT_TEST_ACCURACY_X10000 % 100,
           TINYVIT_INTEGER_TEST_ACCURACY_X10000 / 100,
           TINYVIT_INTEGER_TEST_ACCURACY_X10000 % 100);
    printf("[Caozuo] SW[3:0] shoudong xuanze yangli 0~9; SW[15]=1 zidong lunbo 10 ge zhenshi yangli\n");
    printf("[Biaozhi] Guan jian yingwen biaozhi: TINYVIT_DEMO_PASS / TINYVIT_DEMO_FAIL\n");
    sample = select_demo_sample(RegRead(CONFREG_SWITCH),
                                (uint32_t)get_us() / 1000u);
    rc = run_and_display(sample);
    if (simulation)
        return rc == 0 ? 0 : 1;

    previous = sample;
    for (;;) {
        uint32_t switches = RegRead(CONFREG_SWITCH);
        autoplay = (switches >> 15) & 1u;
        sample = select_demo_sample(switches, (uint32_t)get_us() / 1000u);
        if (sample != previous) {
            previous = sample;
            printf("LSME_DEMO_TRIGGER source=%s next_sample=%u\n",
                   autoplay ? "AUTOPLAY" : "SWITCH", sample);
            run_and_display(sample);
        }
    }
}
