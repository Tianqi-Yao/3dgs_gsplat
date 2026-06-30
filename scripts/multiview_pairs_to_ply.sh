#!/usr/bin/env bash
# 多视角合成(自定义匹配对版): 同场景多机位视频 -> 合成单个 3DGS PLY
#
# 适用: 机位排列规整、相邻机位重叠大(如垂直堆叠 top/mid/bottom)。既知道"谁该和谁配",
#       就不让 COLMAP 盲搜 —— 直接生成匹配对列表, 比 exhaustive / vocab tree 更准更省。
#   · 机位内: 只配相邻帧(overlap, 吃时序)。
#   · 机位间: 用"序号窗口"配对 —— A_i 配 B_{i-w..i+w} —— 窗口 w 吸收"不严格同步"的剪辑漂移。
#   · 不需要 vocab tree。复杂度 ~O(N·overlap + 机位对数·N·窗口)。
#
# ★ COLMAP/训练全程在本地 ext4(WORK_ROOT), 完成后搬到 OUT_ROOT(16TB FUSE)。
#
# 用法:   scripts/multiview_pairs_to_ply.sh [输入目录] [输出名]
# 默认:   scripts/multiview_pairs_to_ply.sh data/jeff_0629 jeff_0629   (-> output/jeff_0629/)
# 依赖:   ffmpeg/ffprobe, colmap, conda activate gsplat

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

IN_DIR="${1:-data/jeff_0629}"
OUT_NAME="${2:-jeff_0629}"
OUT_ROOT="output"
WORK_ROOT="${WORK_ROOT:-$ROOT/scratch}"
CAMERA_MODEL="${CAMERA_MODEL:-OPENCV}"     # 镜头: OPENCV(普通) / OPENCV_FISHEYE(广角鱼眼)

# 质量档(同 multiview 系列, 可用环境变量覆盖)
TARGET_PER_VID="${TARGET_PER_VID:-150}"
SUBCMD="${SUBCMD:-default}"
STEPS="${STEPS:-15000}"
SCALE_H="${SCALE_H:-720}"
FPS_MIN=2
FPS_MAX=15

# ---- 自定义匹配对参数 ----
INTRA_OVERLAP="${INTRA_OVERLAP:-10}"       # 机位内: 每帧配后面多少帧(时序窗口)
INTER_WINDOW="${INTER_WINDOW:-15}"         # 机位间: 序号窗口 ±w(吸收不同步漂移; 漂移大就调大)

FINAL_PLY="results/ply/point_cloud_$((STEPS - 1)).ply"

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
echo "# 多视角合成(自定义匹配对): ${#VIDEOS[@]} 个视频 -> 单个 ply"
echo "#   输入=$IN_DIR  输出=$DEST  相机=$CAMERA_MODEL"
echo "#   每视频~${TARGET_PER_VID}帧  ${SUBCMD} ${STEPS}步  工作盘=$SCENE($wfs)"
echo "#   匹配: 机位内 overlap=$INTRA_OVERLAP + 机位间窗口 ±$INTER_WINDOW"
echo "###################################################################"

# ================= 第一步: 各视频抽帧到同一 images/ (加前缀防冲突) =================
echo "=== [1/5] 抽帧 ==="
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
echo "=== [2/5] COLMAP 特征提取 (single_camera, $CAMERA_MODEL) ==="
colmap feature_extractor \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --ImageReader.single_camera 1 --ImageReader.camera_model "$CAMERA_MODEL" \
  --FeatureExtraction.use_gpu 1

# ================= 第三步: 生成自定义匹配对列表 =================
# 机位内: 同前缀相邻帧(i, i+1..i+overlap)。机位间: 不同前缀, 按帧序号 ±window 配对。
echo "=== [3/5] 生成匹配对 (机位内 overlap=$INTRA_OVERLAP, 机位间窗口 ±$INTER_WINDOW) ==="
python - "$SCENE/images" "$INTRA_OVERLAP" "$INTER_WINDOW" "$SCENE/pairs.txt" <<'PY'
import os, sys, collections
imgdir, overlap, window, out = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]

# 按前缀分组: name="top_0001.jpg" -> prefix="top", idx=1
groups = collections.defaultdict(dict)   # prefix -> {idx: name}
for n in os.listdir(imgdir):
    if not n.lower().endswith(".jpg"):
        continue
    stem, num = n.rsplit("_", 1)
    groups[stem][int(num.split(".")[0])] = n

pairs = set()
def add(a, b):
    pairs.add((a, b) if a < b else (b, a))

# 机位内: 相邻帧
for stem, d in groups.items():
    idxs = sorted(d)
    for k, i in enumerate(idxs):
        for j in idxs[k+1:k+1+overlap]:
            add(d[i], d[j])

# 机位间: 不同前缀两两, 按序号 ±window
prefixes = sorted(groups)
for a in range(len(prefixes)):
    for b in range(a+1, len(prefixes)):
        da, db = groups[prefixes[a]], groups[prefixes[b]]
        for i, na in da.items():
            for j in range(i-window, i+window+1):
                if j in db:
                    add(na, db[j])

with open(out, "w") as f:
    for x, y in sorted(pairs):
        f.write(f"{x} {y}\n")
print(f"  机位: {prefixes}")
print(f"  生成匹配对: {len(pairs)} (对比 exhaustive 全配对 ~{len(sum([list(g) for g in groups.values()],[]))**2//2})")
PY

# ================= 第四步: 按列表匹配 + 建图 =================
echo "=== [4/5] COLMAP 匹配(matches_importer) + 建图 ==="
colmap matches_importer \
  --database_path "$SCENE/database.db" \
  --match_list_path "$SCENE/pairs.txt" --match_type pairs \
  --FeatureMatching.use_gpu 1
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
  echo "⚠ 注册率偏低($best_n/$nframe): 跨机位可能没合上。调大 INTER_WINDOW(如 30) 重跑"
fi
if [ "$(basename "$best")" != "0" ]; then
  mv "$best" "$SCENE/sparse/__best"
  find "$SCENE/sparse" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +
  mv "$SCENE/sparse/__best" "$SCENE/sparse/0"
fi

# 统计各视角注册帧数
echo "=== sparse/0 各视角注册帧数 ==="
python - "$SCENE/sparse/0" <<'PY'
import sys, pycolmap, collections
rec = pycolmap.Reconstruction(sys.argv[1])
c = collections.Counter(img.name.rsplit('_',1)[0] for img in rec.images.values())
for k in sorted(c): print(f"  {k}: {c[k]} 帧")
print(f"  合计注册: {len(rec.images)}")
PY

# ================= 第五步: gsplat 训练 -> 单个 ply =================
echo "=== [5/5] gsplat 训练 ($SUBCMD, $STEPS 步) ==="
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
