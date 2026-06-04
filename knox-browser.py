#!/usr/bin/env python3
"""
Knox Browser Automation Server
Gives Knox full headless browser control + web deploy capability
Runs on Talon at port 8767
Security/system changes are queued — web/deploy actions execute freely
"""

import asyncio
import base64
import json
import os
import random
import shutil
import subprocess
import tempfile
import time
from pathlib import Path
from typing import Optional

from fastapi import FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from pydantic import BaseModel
from playwright.async_api import async_playwright, Browser, BrowserContext, Page
from cryptography.fernet import Fernet

# ─── CONFIG ──────────────────────────────────────────────
VAULT_DIR  = Path("/home/neo/.knox-vault")
VAULT_FILE = VAULT_DIR / "secrets.enc"
KEY_FILE   = VAULT_DIR / "vault.key"
QUEUE_FILE = Path("/home/neo/knox-logs/action-queue.json")
SCREENSHOTS_DIR = Path("/home/neo/knox-logs/screenshots")
WEB_ROOT   = Path("/var/www/html")
GITHUB_RAW = "https://api.github.com"

VAULT_DIR.mkdir(parents=True, exist_ok=True)
SCREENSHOTS_DIR.mkdir(parents=True, exist_ok=True)
QUEUE_FILE.parent.mkdir(parents=True, exist_ok=True)

# ─── SECURITY CLASSIFICATION ─────────────────────────────
# These action types always go to the approval queue
QUEUED_ACTIONS = {
    "firewall", "iptables", "ufw", "systemctl", "apt", "dpkg",
    "ssh_config", "cron_system", "port_forward", "network_change",
    "service_install", "kernel", "sudo_config"
}

# ─── VAULT ───────────────────────────────────────────────
def get_or_create_key() -> bytes:
    if KEY_FILE.exists():
        return KEY_FILE.read_bytes()
    key = Fernet.generate_key()
    KEY_FILE.write_bytes(key)
    KEY_FILE.chmod(0o600)
    return key

def vault_get(name: str) -> Optional[str]:
    if not VAULT_FILE.exists():
        return None
    key = get_or_create_key()
    f = Fernet(key)
    try:
        data = json.loads(f.decrypt(VAULT_FILE.read_bytes()).decode())
        return data.get(name)
    except Exception:
        return None

def vault_set(name: str, value: str):
    key = get_or_create_key()
    f = Fernet(key)
    data = {}
    if VAULT_FILE.exists():
        try:
            data = json.loads(f.decrypt(VAULT_FILE.read_bytes()).decode())
        except Exception:
            pass
    data[name] = value
    VAULT_FILE.write_bytes(f.encrypt(json.dumps(data).encode()))
    VAULT_FILE.chmod(0o600)

# ─── ACTION QUEUE ─────────────────────────────────────────
def queue_action(action_type: str, description: str, payload: dict) -> str:
    queue = []
    if QUEUE_FILE.exists():
        try:
            queue = json.loads(QUEUE_FILE.read_text())
        except Exception:
            pass
    action_id = f"act_{int(time.time())}_{random.randint(1000,9999)}"
    queue.append({
        "id": action_id,
        "type": action_type,
        "description": description,
        "payload": payload,
        "status": "pending",
        "timestamp": time.strftime("%Y-%m-%d %H:%M:%S")
    })
    QUEUE_FILE.write_text(json.dumps(queue, indent=2))
    return action_id

def is_security_action(action_type: str) -> bool:
    return any(q in action_type.lower() for q in QUEUED_ACTIONS)

# ─── BROWSER POOL ─────────────────────────────────────────
_playwright = None
_browser: Optional[Browser] = None

async def get_browser() -> Browser:
    global _playwright, _browser
    if _browser is None or not _browser.is_connected():
        _playwright = await async_playwright().start()
        _browser = await _playwright.chromium.launch(
            headless=True,
            args=["--no-sandbox", "--disable-setuid-sandbox",
                  "--disable-dev-shm-usage", "--disable-gpu"]
        )
    return _browser

async def new_context() -> BrowserContext:
    browser = await get_browser()
    return await browser.new_context(
        viewport={"width": 1280, "height": 900},
        user_agent="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
    )

async def screenshot_b64(page: Page) -> str:
    ts = int(time.time())
    path = SCREENSHOTS_DIR / f"screenshot_{ts}.png"
    await page.screenshot(path=str(path), full_page=False)
    data = Path(path).read_bytes()
    # Clean up old screenshots (keep last 20)
    shots = sorted(SCREENSHOTS_DIR.glob("*.png"))
    for old in shots[:-20]:
        old.unlink(missing_ok=True)
    return base64.b64encode(data).decode()

# ─── FASTAPI APP ──────────────────────────────────────────
app = FastAPI(title="Knox Browser API", version="2.0")
app.add_middleware(CORSMiddleware, allow_origins=["*"],
                   allow_methods=["*"], allow_headers=["*"])

# ─── MODELS ───────────────────────────────────────────────
class NavigateRequest(BaseModel):
    url: str
    wait_for: Optional[str] = "networkidle"

class ClickRequest(BaseModel):
    selector: str
    session_id: Optional[str] = None

class TypeRequest(BaseModel):
    selector: str
    text: str
    session_id: Optional[str] = None

class EvalRequest(BaseModel):
    script: str
    session_id: Optional[str] = None

class DeployRequest(BaseModel):
    html: str
    filename: str
    destination: str = "webroot"  # webroot | github
    repo: Optional[str] = None
    branch: str = "main"
    commit_message: Optional[str] = None

class TestPageRequest(BaseModel):
    html: str
    filename: str = "index.html"

class VaultRequest(BaseModel):
    name: str
    value: str

class SystemActionRequest(BaseModel):
    action_type: str
    description: str
    command: str

class FullPageRequest(BaseModel):
    url: str

# Active sessions: session_id -> (context, page)
sessions: dict = {}

async def get_or_create_session(session_id: Optional[str] = None):
    sid = session_id or f"default_{int(time.time())}"
    if sid not in sessions:
        ctx = await new_context()
        page = await ctx.new_page()
        sessions[sid] = (ctx, page)
    return sid, sessions[sid][1]

# ─── ROUTES ───────────────────────────────────────────────

@app.get("/health")
async def health():
    return {"status": "ok", "service": "knox-browser", "version": "2.0"}

@app.post("/navigate")
async def navigate(req: NavigateRequest):
    """Navigate to a URL, return screenshot + page title"""
    sid, page = await get_or_create_session()
    try:
        await page.goto(req.url, wait_until=req.wait_for, timeout=30000)
        title = await page.title()
        shot = await screenshot_b64(page)
        return {
            "session_id": sid,
            "url": page.url,
            "title": title,
            "screenshot": shot,
            "status": "ok"
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}

@app.post("/click")
async def click(req: ClickRequest):
    sid, page = await get_or_create_session(req.session_id)
    try:
        await page.click(req.selector, timeout=10000)
        await page.wait_for_load_state("networkidle", timeout=10000)
        shot = await screenshot_b64(page)
        return {"session_id": sid, "screenshot": shot, "status": "ok"}
    except Exception as e:
        return {"status": "error", "error": str(e)}

@app.post("/type")
async def type_text(req: TypeRequest):
    sid, page = await get_or_create_session(req.session_id)
    try:
        await page.fill(req.selector, req.text)
        shot = await screenshot_b64(page)
        return {"session_id": sid, "screenshot": shot, "status": "ok"}
    except Exception as e:
        return {"status": "error", "error": str(e)}

@app.post("/eval")
async def evaluate(req: EvalRequest):
    """Run JS in the page context"""
    sid, page = await get_or_create_session(req.session_id)
    try:
        result = await page.evaluate(req.script)
        return {"session_id": sid, "result": result, "status": "ok"}
    except Exception as e:
        return {"status": "error", "error": str(e)}

@app.get("/screenshot")
async def get_screenshot(session_id: Optional[str] = None):
    sid, page = await get_or_create_session(session_id)
    shot = await screenshot_b64(page)
    return {"session_id": sid, "screenshot": shot}

@app.post("/close-session")
async def close_session(session_id: str):
    if session_id in sessions:
        ctx, _ = sessions.pop(session_id)
        await ctx.close()
    return {"status": "closed"}

@app.post("/test-page")
async def test_page(req: TestPageRequest):
    """
    Spin up a temp HTTP server, load the page, take screenshot, tear down.
    No persistence — temp only.
    """
    port = random.randint(9100, 9900)
    tmpdir = tempfile.mkdtemp(prefix="knox_test_")
    try:
        # Write HTML to temp dir
        page_path = Path(tmpdir) / req.filename
        page_path.write_text(req.html)

        # Start temp server
        proc = subprocess.Popen(
            ["python3", "-m", "http.server", str(port)],
            cwd=tmpdir, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )
        await asyncio.sleep(1)  # let it start

        # Load and screenshot
        ctx = await new_context()
        page = await ctx.new_page()
        await page.goto(f"http://localhost:{port}/{req.filename}",
                        wait_until="networkidle", timeout=15000)
        shot = await screenshot_b64(page)
        title = await page.title()
        await ctx.close()

        return {
            "status": "ok",
            "title": title,
            "screenshot": shot,
            "preview_url": f"http://localhost:{port}/{req.filename}",
            "note": "Temp server — screenshot only, no persistence"
        }
    except Exception as e:
        return {"status": "error", "error": str(e)}
    finally:
        proc.terminate()
        shutil.rmtree(tmpdir, ignore_errors=True)

@app.post("/deploy")
async def deploy_page(req: DeployRequest):
    """
    Deploy HTML to webroot or GitHub.
    Web deploys execute freely.
    """
    if req.destination == "webroot":
        target = WEB_ROOT / req.filename
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(req.html)
        return {
            "status": "deployed",
            "path": str(target),
            "url": f"http://100.114.75.23/{req.filename}"
        }

    elif req.destination == "github":
        token = vault_get("github_pat")
        if not token:
            raise HTTPException(status_code=401,
                detail="No GitHub PAT in vault. POST /vault first.")

        repo = req.repo or "TheHandlerProject/talon-scripts"
        commit_msg = req.commit_message or f"Knox: update {req.filename}"

        # Use GitHub API to create/update file
        import urllib.request
        import urllib.error

        # Get current file SHA if exists (needed for update)
        api_url = f"https://api.github.com/repos/{repo}/contents/{req.filename}"
        headers = {
            "Authorization": f"token {token}",
            "Accept": "application/vnd.github.v3+json",
            "Content-Type": "application/json"
        }

        sha = None
        try:
            req2 = urllib.request.Request(api_url, headers=headers)
            with urllib.request.urlopen(req2) as r:
                sha = json.loads(r.read())["sha"]
        except urllib.error.HTTPError as e:
            if e.code != 404:
                raise

        # Push file
        content_b64 = base64.b64encode(req.html.encode()).decode()
        payload = {"message": commit_msg, "content": content_b64,
                   "branch": req.branch}
        if sha:
            payload["sha"] = sha

        data = json.dumps(payload).encode()
        push_req = urllib.request.Request(api_url, data=data,
                                           headers=headers, method="PUT")
        with urllib.request.urlopen(push_req) as r:
            result = json.loads(r.read())

        return {
            "status": "pushed",
            "repo": repo,
            "file": req.filename,
            "commit": result.get("commit", {}).get("sha", "")[:8],
            "url": f"https://github.com/{repo}/blob/{req.branch}/{req.filename}"
        }

@app.post("/vault")
async def store_secret(req: VaultRequest):
    """Store a secret in the encrypted vault. Called once per credential."""
    vault_set(req.name, req.value)
    return {"status": "stored", "name": req.name, "note": "Encrypted at rest"}

@app.get("/vault/keys")
async def list_vault_keys():
    """List what's in the vault (names only, never values)"""
    if not VAULT_FILE.exists():
        return {"keys": []}
    key = get_or_create_key()
    f = Fernet(key)
    try:
        data = json.loads(f.decrypt(VAULT_FILE.read_bytes()).decode())
        return {"keys": list(data.keys())}
    except Exception:
        return {"keys": [], "error": "Vault unreadable"}

@app.post("/system-action")
async def system_action(req: SystemActionRequest):
    """
    System/security actions always go to the approval queue.
    Knox calls this for firewall, installs, network changes.
    """
    action_id = queue_action(req.action_type, req.description,
                              {"command": req.command})
    return {
        "status": "queued",
        "action_id": action_id,
        "message": f"Action queued for Evan's approval — ID: {action_id}"
    }

@app.get("/queue")
async def get_queue():
    """Get pending action queue"""
    if not QUEUE_FILE.exists():
        return {"actions": []}
    return {"actions": json.loads(QUEUE_FILE.read_text())}

@app.post("/queue/{action_id}/approve")
async def approve_action(action_id: str):
    """Approve and execute a queued action"""
    if not QUEUE_FILE.exists():
        raise HTTPException(status_code=404, detail="Queue empty")
    queue = json.loads(QUEUE_FILE.read_text())
    for action in queue:
        if action["id"] == action_id and action["status"] == "pending":
            try:
                result = subprocess.run(
                    action["payload"]["command"], shell=True,
                    capture_output=True, text=True, timeout=60
                )
                action["status"] = "approved"
                action["output"] = result.stdout + result.stderr
                QUEUE_FILE.write_text(json.dumps(queue, indent=2))
                return {"status": "executed", "output": action["output"]}
            except Exception as e:
                action["status"] = "failed"
                QUEUE_FILE.write_text(json.dumps(queue, indent=2))
                return {"status": "failed", "error": str(e)}
    raise HTTPException(status_code=404, detail="Action not found or not pending")

@app.post("/queue/{action_id}/reject")
async def reject_action(action_id: str):
    if not QUEUE_FILE.exists():
        raise HTTPException(status_code=404, detail="Queue empty")
    queue = json.loads(QUEUE_FILE.read_text())
    for action in queue:
        if action["id"] == action_id:
            action["status"] = "rejected"
            QUEUE_FILE.write_text(json.dumps(queue, indent=2))
            return {"status": "rejected"}
    raise HTTPException(status_code=404, detail="Action not found")

@app.get("/sessions")
async def list_sessions():
    return {"sessions": list(sessions.keys())}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="127.0.0.1", port=8767, log_level="warning")
