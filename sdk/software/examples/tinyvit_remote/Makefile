# 面向远程 FPGA 平台的精简 TinyViT 演示固件。
#
# 保留 V2 + 硬件 RMSNorm 的完整推理与 DVI 仪表盘，只删除大量串口讲解文案，
# 使原始 .bin 保持在远程加载器的保守容量范围内。
TARGET = tinyvit_remote

TINYVIT_LSME_MODE ?= 0
# 默认保留 -O2，避免为了缩小镜像牺牲 CPU 侧描述符准备性能；
# 若平台容量更紧，可在构建时传入 TINYVIT_OPT=-Os。
TINYVIT_OPT ?= -O2
CFLAGS += $(TINYVIT_OPT) -g -DTINYVIT_LSME_MODE=$(TINYVIT_LSME_MODE)
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../tinyvit_remote.bin
