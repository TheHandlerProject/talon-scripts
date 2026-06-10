"""
app.py — Flask web server for AI Metrology Inspection Station
"""

import io
import json
import logging
import os
import threading
import time
import uuid
from pathlib import Path

import cv2
import yaml
from flask import Flask, Response, jsonify, render_template, request, send_file

from capture import CameraCapture
from inspector import Inspector

logger = logging.getLogger(__name__)

CONFIG_PATH = "config.yaml"
SCANS_DIR   = Path("/home/neo/inspection/scans")


def load_config() -> dict:
    with open(CONFIG_PATH) as f:
        return yaml.safe_load(f)


def create_app() -> Flask:
    cfg = load_config()
    app = Flask(__name__, template_folder="templates", static_folder="static")

    state = {
        "cfg":           cfg,
        "camera":        None,
        "inspector":     None,
        "latest_result": None,
        "latest_frame":  None,
        "latest_edges":  None,
        "frame_lock":    threading.Lock(),
        "result_lock":   threading.Lock(),
        "running":       False,
        "start_time":    time.time(),
        "rotation":      0,          # degrees: 0 / 90 / 180 / 270
        # scan state
        "scan_active":   False,
        "scan_frames":   [],
        "scan_captured": 0,
        "scan_lock":     threading.Lock(),
        "scan_status":   {},         # session_id -> status dict
    }

    _start_pipeline(state)

    # ── Routes ───────────────────────────────────────────────────────────────

    @app.route("/")
    def index():
        return render_template("dashboard.html")

    @app.route("/scan-viewer")
    def scan_viewer():
        return render_template("scan_viewer.html")

    @app.route("/stream")
    def stream():
        return Response(
            _mjpeg_generator(state, "annotated"),
            mimetype="multipart/x-mixed-replace; boundary=frame",
        )

    @app.route("/stream/edges")
    def stream_edges():
        return Response(
            _mjpeg_generator(state, "edges"),
            mimetype="multipart/x-mixed-replace; boundary=frame",
        )

    @app.route("/api/status")
    def api_status():
        cfg = state["cfg"]
        cam = state["camera"]
        uptime = int(time.time() - state["start_time"])
        return jsonify({
            "ok":           state["running"],
            "uptime_s":     uptime,
            "stage":        cfg.get("stage", 1),
            "camera_open":  cam.is_open() if cam else False,
            "calibrated":   cfg["optics"].get("calibrated", False),
            "px_per_mm":    cfg["optics"].get("px_per_mm"),
            "px_per_inch":  cfg["optics"].get("px_per_inch"),
            "default_unit": cfg["measurement"].get("default_unit", "inches"),
            "canny_low":    cfg["edge_detection"]["canny_low"],
            "canny_high":   cfg["edge_detection"]["canny_high"],
            "server_fps_cap": cfg["server"].get("stream_fps_cap", 15),
            "rotation":     state["rotation"],
        })

    @app.route("/api/results")
    def api_results():
        with state["result_lock"]:
            r = state["latest_result"]
        if r is None:
            return jsonify({"error": "no results yet"}), 503
        from dataclasses import asdict
        return jsonify(asdict(r))

    @app.route("/api/unit/<unit>")
    def api_set_unit(unit: str):
        if unit not in ("inches", "mm"):
            return jsonify({"error": "unit must be 'inches' or 'mm'"}), 400
        state["cfg"]["measurement"]["default_unit"] = unit
        state["inspector"].default_unit = unit
        _persist_config(state["cfg"])
        return jsonify({"unit": unit})

    @app.route("/api/canny", methods=["POST"])
    def api_canny():
        data = request.get_json(force=True)
        low  = data.get("low")
        high = data.get("high")
        if low is not None:
            state["cfg"]["edge_detection"]["canny_low"] = int(low)
            state["inspector"].canny_low = int(low)
        if high is not None:
            state["cfg"]["edge_detection"]["canny_high"] = int(high)
            state["inspector"].canny_high = int(high)
        _persist_config(state["cfg"])
        return jsonify({
            "canny_low":  state["cfg"]["edge_detection"]["canny_low"],
            "canny_high": state["cfg"]["edge_detection"]["canny_high"],
        })

    @app.route("/api/snapshot")
    def api_snapshot():
        with state["frame_lock"]:
            frame = state["latest_frame"]
        if frame is None:
            return jsonify({"error": "no frame available"}), 503
        _, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, 95])
        return send_file(
            io.BytesIO(buf.tobytes()),
            mimetype="image/jpeg",
            as_attachment=True,
            download_name=f"snapshot_{int(time.time())}.jpg",
        )

    @app.route("/api/calibrate/spatial", methods=["POST"])
    def api_calibrate_spatial():
        data = request.get_json(force=True)
        try:
            px_dist   = float(data["px_dist"])
            real_dist = float(data["real_dist"])
            unit      = data.get("unit", "mm").lower()
        except (KeyError, ValueError) as e:
            return jsonify({"error": f"Bad payload: {e}"}), 400

        real_dist_mm = real_dist * 25.4 if unit in ("in", "inch", "inches") else real_dist
        px_per_mm    = px_dist / real_dist_mm
        px_per_inch  = px_per_mm * 25.4

        state["cfg"]["optics"]["px_per_mm"]   = round(px_per_mm, 6)
        state["cfg"]["optics"]["px_per_inch"] = round(px_per_inch, 6)
        state["cfg"]["optics"]["calibrated"]  = True
        _persist_config(state["cfg"])
        state["inspector"].reload_calibration(px_per_mm)

        return jsonify({
            "calibrated":  True,
            "px_per_mm":   round(px_per_mm, 6),
            "px_per_inch": round(px_per_inch, 6),
        })

    # ── Rotate ───────────────────────────────────────────────────────────────

    @app.route("/api/rotate", methods=["POST"])
    def api_rotate():
        data = request.get_json(force=True)
        direction = data.get("direction", "cw")
        if direction == "cw":
            state["rotation"] = (state["rotation"] + 90) % 360
        else:
            state["rotation"] = (state["rotation"] - 90) % 360
        return jsonify({"rotation": state["rotation"]})

    # ── Scan endpoints ───────────────────────────────────────────────────────

    @app.route("/api/scan/capture", methods=["POST"])
    def api_scan_capture():
        with state["frame_lock"]:
            frame = state["latest_frame"]
        if frame is None:
            return jsonify({"error": "no frame available"}), 503
        with state["scan_lock"]:
            state["scan_frames"].append(frame.copy())
            state["scan_captured"] += 1
            count = state["scan_captured"]
        small = cv2.resize(frame, (160, 120))
        _, buf = cv2.imencode(".jpg", small, [cv2.IMWRITE_JPEG_QUALITY, 70])
        import base64
        thumb = "data:image/jpeg;base64," + base64.b64encode(buf).decode()
        return jsonify({"ok": True, "frames_captured": count, "thumbnail": thumb})

    @app.route("/api/scan/clear", methods=["POST"])
    def api_scan_clear():
        with state["scan_lock"]:
            state["scan_frames"]   = []
            state["scan_captured"] = 0
            state["scan_active"]   = False
        return jsonify({"ok": True})

    @app.route("/api/scan/start", methods=["POST"])
    def api_scan_start():
        data     = request.get_json(force=True) or {}
        count    = int(data.get("count", 10))
        interval = float(data.get("interval", 0.5))

        with state["scan_lock"]:
            if state["scan_active"]:
                return jsonify({"error": "scan already running"}), 409
            state["scan_active"]   = True
            state["scan_frames"]   = []
            state["scan_captured"] = 0

        SCANS_DIR.mkdir(parents=True, exist_ok=True)

        def capture_loop():
            for _ in range(count):
                if not state["scan_active"]:
                    break
                with state["frame_lock"]:
                    frame = state["latest_frame"]
                if frame is not None:
                    with state["scan_lock"]:
                        state["scan_frames"].append(frame.copy())
                        state["scan_captured"] += 1
                time.sleep(interval)
            with state["scan_lock"]:
                state["scan_active"] = False

        t = threading.Thread(target=capture_loop, daemon=True, name="ScanCapture")
        t.start()
        return jsonify({"ok": True, "count": count, "interval": interval})

    @app.route("/api/scan/stop", methods=["POST"])
    def api_scan_stop():
        with state["scan_lock"]:
            state["scan_active"] = False
            captured = state["scan_captured"]
        return jsonify({"ok": True, "frames_captured": captured})

    @app.route("/api/scan/status")
    def api_scan_status():
        with state["scan_lock"]:
            return jsonify({
                "active":          state["scan_active"],
                "frames_captured": state["scan_captured"],
            })

    @app.route("/api/scan/reconstruct", methods=["POST"])
    def api_scan_reconstruct():
        with state["scan_lock"]:
            frames   = list(state["scan_frames"])
            captured = state["scan_captured"]

        if len(frames) < 3:
            return jsonify({"error": f"Need at least 3 frames, have {len(frames)}"}), 400

        scan_id = f"scan_{int(time.time())}"

        # Save frames immediately
        img_dir = SCANS_DIR / scan_id / "images"
        img_dir.mkdir(parents=True, exist_ok=True)
        for i, f in enumerate(frames):
            cv2.imwrite(str(img_dir / f"frame_{i:04d}.jpg"), f,
                        [cv2.IMWRITE_JPEG_QUALITY, 95])

        state["scan_status"][scan_id] = {
            "status": "processing",
            "frames": len(frames),
            "scan_id": scan_id,
        }

        def do_reconstruct():
            try:
                from reconstruct import run_reconstruction
                result = run_reconstruction(frames, scan_id)
                state["scan_status"][scan_id].update({
                    "status":      "complete" if result["ok"] else "error",
                    "ply":         result.get("ply"),
                    "point_count": result.get("points", 0),
                    "error":       result.get("error"),
                })
            except Exception as e:
                state["scan_status"][scan_id].update({
                    "status": "error",
                    "error":  str(e),
                })

        t = threading.Thread(target=do_reconstruct, daemon=True, name="Reconstruct")
        t.start()

        return jsonify({"ok": True, "scan_id": scan_id, "frames": len(frames)})

    @app.route("/api/scan/<scan_id>/status")
    def api_scan_session_status(scan_id: str):
        s = state["scan_status"].get(scan_id)
        if s is None:
            return jsonify({"error": "unknown scan_id"}), 404
        return jsonify(s)

    @app.route("/api/scan/<scan_id>/pointcloud")
    def api_scan_pointcloud(scan_id: str):
        ply = SCANS_DIR / scan_id / f"{scan_id}.ply"
        if not ply.exists():
            return jsonify({"error": "point cloud not found"}), 404
        return send_file(str(ply), as_attachment=True,
                         download_name=f"{scan_id}.ply")

    return app


# ── Pipeline ─────────────────────────────────────────────────────────────────

def _start_pipeline(state: dict) -> None:
    cfg = state["cfg"]
    cam = CameraCapture(cfg)
    cam.start()
    inspector = Inspector(cfg)
    state["camera"]    = cam
    state["inspector"] = inspector
    state["running"]   = True

    def pipeline_loop():
        fps_cap  = cfg["server"].get("stream_fps_cap", 15)
        interval = 1.0 / fps_cap

        while state["running"]:
            t0    = time.monotonic()
            frame = cam.read()
            if frame is None:
                time.sleep(0.02)
                continue

            # Apply rotation if set
            rot = state.get("rotation", 0)
            if rot == 90:
                frame = cv2.rotate(frame, cv2.ROTATE_90_CLOCKWISE)
            elif rot == 180:
                frame = cv2.rotate(frame, cv2.ROTATE_180)
            elif rot == 270:
                frame = cv2.rotate(frame, cv2.ROTATE_90_COUNTERCLOCKWISE)

            annotated, result = inspector.process(frame)
            edges = inspector.get_edge_frame(frame)

            with state["frame_lock"]:
                state["latest_frame"] = annotated
                state["latest_edges"] = edges
            with state["result_lock"]:
                state["latest_result"] = result

            elapsed = time.monotonic() - t0
            sleep_t = interval - elapsed
            if sleep_t > 0:
                time.sleep(sleep_t)

    t = threading.Thread(target=pipeline_loop, daemon=True, name="Pipeline")
    t.start()
    logger.info("Pipeline thread started")


def _mjpeg_generator(state: dict, mode: str = "annotated"):
    quality      = state["cfg"]["server"].get("mjpeg_quality", 80)
    encode_params = [cv2.IMWRITE_JPEG_QUALITY, quality]

    while True:
        with state["frame_lock"]:
            frame = state["latest_edges"] if mode == "edges" else state["latest_frame"]

        if frame is None:
            time.sleep(0.05)
            continue

        ret, buf = cv2.imencode(".jpg", frame, encode_params)
        if not ret:
            continue

        yield (
            b"--frame\r\n"
            b"Content-Type: image/jpeg\r\n\r\n"
            + buf.tobytes()
            + b"\r\n"
        )


def _persist_config(cfg: dict) -> None:
    try:
        with open(CONFIG_PATH, "w") as f:
            yaml.dump(cfg, f, default_flow_style=False, sort_keys=False)
    except Exception as e:
        logger.warning("Could not persist config: %s", e)


# ── Entry point ───────────────────────────────────────────────────────────────

if __name__ == "__main__":
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
    )
    cfg    = load_config()
    server = cfg["server"]
    app    = create_app()
    logger.info("Starting inspection server on http://%s:%d",
                server["host"], server["port"])
    app.run(
        host=server["host"],
        port=server["port"],
        debug=server.get("debug", False),
        threaded=True,
        use_reloader=False,
    )
