#!/usr/bin/env bash
# 多视角合成(刚体 rig 约束版, 实验性): 同场景多机位视频 -> 合成单个 3DGS PLY
#
# 适用: 多机位"刚性固定在同一支架上"(相对位姿全程不变, 如垂直堆叠 top/mid/bottom)。
#   把三机位当成一个刚体 rig, 相对外参作为约束 -> 三机位天生同坐标系/同尺度、
#   一处注册带动其余、更抗漂移。
#
# ★ 前提与局限(务必看):
#   1) COLMAP 的 rig 按"frame(同步快照)"工作: 同序号跨机位的帧被当成"同一时刻"组成一个 frame。
#      你若不严格同步(手动剪辑对齐), frame 分组只是近似, 误差靠 BA 的 ba_refine_sensor_from_rig 吸收。
#   2) 这是 COLMAP 4.1 较新功能 + gsplat 读多 camera/子文件夹, 属实验路线, 可能需按实际输出微调。
#   建议: 和 multiview_pairs_to_ply.sh 跑同一场景做 A/B 对比, 谁的 PSNR/注册率高用谁。
#
# 与 pairs 版的命名差异: rig 要求"同 frame 跨机位同名", 所以抽帧到子文件夹 images/<机位>/NNNN.jpg
#   (不是 pairs 版的 images/<机位>_NNNN.jpg)。
#
# 用法:   scripts/multiview_rig_to_ply.sh [输入目录] [输出名]
# 默认:   scripts/multiview_rig_to_ply.sh data/jeff_0629 jeff_0629   (-> output/jeff_0629/)

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

IN_DIR="${1:-data/jeff_0629}"
OUT_NAME="${2:-jeff_0629}"
OUT_ROOT="output"
WORK_ROOT="${WORK_ROOT:-$ROOT/scratch}"
CAMERA_MODEL="${CAMERA_MODEL:-OPENCV}"

TARGET_PER_VID="${TARGET_PER_VID:-150}"
SUBCMD="${SUBCMD:-default}"
STEPS="${STEPS:-15000}"
SCALE_H="${SCALE_H:-720}"
FPS_MIN=2
FPS_MAX=15
BA_REFINE="${BA_REFINE:-1}"                 # rig 配好后是否再做一次全局 BA refine(1/0)

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
echo "# 多视角合成(刚体 rig, 实验): ${#VIDEOS[@]} 个视频 -> 单个 ply"
echo "#   输入=$IN_DIR  输出=$DEST  相机=$CAMERA_MODEL"
echo "#   每视频~${TARGET_PER_VID}帧  ${SUBCMD} ${STEPS}步  工作盘=$SCENE($wfs)"
echo "###################################################################"

# ================= 第一步: 各视频抽帧到 images/<机位>/NNNN.jpg (子文件夹) =================
# rig 靠"同 frame 跨机位同名"分组: 各机位同序号(0001.jpg)=同一时刻的一帧。
echo "=== [1/6] 抽帧(每机位一个子文件夹) ==="
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
  mkdir -p "$SCENE/images/$PREFIX"
  ffmpeg -nostdin -y -i "$VIDEO" -vf "fps=$FPS,scale=-2:$SCALE_H" -qscale:v 2 \
    "$SCENE/images/$PREFIX/%04d.jpg"
done
nframe=$(find "$SCENE/images" -name '*.jpg' | wc -l); echo "总抽帧数: $nframe"

# ================= 第二步: 特征提取(每子文件夹独立 camera) =================
echo "=== [2/6] COLMAP 特征提取 (single_camera_per_folder, $CAMERA_MODEL) ==="
colmap feature_extractor \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --ImageReader.single_camera_per_folder 1 --ImageReader.camera_model "$CAMERA_MODEL" \
  --FeatureExtraction.use_gpu 1

# ================= 第三步: 全配对匹配 + 初始建图(无 rig) =================
echo "=== [3/6] COLMAP 全配对匹配 + 初始建图 ==="
colmap exhaustive_matcher \
  --database_path "$SCENE/database.db" --FeatureMatching.use_gpu 1
mkdir -p "$SCENE/sparse_init"
colmap mapper \
  --database_path "$SCENE/database.db" --image_path "$SCENE/images" \
  --output_path "$SCENE/sparse_init"

# 挑初始重建里注册最多的子模型
best=""; best_n=-1
for d in "$SCENE"/sparse_init/*/; do
  [ -d "$d" ] || continue
  n=$(registered_count "$d"); n=${n:-0}; echo "  ${d} -> registered=${n}"
  if [ "$n" -gt "$best_n" ]; then best_n=$n; best="${d%/}"; fi
done
[ -z "$best" ] || [ "$best_n" -le 0 ] && { echo "✗ 初始重建失败, 中止"; exit 1; }
echo "初始模型: $best (注册 $best_n / 抽帧 $nframe)"

# ================= 第四步: 生成 rig 配置 + 应用(自动推平均外参) =================
echo "=== [4/6] 生成 rig 配置并应用 ==="
python - "$SCENE/images" "$SCENE/rig.json" <<'PY'
import os, sys, json
imgdir, out = sys.argv[1], sys.argv[2]
subs = sorted(d for d in os.listdir(imgdir) if os.path.isdir(os.path.join(imgdir, d)))
cams = []
for i, s in enumerate(subs):
    c = {"image_prefix": f"{s}/"}
    if i == 0:
        c["ref_sensor"] = True      # 第一个机位作参考 sensor
    cams.append(c)
json.dump([{"cameras": cams}], open(out, "w"), indent=2)
print(f"  机位(sensor): {subs}  参考: {subs[0]}")
PY

# rig_configurator: 用初始重建自动算各 sensor 相对参考的平均外参, 输出带 rig/frame 的重建
colmap rig_configurator \
  --database_path "$SCENE/database.db" \
  --rig_config_path "$SCENE/rig.json" \
  --input_path "$best" \
  --output_path "$SCENE/sparse_rig"

FINAL_MODEL="$SCENE/sparse_rig"

# ================= 第五步: (可选)rig 约束下全局 BA refine =================
if [ "$BA_REFINE" = "1" ]; then
  echo "=== [5/6] rig 约束下全局 BA refine ==="
  mkdir -p "$SCENE/sparse_ba"
  if colmap bundle_adjuster \
       --input_path "$SCENE/sparse_rig" --output_path "$SCENE/sparse_ba"; then
    FINAL_MODEL="$SCENE/sparse_ba"
  else
    echo "⚠ BA refine 失败, 用 rig_configurator 的输出继续"
  fi
else
  echo "=== [5/6] 跳过 BA refine (BA_REFINE=0) ==="
fi

# 放最终模型到 sparse/0 供 gsplat 训练
rm -rf "$SCENE/sparse"; mkdir -p "$SCENE/sparse/0"
cp "$FINAL_MODEL"/*.bin "$SCENE/sparse/0/" 2>/dev/null \
  || cp "$FINAL_MODEL"/* "$SCENE/sparse/0/" 2>/dev/null
[ -f "$SCENE/sparse/0/images.bin" ] || { echo "✗ 最终模型缺 images.bin ($FINAL_MODEL), 中止"; exit 1; }

# 统计各机位注册帧数(rig 模式 image.name = "机位/NNNN.jpg")
echo "=== sparse/0 各机位注册帧数 ==="
python - "$SCENE/sparse/0" <<'PY'
import sys, pycolmap, collections
rec = pycolmap.Reconstruction(sys.argv[1])
c = collections.Counter(img.name.split('/')[0] for img in rec.images.values())
for k in sorted(c): print(f"  {k}: {c[k]} 帧")
print(f"  合计注册: {len(rec.images)}  (rig 数: {len(rec.rigs)}, frame 数: {len(rec.frames)})")
PY

# ================= 第六步: gsplat 训练 -> 单个 ply =================
echo "=== [6/6] gsplat 训练 ($SUBCMD, $STEPS 步) ==="
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
