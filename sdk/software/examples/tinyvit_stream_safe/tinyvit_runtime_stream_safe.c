/*
 * 安全演示复用同一套 TinyViT 定点参考、数据准备和 DVI 数据组织代码。
 * 构建选项在 Makefile 中把所有 GEMM 固定为 V1 流式执行，避免触发尚未完成
 * 实板验证的 V2 cached/burst 数据通路。
 */
#include "../tinyvit_demo/tinyvit_runtime.c"
