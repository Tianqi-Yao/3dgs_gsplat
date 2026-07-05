# 网格搜索(两层) + COLMAP 快扫 + 训练参数速查

pipeline 的 grid 是**两层**,配置在 `configs/grid.yaml`:

- **第一层 `colmap`**:抽帧 + COLMAP(改了要**重跑**)。维度 `matcher / camera_model / scale_h / target_per_vid`。
- **第二层 `train`**:复用每个 COLMAP base 只重训练。任意训练参数(`strategy / app_opt / ...`)。
- `base_scenes`:一组 `data/<场景>/` 里的视频(可室内+室外对照)。grid 假设**单视频场景**(取第一个视频)。

`out_dir = output/_grid/`,组合名含所有维度,`metrics` 出表能一眼对比。

---

## 先诊断:重建成不成(COLMAP 快扫)

**某场景效果差(尤其户外/近景)时,先别调训练参数** —— 很可能是 COLMAP 重建就失败了(图没注册上)。
训练再怎么调也救不了没重建出来的几何。用 `--colmap-only` **只跑 COLMAP、不训练、看注册率**(纯 CPU,快):

```bash
conda activate gsplat
python -m pipeline grid -c configs/grid.yaml --colmap-only
```

输出一张**按注册率排序**的表:

```
| 配置 | 注册/帧 | 注册率 | 点数 | 重投影px | 相机 | k1 | 畸变OK |
```

**判读**:
- **注册率接近 100%** + **畸变OK**(`k1` 收敛,`|k1|<1`) = 重建好,可以去训练。
- **注册率很低**(如 `2/283`=0.7%) = **重建失败**,`k1` 常发散(如 4.99)。训练救不了,得先修 COLMAP。

**扫哪些 COLMAP 维度救**(`configs/grid.yaml` 的 `colmap` 段):

| 维度 | 取值 | 作用 |
|---|---|---|
| `matcher` | `sequential`(只配相邻,快但弱) / `exhaustive`(全配对,救断链) / `seq`(顺序+回环 vocab tree) | 相邻帧匹配退化时,exhaustive/seq 补跨帧约束 |
| `camera_model` | `OPENCV`(8参,广角易发散) / `RADIAL`(2参) / `SIMPLE_RADIAL`(1参,最稳) | 少参数防畸变自估发散 |
| `target_per_vid` | 如 `[300, 800]` | 帧密度。fps 被 clamp 到下限时相邻帧间隔大、重叠不足 |
| `scale_h` | `[720, 1080]` | 分辨率;更高 → 更多/更稳的特征 |

**三种结果 → 下一步**:
1. 某配置注册率上来了 → **室外能救**。把 `colmap` 固定成那个组合、填 `train` 参数,**去掉 `--colmap-only`** 再跑(见下)。
2. 有改善但不够 → 加更多维度(更密帧 / 更高分辨率 / RADIAL)。
3. 全都很低 → COLMAP 参数救不了,瓶颈在**采集**(动态/运动模糊/视差不足),得改采集,不是调参数。

> 快速看单个 base 的质量,不跑 grid:`pipeline/_helpers/sfm.py::colmap_report(sparse0_dir, n_frames)` 直接读 `pycolmap`。

---

## 实战经验:室内清晰、室外糊的真相

**"室外模糊"经常不是训练/模糊,而是 COLMAP 注册失败。** 实测 `sanbore_corn_mid`(玉米近景):
`sequential + OPENCV` 只注册 **2/283** 张、`k1` 发散到 4.99、mcmc 只长出 448 个高斯(室内 9 万+)、PSNR 10~13。
对比室内 `farmNG_v1_mid`:150/150 全注册、`k1≈0`、PSNR 36。
原因:近景玉米的**重复纹理(叶片) + 动态(风吹晃) + 运动模糊** 让相邻帧匹配退化 → mapper 增量重建断链。
→ 先用 `--colmap-only` 扫 `matcher` × 相机模型 × **帧密度**看注册率。

**结局(实测确诊)**:`exhaustive`(最强全配对)和 `SIMPLE_RADIAL`(畸变收敛)都**没救**室外(还是 2~3/300)——
排除了 matcher 和相机模型。但**加密帧救活了**:`target 300→1500`(fps 2→10)后 `sequential` 注册
**100%(1500/1500)**、点 13 万、畸变收敛、重投影 0.5px。
**根因是 `fps` 被 clamp 到 2、帧太稀**:车沿行前进 + 近景,相邻帧共视窗口窄,帧一稀就断链。
**教训:轨迹型 / 近景户外要抽密帧(`target_per_vid ≥ 1500`,即 fps ≥ 10),别用默认稀帧。**
(注册率若在密帧下仍上不去,才是采集问题:车速太快 / 视差不足 → 相机侧拍、车慢、退远一点。)

---

## 完整两层网格(训练)

重建 OK 后(或想扫训练参数),把 `colmap` 固定成好的组合,`train` 段列要扫的训练参数:

```yaml
base_scenes: [lab, sanbore_corn_mid]
steps: 7000
colmap:
  matcher: [exhaustive]         # 固定成快扫选出的最优
  camera_model: [SIMPLE_RADIAL]
  target_per_vid: [300]
  scale_h: [720]
train:                          # 任意训练参数 → 取值列表, 笛卡尔积
  strategy: [default, mcmc]
  app_opt: [true, false]
  pose_opt: [true, false]
```

```bash
python -m pipeline grid -c configs/grid.yaml            # base_scenes × colmap × train
python -m pipeline metrics output/_grid --csv grid.csv  # 出对比表选最优
```

**分阶段**(避免笛卡尔积爆炸):先 `train` 只放 3~4 个主流开关(strategy/app_opt/pose_opt)看大方向,
再围绕最优加冷门维度(`patch_size`/`app_embed_dim`/`init_scale`/`grow_grad2d`...)。

---

## 训练参数速查

`train` 段可放的键(默认=gsplat 默认,不放的不动;`pipeline/steps.py::_override_args` 拼命令):

| 参数 | 作用 | 治哪个病 |
|---|---|---|
| `strategy` | `default` / `mcmc`(更稳,可控高斯上限 `cap_max`) | 近景细节密度 |
| `sh_degree` | 球谐阶数(颜色/高光 ↔ 显存) | |
| `ssim_lambda` | SSIM 损失权重(结构 ↔ 像素) | |
| `cap_max`(仅 mcmc) | 高斯数上限 | 近景细节 / 显存 OOM |
| `app_opt`(+`app_embed_dim`) | 每图外观嵌入 | **户外光照/曝光/影子变化** |
| `pose_opt` | 相机位姿优化 | **车颠簸/位姿漂移** |
| `antialiased` | 抗锯齿 | 走样 |
| `patch_size` | 训练随机裁剪 | 强制学局部细节 |
| `post_processing: bilateral_grid` | 曝光后处理 | 户外曝光波动 |
| `init_scale` / `opacity_reg` / `grow_grad2d` | 初始化 / 正则 / 密集化 | 细化 |

> `lpips_net` 固定 `alex`(本机 `vgg` 会让评估崩溃、无指标) + `eval_steps=max_steps`(保证最终步评估)。
> `data_factor` 固定 1 —— **分辨率靠 `colmap.scale_h`(抽帧),不是 data_factor**。
> 动态物体(风吹叶片)是 3DGS 硬伤,gsplat 无 robust loss/自动 mask,只能靠采集端(无风、快门快、车慢)。

---

## 查看指标 / 写文章

指标在 `output/_grid/<组合>/results/`:
- `stats/val_step*.json` —— **PSNR / SSIM / LPIPS**(1/8 held-out 测试视图)、高斯数、耗时。
- `tb/` —— TensorBoard 曲线(`train/loss`、`val/psnr`…);**loss 只在这里**。
- `renders/val_step*_*.png` —— 左 GT 右渲染的定性对比图。

```bash
python -m pipeline metrics output/_grid --csv grid.csv   # markdown 表 + csv
tensorboard --logdir output --port 6006                  # 曲线
```

> 注册率极低时 PSNR 也可能不低(背景/远景拉高),所以**户外先看注册率(`--colmap-only`),别只看 PSNR**。
