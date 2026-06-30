# 多视角视频 → 单个 PLY（顺序匹配版）快速上手

把**同一场景、不同视角**的多个视频合成**一个** 3DGS `.ply`——和 `QUICKSTART_MULTIVIEW.md` 同一目标，
**只是把 COLMAP 匹配从「全配对」换成「顺序匹配 + 回环检测」**，帧数多时快一个量级。

脚本：`scripts/multiview_seq_to_ply.sh`
环境：conda 环境 **`gsplat`**，已装 gsplat + pycolmap，系统有 colmap / ffmpeg，GPU RTX 5080 16GB。
**额外依赖**：vocab tree 文件（已下载到项目根 `vocab_tree_flickr100K_words256K.bin`）。

---

## 和全配对版（`multiview_to_ply.sh`）的区别

| | 全配对版 `multiview_to_ply.sh` | 顺序版 `multiview_seq_to_ply.sh`（本脚本） |
|---|---|---|
| 匹配 | `exhaustive`：每帧配每帧，~O(N²) | `sequential overlap=10` + `loop_detection`（vocab tree） |
| 机位内时序 | 不利用 | **利用**：抽帧带前缀（`top_/mid_/bottom_`），合并库按帧名排序后每个机位连成一段，只配段内相邻帧 |
| 跨机位共视 | 全配对暴力覆盖 | vocab tree 全局检索，把跨机位真正有共视的帧对补上（不依赖时序） |
| 复杂度 | O(N²)，几百帧以上吃小时 | 近线性，几百~几千帧仍是分钟级 |
| 默认档 | 80 帧/视频、7000 步 | 150 帧/视频、15000 步 |

**何时用哪个**：帧数少（`TARGET_PER_VID` ≤ 80、2~3 机位）→ 全配对版最稳；
帧数拉大（200+）或机位多（≥4）→ 本顺序版。

> 原理细节：`sequential` 的「相邻」按图像名排序定义。脚本抽帧成 `bottom_0001.jpg / mid_0001.jpg / top_0001.jpg`，
> 排序后每个机位是一整段，`overlap` 正好吃到「机位内时序」；段与段之间真正的共视，由 `loop_detection`
> 用 vocab tree 全局检索补上。

---

## 输入约定：一个场景 = 一个子文件夹

```
data/
  jeff_0629/            ← 一个场景
    top.mp4
    mid.mp4
    bottom.mp4
  <下一个场景>/         ← 视频数量随意（2 个、4 个都行）
    *.mp4
```

- 文件夹里放这个场景**所有视角**的视频，文件名随意（会用文件名当帧前缀，如 `top_0001.jpg`）。
- 支持 `.mp4 / .MP4 / .mov / .MOV`。

---

## 怎么跑

### 方式 A：改脚本开头两行（你的习惯）

打开 `scripts/multiview_seq_to_ply.sh`，改最上面这两行的默认值：

```bash
IN_DIR="${1:-data/jeff_0629}"   # ← 改成 data/<你的场景名>
OUT_NAME="${2:-jeff_0629}"      # ← 改成 <你的场景名>（输出到 output/<场景名>/）
```

然后：

```bash
conda activate gsplat
scripts/multiview_seq_to_ply.sh
```

### 方式 B：直接传参（不用改脚本）

```bash
conda activate gsplat
scripts/multiview_seq_to_ply.sh data/<场景名> <场景名>
```

> 想和全配对版对比、不互相覆盖：输出名加后缀，如
> `scripts/multiview_seq_to_ply.sh data/jeff_0629 jeff_0629_seq`。

### 后台整夜跑（高质量档耗时长时）

```bash
conda activate gsplat
setsid bash -c 'scripts/multiview_seq_to_ply.sh' </dev/null \
  > output/<场景名>_$(date +%m%d_%H%M).log 2>&1 &
tail -f output/<场景名>_*.log     # Ctrl-C 只退 tail，不停任务
```

---

## 质量 / 速度档（脚本顶部变量，可用环境变量覆盖）

| 变量 | 默认 | 说明 |
|---|---|---|
| `TARGET_PER_VID` | 150 | 每个视频抽多少帧。顺序匹配近线性，可比全配对版抽更密 |
| `SUBCMD` | `default` | 训练算法：`default` / `mcmc`（mcmc 通常质量更好） |
| `STEPS` | 15000 | 训练步数。30000 是高质量常用值 |
| `CAMERA_MODEL` | `OPENCV` | 普通镜头；广角/鱼眼用 `OPENCV_FISHEYE` |
| `SCALE_H` | 720 | 抽帧目标高度（竖屏=长边）；OOM 才降 |
| `OVERLAP` | 10 | **机位内**：每帧配前后多少帧（时序窗口） |
| `LOOP_NUM` | 50 | **跨机位**：每次回环检索取多少候选；机位多/注册率低时调到 80 |
| `VOCAB_TREE` | 项目根的 `vocab_tree_flickr100K_words256K.bin` | vocab tree 路径，一般不用改 |

**高质量**示例：

```bash
TARGET_PER_VID=250 SUBCMD=mcmc STEPS=30000 scripts/multiview_seq_to_ply.sh
```

---

## 跑完怎么看是否成功

脚本会自动打印关键信息：

1. **挑选的 SfM 模型注册数**：`选中: .../sparse/0 (注册 440 / 抽帧 450)`
   —— 注册数接近总抽帧数 = 各视角合到了一起。注册率 < 60% 会有 `⚠` 提示。
2. **各视角注册帧数**：

   ```
   bottom: 150 帧
   mid: 150 帧
   top: 140 帧
   合计注册: 440
   ```
   —— 各前缀都有 = 每个视角都进了同一个模型。**若某视角是 0 帧 / 注册率低**，多半是跨机位
   共视没被检索到：**调大 `LOOP_NUM`（如 80）** 重跑，或退回全配对版 `multiview_to_ply.sh`。
3. 训练末尾的 **PSNR**（越高越好；个位数 = 重建失败）。

成功标志（脚本结尾）：`# ✓ 完成: output/<场景名>/results/ply/point_cloud_<步数-1>.ply`

> 指标查看（PSNR/SSIM/LPIPS 汇总表、loss 曲线、定性对比图）见 `QUICKSTART.md` 的「查看指标 / 写文章」。
> 所有训练脚本已固定 `--lpips_net vgg`（对齐 3DGS）+ 最终步评估。

---

## 产物结构

```
output/<场景名>/
  images/                  各视角合并的抽帧（带前缀）
  database.db              COLMAP 库
  sparse/0/                合并后的完整 SfM 模型（已自动挑选）
  results/ply/             point_cloud_<步数-1>.ply   ← 最终结果
  results/ckpts/           ckpt_*.pt
```

查看 PLY：拖进 https://superspl.at/editor ，或

```bash
python gsplat/examples/simple_viewer.py --ckpt output/<场景名>/results/ckpts/ckpt_<步数-1>_rank0.pt
```

---

## 注意 / 常见问题

| 现象 | 原因 / 解决 |
|------|------|
| 启动即报「找不到 vocab tree」 | 顺序匹配的跨机位回环检测需要它。按提示 `wget` 下载到项目根；或 `VOCAB_TREE=/路径/xxx.bin` 指过去 |
| 某视角注册 0 帧 / 注册率低 | 跨机位共视没被检索到。先调大 `LOOP_NUM`（80）；仍不行说明该视角与其它视角重叠太少，补拍重叠区，或退回全配对版 |
| 整体注册图像很少、PSNR 个位数 | 多半 COLMAP 失败：确认 `WORK_ROOT` 是本地 ext4（脚本会拦 FUSE 盘）、相机模型选对 |
| 顺序版反而比全配对慢 | 帧数太少（≤几百）时全配对本来就快，顺序版的检索开销不划算——这种规模直接用 `multiview_to_ply.sh` |
| 训练卡很久没动 | 首次 `import gsplat` 编译 CUDA 核，约 10~20 分钟，只编一次 |
| 显存 OOM | 调小 `TARGET_PER_VID`，或 `SCALE_H` 降到 540 |

> COLMAP / 训练全程在本地 `scratch/`（ext4），完成后整体搬到 `output/`。原因：`output/` 在 16TB FUSE 盘上，
> COLMAP mapper 在 FUSE 上三角化会失败。详见 `QUICKSTART_BATCH.md` 的「本地工作盘 scratch/」。
