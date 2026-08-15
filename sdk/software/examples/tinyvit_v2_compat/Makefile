# 用已实板验证的 V2 cached 位流演示核心矩阵能力。
# RMSNorm 不向旧硬件发描述符，保持软件定点回退，因此 ABI 与旧位流完全兼容。
TARGET = tinyvit_v2_compat

TINYVIT_LSME_MODE ?= 0
TINYVIT_OPT ?= -O2
# 1 使用 V2 描述符的行/批次步长直读 QKV，并直接写回 token-major context；
# 0 保留分赛区决赛的显式搬运路径，便于受控 A/B 对比。
TINYVIT_ZERO_COPY_HEAD_LAYOUT ?= 1
CFLAGS += $(TINYVIT_OPT) -g -DTINYVIT_LSME_MODE=$(TINYVIT_LSME_MODE) \
	-DTINYVIT_USE_HW_RMSNORM=0 \
	-DTINYVIT_ZERO_COPY_HEAD_LAYOUT=$(TINYVIT_ZERO_COPY_HEAD_LAYOUT)
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../tinyvit_v2_compat.bin
