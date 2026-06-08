"""
calibration.py — Two-phase calibration for AI Metrology Inspection Station

Phase A (Lens): Checkerboard pattern → intrinsics + distortion coefficients
               Writes camera_matrix and dist_coeffs to config.yaml

Phase B (Spatial): Known reference object (e.g. 1" gauge block, coin, ruler) →
                   px_per_mm → px_per_inch
                   Writes px_per_mm, px_per_inch to config.yaml

Usage:
  python calibration.py --lens            # Checkerboard lens calibration
  python calibration.py --spatial         # Reference object spatial calibration
  python calibration.py --lens --spatial  # Both
  python calibration.py --verify          # Show current calibration status
"""

import argparse
import json
import logging
import math
import os
import sys
import time
from pathlib import Path

import cv2
import numpy as np
import yaml

logger = logging.getLogger(__name__)
CONFIG_PATH = "config.yaml"
CAL_DIR = Path("calibration")


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def save_config(cfg: dict) -> None:
    with open(CONFIG_PATH, "w") as f:
        yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    logger.info("config.yaml updated")


# ---------------------------------------------------------------------------
# Camera helpers
# ---------------------------------------------------------------------------

def open_camera(cfg: dict) -> cv2.VideoCapture:
    from capture import CameraCapture
    cam = CameraCapture(cfg)
    cam.start()
    return cam


def grab_frame(cam) -> np.ndarray | None:
    """Wait up to 3s for a valid frame."""
    for _ in range(30):
        f = cam.read()
        if f is not None:
            return f
        time.sleep(0.1)
    return None


# ---------------------------------------------------------------------------
# Phase A — Lens distortion calibration (checkerboard)
# ---------------------------------------------------------------------------

def calibrate_lens(cfg: dict, board_w: int = 9, board_h: int = 6,
                   square_mm: float = 25.0, n_frames: int = 20) -> None:
    """
    Capture N frames of a checkerboard and compute camera intrinsics.

    Args:
        board_w: Inner corner count, width (default 9 for a 10-col board)
        board_h: Inner corner count, height (default 6 for a 7-row board)
        square_mm: Physical size of each square in mm
        n_frames: Number of good frames to collect before computing
    """
    logger.info("=== LENS CALIBRATION ===")
    logger.info("Board: %dx%d inner corners, square=%.1fmm", board_w, board_h, square_mm)
    logger.info("Hold checkerboard in view. Rotate/tilt to different angles.")
    logger.info("Capturing %d good frames automatically...", n_frames)

    CAL_DIR.mkdir(exist_ok=True)

    # Prepare object points (flat checkerboard in 3D)
    objp = np.zeros((board_w * board_h, 3), np.float32)
    objp[:, :2] = np.mgrid[0:board_w, 0:board_h].T.reshape(-1, 2)
    objp *= square_mm

    obj_points = []  # 3D world points
    img_points = []  # 2D image points

    criteria = (cv2.TERM_CRITERIA_EPS + cv2.TERM_CRITERIA_MAX_ITER, 30, 0.001)
    cam = open_camera(cfg)

    try:
        collected = 0
        last_good = 0

        while collected < n_frames:
            frame = grab_frame(cam)
            if frame is None:
                logger.warning("No frame — check camera")
                continue

            gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
            ret, corners = cv2.findChessboardCorners(gray, (board_w, board_h), None)

            if ret:
                # Refine corner locations to subpixel
                corners2 = cv2.cornerSubPix(gray, corners, (11, 11), (-1, -1), criteria)

                # Only accept if enough time has passed (avoid nearly identical frames)
                now = time.monotonic()
                if now - last_good > 0.8:
                    obj_points.append(objp)
                    img_points.append(corners2)
                    collected += 1
                    last_good = now
                    logger.info("  Frame %d/%d accepted", collected, n_frames)

                    # Save debug image
                    vis = frame.copy()
                    cv2.drawChessboardCorners(vis, (board_w, board_h), corners2, ret)
                    cv2.imwrite(str(CAL_DIR / f"lens_cal_{collected:03d}.jpg"), vis)

        logger.info("Computing camera matrix from %d frames...", n_frames)
        h, w = frame.shape[:2]
        ret, mtx, dist, rvecs, tvecs = cv2.calibrateCamera(
            obj_points, img_points, (w, h), None, None
        )

        reprojection_err = _reprojection_error(obj_points, img_points, rvecs, tvecs, mtx, dist)
        logger.info("Calibration RMS reprojection error: %.4f px", reprojection_err)
        if reprojection_err > 1.0:
            logger.warning("RMS > 1.0 px — consider recalibrating with better images")

        # Write to config
        cfg["lens"]["correction_enabled"] = True
        cfg["lens"]["camera_matrix"] = mtx.tolist()
        cfg["lens"]["dist_coeffs"] = dist.flatten().tolist()
        save_config(cfg)

        # Save separate JSON too
        cal_data = {
            "camera_matrix": mtx.tolist(),
            "dist_coeffs": dist.flatten().tolist(),
            "rms_error_px": reprojection_err,
            "image_size": [w, h],
        }
        with open(CAL_DIR / "lens_calibration.json", "w") as f:
            json.dump(cal_data, f, indent=2)

        logger.info("Lens calibration saved. RMS=%.4f px", reprojection_err)

    finally:
        cam.stop()


def _reprojection_error(obj_pts, img_pts, rvecs, tvecs, mtx, dist) -> float:
    total_err = 0.0
    for i in range(len(obj_pts)):
        proj, _ = cv2.projectPoints(obj_pts[i], rvecs[i], tvecs[i], mtx, dist)
        err = cv2.norm(img_pts[i], proj, cv2.NORM_L2) / len(proj)
        total_err += err
    return total_err / len(obj_pts)


# ---------------------------------------------------------------------------
# Phase B — Spatial calibration (px per mm)
# ---------------------------------------------------------------------------

def calibrate_spatial(cfg: dict, method: str = "interactive") -> None:
    """
    Determine px_per_mm by measuring a known reference object in the frame.

    method='interactive': User clicks two points and enters the known distance
    method='auto': Detect largest contour, prompt for its known width
    """
    logger.info("=== SPATIAL CALIBRATION ===")
    logger.info("Place a reference object (gauge block, coin, ruler) flat in the frame.")

    CAL_DIR.mkdir(exist_ok=True)
    cam = open_camera(cfg)

    try:
        logger.info("Waiting for stable frame...")
        time.sleep(1.0)
        frame = grab_frame(cam)
        if frame is None:
            logger.error("Could not grab frame for spatial calibration")
            return

        # Save reference image
        ref_path = str(CAL_DIR / "spatial_reference.jpg")
        cv2.imwrite(ref_path, frame)
        logger.info("Reference image saved: %s", ref_path)

        px_per_mm = _spatial_interactive(frame)

        if px_per_mm is None or px_per_mm <= 0:
            logger.error("Invalid px_per_mm value — aborting spatial calibration")
            return

        px_per_inch = px_per_mm * 25.4
        logger.info("Result: %.4f px/mm = %.4f px/inch", px_per_mm, px_per_inch)

        # Sanity check: warn if suspiciously low or high
        if px_per_mm < 5:
            logger.warning("px/mm < 5 — very wide FOV, precision will be limited")
        if px_per_mm > 500:
            logger.warning("px/mm > 500 — extremely high magnification, verify reference")

        # Write to config
        cfg["optics"]["px_per_mm"] = round(px_per_mm, 6)
        cfg["optics"]["px_per_inch"] = round(px_per_inch, 6)
        cfg["optics"]["calibrated"] = True
        save_config(cfg)

        # Save spatial map JSON
        spatial_data = {
            "px_per_mm": px_per_mm,
            "px_per_inch": px_per_inch,
            "frame_width": frame.shape[1],
            "frame_height": frame.shape[0],
            "timestamp": time.time(),
        }
        with open(CAL_DIR / "spatial_map.json", "w") as f:
            json.dump(spatial_data, f, indent=2)

        logger.info("Spatial calibration complete and saved.")

    finally:
        cam.stop()


def _spatial_interactive(frame: np.ndarray) -> float | None:
    """
    Headless-friendly interactive calibration:
    Prints the reference image path and asks user to measure pixel distance
    between two known points using any image viewer.
    
    For headless Zion: open the saved JPG on another device, measure two
    points with an image viewer, enter the pixel distance.
    """
    h, w = frame.shape[:2]
    print("\n" + "=" * 60)
    print("SPATIAL CALIBRATION — Headless Mode")
    print("=" * 60)
    print(f"\nReference image saved to: calibration/spatial_reference.jpg")
    print(f"Frame size: {w}x{h} px")
    print()
    print("Steps:")
    print("  1. Open calibration/spatial_reference.jpg on any device")
    print("  2. Measure the pixel distance between two known points on")
    print("     your reference object (e.g. two ends of a 1-inch gauge block)")
    print("  3. Enter those values below")
    print()

    while True:
        try:
            px_dist_str = input("Pixel distance between the two points (px): ").strip()
            px_dist = float(px_dist_str)
            if px_dist <= 0:
                print("  Must be > 0")
                continue
            break
        except ValueError:
            print("  Enter a number")

    print()
    print("Known real-world distance between those same points:")

    while True:
        unit = input("  Unit (mm or in): ").strip().lower()
        if unit in ("mm", "in", "inch", "inches"):
            break
        print("  Enter 'mm' or 'in'")

    while True:
        try:
            real_dist_str = input(f"  Distance in {unit}: ").strip()
            real_dist = float(real_dist_str)
            if real_dist <= 0:
                print("  Must be > 0")
                continue
            break
        except ValueError:
            print("  Enter a number")

    # Convert to mm
    if unit in ("in", "inch", "inches"):
        real_dist_mm = real_dist * 25.4
    else:
        real_dist_mm = real_dist

    px_per_mm = px_dist / real_dist_mm
    return px_per_mm


# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

def verify(cfg: dict) -> None:
    print("\n=== CALIBRATION STATUS ===")

    lens = cfg.get("lens", {})
    print(f"\nLens correction:  {'ENABLED' if lens.get('correction_enabled') else 'DISABLED'}")
    if lens.get("camera_matrix"):
        mtx = np.array(lens["camera_matrix"])
        print(f"  fx={mtx[0,0]:.2f}  fy={mtx[1,1]:.2f}  cx={mtx[0,2]:.2f}  cy={mtx[1,2]:.2f}")

    optics = cfg.get("optics", {})
    cal = optics.get("calibrated", False)
    print(f"\nSpatial calibration: {'COMPLETE' if cal else 'NOT DONE'}")
    if cal:
        ppm = optics.get("px_per_mm")
        ppi = optics.get("px_per_inch")
        print(f"  {ppm:.4f} px/mm")
        print(f"  {ppi:.4f} px/inch")
        if ppm:
            # Approximate precision at 1/10px subpixel
            prec_mm = 0.1 / ppm
            prec_in = prec_mm / 25.4
            print(f"\n  Theoretical subpixel precision (~0.1px):")
            print(f"    {prec_mm:.4f} mm  /  {prec_in:.5f} in  ({prec_in * 1000:.2f} thou)")

    print()


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(message)s"
    )

    parser = argparse.ArgumentParser(description="Inspection station calibration")
    parser.add_argument("--lens", action="store_true", help="Run lens distortion calibration")
    parser.add_argument("--spatial", action="store_true", help="Run spatial px/mm calibration")
    parser.add_argument("--verify", action="store_true", help="Show calibration status")
    parser.add_argument("--board-w", type=int, default=9, help="Checkerboard inner corners (width)")
    parser.add_argument("--board-h", type=int, default=6, help="Checkerboard inner corners (height)")
    parser.add_argument("--square-mm", type=float, default=25.0, help="Checkerboard square size (mm)")
    parser.add_argument("--frames", type=int, default=20, help="Frames to collect for lens cal")
    args = parser.parse_args()

    if not any([args.lens, args.spatial, args.verify]):
        parser.print_help()
        sys.exit(0)

    cfg = load_config()

    if args.verify:
        verify(cfg)

    if args.lens:
        calibrate_lens(cfg, args.board_w, args.board_h, args.square_mm, args.frames)
        cfg = load_config()  # Reload after write

    if args.spatial:
        calibrate_spatial(cfg)
        cfg = load_config()

    if args.lens or args.spatial:
        verify(cfg)
