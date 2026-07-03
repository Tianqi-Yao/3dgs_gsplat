"""磁盘/路径: FUSE 拦截、找视频、搬运、ply 路径。"""
from __future__ import annotations

import shutil
import subprocess
import sys
from pathlib import Path

from . import shell

ROOT = Path(__file__).resolve().parents[2]     # 项目根

_VIDEO_GLOBS = ("*.mp4", "*.MP4", "*.mov", "*.MOV")


def require_local_disk(path):
    """COLMAP mapper 在 FUSE 盘上会失败 —— 拦下非本地盘的 work_root。"""
    p = Path(path)
    p.mkdir(parents=True, exist_ok=True)
    try:
        fstype = subprocess.run(["df", "-T", str(p)], capture_output=True, text=True,
                                check=True).stdout.splitlines()[1].split()[1]
    except Exception:
        fstype = "?"
    if fstype == "fuseblk":
        sys.exit(f"✗ work_root({p}) 是 FUSE 盘, COLMAP 会失败! 换本地 ext4")


def find_videos(scene_dir) -> list[Path]:
    d = Path(scene_dir)
    hits = sorted(h for g in _VIDEO_GLOBS for h in d.glob(g))
    if not hits:
        sys.exit(f"✗ {d}/ 里没找到视频(.mp4/.MP4/.mov/.MOV)")
    return hits


def find_video(scene_dir) -> Path:
    return find_videos(scene_dir)[0]


def move_to_output(work_scene, out_scene):
    """把本地 scratch/<scene> 整体搬到 output/<scene>。"""
    work_scene, out_scene = Path(work_scene), Path(out_scene)
    print(f"+ 搬运 {work_scene} -> {out_scene}")
    if shell.DRY_RUN:
        return
    if out_scene.exists():
        shutil.rmtree(out_scene)
    out_scene.parent.mkdir(parents=True, exist_ok=True)
    try:
        shutil.move(str(work_scene), str(out_scene))
    except Exception:
        shutil.copytree(work_scene, out_scene)
        shutil.rmtree(work_scene, ignore_errors=True)


def final_ply(scene_root, max_steps) -> Path:
    """最终 ply 路径(断点续跑判断用)。"""
    return Path(scene_root) / "results" / "ply" / f"point_cloud_{max_steps - 1}.ply"
