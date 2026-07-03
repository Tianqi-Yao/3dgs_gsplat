"""每一步「调什么命令」—— 想改 ffmpeg/colmap/gsplat 的命令或参数, 看这里。

步骤: 抽帧(单/多机位) · COLMAP 重建(按 matcher 分派) · 训练 · 搬运。
真正的 3DGS 算法在 gsplat/(外部), 这里只是调它。
"""
from __future__ import annotations

import shutil
import subprocess
from pathlib import Path

from ._helpers import shell, disk, sfm
from ._helpers.shell import run
from ._helpers.disk import ROOT

VOCAB_DEFAULT = "vocab_tree_flickr100K_words256K.bin"


# ── 抽帧 ────────────────────────────────────────────────────────────────────
def extract_frames(video, images_dir, fps, width):
    Path(images_dir).mkdir(parents=True, exist_ok=True)
    run(["ffmpeg", "-nostdin", "-y", "-i", video,
         "-vf", f"fps={fps},scale={width}:-1", "-qscale:v", "2",
         f"{images_dir}/frame_%04d.jpg"])


def _fps_for(video, target, lo, hi):
    """按时长动态算 fps 使帧数 ≈ target。"""
    try:
        dur = float(subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration",
             "-of", "csv=p=0", str(video)],
            capture_output=True, text=True, check=True).stdout.strip())
        return dur, max(lo, min(hi, target / dur))
    except Exception:
        return None, 5.0


def extract_frames_multiview(videos, images_dir, p, rig=False):
    """多视频抽到同一 images/(带 <前缀>_ 命名) 或 rig 的子文件夹 images/<前缀>/。"""
    images_dir = Path(images_dir)
    for v in videos:
        prefix = Path(v).stem
        dur, fps = _fps_for(v, p.target_per_vid, p.fps_min, p.fps_max)
        print(f"  {prefix}: 时长={dur}s -> fps={fps:.3f}")
        if rig:
            out = images_dir / prefix
            out.mkdir(parents=True, exist_ok=True)
            pattern = f"{out}/%04d.jpg"
        else:
            images_dir.mkdir(parents=True, exist_ok=True)
            pattern = f"{images_dir}/{prefix}_%04d.jpg"
        run(["ffmpeg", "-nostdin", "-y", "-i", v,
             "-vf", f"fps={fps:.3f},scale=-2:{p.scale_h}", "-qscale:v", "2", pattern])


# ── COLMAP 重建(按 matcher 分派) ────────────────────────────────────────────
def colmap_reconstruct(scene_dir, images_dir, camera_model, matcher="sequential", opts=None):
    """matcher: sequential(单视频) / exhaustive / seq(顺序+回环) / pairs(自定义对) / rig。"""
    opts = opts or {}
    scene_dir, images_dir = Path(scene_dir), Path(images_dir)
    db = scene_dir / "database.db"
    if not shell.DRY_RUN and db.exists():
        db.unlink()
    shutil.rmtree(scene_dir / "sparse", ignore_errors=True)

    cam_flag = "--ImageReader.single_camera_per_folder" if matcher == "rig" else "--ImageReader.single_camera"
    run(["colmap", "feature_extractor", "--database_path", db, "--image_path", images_dir,
         cam_flag, "1", "--ImageReader.camera_model", camera_model, "--FeatureExtraction.use_gpu", "1"])

    _match(db, images_dir, scene_dir, matcher, opts)

    (scene_dir / "sparse").mkdir(parents=True, exist_ok=True)
    run(["colmap", "mapper", "--database_path", db, "--image_path", images_dir,
         "--output_path", scene_dir / "sparse"])

    if matcher == "rig":
        _apply_rig(scene_dir, images_dir, opts)
    elif not shell.DRY_RUN:
        sfm.pick_sparse0(scene_dir / "sparse")


def _match(db, images_dir, scene_dir, matcher, opts):
    if matcher in ("sequential", "seq"):
        cmd = ["colmap", "sequential_matcher", "--database_path", db, "--FeatureMatching.use_gpu", "1"]
        if matcher == "seq":
            vocab = ROOT / opts.get("vocab_tree", VOCAB_DEFAULT)
            cmd += ["--SequentialMatching.overlap", opts.get("overlap", 10),
                    "--SequentialMatching.loop_detection", "1",
                    "--SequentialMatching.loop_detection_num_images", opts.get("loop_num", 50),
                    "--SequentialMatching.vocab_tree_path", vocab]
        run(cmd)
    elif matcher in ("exhaustive", "rig"):
        run(["colmap", "exhaustive_matcher", "--database_path", db, "--FeatureMatching.use_gpu", "1"])
    elif matcher == "pairs":
        pairs = scene_dir / "pairs.txt"
        if not shell.DRY_RUN:
            sfm.gen_pairs(images_dir, opts.get("intra_overlap", 10), opts.get("inter_window", 15), pairs)
        run(["colmap", "matches_importer", "--database_path", db,
             "--match_list_path", pairs, "--match_type", "pairs", "--FeatureMatching.use_gpu", "1"])
    else:
        raise SystemExit(f"✗ 未知 matcher: {matcher}")


def _apply_rig(scene_dir, images_dir, opts):
    """rig(实验): 挑初始模型 → rig_configurator 推平均外参 → (可选)BA refine → sparse/0。"""
    if shell.DRY_RUN:
        run(["colmap", "rig_configurator", "--database_path", scene_dir / "database.db",
             "--rig_config_path", scene_dir / "rig.json",
             "--input_path", scene_dir / "sparse/0", "--output_path", scene_dir / "sparse_rig"])
        return
    sfm.pick_sparse0(scene_dir / "sparse")                    # 初始模型挑成 sparse/0
    sfm.write_rig_config(images_dir, scene_dir / "rig.json")
    run(["colmap", "rig_configurator", "--database_path", scene_dir / "database.db",
         "--rig_config_path", scene_dir / "rig.json",
         "--input_path", scene_dir / "sparse/0", "--output_path", scene_dir / "sparse_rig"])
    final = scene_dir / "sparse_rig"
    if opts.get("ba_refine", True):
        ba = scene_dir / "sparse_ba"
        ba.mkdir(exist_ok=True)
        try:
            run(["colmap", "bundle_adjuster", "--input_path", scene_dir / "sparse_rig", "--output_path", ba])
            final = ba
        except subprocess.CalledProcessError:
            print("⚠ BA refine 失败, 用 rig_configurator 输出")
    dst = scene_dir / "sparse" / "0"
    shutil.rmtree(scene_dir / "sparse", ignore_errors=True)
    dst.mkdir(parents=True)
    for f in final.glob("*.bin"):
        shutil.copy(f, dst)


# ── 训练 / 搬运 ──────────────────────────────────────────────────────────────
def train(data_dir, result_dir, p):
    """调 gsplat simple_trainer(子进程)。固定 --lpips_net alex + --eval_steps=max_steps。"""
    data_dir, result_dir = Path(data_dir).resolve(), Path(result_dir).resolve()
    cmd = ["python", "simple_trainer.py", p.strategy,
           "--data_dir", data_dir, "--data_factor", "1", "--result_dir", result_dir,
           "--max_steps", p.max_steps, "--eval_steps", p.max_steps, "--lpips_net", "alex",
           "--sh_degree", p.sh_degree, "--ssim_lambda", p.ssim_lambda]
    if p.strategy == "mcmc":
        cmd += ["--strategy.cap_max", getattr(p, "cap_max", 1_000_000)]
    cmd += ["--save_ply", "--disable_video", "--disable_viewer"]
    run(cmd, cwd=ROOT / "gsplat" / "examples")


def finalize(work_scene, out_scene):
    disk.move_to_output(work_scene, out_scene)
