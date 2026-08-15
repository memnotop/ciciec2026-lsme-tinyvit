# V2 cached 兼容演示：可核查数据卡

| 指标 | 数值 | 来源/限定 |
|---|---:|---|
| LACC / CSR 能力字 | `02404088` / `0240409f` | 完整 SoC 仿真和远程 probe 可复现 |
| MOPA lanes / cached K | 64 / 64 | CSR 能力字与旧 V2 RTL |
| CPU inference cycles | 1,007,050 | 本包固件的完整 SoC 行为仿真 |
| V1 参考 cycles | 1,827,549 | 同模型、同样例、同量化判据的基准仿真 |
| V2 cached 加速 | 1.815× | 由上述两项计算；不等同于远程板实测 |
| descriptors / MOPA / macro tiles | 12 / 12,864 / 546 | 本包完整 SoC 行为仿真 |
| Softmax / 硬件 RMSNorm rows | 256 / 0 | 本包完整 SoC 行为仿真；RMSNorm 为软件回退 |
| 逐位校验 | 10 个 logits 全一致 | `exact=1` / `TINYVIT_V2_COMPAT_PASS` |
| Slice LUT / FF | 43,787 / 19,919 | 与本 `.bit` 对应的 routed Vivado 报告 |
| DSP48 | 0 | 与本 `.bit` 对应的 routed Vivado 报告 |
| 50 MHz WNS / WHS | +0.274 / +0.037 ns | 与本 `.bit` 对应的 routed Vivado 报告 |

可直接放入视频的文字：

```text
LSME-128I V2 cached | 64 INT8 MOPA lanes | 8×8 macro tile
12 descriptors · 12,864 MOPA · 546 macro tiles · 256 Softmax rows
1,007,050 cycles in full-SoC simulation · 1.815× vs V1 · 10/10 logits bit exact
XC7A200T routed: DSP48=0 · WNS +0.274 ns · WHS +0.037 ns
RMSNorm in this remote-compatible package: bit-exact software fallback
```
