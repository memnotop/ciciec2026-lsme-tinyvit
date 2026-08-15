# 面向远程实板的保守演示构建。
# mode=2 会令 V2 描述符进入经过实板验证的 V1 4x4 流式 GEMM 路径；
# 三处 RMSNorm 使用原有软件位精确实现，避免依赖旧位流中不存在的硬件算子。
TARGET = tinyvit_stream_safe

TINYVIT_LSME_MODE ?= 2
TINYVIT_OPT ?= -O2
CFLAGS += $(TINYVIT_OPT) -g -DTINYVIT_LSME_MODE=$(TINYVIT_LSME_MODE) \
	-DTINYVIT_USE_HW_RMSNORM=0
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../tinyvit_stream_safe.bin
