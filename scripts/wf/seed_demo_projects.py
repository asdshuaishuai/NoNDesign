#!/usr/bin/env python3
"""把两个「复杂 demo 项目」写进工作台的真实项目库（可直接在工作台打开）。

用法：
    python3 scripts/wf/seed_demo_projects.py            # 写入
    python3 scripts/wf/seed_demo_projects.py --remove   # 删除

产物（桌面项目根 = ~/Documents/NoNDesign）：
  portfolio/video3d/night-orbit-demo/{scene3d.json,screenplay3d.json}
      12 节点（含旋转/父子位姿）/ 4 灯 / 2 相机 / 4 镜头（含两段相机运动）
  portfolio/video_short/neon-clash-demo/{screenplay.json,style.json}
      3 镜头 / 150 帧 / 15 事件（10 个 VFX，覆盖火/冰/闪电/爆炸/风土）/ 风格包 neon_night

两份都由仓库硬门（verifyVideo3d / verifyVideoScreenplay / verifyVideoStylePack）校验通过：
  [verify-3d]    verified=true nodes=12 lights=4 cameras=2 shots=4 checks=0
  [verify-short] verified=true shots=3 frames=150 events=15 vfx=10 style=neon_night
"""
import argparse
import json
import os
import shutil

HOME = os.path.expanduser("~")
ROOT = f"{HOME}/Documents/NoNDesign/portfolio"
VIDEO3D = f"{ROOT}/video3d/night-orbit-demo"
SHORT = f"{ROOT}/video_short/neon-clash-demo"


def write(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(obj, handle, ensure_ascii=False, indent=2)
        handle.write("\n")
    print("wrote", path, os.path.getsize(path), "B")


def scene3d():
    return {
        "v": 1,
        "units": "m",
        "environment": {"background": "#0b1020"},
        "nodes": [
            {"id": "floor", "type": "box", "size": [14, 0.2, 14], "position": [0, -0.1, 0],
             "material": {"color": "#1b2436", "roughness": 0.9, "metalness": 0.0}},
            {"id": "backdrop", "type": "plane", "size": [14, 8, 0.1], "position": [0, 4, -7],
             "material": {"color": "#111a2c", "roughness": 1.0, "metalness": 0.0}},
            {"id": "plinth", "type": "cylinder", "size": [2.2, 3.0, 0.6], "position": [0, 0.3, 0],
             "material": {"color": "#2a3550", "roughness": 0.6, "metalness": 0.2}},
            {"id": "core", "type": "sphere", "size": [1.1, 1, 1], "position": [0, 2.1, 0],
             "material": {"color": "#ffb347", "roughness": 0.25, "metalness": 0.6}},
            {"id": "ring", "type": "cylinder", "size": [2.4, 2.4, 0.12], "position": [0, 2.1, 0],
             "rotation": [28, 0, 18], "material": {"color": "#7ad7ff", "roughness": 0.2, "metalness": 0.8}},
            {"id": "p1", "type": "box", "size": [0.55, 3.6, 0.55], "position": [-4.6, 1.8, -3.2],
             "rotation": [0, 24, 0], "material": {"color": "#31405e", "roughness": 0.7}},
            {"id": "p2", "type": "box", "size": [0.55, 3.6, 0.55], "position": [4.6, 1.8, -3.2],
             "rotation": [0, -24, 0], "material": {"color": "#31405e", "roughness": 0.7}},
            {"id": "p3", "type": "box", "size": [0.55, 2.4, 0.55], "position": [-4.2, 1.2, 3.4],
             "rotation": [0, -18, 0], "material": {"color": "#26324a", "roughness": 0.75}},
            {"id": "p4", "type": "box", "size": [0.55, 2.4, 0.55], "position": [4.2, 1.2, 3.4],
             "rotation": [0, 18, 0], "material": {"color": "#26324a", "roughness": 0.75}},
            {"id": "satellite", "type": "sphere", "size": [0.42, 1, 1], "position": [2.6, 2.6, 1.6],
             "material": {"color": "#9ef0c8", "roughness": 0.3, "metalness": 0.4}},
            {"id": "orbit", "type": "cylinder", "size": [0.08, 0.08, 3.2], "position": [0, 2.1, 0],
             "rotation": [0, 0, 90], "material": {"color": "#3d4c6b", "roughness": 0.5}},
            {"id": "cap", "type": "box", "size": [1.6, 0.18, 1.6], "position": [0, 4.35, 0],
             "rotation": [0, 45, 0], "material": {"color": "#ff7a59", "roughness": 0.5, "metalness": 0.3}},
        ],
        "lights": [
            {"id": "key", "type": "directional", "intensity": 1.5, "color": "#ffffff",
             "position": [5, 8, 4], "target": [0, 1.5, 0]},
            {"id": "rim", "type": "point", "intensity": 2.4, "color": "#7ad7ff", "position": [-3.5, 3.2, -2.5]},
            {"id": "warm", "type": "point", "intensity": 1.6, "color": "#ffb347", "position": [3.2, 1.8, 2.8]},
            {"id": "fill", "type": "ambient", "intensity": 0.35, "color": "#22304d"},
        ],
        "cameras": [
            {"id": "hero", "position": [6.5, 3.4, 7.5], "target": [0, 2.0, 0], "fov": 42},
            {"id": "close", "position": [2.2, 2.6, 3.0], "target": [0, 2.1, 0], "fov": 50},
        ],
    }


def screenplay3d():
    return {
        "v": 1, "fps": 30,
        "format": {"width": 1280, "height": 720},
        "shots": [
            {"id": "establish", "duration": 3.0, "camera": {"id": "hero"},
             "cues": [{"f": 0, "type": "caption", "text": "夜航 · 01"}]},
            {"id": "orbit", "duration": 3.5,
             "camera": {"move": {"from": [6.5, 3.4, 7.5], "to": [-5.5, 2.6, 6.0],
                                 "target": [0, 2.1, 0], "easing": "easeInOut"}},
             "cues": [{"f": 20, "type": "caption", "text": "环绕"}]},
            {"id": "detail", "duration": 2.5, "camera": {"id": "close"},
             "cues": [{"f": 10, "type": "caption", "text": "核心"}]},
            {"id": "reveal", "duration": 3.0,
             "camera": {"move": {"from": [2.2, 2.6, 3.0], "to": [0, 5.2, 9.5],
                                 "target": [0, 2.2, 0], "easing": "linear"}},
             "cues": [{"f": 60, "type": "caption", "text": "全景"}]},
        ],
    }


def short_screenplay():
    return {
        "schema": "nan.screenplay/1",
        "width": 320, "height": 180,
        "shots": [
            {"id": "open", "start": 0.0, "duration": 1.5, "events": [
                {"f": 0, "type": "caption"},
                {"f": 8, "type": "vfx", "cue": "fire.campfire", "x": 0, "y": 6, "seed": 11, "layer": "back"},
                {"f": 18, "type": "vfx", "cue": "ice.frost-breath", "x": -40, "y": 0, "seed": 21},
                {"f": 28, "type": "sfx"},
                {"f": 38, "type": "vfx", "cue": "fire.fireball", "x": 34, "y": -8, "seed": 31, "scale": 1.3},
            ]},
            {"id": "clash", "start": 1.5, "duration": 2.0, "events": [
                {"f": 0, "type": "vfx", "cue": "lightning.lightning-strike", "x": 10, "y": -6, "seed": 41},
                {"f": 6, "type": "camera.shake"},
                {"f": 12, "type": "vfx", "cue": "explosions.big-explosion", "x": 0, "y": -14,
                 "seed": 51, "scale": 1.4, "layer": "front"},
                {"f": 20, "type": "vfx", "cue": "lightning.spark-arc", "x": -28, "y": 2, "seed": 61},
                {"f": 30, "type": "sfx"},
                {"f": 40, "type": "vfx", "cue": "explosions.small-explosion", "x": 36, "y": 4, "seed": 71},
            ]},
            {"id": "after", "start": 3.5, "duration": 1.5, "events": [
                {"f": 0, "type": "vfx", "cue": "ice.ice-shatter", "x": -18, "y": 0, "seed": 81},
                {"f": 8, "type": "vfx", "cue": "nature.earth-spike", "x": 18, "y": 6, "seed": 91},
                {"f": 16, "type": "caption"},
                {"f": 30, "type": "vfx", "cue": "fire.flame-pillar", "x": 0, "y": 0,
                 "seed": 101, "scale": 1.2},
            ]},
        ],
    }


def short_style():
    return {
        "schema": "nan.style_pack/1",
        "id": "neon_night",
        "palette": {"background": "#070a14", "band": "#101a30",
                    "accent": "#59f2ff", "text": "#f4faff"},
        "typography": {"caption": "lg"},
        "motion": {"progress": "ease_out"},
        "vfxAllowlist": [
            "fire.campfire", "fire.fireball", "fire.flame-pillar",
            "ice.frost-breath", "ice.ice-shatter",
            "lightning.lightning-strike", "lightning.spark-arc",
            "explosions.small-explosion", "explosions.big-explosion",
            "nature.earth-spike",
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--remove", action="store_true", help="删除两个 demo 项目")
    args = parser.parse_args()
    if args.remove:
        for path in (VIDEO3D, SHORT):
            if os.path.isdir(path):
                shutil.rmtree(path)
                print("removed", path)
        return
    write(f"{VIDEO3D}/scene3d.json", scene3d())
    write(f"{VIDEO3D}/screenplay3d.json", screenplay3d())
    write(f"{SHORT}/screenplay.json", short_screenplay())
    write(f"{SHORT}/style.json", short_style())
    print("\n打开方式：")
    print("  3D 视频：3D 视频工作台的「打开…」/ 项目列表选 night-orbit-demo")
    print("  引擎短片：视频工作台 →「更多」→「打开引擎短片…」→ neon-clash-demo")


if __name__ == "__main__":
    main()
