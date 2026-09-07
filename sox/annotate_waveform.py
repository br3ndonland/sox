#!/usr/bin/env -S uv run --script
#
# /// script
# requires-python = ">=3.14"
# dependencies = ["pillow>=12,<13"]
# ///
"""Add time and dB axes to FFmpeg showwavespic output."""

from __future__ import annotations

import sys
from pathlib import Path
from typing import Never

from PIL import Image, ImageDraw

FINAL_WIDTH = 1812
FINAL_HEIGHT = 980
RIGHT_AXIS_WIDTH = 50
BOTTOM_AXIS_HEIGHT = 18
BACKGROUND = (0, 0, 0)
AXIS_COLOR = (64, 75, 84)
LABEL_COLOR = (128, 137, 145)
NEGATIVE_INFINITY_LABEL = "-infinity"


def die(message: str) -> Never:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


def parse_positive_float(raw: str, name: str) -> float:
    try:
        value = float(raw)
    except ValueError:
        die(f"{name} must be a number")
    if value <= 0:
        die(f"{name} must be positive")
    return value


def parse_positive_int(raw: str, name: str) -> int:
    try:
        value = int(raw)
    except ValueError:
        die(f"{name} must be an integer")
    if value <= 0:
        die(f"{name} must be positive")
    return value


def text_size(draw: ImageDraw.ImageDraw, text: str) -> tuple[int, int]:
    bbox = draw.textbbox((0, 0), text)
    return round(bbox[2] - bbox[0]), round(bbox[3] - bbox[1])


def format_time(seconds: float) -> str:
    rounded = round(seconds)
    hours = rounded // 3600
    minutes = (rounded % 3600) // 60
    secs = rounded % 60
    return f"{hours}:{minutes:02d}:{secs:02d}"


def choose_time_step(duration_seconds: float) -> int:
    candidates = (1, 2, 5, 10, 15, 30, 60, 120, 300, 600, 900, 1200, 1800)
    for step in candidates:
        if duration_seconds / step <= 24:
            return step
    return candidates[-1]


def format_db(db: float) -> str:
    if float(db).is_integer():
        return str(int(db))
    return str(db)


def draw_time_axis(
    draw: ImageDraw.ImageDraw,
    plot_width: int,
    plot_height: int,
    duration_seconds: float,
) -> None:
    axis_y = plot_height
    draw.line((0, axis_y, plot_width, axis_y), fill=AXIS_COLOR)

    minor_step = choose_time_step(duration_seconds) / 5
    if minor_step >= 1:
        tick = minor_step
        while tick < duration_seconds:
            x = round((tick / duration_seconds) * plot_width)
            draw.line((x, axis_y, x, axis_y + 3), fill=AXIS_COLOR)
            tick += minor_step

    step = choose_time_step(duration_seconds)
    tick = 0
    while tick <= duration_seconds + 0.5:
        x = round((tick / duration_seconds) * plot_width)
        label = format_time(tick)
        width, _ = text_size(draw, label)
        label_x = max(2, min(plot_width - width - 2, x - width // 2))
        draw.line((x, axis_y, x, axis_y + 7), fill=AXIS_COLOR)
        draw.text((label_x, axis_y + 5), label, fill=LABEL_COLOR)
        tick += step

    label = "h:m:s"
    width, _ = text_size(draw, label)
    draw.text((FINAL_WIDTH - width - 4, FINAL_HEIGHT - 13), label, fill=LABEL_COLOR)


def draw_db_axis(
    draw: ImageDraw.ImageDraw,
    plot_width: int,
    plot_height: int,
    channel_count: int,
) -> None:
    lane_height = plot_height / channel_count
    db_ticks = (-1, -2, -3, -4, -5, -6, -7, -8, -10, -12, -20)

    draw.line((plot_width, 0, plot_width, plot_height), fill=AXIS_COLOR)
    draw.text((plot_width + 4, 4), "dB", fill=LABEL_COLOR)

    for channel_index in range(channel_count):
        lane_top = channel_index * lane_height
        lane_bottom = (channel_index + 1) * lane_height
        center = lane_top + lane_height / 2

        if channel_index > 0:
            y = round(lane_top)
            draw.line((0, y, FINAL_WIDTH, y), fill=AXIS_COLOR)

        for db in db_ticks:
            amplitude = 10 ** (db / 20)
            label = format_db(db)
            for sign in (-1, 1):
                y = round(center + sign * amplitude * (lane_height / 2 - 1))
                if y <= lane_top + 1 or y >= lane_bottom - 1:
                    continue
                draw.line((plot_width, y, plot_width + 4, y), fill=AXIS_COLOR)
                _, height = text_size(draw, label)
                draw.text(
                    (plot_width + 6, y - height // 2),
                    label,
                    fill=LABEL_COLOR,
                )

        center_y = round(center)
        draw.line((plot_width, center_y, plot_width + 4, center_y), fill=AXIS_COLOR)
        _, height = text_size(draw, NEGATIVE_INFINITY_LABEL)
        draw.text(
            (plot_width + 6, center_y - height // 2),
            NEGATIVE_INFINITY_LABEL,
            fill=LABEL_COLOR,
        )


def main() -> None:
    if len(sys.argv) != 5:
        die("usage: annotate_waveform.py RAW_PNG OUTPUT_PNG DURATION_SECONDS CHANNELS")

    raw_path = Path(sys.argv[1])
    output_path = Path(sys.argv[2])
    duration_seconds = parse_positive_float(sys.argv[3], "duration_seconds")
    channel_count = parse_positive_int(sys.argv[4], "channels")

    plot_width = FINAL_WIDTH - RIGHT_AXIS_WIDTH
    plot_height = FINAL_HEIGHT - BOTTOM_AXIS_HEIGHT

    raw = Image.open(raw_path).convert("RGB")
    if raw.size != (plot_width, plot_height):
        die(f"raw waveform has size {raw.size}, expected {(plot_width, plot_height)}")

    canvas = Image.new("RGB", (FINAL_WIDTH, FINAL_HEIGHT), BACKGROUND)
    canvas.paste(raw, (0, 0))

    draw = ImageDraw.Draw(canvas)
    draw_db_axis(draw, plot_width, plot_height, channel_count)
    draw_time_axis(draw, plot_width, plot_height, duration_seconds)

    output_path.parent.mkdir(parents=True, exist_ok=True)
    canvas.save(output_path)


if __name__ == "__main__":
    main()
