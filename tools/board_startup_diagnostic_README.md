# 板级启动二分包

本目录只用于定位“新 bit + 两个不同固件均无首行输出”的问题。心跳程序不访问
LSME、RMSNorm、DVI 或 TinyViT 权重，因此它不能用于证明推理正确性；它只证明
CPU 是否已进入 `main`、CONFREG 是否可访问、UART 是否可输出。

三份 bit 使用**同一份**心跳固件，形成从已验证实物到当前候选设计的单变量二分：

- `regional_v2_known_good.bit`：用户已在远程平台成功展示的区域赛 V2 cached macro8 原始 bit。
- `regional_v2_rebuilt_visible_source.bit`：用当前能找到的区域赛可见 RTL 与同一工具链重新实现的 bit；它不是“已验证基线”的替代品。
- `optimized_v2_rmsnorm_candidate.bit`：加入硬件 RMSNorm 的当前优化候选 bit。

## 固定写入顺序

1. 写入 `regional_v2_known_good.bit`，再将 `lsme_boot_heartbeat.bin` 写到
   BaseRAM 起始地址（偏移 `0x0`），最后执行平台复位。
2. 上电/复位后，预期 UART 立即出现：

   ```text
   LSME_BOOT_HEARTBEAT_START
   BOOT_SCOPE=CPU+CONFREG+UART; LSME=NOT_TOUCHED
   LSME_BOOT_HEARTBEAT step=0 led=0001
   ```

   板载 LED 应从 `0xA55A` 变为单灯循环移动。
3. 保持固件、写入地址、复位操作完全不变，只把 bit 换为
   `regional_v2_rebuilt_visible_source.bit`，重复观察。
4. 再只把 bit 换为 `optimized_v2_rmsnorm_candidate.bit`，重复观察。

每一步等待 5 秒即可；正确时首行应在复位后立即出现，不需要等待 TinyViT 推理。

## 结果判读

| 已验证原始 bit | 可见源码重建 bit | RMSNorm 候选 bit | 结论 |
|---|---|---|---|
| 有 UART、LED 移动 | 无 UART、LED 不动 | 不再需要测试 | 当前可见 RTL/实现流程与历史实物 bit 不等价；先追溯原始构建快照，不能把失败归因给 RMSNorm。 |
| 有 UART、LED 移动 | 有 UART、LED 移动 | 无 UART、LED 不动 | CPU 启动链与重建基线正常，问题定位到 RMSNorm 候选的新增逻辑或其物理实现。 |
| 有 UART、LED 移动 | 有 UART、LED 移动 | 有 UART、LED 移动 | 启动链正常；下一步再测试 `lsme_v2_rmsnorm_preflight.bin`，随后才运行完整演示。 |
| 三者都无 UART/LED | — | — | 当前平台的加载、复位、串口或 BaseRAM 写入链路有问题；重新确认远程平台的 bit/bin 写入顺序与复位操作。 |
| 任一项 LED 移动但 UART 无文字 | — | — | CPU/CONFREG 正常，单独检查 UART 端口、波特率与网页串口窗口。 |

请记录两步中 LED 现象与 UART 原始文本；不要只记录“无输出”。
