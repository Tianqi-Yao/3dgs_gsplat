"""跑命令(subprocess, 列表形式不 shell=True) + dry-run 开关。"""
from __future__ import annotations

import subprocess

DRY_RUN = False        # cli 会按 --dry-run 设置; steps/disk 读它决定是否真执行


def run(cmd, cwd=None):
    print("+ " + " ".join(str(c) for c in cmd) + (f"   (cwd={cwd})" if cwd else ""))
    if DRY_RUN:
        return
    subprocess.run([str(c) for c in cmd], cwd=str(cwd) if cwd else None, check=True)
