"""视频 → 3DGS PLY 的编排包。

看代码只需三处:
  · pipeline/workflow.py   —— 工作流(每个流程 = 几行步骤)
  · pipeline/steps.py      —— 每步调什么命令(ffmpeg/colmap/gsplat)
  · configs/*.yaml         —— 参数
pipeline/_helpers/ 是辅助(subprocess/磁盘/SfM/指标), 一般不用看。

父进程只 subprocess 编排, 绝不 import torch/gsplat —— 保持极轻。
"""
