# 与其他裸机示例共用 BSP、启动代码、LACC 自定义指令封装和 MIF 生成流程。
TARGET = lsme_v2_rmsnorm_preflight

CFLAGS += -O2 -g
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../lsme_v2_rmsnorm_preflight.bin
