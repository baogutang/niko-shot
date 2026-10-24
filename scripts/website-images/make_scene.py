#!/usr/bin/env python3
"""Render the backdrops the website screenshots are composed on, with headless Chrome at 2x.

backdrop.png is the practice note (website/assets/capture-sample.svg) that the capture hero selects.
scene-*.png is a document window scrolled to the middle of a long page, and scroll-preview-source*.png
is everything scrolled past so far, as the long-capture live preview would hold it.
"""
import pathlib, subprocess, sys
from PIL import Image

out = pathlib.Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
SCROLL_Y, VIEW = 560, (135, 60, 450, 400)  # viewport x, y (top-left), width, height in points
SECTIONS = [
    ("冻结功能", "从今天起只修缺陷，不再合入新功能。未完成的需求移到下个版本。", "负责人：产品"),
    ("设计评审", "两种方案并排对比，选定后同步更新设计规范和组件库。", "周三 14:00"),
    ("文案检查", "按钮用动词，提示说清楚下一步。删掉重复的说明文字。", "负责人：设计"),
    ("快捷键冲突", "列出与常用软件冲突的组合，默认只保留一个全局快捷键。", "已完成"),
    ("性能回归", "在 60 Hz 和 120 Hz 屏幕上各测一次框选，拖动要跟手。", "负责人：开发"),
    ("权限说明", "首次启动只请求屏幕录制，其余权限用到时再询问。", "已完成"),
    ("截图素材", "官网和 README 的截图全部重新截取，深浅两套。", "进行中"),
    ("签名与公证", "沿用原有证书，升级后不需要重新授权。", "负责人：发布"),
    ("发布说明", "按用户能感知到的变化来写，不写内部重构。", "周五之前"),
    ("灰度安装", "先发给团队内部，收集一天反馈再公开。", "下周一"),
    ("回滚预案", "保留上一版安装包，出现问题时直接替换。", "负责人：发布"),
    ("复盘", "记录这次踩过的坑，更新发布清单。", "发布后一周"),
]
THEMES = {
    "light": dict(desk="#e6e6eb", page="#ffffff", ink="#1d1d1f", body="#424245", meta="#86868b", rule="#e5e5ea",
                  bar="#f5f5f7", barline="#dcdcdf", title="#4d4d4f", tag="#fbf1e0", tagink="#9a6410",
                  shadow="0 18px 50px rgba(0,0,0,.16), 0 0 0 .5px rgba(0,0,0,.14)"),
    "dark": dict(desk="#1b1b1d", page="#1e1e20", ink="#f5f5f7", body="#c7c7cc", meta="#8e8e93", rule="#38383a",
                 bar="#2c2c2e", barline="#3a3a3c", title="#b0b0b5", tag="#3a2d17", tagink="#e8a333",
                 shadow="0 18px 50px rgba(0,0,0,.5), 0 0 0 .5px rgba(255,255,255,.12)"),
}

def page_html(t):
    items = "".join(
        f'<section><h2><span>{i:02d}</span>{h}</h2><p>{p}</p><div class="meta">{"<b>" + m + "</b>" if m in ("进行中",) else m}</div></section>'
        for i, (h, p, m) in enumerate(SECTIONS, 1))
    return f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;background:{t['page']};}}
.page{{width:450px;box-sizing:border-box;padding:30px 34px 40px;font-family:-apple-system,"PingFang SC",sans-serif;color:{t['ink']};-webkit-font-smoothing:antialiased}}
h1{{font-size:24px;margin:0 0 6px;letter-spacing:-.01em}} .sub{{color:{t['meta']};font-size:13px;margin:0 0 22px}}
section{{padding:16px 0 17px;border-top:1px solid {t['rule']}}}
h2{{font-size:15px;font-weight:600;margin:0 0 6px}} h2 span{{color:{t['meta']};font-weight:500;margin-right:10px;font-variant-numeric:tabular-nums}}
p{{font-size:13px;line-height:1.6;color:{t['body']};margin:0}}
.meta{{font-size:11.5px;color:{t['meta']};margin-top:8px}} .meta b{{font-weight:600;color:{t['tagink']};background:{t['tag']};padding:2px 7px;border-radius:5px}}
</style><div class="page"><h1>0.6.0 发布清单</h1><p class="sub">按顺序完成，每项完成后打勾。</p>{items}</div>"""

def scene_html(t, page_file):
    x, y, w, h = VIEW
    return f"""<!doctype html><meta charset="utf-8"><style>
html,body{{margin:0;width:880px;height:560px;overflow:hidden;background:{t['desk']}}}
.win{{position:absolute;left:{x}px;top:{y-28}px;width:{w}px;height:{h+28}px;border-radius:10px;overflow:hidden;box-shadow:{t['shadow']};background:{t['page']}}}
.bar{{height:28px;background:{t['bar']};border-bottom:1px solid {t['barline']};box-sizing:border-box;position:relative;font:13px -apple-system,"PingFang SC";color:{t['title']};text-align:center;line-height:27px}}
.dots{{position:absolute;left:10px;top:8px;display:flex;gap:8px}} .dots i{{width:12px;height:12px;border-radius:50%;display:block}}
.view{{height:{h}px;overflow:hidden}} iframe{{border:0;width:450px;height:2000px;display:block;margin-top:-{SCROLL_Y}px}}
</style><div class="win"><div class="bar"><div class="dots"><i style="background:#ff5f57"></i><i style="background:#febc2e"></i><i style="background:#28c840"></i></div>发布清单.md</div>
<div class="view"><iframe src="{page_file}" scrolling="no"></iframe></div></div>"""

def shoot(html, png, size):
    subprocess.run([CHROME, "--headless=new", "--disable-gpu", "--hide-scrollbars", f"--user-data-dir={out}/chrome-profile",
        "--force-device-scale-factor=2", f"--window-size={size[0]},{size[1]}", "--allow-file-access-from-files",
        f"--screenshot={png}", html.as_uri()], check=True, capture_output=True)

sample = pathlib.Path(__file__).resolve().parents[2] / "website/assets/capture-sample.svg"
shoot(sample, out / "backdrop.png", (1280, 800))
for name, t in THEMES.items():
    page = out / f"page-{name}.html"; page.write_text(page_html(t))
    shoot(page, out / f"page-{name}.png", (450, 1500))
    scene = out / f"scene-{name}.html"; scene.write_text(scene_html(t, page.name))
    shoot(scene, out / f"scene-{name}.png", (880, 560))
# The stitched preview holds everything scrolled past so far, at the accumulator's 384 px width.
done = Image.open(out / "page-light.png").crop((0, 0, 900, (SCROLL_Y + VIEW[3]) * 2))
done.resize((384, round(done.height * 384 / 900)), Image.LANCZOS).save(out / "scroll-preview-source.png")
done_dark = Image.open(out / "page-dark.png").crop((0, 0, 900, (SCROLL_Y + VIEW[3]) * 2))
done_dark.resize((384, round(done_dark.height * 384 / 900)), Image.LANCZOS).save(out / "scroll-preview-source-dark.png")
print("ok", done.size)
