#!/usr/bin/env python3
"""汇总各场景 gsplat 评估指标(PSNR/SSIM/LPIPS) -> markdown 表 + 可选 csv, 写文章用。

读取 <根>/*/results/stats/val_step*.json (每场景取 step 最大的那次评估)。
评估只在 eval_steps(默认 7000/30000)的前一步触发, 所以 max_steps 要落在这些点上才有结果。

用法:
  python scripts/collect_metrics.py                 # 扫 output/
  python scripts/collect_metrics.py output --csv metrics.csv
"""
import json, glob, os, sys, csv, statistics as st

root, csv_path = "output", None
args = sys.argv[1:]
i = 0
while i < len(args):
    if args[i] == "--csv":
        csv_path = args[i + 1]; i += 2
    else:
        root = args[i]; i += 1

def stepof(p):
    return int("".join(filter(str.isdigit, os.path.basename(p))))

rows = []
for sd in sorted(glob.glob(os.path.join(root, "*", "results", "stats"))):
    scene = sd.split(os.sep)[-3]
    js = glob.glob(os.path.join(sd, "val_step*.json")) or glob.glob(os.path.join(sd, "test_step*.json"))
    if not js:
        continue
    d = json.load(open(max(js, key=stepof)))
    rows.append({
        "scene": scene, "step": stepof(max(js, key=stepof)),
        "psnr": d.get("psnr"), "ssim": d.get("ssim"), "lpips": d.get("lpips"),
        "num_GS": d.get("num_GS"), "s_per_img": d.get("ellipse_time"),
    })

if not rows:
    print(f"✗ 没找到评估结果: {root}/*/results/stats/val_step*.json", file=sys.stderr)
    print("  评估只在 eval_steps(默认7000/30000)-1 步触发; 确认 max_steps 落在这些点上。", file=sys.stderr)
    sys.exit(1)

def f(x, n):
    return f"{x:.{n}f}" if isinstance(x, (int, float)) else "-"

print("| 场景 | step | PSNR↑ | SSIM↑ | LPIPS↓ | #高斯 | s/图 |")
print("|---|---|---|---|---|---|---|")
for r in rows:
    print(f"| {r['scene']} | {r['step']} | {f(r['psnr'],3)} | {f(r['ssim'],4)} | "
          f"{f(r['lpips'],4)} | {r['num_GS'] or '-'} | {f(r['s_per_img'],3)} |")

def avg(k):
    v = [r[k] for r in rows if isinstance(r[k], (int, float))]
    return st.mean(v) if v else None
if len(rows) > 1:
    print(f"| **平均** | | {f(avg('psnr'),3)} | {f(avg('ssim'),4)} | {f(avg('lpips'),4)} | | |")

if csv_path:
    with open(csv_path, "w", newline="") as fp:
        w = csv.DictWriter(fp, fieldnames=list(rows[0].keys()))
        w.writeheader(); w.writerows(rows)
    print(f"\n已写 csv: {csv_path}", file=sys.stderr)
