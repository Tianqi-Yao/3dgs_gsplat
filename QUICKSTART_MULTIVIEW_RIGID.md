# 多视角合成（规整/刚性采集进阶）快速上手

当你的多机位采集**很规整**——机位排在同一垂直线、相邻机位重叠大、且装在**同一支架上刚性固定**——
就不必再让 COLMAP 盲搜匹配。本页两种跑法专门吃这种先验：

- **方法一 · 自定义匹配对**（`scripts/multiview_pairs_to_ply.sh`）—— **推荐、稳**。
- **方法二 · 刚体 rig 约束**（`scripts/multiview_rig_to_ply.sh`）—— **实验性、可能更好**。

> 和已有两种 multiview 的关系：
> - `multiview_to_ply.sh`（exhaustive 全配对）：帧数少、最稳的兜底。
> - `multiview_seq_to_ply.sh`（sequential + vocab tree）：帧数多、无规整先验时的通用加速。
> - **本页两种**：有「规整 + 刚性」先验时的更优解。
>
> 建议拿同一场景把**方法一**和**方法二**各跑一遍做 A/B（见文末），谁的 PSNR / 注册率高用谁。

环境：conda 环境 **`gsplat`**，已装 gsplat + pycolmap，系统有 colmap(4.1) / ffmpeg，GPU RTX 5080 16GB。

---

## 输入约定：一个场景 = 一个子文件夹（两种跑法都一样）

```
data/
  jeff_0629/
    top.mp4
    mid.mp4
    bottom.mp4
```

- 文件夹里放该场景**所有机位**的视频，文件名即机位名（会用作帧前缀/子文件夹名）。
- 支持 `.mp4 / .MP4 / .mov / .MOV`。
- 两脚本内部的抽帧命名不同（pairs 用 `images/top_0001.jpg`，rig 用 `images/top/0001.jpg`），**但你的输入摆放完全一致**，不用管。

---

# 方法一：自定义匹配对（推荐）

**原理**：你知道「谁该和谁配」，就直接生成匹配对列表喂给 COLMAP，不用 vocab tree 盲搜。
- **机位内**：只配相邻帧（`INTRA_OVERLAP`，吃时序）。
- **机位间**：按帧**序号窗口**配对——`top_i` 配 `mid_{i-w … i+w}`——窗口 `w`（`INTER_WINDOW`）
  **吸收你「不严格同步」的剪辑漂移**（开头齐、越往后越可能差几帧）。
- 跨机位用 `colmap matches_importer --match_type pairs`，复杂度近线性。

## 怎么跑

```bash
conda activate gsplat
# 方式A: 改脚本开头 IN_DIR/OUT_NAME 两行默认值后直接跑
scripts/multiview_pairs_to_ply.sh
# 方式B: 传参
scripts/multiview_pairs_to_ply.sh data/jeff_0629 jeff_0629
```

后台整夜跑：

```bash
setsid bash -c 'scripts/multiview_pairs_to_ply.sh' </dev/null \
  > output/jeff_0629_pairs_$(date +%m%d_%H%M).log 2>&1 &
```

## 关键参数（环境变量可覆盖）

| 变量 | 默认 | 说明 |
|---|---|---|
| `INTRA_OVERLAP` | 10 | 机位内：每帧配后面多少帧 |
| `INTER_WINDOW` | 15 | 机位间：序号窗口 ±w。**注册率低先调大这个**（如 30） |
| `TARGET_PER_VID` / `SUBCMD` / `STEPS` / `SCALE_H` / `CAMERA_MODEL` | 150 / default / 15000 / 720 / OPENCV | 同 multiview 系列 |

---

# 方法二：刚体 rig 约束（实验性）

**原理**：三机位刚性固定 = 一个刚体 rig，相对外参全程不变。把这个约束告诉 COLMAP，
三机位**天生同坐标系、同尺度**，一处注册带动其余、更抗漂移。

流程（脚本已封装）：抽帧到子文件夹 → `single_camera_per_folder` 每机位独立 camera →
全配对 + 普通建图 → `rig_configurator` **从初始重建自动推算平均外参** → 可选全局 BA refine → 训练。

**⚠ 前提与局限（务必知道）**：
1. COLMAP 的 rig 按 **frame（同步快照）** 工作：**同序号跨机位**的帧被当成「同一时刻」组成一个 frame。
   你不严格同步，frame 分组只是近似，误差靠 BA 的 `ba_refine_sensor_from_rig`（默认开）吸收——
   所以**开头剪齐、各段时长/帧率尽量接近**会让它更准。
2. 这是 COLMAP 4.1 较新功能 + gsplat 要读多 camera/子文件夹，属实验路线，可能需按实际输出微调。

## 怎么跑

```bash
conda activate gsplat
scripts/multiview_rig_to_ply.sh data/jeff_0629 jeff_0629
```

## 关键参数

| 变量 | 默认 | 说明 |
|---|---|---|
| `BA_REFINE` | 1 | rig 配好后再做一次全局 BA refine；想看纯 rig_configurator 结果设 0 |
| `TARGET_PER_VID` / `SUBCMD` / `STEPS` / `SCALE_H` / `CAMERA_MODEL` | 同上 | |

脚本结尾会打印 `rig 数 / frame 数`，正常应是 1 个 rig、frame 数≈最长机位的帧数。

---

## 跑完怎么看是否成功（两种通用）

1. **各视角/各机位注册帧数**：每个前缀都有、数量接近抽帧数 = 合到了一起；某个为 0 = 没合上。
   - 方法一没合上：调大 `INTER_WINDOW`。
   - 方法二没合上：多半是 frame 分组（同步）太差，先用方法一。
2. 训练末尾 **PSNR**（越高越好；个位数 = 失败）。
3. 成功标志：`output/<场景名>/results/ply/point_cloud_<步数-1>.ply`。

> 指标查看（PSNR/SSIM/LPIPS 汇总表、loss 曲线、定性对比图）见 `QUICKSTART.md` 的「查看指标 / 写文章」。
> 跑 A/B 对比时尤其有用：`python scripts/collect_metrics.py` 一次列出 pairs 版和 rig 版的 PSNR/SSIM/LPIPS。
> 所有训练脚本已固定 `--lpips_net vgg`（对齐 3DGS）+ 最终步评估。

## 产物结构

和其它 multiview 一致：`output/<场景名>/{images, database.db, sparse/0, results/ply, results/ckpts}`
（方法一另有 `pairs.txt`；方法二另有 `rig.json` 和 `sparse_init/ sparse_rig/`）。
查看 PLY：拖进 https://superspl.at/editor 。

---

## A/B 对比（推荐做一次，定下你这套采集长期用哪个）

同一场景、不同输出名各跑一遍，比 PSNR 和注册率：

```bash
conda activate gsplat
scripts/multiview_pairs_to_ply.sh data/jeff_0629 jeff_0629_pairs
scripts/multiview_rig_to_ply.sh   data/jeff_0629 jeff_0629_rig
# 比注册数 / 重投影误差
colmap model_analyzer --path output/jeff_0629_pairs/sparse/0
colmap model_analyzer --path output/jeff_0629_rig/sparse/0
# PSNR 看各自训练日志末尾
```

经验预期：**不严格同步**时方法一通常更稳；若你后续改善了同步（开头对得很齐、各段等长），
方法二（rig）的几何一致性优势会显现。

---

## 常见问题

| 现象 | 原因 / 解决 |
|------|------|
| 方法一某机位注册 0 / 注册率低 | 跨机位窗口太窄。调大 `INTER_WINDOW`（如 30）；仍不行说明该机位重叠太少 |
| 方法二 `rig 数=0` 或 frame 数异常 | rig_configurator 没正确分组：确认各机位子文件夹里同序号文件大致对应同一时刻；同步太差就用方法一 |
| 方法二训练报找不到图像/读不出多 camera | gsplat 读子文件夹+多 camera 的兼容问题，把日志发我调；或先用方法一 |
| 注册图像很少、PSNR 个位数 | 多半 COLMAP 失败：确认 `WORK_ROOT` 是本地 ext4（脚本会拦 FUSE）、相机模型选对 |
| 训练卡很久没动 | 首次编译 CUDA 核，约 10~20 分钟，只编一次 |
| 显存 OOM | 调小 `TARGET_PER_VID` 或 `SCALE_H` 降到 540 |

> COLMAP / 训练全程在本地 `scratch/`（ext4），完成后整体搬到 `output/`。详见 `QUICKSTART_BATCH.md`。
