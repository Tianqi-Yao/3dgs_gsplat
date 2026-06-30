#!/usr/bin/env bash
# 批量跑单视频流程: 给一组场景名, 逐个调用 scripts/video_to_ply.sh。
#
# ★ 本脚本只是 video_to_ply.sh 的薄封装(循环调用)。单视频逻辑(抽帧/COLMAP/训练/搬运)
#   全在 video_to_ply.sh 里 —— 以后改那个, 批量自动跟着更新, 这里不用动。
#
# 每个场景 = data/<场景名>/ 文件夹(里面放一个视频), 产物到 output/<场景名>/。
#
# 怎么给场景 list(三选一):
#   方式A: 改下面 SCENES 数组的默认值, 然后 scripts/batch_video_to_ply.sh
#   方式B: 传参,每个场景名一个   scripts/batch_video_to_ply.sh sceneA sceneB ...
#   方式C: 从文件读,每行一个     scripts/batch_video_to_ply.sh -f scenes.txt
# 给的可以是场景名(jeff_0629_mid)或路径(data/jeff_0629_mid/), 脚本会归一。
#
# 质量档环境变量对所有场景一起生效: MAX_STEPS=30000 scripts/batch_video_to_ply.sh
# 已完成(output/<场景>/results/ply 里有 ply)默认跳过; FORCE=1 强制重跑。

set -uo pipefail

ROOT="/home/tianqi/D/01_Projects/15_3dgs_gsplat"
cd "$ROOT" || { echo "✗ 无法进入项目根 $ROOT"; exit 1; }

ONE="scripts/video_to_ply.sh"
FORCE="${FORCE:-0}"

# ── 方式A: 在这里列要批量跑的场景(一行一个) ─────────────────────────────
SCENES=(
  jeff_0629_iphone1_MID
  jeff_0629_iphone1_TOP
  jeff_0629_iphone2_MID
  jeff_0629_iphone2_TOP
  )
# ────────────────────────────────────────────────────────────────────────

# 方式C(-f 文件) / 方式B(传参) 覆盖默认 list
if [ "${1:-}" = "-f" ]; then
  [ -n "${2:-}" ] && [ -f "$2" ] || { echo "✗ 用法: $0 -f <场景列表文件>"; exit 1; }
  mapfile -t SCENES < <(grep -vE '^[[:space:]]*(#|$)' "$2")
elif [ "$#" -gt 0 ]; then
  SCENES=("$@")
fi

[ "${#SCENES[@]}" -gt 0 ] || { echo "✗ 没有要跑的场景: 改 SCENES 数组 / 传参 / -f 文件"; exit 1; }

echo "###################################################################"
echo "# 批量单视频: 共 ${#SCENES[@]} 个场景  (FORCE=$FORCE)"
echo "#   ${SCENES[*]}"
echo "###################################################################"

ok=(); skip=(); fail=()
i=0
for s in "${SCENES[@]}"; do
  s="${s#data/}"; s="${s%/}"          # 归一: 去掉 data/ 前缀和尾斜杠
  i=$((i + 1))
  echo ""
  echo ">>> [$i/${#SCENES[@]}] 场景: $s"

  if [ "$FORCE" != "1" ] && ls output/"$s"/results/ply/*.ply >/dev/null 2>&1; then
    echo "    已完成, 跳过 (FORCE=1 强制重跑)"; skip+=("$s"); continue
  fi

  "$ONE" "$s"
  # 用产物是否生成判定成败(单视频脚本训练失败时不一定返回非0)
  if ls output/"$s"/results/ply/*.ply >/dev/null 2>&1; then
    echo "    ✓ $s 完成"; ok+=("$s")
  else
    echo "    ✗ $s 失败(未生成 ply)"; fail+=("$s")
  fi
done

echo ""
echo "###################################################################"
echo "# 批量结束: 成功 ${#ok[@]} / 跳过 ${#skip[@]} / 失败 ${#fail[@]}"
echo "#   成功: ${ok[*]:-无}"
echo "#   跳过: ${skip[*]:-无}"
echo "#   失败: ${fail[*]:-无}"
echo "###################################################################"
[ "${#fail[@]}" -eq 0 ]
