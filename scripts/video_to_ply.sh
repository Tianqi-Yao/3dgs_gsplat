#!/usr/bin/env bash
# 单视频 -> COLMAP SfM -> gsplat 训练 -> 单个 PLY 的一键脚本
#
# 输入约定(按文件夹来): data/<场景名>/ 文件夹里放这一个视频(.mp4/.MP4/.mov/.MOV)。
#   脚本自动找文件夹里的视频, 抽帧/COLMAP/训练/产物全部以 <场景名> 命名。
#
# ★ COLMAP/训练全程在本地 ext4(WORK_ROOT=scratch)进行, 完成后整体搬到 output/<场景名>/。
#   原因: data/ 和 output/ 都软链到 16TB FUSE 盘, COLMAP mapper 在 FUSE 上三角化会失败。
#
# 用法:
#   方式A(改下面 NAME 一行的默认值): scripts/video_to_ply.sh
#   方式B(传参):                     scripts/video_to_ply.sh <场景名>
# 质量档用环境变量临时覆盖:          MAX_STEPS=30000 scripts/video_to_ply.sh
#
# 依赖: ffmpeg, colmap(>=3.9/4.x), conda activate gsplat (已装 gsplat + pycolmap)。
# 产物: output/<场景名>/results/ply/point_cloud_<step-1>.ply

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

NAME="${1:-jeff_0629_iphone1_MID}"   # ← 换视频只改这一处(或传参)

IN_DIR="data/$NAME"                      # 输入: 视频放这个文件夹
OUT_ROOT="output"
WORK_ROOT="${WORK_ROOT:-$ROOT/scratch}"  # 本地 ext4 工作盘(COLMAP/训练在这跑)
SCENE="$WORK_ROOT/$NAME"                 # 本地工作目录
DEST="$OUT_ROOT/$NAME"                   # 最终产物落地(16TB)

# 质量/速度档(可用环境变量临时覆盖)
FPS="${FPS:-8}"                          # 每秒抽帧数; 视角稀就调大
WIDTH="${WIDTH:-1920}"                   # 抽帧宽度(4K降到1920, COLMAP/训练都快)
MAX_STEPS="${MAX_STEPS:-7000}"           # 训练步数; 30000=高质量
CAMERA_MODEL="${CAMERA_MODEL:-OPENCV}"   # 普通镜头; 广角鱼眼用 OPENCV_FISHEYE

FINAL_PLY="results/ply/point_cloud_$((MAX_STEPS - 1)).ply"

# 从 colmap model_analyzer 输出里正确取"Registered images"的数值
# (注意: 不能用 grep -oE '[0-9]+' 取首个数字, 会抓到日志行首的时间戳 I20260625)
registered_count() {
  colmap model_analyzer --path "$1" 2>&1 \
    | awk -F'Registered images: ' '/Registered images:/{print $2+0; exit}'
}

# ---- 找输入视频 + 工作盘自检 ----
[ -d "$IN_DIR" ] || { echo "✗ 找不到输入目录 $IN_DIR"; exit 1; }
VIDEO="$(find "$IN_DIR" -maxdepth 1 -type f \( -iname '*.mp4' -o -iname '*.mov' \) 2>/dev/null | sort | head -1)"
[ -z "$VIDEO" ] && { echo "✗ $IN_DIR/ 里没找到视频(.mp4/.MP4/.mov/.MOV)。请把视频放进该文件夹"; exit 1; }
echo "输入视频: $VIDEO"

mkdir -p "$OUT_ROOT" "$WORK_ROOT"
wfs=$(df -T "$WORK_ROOT" 2>/dev/null | awk 'NR==2{print $2}')
[ "$wfs" = "fuseblk" ] && { echo "✗ WORK_ROOT($WORK_ROOT)是 FUSE 盘, COLMAP 会失败! 换本地 ext4"; exit 1; }
rm -rf "$SCENE"; mkdir -p "$SCENE/images"

echo "=== [1/4] ffmpeg 抽帧 (fps=$FPS, 宽=$WIDTH) ==="
ffmpeg -nostdin -y -i "$VIDEO" -vf "fps=$FPS,scale=$WIDTH:-1" -qscale:v 2 \
  "$SCENE/images/frame_%04d.jpg"
nframe=$(ls "$SCENE/images" | wc -l)
echo "抽帧数: $nframe"

echo "=== [2/4] COLMAP 特征提取 ==="
colmap feature_extractor \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --ImageReader.single_camera 1 --ImageReader.camera_model "$CAMERA_MODEL" \
  --FeatureExtraction.use_gpu 1

echo "=== [3/4] COLMAP 顺序匹配 + 建图 ==="
colmap sequential_matcher \
  --database_path "$SCENE/database.db" --FeatureMatching.use_gpu 1
mkdir -p "$SCENE/sparse"
colmap mapper \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --output_path "$SCENE/sparse"

# 自动挑注册图像最多的子模型为 sparse/0 (mapper 可能拆出多个, 完整的不一定是 0 号)
echo "=== 挑选完整 SfM 模型 ==="
best="" best_n=-1
for d in "$SCENE"/sparse/*/; do
  [ -d "$d" ] || continue
  n=$(registered_count "$d"); n=${n:-0}
  echo "  ${d} -> registered=${n}"
  if [ "$n" -gt "$best_n" ]; then best_n=$n; best="${d%/}"; fi
done
if [ -z "$best" ] || [ "$best_n" -le 0 ]; then
  echo "!! COLMAP 未建出有效模型 (registered=$best_n), 放弃"; exit 1
fi
echo "选中: $best (注册 $best_n / 抽帧 $nframe)"
if [ "$best_n" -lt 30 ] || [ "$((best_n * 100 / nframe))" -lt 40 ]; then
  echo "⚠ 注册图像偏少($best_n/$nframe), 重建质量可能差; 若产物不可用, 检查相机模型/抽帧密度"
fi
if [ "$(basename "$best")" != "0" ]; then
  mv "$best" "$SCENE/sparse/__best"
  find "$SCENE/sparse" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +
  mv "$SCENE/sparse/__best" "$SCENE/sparse/0"
fi

echo "=== [4/4] gsplat 训练并导出 PLY (max_steps=$MAX_STEPS) ==="
( cd "$ROOT/gsplat/examples" && python simple_trainer.py default \
    --data_dir "$SCENE" \
    --data_factor 1 \
    --result_dir "$SCENE/results" \
    --max_steps "$MAX_STEPS" \
    --eval_steps "$MAX_STEPS" \
    --lpips_net vgg \
    --save_ply \
    --disable_viewer )
ok=$?
[ "$ok" -eq 0 ] && [ -f "$SCENE/$FINAL_PLY" ] || echo "✗ 训练失败或未生成 ply"

# ---- 搬运到 16TB ----
echo "=== 搬运产物到 $DEST ==="
rm -rf "$DEST"; mkdir -p "$OUT_ROOT"
mv "$SCENE" "$DEST" 2>/dev/null || { cp -r "$SCENE" "$DEST" && rm -rf "$SCENE"; }

echo "==================================================================="
if [ -f "$DEST/$FINAL_PLY" ]; then
  echo "# ✓ 完成: $DEST/$FINAL_PLY"
  ls -lh "$DEST/$FINAL_PLY"
else
  echo "# ✗ 失败: 未找到 $DEST/$FINAL_PLY, 看上面日志"
fi
echo "==================================================================="
