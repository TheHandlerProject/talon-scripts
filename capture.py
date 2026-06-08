"""
capture.py — Camera interface for AI Metrology Inspection Station
Supports: Iriun (Stage 1), Canon EOS Webcam Utility (Stage 2), industrial (Stage 3)
All stage switching is done via config.yaml only.
"""

import cv2
import threading
import logging
import time
from pathlib import Path

import yaml
import numpy as np

logger = logging.getLogger(__name__)


def load_config(path: str = "config.yaml") -> dict:
    with open(path, "r") as f:
        return yaml.safe_load(f)


class CameraCapture:
    """
    Thread-safe camera wrapper. Runs a background reader thread so the main
    pipeline always has the latest frame without blocking on cap.read().
    """

    def __init__(self, config: dict):
        cam = config["camera"]
        self.source = cam["source"]
        self.width = cam["width"]
        self.height = cam["height"]
        self.fps = cam["fps"]
        self.backend_str = cam.get("backend", "v4l2")

        self._backend = self._resolve_backend(self.backend_str)
        self._cap: cv2.VideoCapture | None = None
        self._frame: np.ndarray | None = None
        self._lock = threading.Lock()
        self._running = False
        self._thread: threading.Thread | None = None
        self._last_frame_time: float = 0.0
        self._frame_count: int = 0
        self._drop_count: int = 0

        # Lens distortion correction
        lens = config.get("lens", {})
        self._correction_enabled = lens.get("correction_enabled", False)
        self._camera_matrix: np.ndarray | None = None
        self._dist_coeffs: np.ndarray | None = None
        self._map1: np.ndarray | None = None
        self._map2: np.ndarray | None = None

        if self._correction_enabled and lens.get("camera_matrix"):
            self._camera_matrix = np.array(lens["camera_matrix"], dtype=np.float64)
            self._dist_coeffs = np.array(lens["dist_coeffs"], dtype=np.float64)
            logger.info("Lens distortion correction enabled")

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def start(self) -> None:
        """Open camera and start background reader thread."""
        logger.info("Opening camera source=%s backend=%s", self.source, self.backend_str)
        self._cap = cv2.VideoCapture(self.source, self._backend)

        if not self._cap.isOpened():
            raise RuntimeError(
                f"Cannot open camera source={self.source}. "
                "Check `v4l2-ctl --list-devices` and confirm Iriun is streaming."
            )

        self._cap.set(cv2.CAP_PROP_FRAME_WIDTH, self.width)
        self._cap.set(cv2.CAP_PROP_FRAME_HEIGHT, self.height)
        self._cap.set(cv2.CAP_PROP_FPS, self.fps)

        # Drain the internal buffer so we don't start on a stale frame
        for _ in range(3):
            self._cap.grab()

        self._running = True
        self._thread = threading.Thread(target=self._reader, daemon=True, name="CameraReader")
        self._thread.start()
        logger.info("Camera reader thread started")

    def stop(self) -> None:
        """Stop background thread and release camera."""
        self._running = False
        if self._thread:
            self._thread.join(timeout=2.0)
        if self._cap:
            self._cap.release()
        logger.info(
            "Camera stopped. frames=%d drops=%d", self._frame_count, self._drop_count
        )

    def read(self) -> np.ndarray | None:
        """Return the most recent frame (BGR). Returns None if not yet available."""
        with self._lock:
            if self._frame is None:
                return None
            return self._frame.copy()

    def is_open(self) -> bool:
        return self._running and self._cap is not None and self._cap.isOpened()

    @property
    def actual_resolution(self) -> tuple[int, int]:
        if self._cap and self._cap.isOpened():
            w = int(self._cap.get(cv2.CAP_PROP_FRAME_WIDTH))
            h = int(self._cap.get(cv2.CAP_PROP_FRAME_HEIGHT))
            return (w, h)
        return (self.width, self.height)

    @property
    def fps_actual(self) -> float:
        """Approximate measured FPS over recent frames."""
        return self._measured_fps

    # ------------------------------------------------------------------
    # Internal
    # ------------------------------------------------------------------

    def _reader(self) -> None:
        """Background thread: continuously grab frames into buffer."""
        self._measured_fps = 0.0
        t_start = time.monotonic()
        local_count = 0

        while self._running:
            ret, frame = self._cap.read()
            if not ret:
                logger.warning("Frame grab failed — camera may have disconnected")
                self._drop_count += 1
                time.sleep(0.05)
                continue

            frame = self._correct_distortion(frame)

            with self._lock:
                self._frame = frame
                self._frame_count += 1

            local_count += 1
            elapsed = time.monotonic() - t_start
            if elapsed >= 2.0:
                self._measured_fps = local_count / elapsed
                local_count = 0
                t_start = time.monotonic()

    def _correct_distortion(self, frame: np.ndarray) -> np.ndarray:
        if not self._correction_enabled or self._camera_matrix is None:
            return frame

        h, w = frame.shape[:2]

        # Build undistort maps once (cached after first frame)
        if self._map1 is None:
            new_matrix, _ = cv2.getOptimalNewCameraMatrix(
                self._camera_matrix, self._dist_coeffs, (w, h), 1, (w, h)
            )
            self._map1, self._map2 = cv2.initUndistortRectifyMap(
                self._camera_matrix,
                self._dist_coeffs,
                None,
                new_matrix,
                (w, h),
                cv2.CV_16SC2,
            )

        return cv2.remap(frame, self._map1, self._map2, cv2.INTER_LINEAR)

    @staticmethod
    def _resolve_backend(name: str) -> int:
        backends = {
            "v4l2": cv2.CAP_V4L2,
            "dshow": cv2.CAP_DSHOW,
            "auto": cv2.CAP_ANY,
            "gstreamer": cv2.CAP_GSTREAMER,
        }
        b = backends.get(name.lower(), cv2.CAP_ANY)
        if b == cv2.CAP_ANY and name.lower() not in ("auto",):
            logger.warning("Unknown backend '%s', falling back to CAP_ANY", name)
        return b


# ------------------------------------------------------------------
# Standalone test
# ------------------------------------------------------------------
if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    cfg = load_config()
    cam = CameraCapture(cfg)
    cam.start()

    logger.info("Camera open. Resolution: %s", cam.actual_resolution)
    logger.info("Reading 30 frames to verify stream...")

    good = 0
    for i in range(30):
        time.sleep(0.1)
        f = cam.read()
        if f is not None:
            good += 1

    logger.info("Got %d/30 frames. Camera OK: %s", good, good > 20)
    cam.stop()
