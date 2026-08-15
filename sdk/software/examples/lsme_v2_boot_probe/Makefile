# V2 bitstream 的最小实板启动探针。
# 它不包含 TinyViT 权重，目的是先区分“配置/启动失败”和“完整固件过大或推理失败”。
TARGET = lsme_v2_boot_probe

CFLAGS += -Os -g
C_SRCS := $(wildcard ./*.c)

OBJDIR = obj
COMMON_DIR = ../../bsp
GCC_DIR = ../../../toolchains/loongson-gnu-toolchain-8.3-x86_64-loongarch32r-linux-gnusf-v2.0
PICOLIBC_DIR = ../../../toolchains/picolibc
include ../../bsp/common.mk

.PHONY: user-sample
all: user-sample
user-sample: $(TARGET)
	cp obj/$(TARGET).bin ../../../lsme_v2_boot_probe.bin
