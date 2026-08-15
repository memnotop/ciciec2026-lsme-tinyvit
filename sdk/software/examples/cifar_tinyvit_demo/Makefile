# 大规模 CIFAR-10 演示仍面向已验证可启动的 V1 Stream 位流。
TARGET = cifar_tinyvit_demo

TINYVIT_LSME_MODE ?= 2
TINYVIT_USE_FUSED_ATTENTION ?= 0
TINYVIT_FUSED_SHADOW_CHECK ?= 0
TINYVIT_OPT ?= -O2
CFLAGS += $(TINYVIT_OPT) -g -DTINYVIT_LSME_MODE=$(TINYVIT_LSME_MODE) \
	-DTINYVIT_USE_FUSED_ATTENTION=$(TINYVIT_USE_FUSED_ATTENTION) \
	-DTINYVIT_FUSED_SHADOW_CHECK=$(TINYVIT_FUSED_SHADOW_CHECK)
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../cifar_tinyvit_demo.bin
