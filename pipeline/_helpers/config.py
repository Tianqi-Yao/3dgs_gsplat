"""配置 schema(dataclass) + 从 YAML 加载。用户日常改 configs/*.yaml, 一般不改这里。"""
from __future__ import annotations

from dataclasses import dataclass, field, fields
from pathlib import Path

import yaml


# ── 单视频 / 批量 / 网格 ────────────────────────────────────────────────────
@dataclass
class Params:
    fps: float = 5
    width: int = 1920
    max_steps: int = 7000
    camera_model: str = "OPENCV"       # 广角鱼眼用 OPENCV_FISHEYE
    sh_degree: int = 3
    ssim_lambda: float = 0.2
    strategy: str = "default"          # default / mcmc
    cap_max: int = 1_000_000           # 仅 mcmc


@dataclass
class RunConfig:                       # single / batch
    scenes: list
    work_root: str = "scratch"
    out_root: str = "output"
    params: Params = field(default_factory=Params)


@dataclass
class GridConfig:                      # grid
    base_scene: str = "lab"
    work_root: str = "scratch"
    out_root: str = "output"
    steps: int = 7000
    camera_model: str = "OPENCV"
    strategy: list = field(default_factory=lambda: ["default", "mcmc"])
    sh_degree: list = field(default_factory=lambda: [1, 2, 3])
    ssim_lambda: list = field(default_factory=lambda: [0.2, 0.05])
    cap_max: list = field(default_factory=lambda: [300_000, 1_000_000])

    @property
    def out_dir(self) -> str:
        return f"{self.out_root}/_grid_{self.base_scene}"


# ── 多机位 ──────────────────────────────────────────────────────────────────
@dataclass
class MVParams:
    target_per_vid: int = 150          # 每视频目标抽帧数(按时长动态算 fps)
    scale_h: int = 720                 # 抽帧目标高度
    max_steps: int = 15000
    camera_model: str = "OPENCV"
    strategy: str = "default"
    sh_degree: int = 3
    ssim_lambda: float = 0.2
    cap_max: int = 1_000_000
    fps_min: float = 2
    fps_max: float = 15


@dataclass
class MultiviewConfig:
    scenes: list
    matcher: str = "exhaustive"        # exhaustive / seq / pairs / rig
    work_root: str = "scratch"
    out_root: str = "output"
    params: MVParams = field(default_factory=MVParams)
    matcher_opts: dict = field(default_factory=dict)   # {seq:{...}, pairs:{...}, rig:{...}}


# ── 加载 ────────────────────────────────────────────────────────────────────
def _filter(cls, d):
    known = {f.name for f in fields(cls)}
    unknown = set(d) - known
    if unknown:
        raise ValueError(f"{cls.__name__} 不认识的配置项: {sorted(unknown)}; 可用: {sorted(known)}")
    return {k: v for k, v in d.items() if k in known}


def load_run(path) -> RunConfig:
    d = yaml.safe_load(Path(path).read_text()) or {}
    p = Params(**_filter(Params, d.pop("params", {}) or {}))
    return RunConfig(**_filter(RunConfig, d), params=p)


def load_grid(path) -> GridConfig:
    d = yaml.safe_load(Path(path).read_text()) or {}
    grid = d.pop("grid", {}) or {}
    return GridConfig(**_filter(GridConfig, {**d, **grid}))


def load_multiview(path) -> MultiviewConfig:
    d = yaml.safe_load(Path(path).read_text()) or {}
    p = MVParams(**_filter(MVParams, d.pop("params", {}) or {}))
    return MultiviewConfig(**_filter(MultiviewConfig, d), params=p)
