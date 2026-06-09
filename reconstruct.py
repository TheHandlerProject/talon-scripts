"""
reconstruct.py — SfM point cloud reconstruction using pycolmap
Called from app.py via /api/scan/reconstruct
"""
import os
import time
import logging
import threading
import numpy as np
import cv2
import pycolmap
from pathlib import Path

logger = logging.getLogger(__name__)

WORK_DIR = Path("/home/neo/inspection/scans")


def save_frames(frames: list, scan_id: str) -> Path:
    """Save numpy frames to disk as JPEGs for pycolmap."""
    img_dir = WORK_DIR / scan_id / "images"
    img_dir.mkdir(parents=True, exist_ok=True)
    for i, frame in enumerate(frames):
        path = img_dir / f"frame_{i:04d}.jpg"
        cv2.imwrite(str(path), frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
    logger.info("Saved %d frames to %s", len(frames), img_dir)
    return img_dir


def run_reconstruction(frames: list, scan_id: str, status_cb=None) -> dict:
    """
    Full SfM pipeline:
      1. Save frames to disk
      2. Extract features
      3. Match features
      4. Reconstruct sparse model
      5. Export .ply
    Returns dict with status and output path.
    """
    if len(frames) < 3:
        return {"ok": False, "error": "Need at least 3 frames for reconstruction"}

    workspace = WORK_DIR / scan_id
    workspace.mkdir(parents=True, exist_ok=True)

    db_path = workspace / "database.db"
    img_dir = save_frames(frames, scan_id)
    sparse_dir = workspace / "sparse"
    sparse_dir.mkdir(exist_ok=True)
    ply_path = workspace / f"{scan_id}.ply"

    def cb(msg):
        logger.info(msg)
        if status_cb:
            status_cb(msg)

    try:
        cb("Extracting features...")
        pycolmap.extract_features(
            database_path=db_path,
            image_path=img_dir,
            camera_mode=pycolmap.CameraMode.SINGLE,
        )

        cb("Matching features...")
        pycolmap.match_exhaustive(database_path=db_path)

        cb("Running sparse reconstruction...")
        maps = pycolmap.incremental_mapping(
            database_path=db_path,
            image_path=img_dir,
            output_path=sparse_dir,
        )

        if not maps:
            return {"ok": False, "error": "Reconstruction failed — not enough feature matches. Try more frames with more overlap."}

        cb("Exporting point cloud...")
        # Use the largest reconstruction
        best = max(maps.values(), key=lambda r: r.num_points3D())
        best.export_PLY(str(ply_path))

        cb(f"Done. {best.num_points3D()} points reconstructed.")
        return {
            "ok": True,
            "ply": str(ply_path),
            "points": best.num_points3D(),
            "images_registered": best.num_reg_images(),
            "scan_id": scan_id,
        }

    except Exception as e:
        logger.error("Reconstruction error: %s", e)
        return {"ok": False, "error": str(e)}
