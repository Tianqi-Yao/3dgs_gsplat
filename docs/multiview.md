# 多机位 → 合成一个 PLY

把**同一场景、不同机位**的多个视频合成**一个** 3DGS `.ply`。各视频抽帧到一起 → COLMAP 注册到同一坐标系 → 一次训练。

## 输入

一个场景 = `data/<场景名>/` 文件夹，里面放该场景**所有机位**的视频（文件名即机位名，用作帧前缀）。

## 跑

编辑 `configs/multiview.yaml`（重点选 `matcher`），然后：

```bash
conda activate gsplat
python -m pipeline multiview --config configs/multiview.yaml
python -m pipeline multiview --config configs/multiview.yaml -n   # 干跑
```

跑完脚本打印**各视角注册帧数**（每个机位都有、接近抽帧数 = 合到了一起；某个 0 帧 = 没合上）。

## 选哪个 matcher

| matcher | 原理 | 适用 |
|---|---|---|
| **exhaustive** | 全配对，每帧配每帧 ~O(N²) | 帧数少（≤几百）、最稳的默认 |
| **seq** | 顺序匹配 + 回环检测（vocab tree 全局检索跨机位共视） | 帧数多（几百~几千）、通用加速；需 `vocab_tree_*.bin` |
| **pairs** | 只配 机位内相邻 + 机位间序号窗口（不依赖同步） | 采集规整、相邻机位重叠大 |
| **rig** | 刚体 rig 约束（`rig_configurator` 推平均外参 + BA） | 机位刚性固定在同一支架；**实验性** |

`matcher_opts` 里各 matcher 的旋钮（只有选中的那组生效）：
- `seq`: `overlap`(机位内窗口) / `loop_num`(跨机位检索候选，机位多调大) / `vocab_tree`
- `pairs`: `intra_overlap`(机位内) / `inter_window`(机位间序号窗口 ±，吸收不同步漂移)
- `rig`: `ba_refine`(rig 配好后再全局 BA)

## 参数（`params:`）

`target_per_vid`(每视频目标抽帧数，按时长自动算 fps) / `scale_h`(抽帧高度) / `max_steps`(默认 15000) / `strategy` / `sh_degree` / `ssim_lambda` / `camera_model`。训练参数含义见 [grid.md](grid.md)。

## 常见问题

| 现象 | 解决 |
|---|---|
| 某机位注册 0 帧 / 注册率低 | 跨机位没合上：`seq` 调大 `loop_num`；`pairs` 调大 `inter_window`；或补拍重叠区、退回 `exhaustive` |
| seq 报找不到 vocab tree | 下载到项目根：`wget -O vocab_tree_flickr100K_words256K.bin https://demuc.de/colmap/vocab_tree_flickr100K_words256K.bin` |
| rig `rig 数=0`/异常 | rig 按「同序号=同 frame」分组，依赖同步；不严格同步时先用 `pairs` |
| 整体注册很少、PSNR 个位数 | 确认 `work_root` 本地 ext4、相机模型选对 |

指标查看同 [grid.md](grid.md) 的「查看指标」。
