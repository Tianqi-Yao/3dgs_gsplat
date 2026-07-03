"""汇总各场景评估指标(PSNR/SSIM/LPIPS) → markdown 表 + 可选 csv。

读 <root>/*/results/stats/val_step*.json (每场景取 step 最大的那次评估)。
"""
from __future__ import annotations

import csv as _csv
import glob
import json
import os
import statistics as st


def _stepof(p):
    return int("".join(filter(str.isdigit, os.path.basename(p))))


def collect(root="output", csv_path=None):
    rows = []
    for sd in sorted(glob.glob(os.path.join(root, "*", "results", "stats"))):
        scene = sd.split(os.sep)[-3]
        js = (glob.glob(os.path.join(sd, "val_step*.json"))
              or glob.glob(os.path.join(sd, "test_step*.json")))
        if not js:
            continue
        with open(max(js, key=_stepof)) as fp:
            d = json.load(fp)
        rows.append({"scene": scene, "step": _stepof(max(js, key=_stepof)),
                     "psnr": d.get("psnr"), "ssim": d.get("ssim"), "lpips": d.get("lpips"),
                     "num_GS": d.get("num_GS"), "s_per_img": d.get("ellipse_time")})

    if not rows:
        print(f"✗ 没找到评估结果: {root}/*/results/stats/val_step*.json")
        print("  评估只在 eval_steps-1 触发; 确认训练已跑完且用 --lpips_net alex")
        return

    def f(x, n):
        return f"{x:.{n}f}" if isinstance(x, (int, float)) else "-"

    print("| 场景 | step | PSNR↑ | SSIM↑ | LPIPS↓ | #高斯 | s/图 |")
    print("|---|---|---|---|---|---|---|")
    for r in rows:
        print(f"| {r['scene']} | {r['step']} | {f(r['psnr'], 3)} | {f(r['ssim'], 4)} | "
              f"{f(r['lpips'], 4)} | {r['num_GS'] or '-'} | {f(r['s_per_img'], 3)} |")

    def avg(k):
        v = [r[k] for r in rows if isinstance(r[k], (int, float))]
        return st.mean(v) if v else None
    if len(rows) > 1:
        print(f"| **平均** | | {f(avg('psnr'), 3)} | {f(avg('ssim'), 4)} | {f(avg('lpips'), 4)} | | |")

    if csv_path:
        with open(csv_path, "w", newline="") as fp:
            w = _csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
            w.writeheader()
            w.writerows(rows)
        print(f"\n已写 csv: {csv_path}")
