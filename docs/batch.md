# 批量 → 各出一个 PLY

给一组场景，逐个跑[单视频流程](single.md)。就是「把单视频跑很多遍 + 断点续跑 + 汇总」。

## 跑

编辑 `configs/batch.yaml` 的 `scenes:`（多列几个），然后：

```bash
conda activate gsplat
python -m pipeline batch --config configs/batch.yaml
```

- **参数**（`params:`）对所有场景统一，同 [single.md](single.md)。想让不同场景用不同参数，就分成几个 yaml 分别跑。
- **断点续跑**：`output/<场景>/results/ply/` 已有最终 ply 的场景自动跳过；结尾打印 成功/跳过/失败 汇总。

## 后台整夜跑

```bash
conda activate gsplat
setsid bash -c 'python -m pipeline batch --config configs/batch.yaml' </dev/null \
  > output/batch_$(date +%m%d_%H%M).log 2>&1 &
tail -f output/batch_*.log
```

- 必须先 `conda activate gsplat`；`setsid + </dev/null` 让任务脱离终端（否则后台 ffmpeg 会被 `SIGTTIN` 挂起）。
- 中途停：`pkill -9 -f "pipeline"; pkill -9 -f colmap`。重跑同一命令会跳过已完成的。

跑完出表：`python -m pipeline metrics output --csv batch.csv`。
