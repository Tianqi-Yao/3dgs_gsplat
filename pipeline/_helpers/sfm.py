"""COLMAP/SfM 辅助: 挑 sparse/0、生成匹配对、rig 配置、各视角统计。

pycolmap 都在函数内 lazy import —— import 本模块不触发它。
"""
from __future__ import annotations

import collections
import json
import shutil
from pathlib import Path


def pick_sparse0(sparse_dir) -> Path:
    """挑注册图像最多的子模型设为 sparse/0。"""
    import pycolmap
    sparse = Path(sparse_dir)
    subs = [d for d in sorted(sparse.iterdir())
            if d.is_dir() and (d / "cameras.bin").exists()]
    if not subs:
        raise RuntimeError("COLMAP 未建出有效模型")
    n = lambda d: len(pycolmap.Reconstruction(str(d)).images)
    best = max(subs, key=n)
    print(f"选中 {best} (注册 {n(best)} / 子模型 {len(subs)} 个)")
    if best.name != "0":
        tmp = sparse / "__best"
        best.rename(tmp)
        for d in sparse.iterdir():
            if d.name.isdigit():
                shutil.rmtree(d)
        tmp.rename(sparse / "0")
    return best


def gen_pairs(images_dir, intra_overlap, inter_window, out_path) -> int:
    """自定义匹配对: 机位内相邻(overlap) + 机位间序号窗口(±window)。写 pairs.txt。

    帧名约定 <前缀>_NNNN.jpg; 前缀=机位。返回对数。
    """
    images_dir = Path(images_dir)
    groups: dict[str, dict[int, str]] = collections.defaultdict(dict)
    for f in images_dir.iterdir():
        if f.suffix.lower() != ".jpg" or "_" not in f.stem:
            continue
        stem, num = f.name.rsplit("_", 1)
        groups[stem][int(num.split(".")[0])] = f.name

    pairs: set[tuple[str, str]] = set()
    def add(a, b):
        pairs.add((a, b) if a < b else (b, a))

    for d in groups.values():                       # 机位内: 相邻 overlap 帧
        idxs = sorted(d)
        for k, i in enumerate(idxs):
            for j in idxs[k + 1:k + 1 + intra_overlap]:
                add(d[i], d[j])
    prefixes = sorted(groups)                        # 机位间: 序号 ±window
    for a in range(len(prefixes)):
        for b in range(a + 1, len(prefixes)):
            da, db = groups[prefixes[a]], groups[prefixes[b]]
            for i, na in da.items():
                for j in range(i - inter_window, i + inter_window + 1):
                    if j in db:
                        add(na, db[j])

    Path(out_path).write_text("".join(f"{x} {y}\n" for x, y in sorted(pairs)))
    print(f"生成匹配对: {len(pairs)} (机位 {prefixes})")
    return len(pairs)


def write_rig_config(images_dir, out_path) -> list[str]:
    """每个机位子文件夹一个 sensor, 第一个作参考。写 rig.json。"""
    images_dir = Path(images_dir)
    subs = sorted(d.name for d in images_dir.iterdir() if d.is_dir())
    cams = []
    for i, s in enumerate(subs):
        c = {"image_prefix": f"{s}/"}
        if i == 0:
            c["ref_sensor"] = True
        cams.append(c)
    Path(out_path).write_text(json.dumps([{"cameras": cams}], indent=2))
    print(f"rig sensors: {subs}  参考: {subs[0]}")
    return subs


def per_view_report(sparse0_dir, rig=False) -> dict:
    """统计 sparse/0 里各视角(前缀 / rig 子文件夹)注册了多少帧。"""
    import pycolmap
    rec = pycolmap.Reconstruction(str(sparse0_dir))
    key = (lambda n: n.split("/")[0]) if rig else (lambda n: n.rsplit("_", 1)[0])
    c = collections.Counter(key(img.name) for img in rec.images.values())
    for k in sorted(c):
        print(f"  {k}: {c[k]} 帧")
    print(f"  合计注册: {len(rec.images)}")
    return dict(c)
