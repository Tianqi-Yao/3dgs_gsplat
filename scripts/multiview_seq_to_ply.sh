#!/usr/bin/env bash
# 多视角合成(顺序匹配版): 一个目录下多个视频(同场景不同视角) -> 合成单个 3DGS PLY
#
# 与 multiview_to_ply.sh 的唯一区别 = 第三步的匹配策略:
#   - multiview_to_ply.sh   : exhaustive(全配对), 每帧配每帧, ~O(N^2)。帧数少(≤几百)最稳。
#   - 本脚本(seq)           : sequential + loop_detection(vocab tree)。
#       · 抽帧带前缀(top_/mid_/bottom_), 合并库按图像名排序后每个机位连成一段,
#         sequential 的 overlap 正好吃到"机位内时序"(只配前后若干帧, 便宜)。
#       · loop_detection 用 vocab tree 做全局检索, 把"跨机位真正有共视"的帧对补上,
#         不依赖时序。复杂度近线性, 帧数多(几百~几千)时比 exhaustive 快一个量级。
#   何时用哪个: TARGET_PER_VID 小(80)/机位少 -> exhaustive; 帧数拉大/机位多 -> 本脚本。
#
# ★ 需要 vocab tree 文件(一次性下载, 见下方 VOCAB_TREE 自检处的提示)。
# ★ COLMAP/训练全程在本地 ext4(WORK_ROOT)进行, 完成后搬到 OUT_ROOT(16TB FUSE)。
#
# 用法:   scripts/multiview_seq_to_ply.sh [输入目录] [输出名]
# 默认:   scripts/multiview_seq_to_ply.sh data/jeff_0629 jeff_0629   (-> output/jeff_0629/)
# 依赖:   ffmpeg/ffprobe, colmap, conda activate gsplat, vocab tree bin

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
# │ 标准     │ 150            │ default │ 15000 │ 顺序匹配, 帧数多时也不慢    │
# │ 高质量   │ 250            │ mcmc    │ 30000 │ 机位多/轨迹长时优先用本脚本 │
# └──────────┴────────────────┴─────────┴───────┴────────────────────────────┘
# 临时覆盖示例: TARGET_PER_VID=250 SUBCMD=mcmc STEPS=30000 scripts/multiview_seq_to_ply.sh
TARGET_PER_VID="${TARGET_PER_VID:-150}"    # 每个视频目标抽帧数(顺序匹配近线性, 可比 exhaustive 抽更密)
SUBCMD="${SUBCMD:-default}"                # 训练算法: default / mcmc
STEPS="${STEPS:-15000}"                    # 训练步数
SCALE_H="${SCALE_H:-720}"                  # 抽帧目标高度(竖屏=长边); OOM 才降, 16GB 一般到 2160 都行
FPS_MIN=2
FPS_MAX=15

# ---- 顺序匹配 + 回环检测参数 ----
VOCAB_TREE="${VOCAB_TREE:-$ROOT/vocab_tree_flickr100K_words256K.bin}"  # vocab tree 文件
OVERLAP="${OVERLAP:-10}"                   # 机位内: 每帧配前后多少帧(时序窗口)
LOOP_NUM="${LOOP_NUM:-50}"                 # 跨机位: 每次回环检索取多少候选(机位多可调大)

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
if [ ! -f "$VOCAB_TREE" ]; then
  echo "✗ 找不到 vocab tree: $VOCAB_TREE"
  echo "  顺序匹配的跨机位回环检测需要它。一次性下载(约150MB):"
  echo "    wget -O \"$VOCAB_TREE\" https://demuc.de/colmap/vocab_tree_flickr100K_words256K.bin"
  echo "  或用环境变量指向已有文件: VOCAB_TREE=/路径/xxx.bin scripts/multiview_seq_to_ply.sh"
  exit 1
fi

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
echo "# 多视角合成(顺序匹配): ${#VIDEOS[@]} 个视频 -> 单个 ply"
echo "#   输入=$IN_DIR  输出=$DEST  相机=$CAMERA_MODEL"
echo "#   每视频~${TARGET_PER_VID}帧  ${SUBCMD} ${STEPS}步  工作盘=$SCENE($wfs)"
echo "#   匹配: sequential overlap=$OVERLAP + loop_detection(num=$LOOP_NUM)"
echo "###################################################################"

# ================= 第一步: 各视频抽帧到同一 images/ (加前缀防冲突) =================
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

# ================= 第三步: 顺序匹配 + 回环检测 + 建图 =================
# overlap   -> 机位内: 图像名排序后每机位成段, 只配段内相邻帧(吃时序, 便宜)
# loop_*    -> 跨机位: vocab tree 全局检索相似帧, 把跨机位共视对补上(不依赖时序)
echo "=== [3/4] COLMAP 顺序匹配(sequential + loop_detection) + 建图 ==="
colmap sequential_matcher \
  --database_path "$SCENE/database.db" --FeatureMatching.use_gpu 1 \
  --SequentialMatching.overlap "$OVERLAP" \
  --SequentialMatching.loop_detection 1 \
  --SequentialMatching.loop_detection_num_images "$LOOP_NUM" \
  --SequentialMatching.vocab_tree_path "$VOCAB_TREE"
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
  echo "⚠ 注册率偏低($best_n/$nframe): 跨机位可能没完全合到一起。"
  echo "  顺序匹配靠 loop_detection 找跨机位共视, 可调大 LOOP_NUM(如 80) 或退回 exhaustive 版"
fi
if [ "$(basename "$best")" != "0" ]; then
  mv "$best" "$SCENE/sparse/__best"
  find "$SCENE/sparse" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +
  mv "$SCENE/sparse/__best" "$SCENE/sparse/0"
fi

# 统计 sparse/0 里各视角各注册了多少帧(验证是否真的合到一起)
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
