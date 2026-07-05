"""工作流 —— 每个 run_* 就是一串步骤调用, 想调整流程(加/减/换步骤顺序)看这里。

四个流程:
  run_video      单视频 → 一个 ply
  run_batch      一组场景各出一个 ply(循环 run_video)
  run_multiview  多机位合成一个 ply(matcher: exhaustive/seq/pairs/rig)
  run_grid       参数网格搜索(复用一个场景的 COLMAP, 只重训练)
"""
from __future__ import annotations

import itertools
import shutil
from pathlib import Path

from . import steps
from ._helpers import shell, disk, sfm


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
    steps.train(work, work / "results", p.strategy, p.max_steps, steps.params_to_overrides(p))
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
            steps.train(work, work / "results", p.strategy, p.max_steps, steps.params_to_overrides(p))
            steps.finalize(work, dest)
            res["ok" if shell.DRY_RUN or disk.final_ply(dest, p.max_steps).exists() else "fail"].append(scene)
        except Exception as e:
            print(f"✗ {scene} 失败: {e}")
            res["fail"].append(scene)
    _summary(res)


# ── 两层网格搜索 ───────────────────────────────────────────────────────────
def _combos(grid: dict) -> list:
    """{key:[v1,v2], ...} → 笛卡尔积的 dict 列表。空 → [{}]。"""
    grid = grid or {}
    keys = list(grid)
    return [dict(zip(keys, vals)) for vals in itertools.product(*(grid[k] for k in keys))]


def _colmap_tag(cc: dict) -> str:
    return (f"m{cc.get('matcher', 'sequential')}_cm{cc.get('camera_model', 'OPENCV')}"
            f"_h{cc.get('scale_h', 720)}_t{cc.get('target_per_vid', 150)}")


def _train_tag(tc: dict) -> str:
    parts = [tc.get("strategy", "default")]
    for k, v in tc.items():
        if k == "strategy":
            continue
        parts.append(f"{k}{1 if v is True else 0 if v is False else v}")
    return "_".join(parts)


def _build_grid_base(base: Path, video, cc: dict):
    """第一层: 抽帧(scale_h/target)+COLMAP(camera_model, 单视频 sequential)。已存在则复用。"""
    if (base / "sparse" / "0" / "cameras.bin").exists() and (base / "images").exists():
        print(f"复用 COLMAP base: {base}")
        return
    if not shell.DRY_RUN:
        shutil.rmtree(base, ignore_errors=True)
    steps.extract_frames_scaled(video, base / "images",
                                cc.get("target_per_vid", 150), cc.get("scale_h", 720))
    steps.colmap_reconstruct(base, base / "images", cc.get("camera_model", "OPENCV"),
                             matcher=cc.get("matcher", "sequential"))


def run_grid(cfg, colmap_only=False):
    disk.require_local_disk(cfg.work_root)
    out_dir = Path(cfg.out_dir)
    colmap_combos, train_combos = _combos(cfg.colmap), _combos(cfg.train)
    if colmap_only:
        print(f"\nCOLMAP 快扫: {len(cfg.base_scenes)}场景 × {len(colmap_combos)}COLMAP = "
              f"{len(cfg.base_scenes) * len(colmap_combos)} 次(不训练)")
    else:
        out_dir.mkdir(parents=True, exist_ok=True)
        total = len(cfg.base_scenes) * len(colmap_combos) * len(train_combos)
        print(f"\n两层网格: {len(cfg.base_scenes)}场景 × {len(colmap_combos)}COLMAP × "
              f"{len(train_combos)}训练 = {total} 次  steps={cfg.steps}")
    res = {"ok": [], "skip": [], "fail": []}
    reports = []

    for scene in cfg.base_scenes:
        try:
            vids = disk.find_videos(Path("data") / scene)     # grid 假设单视频场景
            if len(vids) > 1:
                print(f"⚠ {scene} 有 {len(vids)} 个视频, grid 单视频模式只用第一个: {vids[0].name}")
            video = vids[0]
        except Exception as e:
            print(f"✗ 场景 {scene} 无视频: {e}")
            continue
        for cc in colmap_combos:
            variant = f"{scene}__{_colmap_tag(cc)}"
            base = Path(cfg.work_root) / f"_gbase_{variant}"
            try:
                _build_grid_base(base, video, cc)
            except Exception as e:
                print(f"✗ COLMAP base {variant} 失败: {e}")
                if not colmap_only:
                    for tc in train_combos:
                        res["fail"].append(f"{variant}__{_train_tag(tc)}")
                continue

            if colmap_only:                        # 只报注册率, 跳过训练
                if not shell.DRY_RUN:
                    try:
                        n = len(list((base / "images").glob("*.jpg")))
                        reports.append((variant, sfm.colmap_report(base / "sparse" / "0", n)))
                    except Exception as e:
                        print(f"⚠ {variant} 读取重建失败: {e}")
                continue

            for tc in train_combos:
                name = f"{variant}__{_train_tag(tc)}"
                dest = out_dir / name
                if disk.final_ply(dest, cfg.steps).exists():
                    print(f">>> 跳过 {name} (已有 ply)")
                    res["skip"].append(name)
                    continue
                try:
                    print(f"\n>>> {name}")
                    wres = Path(cfg.work_root) / f"_g_{name}"
                    if not shell.DRY_RUN:
                        shutil.rmtree(wres, ignore_errors=True)
                    steps.train(base, wres / "results", tc.get("strategy", "default"), cfg.steps, tc)
                    steps.finalize(wres, dest)
                    ok = shell.DRY_RUN or disk.final_ply(dest, cfg.steps).exists()
                    res["ok" if ok else "fail"].append(name)
                except Exception as e:
                    print(f"✗ {name} 失败: {e}")
                    res["fail"].append(name)

    if colmap_only:
        _colmap_summary(reports)
    else:
        _summary(res)
        print(f"出对比表: python -m pipeline metrics {out_dir} --csv grid.csv")


def _colmap_summary(reports):
    print("\n" + "#" * 70)
    print("# COLMAP 快扫结果(按注册率排序; 注册率高 + 畸变OK = 能重建)")
    print("| 配置 | 注册/帧 | 注册率 | 点数 | 重投影px | 相机 | k1 | 畸变OK |")
    print("|---|---|---|---|---|---|---|---|")
    for variant, r in sorted(reports, key=lambda x: -(x[1]["reg_rate"] or 0)):
        rate = f"{r['reg_rate'] * 100:.0f}%" if r["reg_rate"] is not None else "-"
        rp = f"{r['reproj_px']:.2f}" if r["reproj_px"] else "-"
        print(f"| {variant} | {r['registered']}/{r['frames']} | {rate} | {r['points']} | "
              f"{rp} | {r['model']} | {r['k1']:.3f} | {'✓' if r['k1_ok'] else '✗'} |")
    print("#" * 70)


def _summary(res):
    print("\n" + "#" * 60)
    print(f"# 完成: 成功 {len(res['ok'])} / 跳过 {len(res['skip'])} / 失败 {len(res['fail'])}")
    for k in ("ok", "skip", "fail"):
        if res[k]:
            print(f"#   {k}: {' '.join(res[k])}")
    print("#" * 60)
