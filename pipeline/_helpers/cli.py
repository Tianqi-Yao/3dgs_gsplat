"""命令行入口:  python -m pipeline <video|batch|grid|multiview|metrics> [--config …] [-n]"""
from __future__ import annotations

import argparse
import os

from . import disk, shell
from .config import load_run, load_grid, load_multiview


def main(argv=None):
    ap = argparse.ArgumentParser(prog="python -m pipeline")
    sub = ap.add_subparsers(dest="cmd", required=True)
    for c in ("video", "batch", "grid", "multiview"):
        s = sub.add_parser(c, help=f"跑 {c} 流程")
        s.add_argument("--config", "-c", required=True, help="YAML 配置")
        s.add_argument("--dry-run", "-n", action="store_true", help="只打印命令不执行")
    m = sub.add_parser("metrics", help="汇总各场景 PSNR/SSIM/LPIPS")
    m.add_argument("root", nargs="?", default="output", help="扫 <root>/*/results/stats/")
    m.add_argument("--csv", help="同时导出 csv")
    a = ap.parse_args(argv)

    if a.cmd == "metrics":
        from . import metrics
        os.chdir(disk.ROOT)                    # root/output 等相对项目根
        metrics.collect(a.root, a.csv)
        return

    cfg_path = os.path.abspath(a.config)       # --config 相对用户当前目录先解析
    os.chdir(disk.ROOT)                        # 之后 data/scratch/output 都相对项目根, 不管从哪跑
    shell.DRY_RUN = a.dry_run
    from .. import workflow
    if a.cmd in ("video", "batch"):
        workflow.run_batch(load_run(cfg_path))
    elif a.cmd == "grid":
        workflow.run_grid(load_grid(cfg_path))
    elif a.cmd == "multiview":
        workflow.run_multiview(load_multiview(cfg_path))


if __name__ == "__main__":
    main()
