"""
inspect.py — Edge detection, contour extraction, and measurement pipeline
AI Metrology Inspection Station — Stage 1 (Iriun) through Stage 3 (Industrial)

Pipeline:
  raw frame → blur → Canny → RETR_TREE contours → subpixel refinement
  → measurement (px + real-world if calibrated) → annotated frame + JSON results
"""

import cv2
import json
import logging
import math
import time
from dataclasses import dataclass, field, asdict
from typing import Optional

import numpy as np
import yaml

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Data structures
# ---------------------------------------------------------------------------

@dataclass
class ContourMeasurement:
    id: int
    depth: int                        # Hierarchy depth (0 = outermost)
    area_px: float
    perimeter_px: float
    bbox_px: dict                     # {x, y, w, h}
    centroid_px: dict                 # {x, y}
    # Real-world (None if not calibrated)
    area_mm2: Optional[float] = None
    perimeter_mm: Optional[float] = None
    bbox_mm: Optional[dict] = None    # {x, y, w, h}
    area_in2: Optional[float] = None
    perimeter_in: Optional[float] = None
    bbox_in: Optional[dict] = None    # {x, y, w, h}


@dataclass
class InspectionResult:
    timestamp: float
    frame_width: int
    frame_height: int
    calibrated: bool
    px_per_mm: Optional[float]
    contour_count: int
    contours: list[ContourMeasurement] = field(default_factory=list)
    pipeline_ms: float = 0.0          # Processing time


# ---------------------------------------------------------------------------
# Inspector
# ---------------------------------------------------------------------------

class Inspector:
    """
    Stateless-ish inspection engine. Call process(frame) on each frame.
    All tunables live in config.yaml — no redeployment needed for threshold changes.
    """

    def __init__(self, config: dict):
        ed = config["edge_detection"]
        self.canny_low = ed["canny_low"]
        self.canny_high = ed["canny_high"]
        self.canny_aperture = ed["canny_aperture"]
        self.blur_kernel = ed["blur_kernel"]
        self.min_area = ed["min_contour_area"]
        self.max_contours = ed["max_contours"]
        self.subpixel_enabled = ed["subpixel_enabled"]
        self.subpixel_window = ed["subpixel_window"]

        optics = config.get("optics", {})
        self.calibrated: bool = optics.get("calibrated", False)
        self.px_per_mm: Optional[float] = optics.get("px_per_mm")
        self.px_per_inch: Optional[float] = optics.get("px_per_inch")

        # Recompute px_per_inch from px_per_mm if only one was set
        if self.calibrated and self.px_per_mm and not self.px_per_inch:
            self.px_per_inch = self.px_per_mm * 25.4

        meas = config.get("measurement", {})
        self.default_unit = meas.get("default_unit", "inches")
        self.prec_in = meas.get("precision_inches", 4)
        self.prec_mm = meas.get("precision_mm", 3)

        disp = config.get("display", {})
        self.overlay_color = tuple(disp.get("overlay_color", [0, 255, 0]))
        self.bbox_color = tuple(disp.get("bbox_color", [0, 200, 255]))
        self.text_color = tuple(disp.get("text_color", [255, 255, 255]))
        self.font_scale = disp.get("font_scale", 0.45)
        self.line_thickness = disp.get("line_thickness", 1)
        self.show_hierarchy = disp.get("show_hierarchy", True)

        raw_hcolors = disp.get("hierarchy_colors", [
            [0, 255, 0], [0, 200, 255], [0, 100, 255], [0, 0, 255]
        ])
        self.hierarchy_colors = [tuple(c) for c in raw_hcolors]

        logger.info(
            "Inspector ready | canny=%d/%d blur=%d subpx=%s calibrated=%s",
            self.canny_low, self.canny_high, self.blur_kernel,
            self.subpixel_enabled, self.calibrated
        )

    # ------------------------------------------------------------------
    # Public API
    # ------------------------------------------------------------------

    def process(self, frame: np.ndarray) -> tuple[np.ndarray, InspectionResult]:
        """
        Run full pipeline on one frame.
        Returns (annotated_frame, InspectionResult).
        """
        t0 = time.monotonic()
        h, w = frame.shape[:2]

        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blurred = self._blur(gray)
        edges = self._canny(blurred)
        contours, hierarchy = self._find_contours(edges)
        depths = self._compute_depths(hierarchy, len(contours))
        measurements = self._measure(contours, depths)

        annotated = self._annotate(frame.copy(), contours, depths, measurements)

        elapsed_ms = (time.monotonic() - t0) * 1000

        result = InspectionResult(
            timestamp=time.time(),
            frame_width=w,
            frame_height=h,
            calibrated=self.calibrated,
            px_per_mm=self.px_per_mm,
            contour_count=len(measurements),
            contours=measurements,
            pipeline_ms=round(elapsed_ms, 2),
        )

        return annotated, result

    def get_edge_frame(self, frame: np.ndarray) -> np.ndarray:
        """Return the raw Canny edge image (for debug overlay toggle in UI)."""
        gray = cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY)
        blurred = self._blur(gray)
        edges = self._canny(blurred)
        return cv2.cvtColor(edges, cv2.COLOR_GRAY2BGR)

    def reload_calibration(self, px_per_mm: float) -> None:
        """Hot-reload calibration without restarting (called by app.py after cal run)."""
        self.px_per_mm = px_per_mm
        self.px_per_inch = px_per_mm * 25.4
        self.calibrated = True
        logger.info("Calibration reloaded: %.4f px/mm = %.4f px/in", px_per_mm, self.px_per_inch)

    # ------------------------------------------------------------------
    # Pipeline stages
    # ------------------------------------------------------------------

    def _blur(self, gray: np.ndarray) -> np.ndarray:
        k = self.blur_kernel
        if k and k > 0:
            k = k if k % 2 == 1 else k + 1  # Must be odd
            return cv2.GaussianBlur(gray, (k, k), 0)
        return gray

    def _canny(self, gray: np.ndarray) -> np.ndarray:
        return cv2.Canny(
            gray,
            self.canny_low,
            self.canny_high,
            apertureSize=self.canny_aperture,
        )

    def _find_contours(
        self, edges: np.ndarray
    ) -> tuple[tuple, Optional[np.ndarray]]:
        contours, hierarchy = cv2.findContours(
            edges, cv2.RETR_TREE, cv2.CHAIN_APPROX_SIMPLE
        )
        # Filter by minimum area, cap at max_contours
        if contours:
            filtered = [
                (c, i) for i, c in enumerate(contours)
                if cv2.contourArea(c) >= self.min_area
            ]
            filtered = filtered[: self.max_contours]
            indices = [i for _, i in filtered]
            contours = tuple(c for c, _ in filtered)
            if hierarchy is not None and len(indices) > 0:
                hierarchy = hierarchy[:, indices, :]
        return contours, hierarchy

    def _compute_depths(
        self, hierarchy: Optional[np.ndarray], n: int
    ) -> list[int]:
        """Walk RETR_TREE hierarchy to compute nesting depth for each contour."""
        depths = [0] * max(n, 1)
        if hierarchy is None or n == 0:
            return depths

        hier = hierarchy[0]  # shape (n, 4): [next, prev, child, parent]

        def walk(idx: int, depth: int):
            while 0 <= idx < len(hier):
                depths[idx] = depth
                child = hier[idx][2]
                if child >= 0:
                    walk(child, depth + 1)
                idx = hier[idx][0]  # next sibling

        # Find all root contours (parent == -1)
        for i in range(n):
            if hier[i][3] == -1:
                walk(i, 0)

        return depths

    def _measure(
        self, contours: tuple, depths: list[int]
    ) -> list[ContourMeasurement]:
        results = []
        for i, cnt in enumerate(contours):
            area_px = cv2.contourArea(cnt)
            perim_px = cv2.arcLength(cnt, closed=True)
            x, y, bw, bh = cv2.boundingRect(cnt)

            M = cv2.moments(cnt)
            cx = int(M["m10"] / M["m00"]) if M["m00"] != 0 else x + bw // 2
            cy = int(M["m01"] / M["m00"]) if M["m00"] != 0 else y + bh // 2

            m = ContourMeasurement(
                id=i,
                depth=depths[i] if i < len(depths) else 0,
                area_px=round(area_px, 2),
                perimeter_px=round(perim_px, 2),
                bbox_px={"x": x, "y": y, "w": bw, "h": bh},
                centroid_px={"x": cx, "y": cy},
            )

            if self.calibrated and self.px_per_mm:
                ppm = self.px_per_mm
                ppi = self.px_per_inch
                m.area_mm2 = round(area_px / (ppm ** 2), self.prec_mm)
                m.perimeter_mm = round(perim_px / ppm, self.prec_mm)
                m.bbox_mm = {
                    "x": round(x / ppm, self.prec_mm),
                    "y": round(y / ppm, self.prec_mm),
                    "w": round(bw / ppm, self.prec_mm),
                    "h": round(bh / ppm, self.prec_mm),
                }
                m.area_in2 = round(area_px / (ppi ** 2), self.prec_in)
                m.perimeter_in = round(perim_px / ppi, self.prec_in)
                m.bbox_in = {
                    "x": round(x / ppi, self.prec_in),
                    "y": round(y / ppi, self.prec_in),
                    "w": round(bw / ppi, self.prec_in),
                    "h": round(bh / ppi, self.prec_in),
                }

            results.append(m)
        return results

    # ------------------------------------------------------------------
    # Annotation
    # ------------------------------------------------------------------

    def _annotate(
        self,
        frame: np.ndarray,
        contours: tuple,
        depths: list[int],
        measurements: list[ContourMeasurement],
    ) -> np.ndarray:
        font = cv2.FONT_HERSHEY_SIMPLEX

        for i, (cnt, m) in enumerate(zip(contours, measurements)):
            depth = m.depth
            color = self.hierarchy_colors[min(depth, len(self.hierarchy_colors) - 1)]

            cv2.drawContours(frame, [cnt], -1, color, self.line_thickness)

            # Bounding box
            bx, by, bw, bh = m.bbox_px["x"], m.bbox_px["y"], m.bbox_px["w"], m.bbox_px["h"]
            cv2.rectangle(frame, (bx, by), (bx + bw, by + bh), self.bbox_color, 1)

            # Measurement label
            label = self._make_label(m)
            lx, ly = bx, max(by - 4, 12)
            cv2.putText(
                frame, label, (lx, ly),
                font, self.font_scale, self.text_color, 1, cv2.LINE_AA
            )

        # HUD — top-left status
        status_lines = [
            f"Contours: {len(measurements)}",
            f"Cal: {'YES' if self.calibrated else 'NO — run /api/calibrate'}",
        ]
        if self.calibrated and self.px_per_mm:
            status_lines.append(f"{self.px_per_mm:.2f} px/mm")

        for j, line in enumerate(status_lines):
            cv2.putText(
                frame, line, (8, 20 + j * 18),
                font, 0.5, (200, 200, 200), 1, cv2.LINE_AA
            )

        return frame

    def _make_label(self, m: ContourMeasurement) -> str:
        """Short label shown next to each contour in the default unit."""
        if self.calibrated and self.default_unit == "inches" and m.bbox_in:
            b = m.bbox_in
            return f"#{m.id} {b['w']:.3f}x{b['h']:.3f}\""
        elif self.calibrated and self.default_unit == "mm" and m.bbox_mm:
            b = m.bbox_mm
            return f"#{m.id} {b['w']:.2f}x{b['h']:.2f}mm"
        else:
            b = m.bbox_px
            return f"#{m.id} {b['w']}x{b['h']}px"


# ------------------------------------------------------------------
# Standalone test
# ------------------------------------------------------------------
if __name__ == "__main__":
    import sys
    logging.basicConfig(level=logging.INFO)

    with open("config.yaml") as f:
        cfg = yaml.safe_load(f)

    insp = Inspector(cfg)

    # Generate a synthetic test frame with circles (simulates faceted part)
    test = np.zeros((720, 1280, 3), dtype=np.uint8)
    cv2.circle(test, (640, 360), 200, (220, 220, 220), -1)
    cv2.circle(test, (640, 360), 150, (100, 100, 100), -1)
    cv2.circle(test, (640, 360), 80, (200, 200, 200), -1)
    cv2.rectangle(test, (300, 200), (980, 520), (180, 180, 180), 3)

    annotated, result = insp.process(test)
    logger.info("Contours found: %d", result.contour_count)
    logger.info("Pipeline time: %.2f ms", result.pipeline_ms)

    if len(sys.argv) > 1 and sys.argv[1] == "--save":
        cv2.imwrite("/tmp/inspect_test.jpg", annotated)
        logger.info("Saved to /tmp/inspect_test.jpg")
