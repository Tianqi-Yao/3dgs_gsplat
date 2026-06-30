#!/usr/bin/env bash
# 参数扫描实验: 用单株 data/0623_one_tomato.mp4 跑多种训练参数组合, 对比效果。
#
# ★ 重要: COLMAP/训练全程在本地 ext4(WORK_ROOT)进行, 结果搬到 OUT 下。
#   原因: 16TB 输出盘是 FUSE(fuseblk), COLMAP mapper 在其上三角化会失败(只注册个位数帧)。
#
# 关键优化: 抽帧 + COLMAP 只做一次(共享 base), 各组合只重跑训练。
#
# 组合(10个), 输出目录名体现参数:
#   default__app{0,1}_pose{0,1}   mcmc__app{0,1}_pose{0,1}   mcmc_3dgut__app{0,1}
#   app=--app_opt(户外曝光) pose=--pose_opt(抗漂移) 3dgut=--with_ut --with_eval3d(广角畸变,仅MCMC)
#
# 用法: scripts/ablation_one_tomato.sh    依赖: ffmpeg/ffprobe, colmap, conda activate gsplat

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

VIDEO="data/tomato_0623_mp4/0623_1tomato_2.mp4"
OUT="output/_ablation_one_tomato"           # 16TB 上的最终输出根
WORK_ROOT="${WORK_ROOT:-$ROOT/scratch}"      # 本地 ext4 高速计算盘, 成品搬到 OUT 后可清
WBASE="$WORK_ROOT/_ablation_base"           # 本地共享 base(images + sparse/0)
WIDTH=1920
TARGET=300
STEPS=15000
CAMERA_MODEL="${CAMERA_MODEL:-OPENCV}"
FINAL_PLY="ply/point_cloud_$((STEPS - 1)).ply"

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
[ -f "$VIDEO" ] || { echo "✗ 找不到输入视频 $VIDEO"; exit 1; }
mkdir -p "$OUT" "$WORK_ROOT"
wfs=$(df -T "$WORK_ROOT" 2>/dev/null | awk 'NR==2{print $2}')
[ "$wfs" = "fuseblk" ] && { echo "✗ WORK_ROOT 是 FUSE 盘, COLMAP 会失败! 换本地 ext4"; exit 1; }

# ================= 第一步: 抽帧 + COLMAP (本地, 只做一次) =================
if [ -f "$WBASE/sparse/0/cameras.bin" ] && [ -d "$WBASE/images" ]; then
  echo "=== 复用已有本地 base: $WBASE ==="
else
  echo "=== 准备共享 base(本地 ext4): 抽帧 + COLMAP ==="
  rm -rf "$WBASE"; mkdir -p "$WBASE/images"

  DUR="$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$VIDEO" 2>/dev/null)"
  if [[ "$DUR" =~ ^[0-9]+(\.[0-9]+)?$ ]] && (( $(awk -v d="$DUR" 'BEGIN{print (d>0)}') )); then
    FPS="$(awk -v t="$TARGET" -v d="$DUR" 'BEGIN{f=t/d; if(f<2)f=2; if(f>15)f=15; printf "%.3f", f}')"
  else
    FPS=14
  fi
  echo "时长=${DUR}s 目标=${TARGET}帧 -> fps=$FPS 宽=$WIDTH"

  ffmpeg -nostdin -y -i "$VIDEO" -vf "fps=$FPS,scale=$WIDTH:-1" -qscale:v 2 \
    "$WBASE/images/frame_%04d.jpg"
  nframe=$(ls "$WBASE/images" | wc -l); echo "抽帧数: $nframe"

  colmap feature_extractor \
    --database_path "$WBASE/database.db" --image_path "$WBASE/images" \
    --ImageReader.single_camera 1 --ImageReader.camera_model "$CAMERA_MODEL" \
    --FeatureExtraction.use_gpu 1
  colmap sequential_matcher \
    --database_path "$WBASE/database.db" --FeatureMatching.use_gpu 1
  mkdir -p "$WBASE/sparse"
  colmap mapper \
    --database_path "$WBASE/database.db" --image_path "$WBASE/images" \
    --output_path "$WBASE/sparse"

  best=""; best_n=-1
  for d in "$WBASE"/sparse/*/; do
    [ -d "$d" ] || continue
    n=$(registered_count "$d"); n=${n:-0}; echo "  ${d} -> registered=${n}"
    if [ "$n" -gt "$best_n" ]; then best_n=$n; best="${d%/}"; fi
  done
  if [ -z "$best" ] || [ "$best_n" -le 0 ]; then
    echo "✗ COLMAP 未建出有效模型, 实验中止"; exit 1
  fi
  echo "base 注册 $best_n / 抽帧 $nframe"
  if [ "$(basename "$best")" != "0" ]; then
    mv "$best" "$WBASE/sparse/__best"
    find "$WBASE/sparse" -mindepth 1 -maxdepth 1 -name '[0-9]*' -exec rm -rf {} +
    mv "$WBASE/sparse/__best" "$WBASE/sparse/0"
  fi
  echo "=== 本地 base 就绪: $WBASE ==="
fi

# ================= 第二步: 扫训练参数组合 =================
COMBOS=(
  "default__app0_pose0|default|"
  "default__app1_pose0|default|--app_opt"
  "default__app0_pose1|default|--pose_opt"
  "default__app1_pose1|default|--app_opt --pose_opt"
  "mcmc__app0_pose0|mcmc|"
  "mcmc__app1_pose0|mcmc|--app_opt"
  "mcmc__app0_pose1|mcmc|--pose_opt"
  "mcmc__app1_pose1|mcmc|--app_opt --pose_opt"
  "mcmc_3dgut__app0_pose0|mcmc|--with_ut --with_eval3d"
  "mcmc_3dgut__app1_pose0|mcmc|--with_ut --with_eval3d --app_opt"
)

echo
echo "###################################################################"
echo "# 参数扫描: ${#COMBOS[@]} 个组合   steps=$STEPS  (训练本地, 结果搬 $OUT)"
echo "###################################################################"

OK=(); FAIL=(); SKIP=()
for entry in "${COMBOS[@]}"; do
  IFS='|' read -r NAME SUBCMD FLAGS <<<"$entry"
  DEST="$OUT/$NAME"

  echo
  echo ">>> 组合: $NAME   [$SUBCMD $FLAGS]"
  if [ -f "$DEST/$FINAL_PLY" ]; then
    echo "已存在最终 PLY, 跳过。"; SKIP+=("$NAME"); continue
  fi

  WRES="$WORK_ROOT/_abl_$NAME"
  rm -rf "$WRES"; mkdir -p "$WRES"
  # 训练读本地 base, 结果写本地 WRES, 最后搬 16TB。--disable_video 避免 render_traj 崩。
  ( cd "$ROOT/gsplat/examples" && python simple_trainer.py "$SUBCMD" \
      --data_dir "$WBASE" \
      --data_factor 1 \
      --result_dir "$WRES" \
      --max_steps "$STEPS" \
      --eval_steps "$STEPS" \
      --lpips_net vgg \
      --save_ply \
      --disable_video \
      --disable_viewer \
      $FLAGS ) 2>&1 | tee "$WRES/train.log"
  ok="${PIPESTATUS[0]}"

  rm -rf "$DEST"; mkdir -p "$OUT"
  mv "$WRES" "$DEST" 2>/dev/null || { cp -r "$WRES" "$DEST" && rm -rf "$WRES"; }

  if [ "$ok" -eq 0 ] && [ -f "$DEST/$FINAL_PLY" ]; then OK+=("$NAME"); else FAIL+=("$NAME"); fi
done

echo
echo "###################################################################"
echo "# 参数扫描完成"
echo "#   成功(${#OK[@]}): ${OK[*]:-无}"
echo "#   跳过(${#SKIP[@]}): ${SKIP[*]:-无}"
echo "#   失败(${#FAIL[@]}): ${FAIL[*]:-无}"
echo "###################################################################"
for NAME in "${OK[@]}"; do
  printf "  %-28s %s\n" "$NAME" "$(ls -1sh "$OUT/$NAME/$FINAL_PLY" 2>/dev/null | awk '{print $1}')"
done
echo "全部在: $OUT/<组合名>/$FINAL_PLY"
