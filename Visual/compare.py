#!/usr/bin/env python3
"""Compare two captures of the scenarios: a baseline and the current build.

usage: python3 Visual/compare.py [--baseline DIR] [--current DIR] [--out DIR]
                                 [--threshold N] [--tolerance PT]
                                 [--ignore X,Y,W,H ...] [names ...]

For every scenario with a PNG and/or geometry JSON on both sides it writes
<out>/<name>.diff.png, <out>/<name>.side.png, <out>/summary.txt and
<out>/index.html. It is a report: the exit status is 0 whatever the
differences, and non-zero only when inputs are missing. See README.md.
"""

import argparse
import glob
import html
import json
import math
import os
import sys
from collections import deque

import numpy as np
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
VISUAL_BUILD = os.path.join(ROOT, "build", "visual")
# Core's scenarios and every plugin's.
SCENARIOS_DIRS = [os.path.join(HERE, "scenarios")] + sorted(glob.glob(os.path.join(ROOT, "Plugins", "*", "Visual", "scenarios")))

# Cluster detection works on square blocks of device pixels: differing pixels
# in touching blocks (8-connected) are one cluster, so a glyph or an edge that
# differs along its length reads as one problem, not hundreds.
CLUSTER_BLOCK = 8
TOP_CLUSTERS = 6


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--baseline", default=os.path.join(VISUAL_BUILD, "baseline"))
    parser.add_argument("--current", default=os.path.join(VISUAL_BUILD, "current"))
    parser.add_argument("--out", default=os.path.join(VISUAL_BUILD, "compare"))
    parser.add_argument("--scenarios", action="append",
                        help="a directory of scenario JSONs (descriptions, per-scenario ignore regions); repeatable "
                             "(default: Visual/scenarios and every Plugins/*/Visual/scenarios)")
    parser.add_argument("--threshold", type=int, default=24,
                        help="a pixel differs when its max channel delta exceeds this (antialiasing tolerance; default 24)")
    parser.add_argument("--tolerance", type=float, default=0.5,
                        help="a rect differs when any edge moves more than this many points (default 0.5)")
    parser.add_argument("--ignore", action="append", default=[], metavar="X,Y,W,H",
                        help="region (points) excluded from the pixel diff in every scenario (repeatable)")
    parser.add_argument("names", nargs="*")
    return parser.parse_args(argv)


def scenario_names(directory):
    names = set()
    if not os.path.isdir(directory):
        return names
    for file in os.listdir(directory):
        if file.endswith(".geometry.json"):
            names.add(file[: -len(".geometry.json")])
        elif file.endswith(".png") and "." not in file[:-4]:
            names.add(file[:-4])
    return names


def load_json(path):
    if not os.path.exists(path):
        return None
    with open(path) as f:
        return json.load(f)


# ---------------------------------------------------------------------------
# Pixels
# ---------------------------------------------------------------------------

def load_rgb(path):
    if not os.path.exists(path):
        return None
    image = Image.open(path)
    if image.mode in ("RGBA", "LA", "P"):
        image = image.convert("RGBA")
        backdrop = Image.new("RGBA", image.size, (255, 0, 255, 255))
        image = Image.alpha_composite(backdrop, image)
    return np.asarray(image.convert("RGB"), dtype=np.int16)


def on_canvas(pixels, height, width):
    """`pixels` padded to height x width; the padding is marked missing."""
    canvas = np.zeros((height, width, 3), dtype=np.int16)
    present = np.zeros((height, width), dtype=bool)
    h, w = pixels.shape[:2]
    canvas[:h, :w] = pixels
    present[:h, :w] = True
    return canvas, present


def find_clusters(mask, scale):
    """Connected groups of differing pixels, largest first, as (pixel count, [x, y, w, h] in points)."""
    height, width = mask.shape
    bh, bw = math.ceil(height / CLUSTER_BLOCK), math.ceil(width / CLUSTER_BLOCK)
    padded = np.zeros((bh * CLUSTER_BLOCK, bw * CLUSTER_BLOCK), dtype=bool)
    padded[:height, :width] = mask
    counts = padded.reshape(bh, CLUSTER_BLOCK, bw, CLUSTER_BLOCK).sum(axis=(1, 3))
    labels = np.full((bh, bw), -1, dtype=np.int32)
    clusters = []
    for start in zip(*np.nonzero(counts)):
        if labels[start] != -1:
            continue
        label = len(clusters)
        labels[start] = label
        queue = deque([start])
        top, left, bottom, right, total = start[0], start[1], start[0], start[1], 0
        while queue:
            r, c = queue.popleft()
            total += int(counts[r, c])
            top, bottom, left, right = min(top, r), max(bottom, r), min(left, c), max(right, c)
            for dr in (-1, 0, 1):
                for dc in (-1, 0, 1):
                    nr, nc = r + dr, c + dc
                    if 0 <= nr < bh and 0 <= nc < bw and counts[nr, nc] and labels[nr, nc] == -1:
                        labels[nr, nc] = label
                        queue.append((nr, nc))
        # Tighten the block bbox to the differing pixels themselves.
        y0, y1 = top * CLUSTER_BLOCK, (bottom + 1) * CLUSTER_BLOCK
        x0, x1 = left * CLUSTER_BLOCK, (right + 1) * CLUSTER_BLOCK
        region = padded[y0:y1, x0:x1]
        rows, cols = np.nonzero(region.any(axis=1))[0], np.nonzero(region.any(axis=0))[0]
        px = (x0 + cols[0], y0 + rows[0], x0 + cols[-1] + 1, y0 + rows[-1] + 1)
        rect = [round(px[0] / scale, 1), round(px[1] / scale, 1),
                round((px[2] - px[0]) / scale, 1), round((px[3] - px[1]) / scale, 1)]
        clusters.append((total, rect, px))
    clusters.sort(key=lambda item: -item[0])
    return clusters


def compare_pixels(name, baseline_path, current_path, out_dir, threshold, ignore_rects, width_pt):
    baseline = load_rgb(baseline_path)
    current = load_rgb(current_path)
    if baseline is None or current is None:
        missing = "baseline" if baseline is None else "current"
        return {"error": f"no {missing} PNG"}

    height = max(baseline.shape[0], current.shape[0])
    width = max(baseline.shape[1], current.shape[1])
    b_canvas, b_present = on_canvas(baseline, height, width)
    c_canvas, c_present = on_canvas(current, height, width)
    scale = baseline.shape[1] / width_pt if width_pt else 2.0

    delta = np.abs(b_canvas - c_canvas).max(axis=2)
    delta[~(b_present & c_present)] = 255
    ignored = np.zeros((height, width), dtype=bool)
    for x, y, w, h in ignore_rects:
        ignored[int(round(y * scale)):int(round((y + h) * scale)), int(round(x * scale)):int(round((x + w) * scale))] = True
    delta[ignored] = 0
    differs = delta > threshold

    compared = int((~ignored).sum())
    count = int(differs.sum())
    clusters = find_clusters(differs, scale)
    stats = {
        "size_baseline": [int(baseline.shape[1]), int(baseline.shape[0])],
        "size_current": [int(current.shape[1]), int(current.shape[0])],
        "differing": count,
        "percent": 100.0 * count / compared if compared else 0.0,
        "max_delta": int(delta.max()),
        "mean_delta": float(delta[~ignored].mean()) if compared else 0.0,
        "clusters": [{"pixels": total, "rect": rect} for total, rect, _ in clusters[:TOP_CLUSTERS]],
        "cluster_count": len(clusters),
    }

    # Diff: the current render dimmed to grey, differing pixels in red, sub-
    # threshold (antialiasing-level) differences as a faint amber, ignored
    # regions tinted blue, and the largest clusters boxed in cyan.
    gray = 24 + (c_canvas * np.array([0.299, 0.587, 0.114])).sum(axis=2) * 0.35
    diff = np.repeat(gray[:, :, None], 3, axis=2)
    faint = (delta > 0) & ~differs
    diff[faint] = diff[faint] * 0.5 + np.array([110, 80, 0])
    diff[differs] = [255, 0, 0]
    diff[ignored] = diff[ignored] * 0.5 + np.array([0, 0, 90])
    diff_image = Image.fromarray(np.clip(diff, 0, 255).astype(np.uint8))
    draw = ImageDraw.Draw(diff_image)
    pad = int(2 * scale)
    for _, _, (x0, y0, x1, y1) in clusters[:TOP_CLUSTERS]:
        draw.rectangle([x0 - pad, y0 - pad, x1 + pad, y1 + pad], outline=(0, 230, 255), width=max(1, int(scale)))
    diff_image.save(os.path.join(out_dir, f"{name}.diff.png"))

    # Side by side at 1x: baseline | current | diff.
    panels = [Image.fromarray(b_canvas.astype(np.uint8)), Image.fromarray(c_canvas.astype(np.uint8)), diff_image]
    width_1x, height_1x = max(1, round(width / scale)), max(1, round(height / scale))
    label_h, gap = 22, 8
    side = Image.new("RGB", (width_1x * 3 + gap * 2, height_1x + label_h), (40, 40, 40))
    draw = ImageDraw.Draw(side)
    for index, (panel, label) in enumerate(zip(panels, ("baseline", "current", "diff"))):
        x = index * (width_1x + gap)
        side.paste(panel.resize((width_1x, height_1x), Image.LANCZOS), (x, label_h))
        draw.text((x + 6, 5), label, fill=(230, 230, 230))
    side.save(os.path.join(out_dir, f"{name}.side.png"))
    return stats


# ---------------------------------------------------------------------------
# Geometry
# ---------------------------------------------------------------------------

def is_rect(value):
    return isinstance(value, list) and len(value) == 4 and all(
        isinstance(v, (int, float)) and not isinstance(v, bool) for v in value)


def flatten(value, prefix=""):
    """Leaf path -> value. Rects and scalars are leaves; objects and other lists recurse."""
    out = {}
    if isinstance(value, dict):
        for key, child in value.items():
            out.update(flatten(child, f"{prefix}.{key}" if prefix else key))
    elif isinstance(value, list) and not is_rect(value):
        for index, child in enumerate(value):
            out.update(flatten(child, f"{prefix}[{index}]"))
        if not value:
            out[prefix] = []
    else:
        out[prefix] = value
    return out


def fmt_rect(rect):
    return "[" + ", ".join(f"{v:g}" for v in rect) + "]"


def compare_geometry(baseline, current, tolerance):
    """Human-readable differences, one per line, and a count of rects compared."""
    b_flat = flatten(baseline)
    c_flat = flatten(current)
    lines, rects = [], 0
    for key in sorted(set(b_flat) | set(c_flat)):
        if key not in c_flat:
            lines.append(f"gone:    {key} = {describe(b_flat[key])}")
            continue
        if key not in b_flat:
            lines.append(f"new:     {key} = {describe(c_flat[key])}")
            continue
        b, c = b_flat[key], c_flat[key]
        if is_rect(b) and is_rect(c):
            rects += 1
            edges = edge_deltas(b, c)
            if any(abs(d) > tolerance for d in edges.values()):
                moved = " ".join(f"{side}{d:+.2f}" for side, d in edges.items() if abs(d) > tolerance)
                lines.append(f"rect {key}: baseline {fmt_rect(b)} current {fmt_rect(c)}  ({moved})")
        elif isinstance(b, (int, float)) and isinstance(c, (int, float)) and not isinstance(b, bool) and not isinstance(c, bool):
            if abs(b - c) > tolerance:
                lines.append(f"value {key}: baseline {b:g} current {c:g}")
        elif b != c:
            lines.append(f"value {key}: baseline {describe(b)} current {describe(c)}")
    return lines, rects


def edge_deltas(b, c):
    """current minus baseline, per edge: left, top, right, bottom."""
    return {
        "L": c[0] - b[0],
        "T": c[1] - b[1],
        "R": (c[0] + c[2]) - (b[0] + b[2]),
        "B": (c[1] + c[3]) - (b[1] + b[3]),
    }


def describe(value):
    if is_rect(value):
        return fmt_rect(value)
    return json.dumps(value)


# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------

def parse_ignore(values):
    rects = []
    for value in values:
        parts = [float(p) for p in value.split(",")]
        if len(parts) != 4:
            raise SystemExit(f"--ignore expects X,Y,W,H, got {value!r}")
        rects.append(parts)
    return rects


def stats_line(stats):
    if "error" in stats:
        return f"pixels: {stats['error']}"
    size = ""
    if stats["size_baseline"] != stats["size_current"]:
        size = f"  SIZE MISMATCH baseline {stats['size_baseline']} current {stats['size_current']}"
    return (f"pixels: {stats['percent']:.3f}% differ ({stats['differing']} px > threshold), "
            f"max delta {stats['max_delta']}, mean {stats['mean_delta']:.2f}, "
            f"{stats['cluster_count']} clusters{size}")


def write_html(out_dir, results, baseline_dir, current_dir, args):
    def rel(path):
        return html.escape(os.path.relpath(path, out_dir))

    sections = []
    toc = []
    for result in results:
        name = result["name"]
        stats = result["pixels"]
        geo = result["geometry"]
        badge = "ok" if result["clean"] else "diff"
        pct = f"{stats['percent']:.2f}%" if "percent" in stats else "n/a"
        toc.append(f'<tr><td><a href="#{name}">{name}</a></td><td class="{badge}">{pct}</td>'
                   f'<td class="{badge}">{len(geo) if geo is not None else "n/a"}</td></tr>')
        clusters = "".join(f"<li>{c['pixels']} px at {fmt_rect(c['rect'])}</li>" for c in stats.get("clusters", []))
        geo_items = "".join(f"<li><code>{html.escape(line)}</code></li>" for line in (geo or []))
        b_png = os.path.join(baseline_dir, f"{name}.png")
        c_png = os.path.join(current_dir, f"{name}.png")
        d_png = os.path.join(out_dir, f"{name}.diff.png")
        sections.append(f"""
<section id="{name}">
  <h2>{name} <span class="{badge}">{badge}</span></h2>
  <p class="desc">{html.escape(result.get("description", ""))}</p>
  <p class="stats">{html.escape(stats_line(stats))}</p>
  {f'<details><summary>largest clusters (pt)</summary><ul>{clusters}</ul></details>' if clusters else ''}
  <details {'open' if geo and len(geo) <= 12 else ''}><summary>geometry: {len(geo) if geo is not None else 'n/a'} difference(s) over {result['rects']} rects</summary><ul>{geo_items}</ul></details>
  <div class="views">
    <figure><figcaption>baseline</figcaption><a href="{rel(b_png)}" target="_blank"><img loading="lazy" src="{rel(b_png)}"></a></figure>
    <figure><figcaption>current</figcaption><a href="{rel(c_png)}" target="_blank"><img loading="lazy" src="{rel(c_png)}"></a></figure>
    <figure><figcaption>diff</figcaption><a href="{rel(d_png)}" target="_blank"><img loading="lazy" src="{rel(d_png)}"></a></figure>
    <figure class="flip" title="click to flip baseline / current"><figcaption>flip: <b>baseline</b></figcaption>
      <img loading="lazy" src="{rel(b_png)}" data-a="{rel(b_png)}" data-b="{rel(c_png)}"></figure>
  </div>
</section>""")

    page = f"""<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>Visual compare</title>
<meta name="viewport" content="width=device-width, initial-scale=1">
<style>
  :root {{ color-scheme: dark; --bg: #16171b; --text: #e6e6eb; --dim: #9a9ba6; --ok: #4caf50; --diff: #ff5a4f; }}
  body {{ background: var(--bg); color: var(--text); font: 13px system-ui, sans-serif; margin: 16px; }}
  table {{ border-collapse: collapse; }} td, th {{ padding: 2px 12px 2px 0; text-align: left; }}
  a {{ color: #7aa7ff; }} .ok {{ color: var(--ok); }} .diff {{ color: var(--diff); }}
  .desc {{ color: var(--dim); max-width: 100ch; }} .stats {{ font-family: ui-monospace, monospace; }}
  section {{ border-top: 1px solid #333; margin-top: 24px; padding-top: 8px; }}
  h2 span {{ font-size: 12px; font-weight: normal; }}
  .views {{ display: grid; grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); gap: 8px; }}
  figure {{ margin: 0; }} figcaption {{ color: var(--dim); margin-bottom: 2px; }}
  img {{ width: 100%; display: block; border: 1px solid #333; image-rendering: auto; }}
  .flip {{ cursor: pointer; }}
  code {{ font-size: 12px; }}
</style></head><body>
<h1>Visual compare</h1>
<p class="desc">baseline: <code>{html.escape(baseline_dir)}</code><br>current: <code>{html.escape(current_dir)}</code><br>
pixel threshold {args.threshold} (max channel delta), geometry tolerance {args.tolerance} pt.
Diff: current in grey, red = differs, amber = below threshold, blue = ignored, cyan boxes = largest clusters.
Click a flip image to swap baseline/current (or press <kbd>f</kbd> to flip all); click any other image for full size.</p>
<table><tr><th>scenario</th><th>pixels differing</th><th>geometry diffs</th></tr>{''.join(toc)}</table>
{''.join(sections)}
<script>
  function flip(fig) {{
    const img = fig.querySelector('img'), label = fig.querySelector('b');
    const toB = img.getAttribute('src') === img.dataset.a;
    img.src = toB ? img.dataset.b : img.dataset.a;
    label.textContent = toB ? 'current' : 'baseline';
  }}
  document.querySelectorAll('.flip').forEach((fig) => fig.addEventListener('click', () => flip(fig)));
  document.addEventListener('keydown', (e) => {{ if (e.key === 'f') document.querySelectorAll('.flip').forEach(flip); }});
</script>
</body></html>
"""
    with open(os.path.join(out_dir, "index.html"), "w") as f:
        f.write(page)


def main(argv):
    args = parse_args(argv)
    global_ignore = parse_ignore(args.ignore)
    for label, directory in (("baseline", args.baseline), ("current", args.current)):
        if not os.path.isdir(directory):
            print(f"error: {label} directory not found: {directory}", file=sys.stderr)
            return 2
    baseline_names, current_names = scenario_names(args.baseline), scenario_names(args.current)
    common = sorted(baseline_names & current_names)
    if args.names:
        missing = [n for n in args.names if n not in common]
        if missing:
            print(f"error: not captured on both sides: {', '.join(missing)}", file=sys.stderr)
            return 2
        common = args.names
    if not common:
        print("error: no scenario captured on both sides", file=sys.stderr)
        return 2
    os.makedirs(args.out, exist_ok=True)

    report, results = [], []
    only_b = sorted(baseline_names - current_names)
    only_c = sorted(current_names - baseline_names)
    if only_b and not args.names:
        report.append(f"not in the current capture: {', '.join(only_b)}")
    if only_c and not args.names:
        report.append(f"not in the baseline capture: {', '.join(only_c)}")

    for name in common:
        scenario = next((load_json(path) for path in (os.path.join(d, f"{name}.json") for d in args.scenarios or SCENARIOS_DIRS)
                         if os.path.exists(path)), None) or {}
        ignore = global_ignore + [list(r) for r in scenario.get("ignore", [])]
        b_geo = load_json(os.path.join(args.baseline, f"{name}.geometry.json"))
        c_geo = load_json(os.path.join(args.current, f"{name}.geometry.json"))
        width_pt = (b_geo or {}).get("size", {}).get("width") or scenario.get("size", {}).get("width")
        pixels = compare_pixels(name, os.path.join(args.baseline, f"{name}.png"),
                                os.path.join(args.current, f"{name}.png"), args.out,
                                args.threshold, ignore, width_pt)
        if b_geo is None or c_geo is None:
            geo, rects = None, 0
        else:
            geo, rects = compare_geometry(b_geo, c_geo, args.tolerance)
        clean = "error" not in pixels and pixels["differing"] == 0 and geo == []
        results.append({"name": name, "description": scenario.get("description", ""),
                        "pixels": pixels, "geometry": geo, "rects": rects, "clean": clean})

        report.append("")
        report.append(f"== {name} {'(clean)' if clean else ''}".rstrip())
        report.append("  " + stats_line(pixels))
        for cluster in pixels.get("clusters", []):
            report.append(f"    cluster {cluster['pixels']:>7} px at {fmt_rect(cluster['rect'])}")
        if geo is None:
            report.append("  geometry: missing " + ("baseline" if b_geo is None else "current") + " geometry JSON")
        else:
            report.append(f"  geometry: {len(geo)} difference(s) over {rects} rects")
            report.extend("    " + line for line in geo)

    clean_count = sum(1 for r in results if r["clean"])
    report.insert(0, f"{len(results)} scenario(s) compared, {clean_count} clean "
                     f"(threshold {args.threshold}, tolerance {args.tolerance} pt)")
    text = "\n".join(report) + "\n"
    with open(os.path.join(args.out, "summary.txt"), "w") as f:
        f.write(text)
    write_html(args.out, results, os.path.abspath(args.baseline), os.path.abspath(args.current), args)
    sys.stdout.write(text)
    print(f"\nreport: {os.path.join(os.path.abspath(args.out), 'index.html')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
