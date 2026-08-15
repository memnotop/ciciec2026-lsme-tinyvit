/*
 * V2 兼容演示与标准 TinyViT 共用同一份定点推理实现。
 *
 * 本目录的 Makefile 会定义 TINYVIT_USE_HW_RMSNORM=0：旧的、已实板验证的
 * V2 cached 位流没有 RMSNorm 描述符，因此三处 RMSNorm 使用完全相同的
 * 软件定点公式；GEMM、Softmax 和 VADD 仍通过 V2 描述符进入 LSME 硬件。
 */
#include "../tinyvit_demo/tinyvit_runtime.c"
