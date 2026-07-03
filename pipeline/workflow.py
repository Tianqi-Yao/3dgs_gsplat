"""工作流 —— 每个 run_* 就是一串步骤调用, 想调整流程(加/减/换步骤顺序)看这里。

四个流程:
  run_video      单视频 → 一个 ply
  run_batch      一组场景各出一个 ply(循环 run_video)
  run_multiview  多机位合成一个 ply(matcher: exhaustive/seq/pairs/rig)
  run_grid       参数网格搜索(复用一个场景的 COLMAP, 只重训练)
"""
from __future__ import annotations

import shutil
from pathlib import Path

from . import steps
from ._helpers import shell, disk, sfm
from ._helpers.config import Params


# ── 单视频 / 批量 ──────────────────────────────────────────────────────────
def run_video(scene, cfg) -> str:
    work = Path(cfg.work_root) / scene
    dest = Path(cfg.out_root) / scene
    p = cfg.params
    if disk.final_ply(dest, p.max_steps).exists():
        print(f">>> 跳过 {scene} (已有最终 ply)")
        return "skip"

    print(f"\n>>> 场景 {scene}")
    video = disk.find_video(Path("data") / scene)
    print(f"输入视频: {video}")
    if not shell.DRY_RUN:
        shutil.rmtree(work, ignore_errors=True)

    steps.extract_frames(video, work / "images", p.fps, p.width)
    steps.colmap_reconstruct(work, work / "images", p.camera_model, matcher="sequential")
    steps.train(work, work / "results", p)
    steps.finalize(work, dest)
    return "ok" if shell.DRY_RUN or disk.final_ply(dest, p.max_steps).exists() else "fail"


def run_batch(cfg):
    disk.require_local_disk(cfg.work_root)
    Path(cfg.out_root).mkdir(parents=True, exist_ok=True)
    res = {"ok": [], "skip": [], "fail": []}
    for scene in cfg.scenes:
        try:
            res[run_video(scene, cfg)].append(scene)     # 单个失败不影响其余
        except Exception as e:
            print(f"✗ {scene} 失败: {e}")
            res["fail"].append(scene)
    _summary(res)


# ── 多机位合成 ─────────────────────────────────────────────────────────────
def run_multiview(cfg):
    disk.require_local_disk(cfg.work_root)
    Path(cfg.out_root).mkdir(parents=True, exist_ok=True)
    res = {"ok": [], "skip": [], "fail": []}
    p = cfg.params
    rig = cfg.matcher == "rig"
    for scene in cfg.scenes:
        work = Path(cfg.work_root) / scene
        dest = Path(cfg.out_root) / scene
        if disk.final_ply(dest, p.max_steps).exists():
            print(f">>> 跳过 {scene} (已有最终 ply)")
            res["skip"].append(scene)
            continue
        try:
            print(f"\n>>> 多机位 {scene}  matcher={cfg.matcher}")
            videos = disk.find_videos(Path("data") / scene)
            if not shell.DRY_RUN:
                shutil.rmtree(work, ignore_errors=True)

            steps.extract_frames_multiview(videos, work / "images", p, rig=rig)
            steps.colmap_reconstruct(work, work / "images", p.camera_model,
                                     matcher=cfg.matcher, opts=cfg.matcher_opts.get(cfg.matcher, {}))
            if not shell.DRY_RUN:
                sfm.per_view_report(work / "sparse" / "0", rig=rig)
            steps.train(work, work / "results", p)
            steps.finalize(work, dest)
            res["ok" if shell.DRY_RUN or disk.final_ply(dest, p.max_steps).exists() else "fail"].append(scene)
        except Exception as e:
            print(f"✗ {scene} 失败: {e}")
            res["fail"].append(scene)
    _summary(res)


# ── 网格搜索 ───────────────────────────────────────────────────────────────
def grid_combos(cfg):
    """default: sh×ssim 个; mcmc: sh×ssim×cap 个。"""
    for s in cfg.strategy:
        for sh in cfg.sh_degree:
            for ss in cfg.ssim_lambda:
                caps = cfg.cap_max if s == "mcmc" else [None]
                for cap in caps:
                    name = f"{s}_sh{sh}_ssim{int(round(ss * 100)):03d}"
                    if cap is not None:
                        name += f"_cap{cap // 1000}k"
                    yield name, Params(
                        max_steps=cfg.steps, camera_model=cfg.camera_model,
                        strategy=s, sh_degree=sh, ssim_lambda=ss,
                        cap_max=cap if cap is not None else 1_000_000)


def run_grid(cfg):
    disk.require_local_disk(cfg.work_root)
    base = _prepare_base(cfg)
    out_dir = Path(cfg.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    combos = list(grid_combos(cfg))
    print(f"\n网格: {len(combos)} 个组合  steps={cfg.steps}  base={cfg.base_scene}")
    res = {"ok": [], "skip": [], "fail": []}
    for name, p in combos:
        dest = out_dir / name
        if disk.final_ply(dest, p.max_steps).exists():
            print(f">>> 跳过 {name} (已有 ply)")
            res["skip"].append(name)
            continue
        try:
            tag = f"{p.strategy} sh={p.sh_degree} ssim={p.ssim_lambda}"
            tag += f" cap={p.cap_max}" if p.strategy == "mcmc" else ""
            print(f"\n>>> 组合 {name}  [{tag}]")
            wres = Path(cfg.work_root) / f"_grid_{name}"
            if not shell.DRY_RUN:
                shutil.rmtree(wres, ignore_errors=True)
            steps.train(base, wres / "results", p)     # data_dir=共享 base
            steps.finalize(wres, dest)
            res["ok" if shell.DRY_RUN or disk.final_ply(dest, p.max_steps).exists() else "fail"].append(name)
        except Exception as e:                          # 一个组合 OOM/失败, 继续下一个
            print(f"✗ {name} 失败: {e}")
            res["fail"].append(name)
    _summary(res)
    print(f"出对比表: python -m pipeline metrics {out_dir} --csv {out_dir.name}.csv")


def _prepare_base(cfg) -> Path:
    """复用 output/<base_scene> 的 images+sparse, 复制到本地 base(不重跑 COLMAP)。"""
    base = Path(cfg.work_root) / f"_grid_base_{cfg.base_scene}"
    if (base / "sparse" / "0" / "cameras.bin").exists() and (base / "images").exists():
        print(f"复用本地 base: {base}")
        return base
    src = Path(cfg.out_root) / cfg.base_scene
    if not ((src / "sparse" / "0" / "cameras.bin").exists() and (src / "images").exists()):
        raise SystemExit(f"✗ 基准场景 {src} 缺 images/ 或 sparse/0/; 先把它跑出来")
    print(f"从 {src} 复制 base -> {base}")
    if not shell.DRY_RUN:
        shutil.rmtree(base, ignore_errors=True)
        base.mkdir(parents=True)
        shutil.copytree(src / "images", base / "images")
        shutil.copytree(src / "sparse", base / "sparse")
    return base


def _summary(res):
    print("\n" + "#" * 60)
    print(f"# 完成: 成功 {len(res['ok'])} / 跳过 {len(res['skip'])} / 失败 {len(res['fail'])}")
    for k in ("ok", "skip", "fail"):
        if res[k]:
            print(f"#   {k}: {' '.join(res[k])}")
    print("#" * 60)
