# 批量单视频 → 各出一个 PLY 快速上手

给一组场景名，**批量跑单视频流程**——每个场景按 `QUICKSTART.md` 那套（抽帧 → COLMAP → 训练 → 导 PLY）
独立出一个 `.ply`。

脚本：`scripts/batch_video_to_ply.sh`
环境：conda 环境 **`gsplat`**，已装 gsplat + pycolmap，系统有 colmap / ffmpeg，GPU RTX 5080 16GB。

> **本脚本只是 `video_to_ply.sh` 的薄封装**（循环调用它）。所有单视频逻辑都在 `video_to_ply.sh` 里——
> 以后你改 `QUICKSTART.md` / `video_to_ply.sh`，批量跑自动跟着更新，这个脚本不用动。
> 参数怎么调、产物结构、常见问题，全部同 **`QUICKSTART.md`**，本页只讲「批量」那层。

---

## 输入约定：和单视频完全一样

每个场景 = 一个 `data/<场景名>/` 文件夹，里面放该场景的一个视频。批量就是一串这样的场景：

```
data/
  jeff_0629_iphone1_MID/      场景1: 里面一个视频
    xxx.mp4
  jeff_0629_iphone1_TOP/      场景2
    yyy.mp4
  jeff_0629_iphone1_BOTTOM/   场景3
    zzz.mov
```

产物各自到 `output/<场景名>/`（本地 `scratch/` 算完搬过来）。

---

## 怎么给场景 list（三选一）

### 方式 A：改脚本顶部 `SCENES` 数组（你的习惯）

打开 `scripts/batch_video_to_ply.sh`，编辑顶部数组（一行一个场景名）：

```bash
SCENES=(
  jeff_0629_iphone1_MID
  jeff_0629_iphone1_TOP
  jeff_0629_iphone1_BOTTOM
)
```

然后：

```bash
conda activate gsplat
scripts/batch_video_to_ply.sh
```

### 方式 B：直接传参（每个场景名一个）

```bash
conda activate gsplat
scripts/batch_video_to_ply.sh jeff_0629_iphone1_MID jeff_0629_iphone1_TOP
```

### 方式 C：从文件读（每行一个，`#` 开头是注释）

```bash
conda activate gsplat
scripts/batch_video_to_ply.sh -f scenes.txt
```

> 给的可以是场景名（`jeff_0629_mid`）或路径（`data/jeff_0629_mid/`），脚本会自动归一。

---

## 质量档：环境变量对所有场景一起生效

`video_to_ply.sh` 的档位（`FPS` / `WIDTH` / `MAX_STEPS` / `CAMERA_MODEL`）会原样透传给每个场景：

```bash
MAX_STEPS=30000 CAMERA_MODEL=OPENCV_FISHEYE scripts/batch_video_to_ply.sh
```

> 这是全局统一档。**想让不同场景用不同参数**，就把它们分成几批、各用各的环境变量分别跑
> （薄封装不做逐场景判档；逐场景差异化属于另一种需求，需要再说）。

---

## 断点续跑 & 容错

- **已完成自动跳过**：`output/<场景>/results/ply/` 里已有 `.ply` 的场景默认跳过；想强制重跑用 `FORCE=1`。
- **单个失败不影响其余**：某场景失败（COLMAP 没建出模型 / 没生成 ply）记入「失败」，继续下一个。
- 结束打印 **成功 / 跳过 / 失败** 三类汇总。

```bash
FORCE=1 scripts/batch_video_to_ply.sh           # 全部强制重跑
```

---

## 后台整夜跑（推荐）

```bash
cd /home/tianqi/D/01_Projects/15_3dgs_gsplat
conda activate gsplat        # ← 必须先激活, 否则训练步找不到 gsplat
setsid bash -c 'scripts/batch_video_to_ply.sh' </dev/null \
  > output/batch_$(date +%m%d_%H%M).log 2>&1 &
```

要点（踩过的坑）：
- **`conda activate gsplat`**：必须先激活，否则训练找不到 gsplat。
- **`setsid` + `</dev/null`**：让任务脱离终端跑——否则后台 ffmpeg 会被 `SIGTTIN` 挂起（卡着不动、GPU 0%）。`video_to_ply.sh` 里 ffmpeg 已加 `-nostdin` 双保险。
- 关掉终端不影响，任务继续。

看进度：

```bash
tail -f output/batch_*.log
grep -E ">>> |✓ .* 完成|✗ .* 失败|批量结束" output/batch_*.log | tail -20
```

中途想停：`pkill -9 -f batch_video_to_ply; pkill -9 -f video_to_ply; pkill -9 -f colmap`
（孤儿 colmap 也要杀）。重跑同一命令会跳过已完成的场景、从没跑完的继续。

---

## 产物 / 参数 / 常见问题

全部同 **`QUICKSTART.md`**：

- 每个场景产物结构：`output/<场景名>/{images, database.db, sparse/0, results/ply, results/ckpts}`。
- 改 `FPS` / `WIDTH` / `MAX_STEPS` / `CAMERA_MODEL`、查看 PLY、COLMAP 4.x 参数名坑、首次编译 CUDA 核、OOM
  等，见 `QUICKSTART.md`。
- **指标查看 / 写文章**：见 `QUICKSTART.md` 的「查看指标 / 写文章」。批量跑完直接
  `python scripts/collect_metrics.py` 一次出**所有场景**的 PSNR/SSIM/LPIPS 汇总表（写论文最省事）。
- 单视频流程跑通了，批量就是「把它跑很多遍 + 汇总 + 断点续跑」而已。

> 单独跑某一个场景排查时，直接用单视频脚本：`scripts/video_to_ply.sh <场景名>`。

---

## 另：参数扫描实验

`scripts/ablation_one_tomato.sh` 是对单个场景做参数扫描的独立实验脚本（和本批量封装是两回事，
按需使用）。
