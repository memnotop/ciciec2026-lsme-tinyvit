TARGET = tinyvit_demo

TINYVIT_LSME_MODE ?= 0
# 0：显式 Q/K/V 搬运与 head 合并的历史基线；1：描述符张量视图零拷贝。
TINYVIT_ZERO_COPY_HEAD_LAYOUT ?= 1
# 1：仅用于远程启动排障，保留区域赛程序的 BSS/代码布局；算法仍为零拷贝。
TINYVIT_LAYOUT_STABLE ?= 0
CFLAGS += -O2 -g -DTINYVIT_LSME_MODE=$(TINYVIT_LSME_MODE) \
	-DTINYVIT_ZERO_COPY_HEAD_LAYOUT=$(TINYVIT_ZERO_COPY_HEAD_LAYOUT) \
	-DTINYVIT_LAYOUT_STABLE=$(TINYVIT_LAYOUT_STABLE)
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../user-sample.bin
