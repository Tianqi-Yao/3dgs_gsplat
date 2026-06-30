#!/usr/bin/env bash
# 多视角合成: 一个目录下的多个视频(同一场景不同视角) -> 合成单个 3DGS PLY
#
# 与 batch_video_to_ply.sh 的关键区别:
#   - batch 是"每个视频独立出一个 ply", 用 sequential_matcher(只配相邻帧)。
#   - 本脚本把所有视频的帧抽到同一 images/, 用 exhaustive_matcher(全配对),
#     让跨视频的帧互相匹配, 从而注册到同一坐标系 -> 一次 SfM + 一次训练 -> 单个 ply。
#
# ★ COLMAP/训练全程在本地 ext4(WORK_ROOT)进行, 完成后搬到 OUT_ROOT(16TB FUSE)。
#   原因: FUSE 盘上 COLMAP mapper 三角化会退化、只注册个位数帧。
#
# 用法:   scripts/multiview_to_ply.sh [输入目录] [输出名]
# 默认:   scripts/multiview_to_ply.sh data/farmNG_v1 farmNG_v1   (-> output/farmNG_v1/)
# 依赖:   ffmpeg/ffprobe, colmap, conda activate gsplat

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

IN_DIR="${1:-data/jeff_0629}"
OUT_NAME="${2:-jeff_0629}"
OUT_ROOT="output"
WORK_ROOT="${WORK_ROOT:-$ROOT/scratch}"
CAMERA_MODEL="${CAMERA_MODEL:-OPENCV}"     # 镜头: OPENCV(普通) / OPENCV_FISHEYE(广角鱼眼)

# ┌─────────────────────────────────────────────────────────────────────────┐
# │ 质量档参数表 —— 改下面 4 个变量的默认值即可切换 (也可用环境变量临时覆盖)   │
# ├──────────┬────────────────┬─────────┬───────┬────────────────────────────┤
# │ 档位     │ TARGET_PER_VID │ SUBCMD  │ STEPS │ 大概耗时 / 用途             │
# ├──────────┼────────────────┼─────────┼───────┼────────────────────────────┤
# │ 快速预览 │ 80             │ default │ 7000  │ ~15 分钟, 先验证能否合到一起│
# │ 标准     │ 150            │ default │ 15000 │ ~30-50 分钟, 日常够用       │
# │ 高质量   │ 250            │ mcmc    │ 30000 │ ~1.5-2 小时, 细节最好       │
# └──────────┴────────────────┴─────────┴───────┴────────────────────────────┘
# 临时覆盖示例: TARGET_PER_VID=250 SUBCMD=mcmc STEPS=30000 scripts/multiview_to_ply.sh
TARGET_PER_VID="${TARGET_PER_VID:-80}"     # 每个视频目标抽帧数(全配对随帧数 ~O(N^2), 别一上来就拉满)
SUBCMD="${SUBCMD:-default}"                # 训练算法: default / mcmc
STEPS="${STEPS:-7000}"                     # 训练步数
# ┌─────────────────────────────────────────────────────────────────────────────┐
# │ 分辨率参考 (SCALE_H = 喂给训练的图像"高度"; 竖屏=长边, 横屏=短边)              │
# │ ★ 重要: 清晰度上限 = 采集分辨率。SCALE_H 只能降采样, 不能放大无中生有。        │
# │   采集低了(如本例源仅 406x720 + 0.85Mbps), 后期调 SCALE_H 再高也只是插值变糊。 │
# │ ★ 显存几乎不是瓶颈: RTX 5080 16GB, 实测 720高/54万点峰值仅 ~0.9GB。            │
# ├──────────────┬──────────────────────┬──────────────────┬───────────────────────┤
# │ SCALE_H      │ 采集建议(竖屏长边)   │ 预计显存(16GB)   │ 用途                  │
# ├──────────────┼──────────────────────┼──────────────────┼───────────────────────┤
# │ 540          │ ≥540                 │ ~0.6GB           │ 极速预览              │
# │ 720(本例)    │ ≥720                 │ ~0.9GB           │ 偏糊(本例源即此分辨率)│
# │ 1080  ← 推荐 │ ≥1080×1920 (1080p)   │ ~2-3GB           │ 标准, 清晰够用        │
# │ 1440         │ ≥1440×2560 (2K)      │ ~4-6GB           │ 高清                  │
# │ 2160         │ 2160×3840 (4K)       │ ~8-12GB          │ 极致, 训练/COLMAP 较慢│
# └──────────────┴──────────────────────┴──────────────────┴───────────────────────┘
# 采集要点: ①分辨率尽量高(竖屏 1080p 起步, 有条件上 4K) ②高码率(≥20-30Mbps)
#           ③关掉微信/社交软件转码、用原片导出 ④横屏拍则 SCALE_H 填短边(如 1080)
SCALE_H="${SCALE_H:-720}"                  # 抽帧目标高度(见上表; OOM 才降, 16GB 一般到 2160 都行)
FPS_MIN=2
FPS_MAX=15

FINAL_PLY="results/ply/point_cloud_$((STEPS - 1)).ply"

# 从 colmap model_analyzer 输出里取 "Registered images" 数值(避开日志行首时间戳)
registered_count() {
  colmap model_analyzer --path "$1" 2>&1 \
    | awk -F'Registered images: ' '/Registered images:/{print $2+0; exit}'
}

# ---- 自检 ----
command -v ffmpeg  >/dev/null || { echo "✗ 缺 ffmpeg";  exit 1; }
command -v ffprobe >/dev/null || { echo "✗ 缺 ffprobe"; exit 1; }
command -v colmap  >/dev/null || { echo "✗ 缺 colmap";  exit 1; }
python -c "import importlib.util,sys; sys.exit(0 if importlib.util.find_spec('gsplat') else 1)" 2>/dev/null \
  || { echo "✗ 当前 python 找不到 gsplat, 请先 conda activate gsplat"; exit 1; }
[ -d "$IN_DIR" ] || { echo "✗ 找不到输入目录 $IN_DIR"; exit 1; }

shopt -s nullglob
VIDEOS=( "$IN_DIR"/*.mp4 "$IN_DIR"/*.MP4 "$IN_DIR"/*.mov "$IN_DIR"/*.MOV )
[ "${#VIDEOS[@]}" -gt 0 ] || { echo "✗ $IN_DIR 下没有视频"; exit 1; }

mkdir -p "$OUT_ROOT" "$WORK_ROOT"
wfs=$(df -T "$WORK_ROOT" 2>/dev/null | awk 'NR==2{print $2}')
[ "$wfs" = "fuseblk" ] && { echo "✗ WORK_ROOT($WORK_ROOT)是 FUSE 盘, COLMAP 会失败! 换本地 ext4"; exit 1; }

SCENE="$WORK_ROOT/$OUT_NAME"
DEST="$OUT_ROOT/$OUT_NAME"
rm -rf "$SCENE"; mkdir -p "$SCENE/images"

echo "###################################################################"
echo "# 多视角合成: ${#VIDEOS[@]} 个视频 -> 单个 ply"
echo "#   输入=$IN_DIR  输出=$DEST  相机=$CAMERA_MODEL"
echo "#   每视频~${TARGET_PER_VID}帧  ${SUBCMD} ${STEPS}步  工作盘=$SCENE($wfs)"
echo "###################################################################"

# ================= 第一步: 三视频抽帧到同一 images/ (加前缀防冲突) =================
echo "=== [1/4] 抽帧 ==="
for VIDEO in "${VIDEOS[@]}"; do
  PREFIX="$(basename "${VIDEO%.*}")"
  DUR="$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$VIDEO" 2>/dev/null)"
  if [[ "$DUR" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(awk -v d="$DUR" 'BEGIN{print (d>0)}') )); then
    FPS="$(awk -v t="$TARGET_PER_VID" -v d="$DUR" -v lo="$FPS_MIN" -v hi="$FPS_MAX" \
      'BEGIN{f=t/d; if(f<lo)f=lo; if(f>hi)f=hi; printf "%.3f", f}')"
  else
    FPS=5; DUR="?"
  fi
  echo "  $PREFIX: 时长=${DUR}s -> fps=$FPS"
  ffmpeg -nostdin -y -i "$VIDEO" -vf "fps=$FPS,scale=-2:$SCALE_H" -qscale:v 2 \
    "$SCENE/images/${PREFIX}_%04d.jpg"
done
nframe=$(ls "$SCENE/images" | wc -l); echo "总抽帧数: $nframe"

# ================= 第二步: COLMAP 特征提取 =================
echo "=== [2/4] COLMAP 特征提取 (single_camera, $CAMERA_MODEL) ==="
colmap feature_extractor \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --ImageReader.single_camera 1 --ImageReader.camera_model "$CAMERA_MODEL" \
  --FeatureExtraction.use_gpu 1

# ================= 第三步: 全配对匹配 + 建图 =================
echo "=== [3/4] COLMAP 全配对匹配(exhaustive) + 建图 ==="
colmap exhaustive_matcher \
  --database_path "$SCENE/database.db" --FeatureMatching.use_gpu 1
mkdir -p "$SCENE/sparse"
colmap mapper \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --output_path "$SCENE/sparse"

# 挑注册图像最多的子模型当 sparse/0
echo "=== 挑选完整 SfM 模型 ==="
best=""; best_n=-1
for d in "$SCENE"/sparse/*/; do
  [ -d "$d" ] || continue
  n=$(registered_count "$d"); n=${n:-0}; echo "  ${d} -> registered=${n}"
  if [ "$n" -gt "$best_n" ]; then best_n=$n; best="${d%/}"; fi
done
if [ -z "$best" ] || [ "$best_n" -le 0 ]; then
  echo "✗ COLMAP 未建出有效模型, 中止"; exit 1
fi
echo "选中: $best (注册 $best_n / 抽帧 $nframe)"
if [ "$((best_n * 100 / nframe))" -lt 60 ]; then
  echo "⚠ 注册率偏低($best_n/$nframe): 三视角可能没完全合到一起, 看下面前缀统计"
fi
if [ "$(basename "$best")" != "0" ]; then
  mv "$best" "$SCENE/sparse/__best"
  find "$SCENE/sparse" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +
  mv "$SCENE/sparse/__best" "$SCENE/sparse/0"
fi

# 统计 sparse/0 里三个视角各注册了多少帧(验证是否真的合到一起)
echo "=== sparse/0 各视角注册帧数 ==="
python - "$SCENE/sparse/0" <<'PY'
import sys, pycolmap, collections
rec = pycolmap.Reconstruction(sys.argv[1])
c = collections.Counter(img.name.rsplit('_',1)[0] for img in rec.images.values())
for k in sorted(c): print(f"  {k}: {c[k]} 帧")
print(f"  合计注册: {len(rec.images)}")
PY

# ================= 第四步: gsplat 训练 -> 单个 ply =================
echo "=== [4/4] gsplat 训练 ($SUBCMD, $STEPS 步) ==="
( cd "$ROOT/gsplat/examples" && python simple_trainer.py "$SUBCMD" \
    --data_dir "$SCENE" \
    --data_factor 1 \
    --result_dir "$SCENE/results" \
    --max_steps "$STEPS" \
    --eval_steps "$STEPS" \
    --lpips_net vgg \
    --save_ply \
    --disable_video \
    --disable_viewer )
ok=$?

[ "$ok" -eq 0 ] && [ -f "$SCENE/$FINAL_PLY" ] || { echo "✗ 训练失败或未生成 ply"; }

# ================= 搬运到 16TB =================
echo "=== 搬运产物到 $DEST ==="
rm -rf "$DEST"; mkdir -p "$OUT_ROOT"
mv "$SCENE" "$DEST" 2>/dev/null || { cp -r "$SCENE" "$DEST" && rm -rf "$SCENE"; }

echo "###################################################################"
if [ -f "$DEST/$FINAL_PLY" ]; then
  echo "# ✓ 完成: $DEST/$FINAL_PLY"
  ls -lh "$DEST/$FINAL_PLY"
else
  echo "# ✗ 失败: 未找到 $DEST/$FINAL_PLY, 看上面日志"
fi
echo "###################################################################"
