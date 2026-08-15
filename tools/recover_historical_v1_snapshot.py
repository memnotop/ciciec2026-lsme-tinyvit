#!/usr/bin/env python3
"""从 2026-07-11 的本地会话记录恢复生成历史 bit 前的源码快照。

该工具只操作调用者指定的输出目录。它先解压区域赛起始工程，再按原始时间顺序
回放所有 apply_patch 补丁，最后将当时工作目录中的绝对路径替换为新快照路径。
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
import zipfile
from pathlib import Path


DEFAULT_SESSION = Path(
    "/home/liumingjian/.codex/sessions/2026/07/10/"
    "rollout-2026-07-10T23-23-59-019f4ca0-dfdf-72f1-8181-1f3df7077c22.jsonl"
)
# ``mloongson/ciciec2026_loongson_regional.zip`` 后来被一份 7 月工作树覆盖，
# 不能拿它回放 7 月 11 日的首次实现。这里固定使用本机保留的 6 月原始赛题包。
DEFAULT_ZIP = Path(
    "/home/liumingjian/jichuangloongson/ciciec2026_loongson_regional.zip"
)
HISTORICAL_ROOT = "/home/liumingjian/mloongson/ciciec2026_lsme_tinyvit"
# bit 文件头中的 2026/07/11 19:06:50 是本地 UTC+8 时间；会话日志是 UTC。
# 因而要保留到 11:14 UTC，才能包含 V2 cached 和发布前的最后修正。
LAST_PATCH_TIME = "2026-07-11T11:14:55.499Z"
def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--session", type=Path, default=DEFAULT_SESSION)
    parser.add_argument("--archive", type=Path, default=DEFAULT_ZIP)
    args = parser.parse_args()

    output = args.output.resolve()
    if output.exists():
        raise SystemExit(f"输出目录已存在，拒绝覆盖：{output}")
    if not args.session.is_file() or not args.archive.is_file():
        raise SystemExit("找不到会话记录或区域赛起始压缩包")

    output.mkdir(parents=True)
    with zipfile.ZipFile(args.archive) as archive:
        archive.extractall(output)

    # 原始赛题包保留默认 DMA tie-off；首次 LSME 接入补丁会删除它。若用户显式
    # 传入的是后来被覆盖的工作包，则仍可临时补回这段历史上下文再回放。
    legacy_soc = output / "rtl/soc_top.v"
    legacy_anchor = "wire [4 :0] dma_s_arid   ;"
    legacy_tieoffs = """assign dma_m_arid       = 4'b0  ;
assign dma_m_araddr     = 32'h0;
assign dma_m_arlen      = 8'b0  ;
assign dma_m_arsize     = 3'b0 ;
assign dma_m_arburst    = 2'b0;
assign dma_m_arlock     = 1'b0;
assign dma_m_arcache    = 4'b0;
assign dma_m_arprot     = 3'b0;
assign dma_m_arvalid    = 1'b0;
assign dma_m_rready     = 1'b1;
assign dma_m_awid       = 4'b0;
assign dma_m_awaddr     = 32'b0;
assign dma_m_awlen      = 8'b0;
assign dma_m_awsize     = 3'b0;
assign dma_m_awburst    = 2'b0;
assign dma_m_awlock     = 1'b0;
assign dma_m_awcache    = 4'b0;
assign dma_m_awprot     = 3'b0;
assign dma_m_awvalid    = 1'b1;
assign dma_m_wid        = 4'b0;
assign dma_m_wdata      = 32'b0;
assign dma_m_wstrb      = 4'b0;
assign dma_m_wlast      = 1'b0;
assign dma_m_wvalid     = 1'b0;
assign dma_m_bready     = 1'b1;

"""
    legacy_dma_s_tieoffs = """assign dma_s_arready    = 1'b1;
assign dma_s_rid        = 5'b0;
assign dma_s_rdata      = 32'b0;
assign dma_s_rresp      = 2'b0;
assign dma_s_rlast      = 1'b0;
assign dma_s_rvalid     = 1'b0;
assign dma_s_awready    = 1'b1;
assign dma_s_wready     = 1'b1;
assign dma_s_bid        = 5'b0;
assign dma_s_bresp      = 2'b0;
assign dma_s_bvalid     = 1'b0;

"""
    legacy_dvi_tieoffs = """assign dvi_arready  = 1'b1;
assign dvi_rid      = 5'b0;
assign dvi_rdata    = 32'b0;
assign dvi_rresp    = 2'b0;
assign dvi_rlast    = 1'b0;
assign dvi_rvalid   = 1'b0;
assign dvi_awready  = 1'b1;
assign dvi_wready   = 1'b1;
assign dvi_bid      = 5'b0;
assign dvi_bresp    = 2'b0;
assign dvi_bvalid   = 1'b0;

"""
    legacy_text = legacy_soc.read_text(encoding="utf-8")
    # 只有“被覆盖包”已经丢失原始 tie-off 时才补它；原始赛题包本身有这段
    # 文本，若重复插入会让 04:03 的历史删除补丁只删掉其中一份。
    if legacy_anchor in legacy_text and "assign dma_m_arid       = 4'b0" not in legacy_text:
        legacy_text = legacy_text.replace(legacy_anchor, legacy_tieoffs + legacy_anchor, 1)
        legacy_text = legacy_text.replace("// reserved", legacy_dma_s_tieoffs + "// reserved", 1)
        legacy_text = legacy_text.replace("//axi confreg", legacy_dvi_tieoffs + "//axi confreg", 1)
        legacy_soc.write_text(legacy_text, encoding="utf-8")

    # 对被覆盖的工作包，恢复早期 ``// add your code`` 占位符；原始赛题包本来
    # 就含有该占位符，因此不会进入此分支。
    legacy_start = "// CPU 核：负责运行 SDK 程序，配置外设并通过 UART 输出完成标志。\ncore_top u_cpu ("
    if legacy_start in legacy_text:
        prefix, _ = legacy_text.split(legacy_start, 1)
        legacy_text = prefix + "// add your code\n\nendmodule\n"
        legacy_soc.write_text(legacy_text, encoding="utf-8")

    # 成功回执保存了所有 Add 文件的完整内容；Update 则以统一 diff 保存。这里先
    # 将每个 exec 调用与其回执配对，之后按调用发生顺序回放，不依赖 apply_patch
    # 对多文件补丁的非事务行为。
    session_events = [json.loads(raw) for raw in args.session.read_text(encoding="utf-8").splitlines()]
    tool_results: dict[str, dict] = {}
    pending_patch_calls: dict[str, list[str]] = {}
    for event in session_events:
        payload = event.get("payload", {})
        if payload.get("type") == "custom_tool_call" and payload.get("name") == "exec":
            source = payload.get("input", "")
            if "apply_patch" in source:
                turn_id = payload.get("internal_chat_message_metadata_passthrough", {}).get(
                    "turn_id", ""
                )
                pending_patch_calls.setdefault(turn_id, []).append(payload.get("id", ""))
        elif payload.get("type") == "patch_apply_end" and payload.get("success"):
            turn_id = payload.get("turn_id", "")
            pending = pending_patch_calls.get(turn_id, [])
            if pending:
                tool_results[pending.pop(0)] = payload

    def safe_path(absolute_path: str) -> Path:
        rewritten = absolute_path.replace(HISTORICAL_ROOT, str(output), 1)
        candidate = Path(rewritten).resolve()
        try:
            candidate.relative_to(output)
        except ValueError as error:
            raise RuntimeError(f"历史补丁路径越出恢复目录：{absolute_path}") from error
        return candidate

    def apply_hunks(path: Path, unified_diff: str, timestamp: str) -> None:
        """使用系统 patch 应用单文件 unified diff；路径始终相对恢复目录。"""
        relative = path.relative_to(output).as_posix()
        clean = unified_diff.replace("\r\n", "\n")
        patch_text = f"--- {relative}\n+++ {relative}\n{clean}"

        def invoke(
            text: str, *, dry_run: bool, ignore_whitespace: bool
        ) -> subprocess.CompletedProcess[str]:
            command = ["/usr/bin/patch", "-p0", "--batch", "--forward"]
            if dry_run:
                # ``patch`` 会在某个 hunk 失败后保留前面已经成功的 hunk；回放器
                # 不能接受这种半完成状态，必须先验证全部 hunk 都能落到同一版本。
                command.append("--dry-run")
            if ignore_whitespace:
                command.append("-l")
            return subprocess.run(
                command,
                input=text,
                text=True,
                cwd=output,
                stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT,
            )

        # 会话的 unified diff 使用 LF，而区域赛压缩包的一部分文件是 CRLF。先将
        # 当前文件归一化为 LF，后续每一次回放也保持 LF；这样不会出现“一个 hunk
        # 成功、另一个因 CRLF 失败”的半修改文件。
        original = path.read_bytes()
        if b"\r\n" in original:
            path.write_bytes(original.replace(b"\r\n", b"\n"))
        for ignore_whitespace in (False, True):
            checked = invoke(
                patch_text,
                dry_run=True,
                ignore_whitespace=ignore_whitespace,
            )
            if checked.returncode == 0:
                completed = invoke(
                    patch_text,
                    dry_run=False,
                    ignore_whitespace=ignore_whitespace,
                )
                if completed.returncode == 0:
                    return
                # 理论上 dry-run 成功后真实应用不应失败；恢复原文件，避免把一份
                # 不完整快照误认为可用快照。
                path.write_bytes(original)
                raise SystemExit(
                    f"历史补丁 dry-run 后仍失败，时间戳：{timestamp}，文件：{relative}"
                )
            # 发布 zip 已含有少量在本次历史会话早期完成的通用基础修订；对此类
            # “反向/已应用”提示，继续回放会损坏文件，应将它视为已满足。
            if "Reversed (or previously applied) patch detected" in checked.stdout:
                return
        path.write_bytes(original)
        sys.stderr.write(checked.stdout)
        raise SystemExit(f"回放更新补丁失败，时间戳：{timestamp}，文件：{relative}")

    applied = 0
    for event in session_events:
        payload = event.get("payload", {})
        if payload.get("type") != "custom_tool_call" or payload.get("name") != "exec":
            continue
        timestamp = event.get("timestamp", "")
        if not ("2026-07-11T03:18:33.595Z" <= timestamp <= LAST_PATCH_TIME):
            continue
        result = tool_results.get(payload.get("id", ""))
        if result is None:
            continue
        changes = result.get("changes", {})
        if not changes:
            continue
        for absolute_path, change in changes.items():
            path = safe_path(absolute_path)
            kind = change.get("type")
            if kind == "add":
                content = change.get("content")
                if not isinstance(content, str):
                    raise SystemExit(f"历史 Add 缺少内容，时间戳：{timestamp}，文件：{path}")
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content, encoding="utf-8")
            elif kind == "delete":
                if path.exists():
                    path.unlink()
            elif kind == "update":
                diff = change.get("unified_diff")
                if not isinstance(diff, str):
                    raise SystemExit(f"历史 Update 缺少 diff，时间戳：{timestamp}，文件：{path}")
                apply_hunks(path, diff, timestamp)
            else:
                raise SystemExit(f"未知历史补丁类型：{kind}，时间戳：{timestamp}")
        applied += 1

    manifest = output / "HISTORICAL_RECOVERY_MANIFEST.txt"
    manifest.write_text(
        "Recovered from local Codex session before historic bit creation\n"
        f"session={args.session}\n"
        f"archive={args.archive}\n"
        f"last_patch_time={LAST_PATCH_TIME}\n"
        f"patches_applied={applied}\n",
        encoding="utf-8",
    )
    print(f"HISTORICAL_RECOVERY_PASS patches={applied} output={output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
