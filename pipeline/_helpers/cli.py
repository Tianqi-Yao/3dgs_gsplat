"""命令行入口:  python -m pipeline <video|batch|grid|multiview|metrics> [--config …] [-n]"""
from __future__ import annotations

import argparse

from . import shell
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
        metrics.collect(a.root, a.csv)
        return

    shell.DRY_RUN = a.dry_run
    from .. import workflow
    if a.cmd in ("video", "batch"):
        workflow.run_batch(load_run(a.config))
    elif a.cmd == "grid":
        workflow.run_grid(load_grid(a.config))
    elif a.cmd == "multiview":
        workflow.run_multiview(load_multiview(a.config))


if __name__ == "__main__":
    main()
