"""
qwen-ui — minimal FastAPI control plane + chat UI on top of llama-server.

Responsibilities:
  • Serve the single-page UI at /
  • Proxy /v1/* to the running llama-server (default 127.0.0.1:8080)
  • Expose /api/* control endpoints (model list, profile list, switch, state)
  • Orchestrate model/profile switching via scripts/qwen.ps1

Designed to stay small (one file, no DB, in-memory state) but with clear
extension points: REGISTRY_PATH, PROFILES, swap_server() are all easily
swappable when this grows up.
"""
from __future__ import annotations

import asyncio
import json
import os
import secrets
import subprocess
import time
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import (
    FileResponse,
    JSONResponse,
    Response,
    StreamingResponse,
)
from fastapi.staticfiles import StaticFiles

# ----- Configuration ---------------------------------------------------------

REPO_ROOT = Path(__file__).resolve().parent.parent
QWEN_PS1 = REPO_ROOT / "scripts" / "qwen.ps1"
REGISTRY_PATH = REPO_ROOT / "models.json"
STATIC_DIR = Path(__file__).resolve().parent / "static"

LLAMA_HOST = os.environ.get("QWEN_LLAMA_HOST", "127.0.0.1")
LLAMA_PORT = int(os.environ.get("QWEN_LLAMA_PORT", "8080"))
LLAMA_BASE = f"http://{LLAMA_HOST}:{LLAMA_PORT}"

# Profile metadata. Mirrors qwen.ps1's $Profiles hashtable. Kept in sync manually
# for now — small list, rare changes. If this drifts we can switch to parsing the
# PS file at startup.
PROFILES: dict[str, dict[str, Any]] = {
    "safe":     {"n_cpu_moe": 31, "ctx": 16384, "vision": False,
                 "note": "~540 MB headroom; busy desktops"},
    "balanced": {"n_cpu_moe": 29, "ctx": 24576, "vision": False,
                 "note": "Sweep optimum (text-only)"},
    "longctx":  {"n_cpu_moe": 30, "ctx": 32768, "vision": False,
                 "note": "Longest context, slightly slower"},
    "conserve": {"n_cpu_moe": 33, "ctx": 8192,  "vision": False,
                 "note": "Frees ~1 GB VRAM for other apps"},
    "vision":   {"n_cpu_moe": 35, "ctx": 16384, "vision": True,
                 "note": "Image input enabled (mmproj loaded)"},
}

# Per-process secret token for mutating /api/* endpoints.
# Delivered to the UI via /api/state (same-origin GET, CORS blocks cross-origin reads).
# Mutating endpoints require it as X-Control-Token; requiring a custom header forces a
# CORS preflight that the server rejects for non-localhost origins, so cross-site
# requests never reach the handler body.
_CONTROL_TOKEN = secrets.token_hex(16)

_LOCAL_ORIGINS = {"http://127.0.0.1", "http://localhost"}


def llama_client(**kwargs: Any) -> httpx.AsyncClient:
    """Create an HTTP client for the local llama-server upstream.

    httpx reads HTTP(S)_PROXY from the process environment by default. That is
    the wrong default for this control plane: calls to 127.0.0.1 must stay local
    or the UI can report "down" while llama-server is actually running.
    """
    kwargs.setdefault("trust_env", False)
    return httpx.AsyncClient(**kwargs)


def _assert_local(req: Request) -> None:
    """Raise 403 if the request originates from a non-localhost origin or carries
    a wrong/missing control token.  Both checks are needed:
      • Origin check  — rejects visible cross-origin fetch attempts.
      • Token check   — rejects simple-request forms that browsers send without a
                        preflight (e.g. text/plain bodies), where Origin may or may
                        not be present.
    """
    origin = req.headers.get("origin", "")
    if origin:
        base = origin.split(":", 2)  # strip port: "http://127.0.0.1:8090" → base host
        host_part = f"{base[0]}:{base[1]}" if len(base) >= 2 else origin
        if host_part not in _LOCAL_ORIGINS:
            raise HTTPException(403, "cross-origin control requests are not allowed")
    token = req.headers.get("x-control-token", "")
    if not secrets.compare_digest(token, _CONTROL_TOKEN):
        raise HTTPException(403, "missing or invalid X-Control-Token")


# ----- Mutable state (in-memory) --------------------------------------------

# Tracks what we last asked qwen.ps1 to start, and any pending switch.
# Not persisted across qwen-ui restarts — UI re-derives current state from
# llama-server's /v1/models on startup.
state: dict[str, Any] = {
    "current": None,        # {"model_id": str, "profile": str, "alias": str} | None
    "switching_to": None,   # {"model_id": str, "profile": str} | None
    "switch_error": None,   # str | None — last error if a switch failed
    "switch_started_at": None,  # float | None
    "switch_phase": None,   # str | None — current switch step
    "last_completion": None,  # compact timings/usage from the latest chat completion
    "last_health": None,    # compact result from /api/health
}

_switch_lock = asyncio.Lock()

# ----- Helpers --------------------------------------------------------------

def load_registry() -> dict[str, Any]:
    """Read models.json. Raises HTTPException 500 on any parse error."""
    try:
        return json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
    except FileNotFoundError:
        raise HTTPException(500, f"models.json not found at {REGISTRY_PATH}")
    except json.JSONDecodeError as e:
        raise HTTPException(500, f"models.json is not valid JSON: {e}")


async def server_alive(client: httpx.AsyncClient) -> tuple[bool, list[str], str | None]:
    """Returns (alive, aliases_served, error). Short timeout."""
    try:
        r = await client.get(f"{LLAMA_BASE}/v1/models", timeout=2.0)
        if r.status_code != 200:
            return False, [], f"HTTP {r.status_code} from {LLAMA_BASE}/v1/models"
        data = r.json()
        return True, [m["id"] for m in data.get("data", [])], None
    except Exception as e:
        return False, [], f"{type(e).__name__}: {e}"


async def get_json(
    client: httpx.AsyncClient,
    path: str,
    timeout: float = 2.0,
) -> tuple[Any | None, str | None, int | None]:
    try:
        r = await client.get(f"{LLAMA_BASE}{path}", timeout=timeout)
        if r.status_code != 200:
            return None, f"HTTP {r.status_code} from {LLAMA_BASE}{path}", r.status_code
        return r.json(), None, r.status_code
    except Exception as e:
        return None, f"{type(e).__name__}: {e}", None


def resolve_model_id(alias: str | None) -> str | None:
    if not alias:
        return None
    try:
        reg = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
        for mid, entry in reg.get("models", {}).items():
            if entry.get("alias") == alias:
                return mid
    except Exception:
        pass
    return None


def compact_props(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict):
        return None
    settings = raw.get("default_generation_settings") or {}
    params = settings.get("params") or {}
    n_ctx = settings.get("n_ctx") or params.get("n_ctx")
    model_path = raw.get("model_path")
    return {
        "model_alias": raw.get("model_alias"),
        "model_file": Path(model_path).name if model_path else None,
        "n_ctx": n_ctx,
        "total_slots": raw.get("total_slots"),
        "modalities": raw.get("modalities"),
        "build_info": raw.get("build_info"),
        "is_sleeping": raw.get("is_sleeping"),
        "endpoints": {
            "slots": raw.get("endpoint_slots"),
            "props": raw.get("endpoint_props"),
            "metrics": raw.get("endpoint_metrics"),
        },
    }


def compact_slots(raw: Any) -> tuple[list[dict[str, Any]], dict[str, Any]]:
    if not isinstance(raw, list):
        return [], {
            "active": False,
            "n_ctx": None,
            "used_tokens": None,
            "used_pct": None,
            "input_tokens": None,
            "output_tokens": None,
            "cache_tokens": None,
        }

    slots: list[dict[str, Any]] = []
    best_ctx = None
    best_used = 0
    total_prompt = 0
    total_decoded = 0
    total_cache = 0
    active = False

    for slot in raw:
        if not isinstance(slot, dict):
            continue
        next_token = slot.get("next_token") or []
        decoded = 0
        remain = None
        if isinstance(next_token, list):
            for item in next_token:
                if isinstance(item, dict):
                    decoded = max(decoded, int(item.get("n_decoded") or 0))
                    if item.get("n_remain") is not None:
                        remain = item.get("n_remain")

        n_ctx = slot.get("n_ctx")
        prompt = int(slot.get("n_prompt_tokens") or 0)
        processed = int(slot.get("n_prompt_tokens_processed") or 0)
        cache = int(slot.get("n_prompt_tokens_cache") or 0)
        used = max(prompt, processed) + decoded
        is_processing = bool(slot.get("is_processing"))
        active = active or is_processing
        if n_ctx and (best_ctx is None or used >= best_used):
            best_ctx = int(n_ctx)
            best_used = used
        total_prompt += prompt
        total_decoded += decoded
        total_cache += cache
        slots.append({
            "id": slot.get("id"),
            "task_id": slot.get("id_task"),
            "n_ctx": n_ctx,
            "is_processing": is_processing,
            "prompt_tokens": prompt,
            "processed_tokens": processed,
            "cache_tokens": cache,
            "decoded_tokens": decoded,
            "remaining_tokens": remain,
            "used_tokens": used,
            "used_pct": round(used / n_ctx * 100, 1) if n_ctx else None,
        })

    return slots, {
        "active": active,
        "n_ctx": best_ctx,
        "used_tokens": best_used if best_ctx else None,
        "used_pct": round(best_used / best_ctx * 100, 1) if best_ctx else None,
        "input_tokens": total_prompt,
        "output_tokens": total_decoded,
        "cache_tokens": total_cache,
    }


def latest_logs() -> dict[str, Any]:
    logs_dir = REPO_ROOT / "logs"
    if not logs_dir.exists():
        return {"dir": str(logs_dir), "files": []}
    files = sorted(
        [p for p in logs_dir.iterdir() if p.is_file()],
        key=lambda p: p.stat().st_mtime,
        reverse=True,
    )[:6]
    return {
        "dir": str(logs_dir),
        "files": [
            {
                "name": p.name,
                "path": str(p),
                "bytes": p.stat().st_size,
                "modified_at": p.stat().st_mtime,
            }
            for p in files
        ],
    }


async def collect_runtime(client: httpx.AsyncClient) -> dict[str, Any]:
    models, models_error, _ = await get_json(client, "/v1/models")
    served_aliases = [m["id"] for m in (models or {}).get("data", [])] if isinstance(models, dict) else []
    props_raw, props_error, _ = await get_json(client, "/props")
    slots_raw, slots_error, _ = await get_json(client, "/slots")
    props = compact_props(props_raw)
    slots, context = compact_slots(slots_raw)
    if context["n_ctx"] is None and props and props.get("n_ctx"):
        context["n_ctx"] = props.get("n_ctx")

    reachable = models_error is None
    upstream_error = models_error
    errors = {
        "models": models_error,
        "props": props_error,
        "slots": slots_error,
    }
    return {
        "reachable": reachable,
        "base": LLAMA_BASE,
        "error": upstream_error,
        "served_aliases": served_aliases,
        "props": props,
        "slots": slots,
        "context": context,
        "errors": errors,
        "last_completion": state.get("last_completion"),
        "last_health": state.get("last_health"),
        "logs": latest_logs(),
    }


def record_completion(obs: dict[str, Any]) -> None:
    timings = obs.get("timings") or {}
    usage = obs.get("usage") or {}
    completion = {
        "finished_at": time.time(),
        "started_at": obs.get("started_at"),
        "model": obs.get("model"),
        "finish_reason": obs.get("finish_reason"),
        "stream": bool(obs.get("stream")),
        "output_chars": obs.get("output_chars"),
        "prompt_tokens": usage.get("prompt_tokens") or timings.get("prompt_n"),
        "completion_tokens": usage.get("completion_tokens") or timings.get("predicted_n"),
        "total_tokens": usage.get("total_tokens"),
        "prompt_tps": timings.get("prompt_per_second"),
        "generation_tps": timings.get("predicted_per_second"),
        "prompt_ms": timings.get("prompt_ms"),
        "generation_ms": timings.get("predicted_ms"),
        "timings": timings or None,
        "usage": usage or None,
    }
    state["last_completion"] = completion


def observe_sse_line(obs: dict[str, Any], raw: str) -> None:
    raw = raw.strip()
    if raw == "[DONE]":
        obs["done"] = True
        return
    try:
        data = json.loads(raw)
    except Exception:
        return
    obs["model"] = data.get("model") or obs.get("model")
    if data.get("timings"):
        obs["timings"] = data["timings"]
    if data.get("usage"):
        obs["usage"] = data["usage"]
    for choice in data.get("choices") or []:
        if choice.get("finish_reason"):
            obs["finish_reason"] = choice.get("finish_reason")
        delta = choice.get("delta") or {}
        content = delta.get("content")
        if content:
            obs["output_chars"] = int(obs.get("output_chars") or 0) + len(content)


def run_qwen_restart(model_id: str, profile: str) -> int:
    """Blocking — invokes qwen.ps1 restart -Background. Returns exit code.

    Must NOT use capture_output / PIPE on Windows: qwen.ps1 uses Write-Host
    (PowerShell information stream) for all output, so PIPE captures nothing
    useful.  More importantly, Start-Process inside qwen.ps1 inherits the pipe
    write-handles created by Python, and llama-server (the grandchild) keeps
    those handles open after pwsh exits.  This causes communicate() to block
    indefinitely waiting for the write-end to close — hence the infinite
    "switching" state even after the server is fully up.  DEVNULL avoids
    creating pipe handles entirely.
    """
    cmd = [
        "pwsh", "-NoProfile", "-File", str(QWEN_PS1),
        "restart", "-Model", model_id, "-Profile", profile,
        "-Background", "-Quiet",
    ]
    p = subprocess.run(
        cmd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        timeout=300,
    )
    return p.returncode


async def perform_switch(model_id: str, profile: str, expected_alias: str) -> None:
    """Background task: call qwen.ps1 restart, poll until alias appears."""
    loop = asyncio.get_running_loop()
    try:
        state["switch_phase"] = "launching"
        rc = await loop.run_in_executor(None, run_qwen_restart, model_id, profile)
        if rc != 0:
            state["switch_error"] = f"qwen.ps1 restart failed (rc={rc}) — check logs\\ for details"
            state["switching_to"] = None
            state["switch_phase"] = "failed"
            return
        # qwen.ps1 -Background already waited for "ready" — but double-check.
        state["switch_phase"] = "verifying_alias"
        async with llama_client() as client:
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                alive, aliases, _ = await server_alive(client)
                if alive and expected_alias in aliases:
                    state["current"] = {
                        "model_id": model_id,
                        "profile": profile,
                        "alias": expected_alias,
                    }
                    state["switching_to"] = None
                    state["switch_error"] = None
                    state["switch_phase"] = "ready"
                    return
                await asyncio.sleep(1.0)
        state["switch_error"] = f"server did not report alias '{expected_alias}' within 60s after restart"
        state["switching_to"] = None
        state["switch_phase"] = "failed"
    except Exception as e:
        state["switch_error"] = f"switch failed: {type(e).__name__}: {e}"
        state["switching_to"] = None
        state["switch_phase"] = "failed"


# ----- Lifecycle ------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    # On startup: ask llama-server what's actually running so the UI is honest
    # even when qwen-ui restarts while llama-server keeps going.
    async with llama_client() as client:
        alive, aliases, _ = await server_alive(client)
        if alive and aliases:
            # We don't know which model_id maps to this alias without the registry;
            # try to back-resolve.
            try:
                reg = json.loads(REGISTRY_PATH.read_text(encoding="utf-8"))
                model_id = None
                for mid, entry in reg.get("models", {}).items():
                    if entry.get("alias") == aliases[0]:
                        model_id = mid
                        break
                state["current"] = {
                    "model_id": model_id,
                    "profile": None,   # unknown — wasn't started by us
                    "alias": aliases[0],
                }
            except Exception:
                state["current"] = {"model_id": None, "profile": None, "alias": aliases[0]}
    yield


app = FastAPI(title="qwen-ui", lifespan=lifespan)


# ----- /api/* control endpoints --------------------------------------------

@app.get("/api/state")
async def api_state() -> JSONResponse:
    async with llama_client() as client:
        runtime = await collect_runtime(client)
    alive = runtime["reachable"]
    aliases = runtime["served_aliases"]
    upstream_error = runtime["error"]
    if state["switching_to"] is not None:
        server_status = "switching"
    elif alive:
        server_status = "running"
    else:
        server_status = "down"
    if alive and aliases and (not state["current"] or state["current"].get("alias") not in aliases):
        state["current"] = {
            "model_id": resolve_model_id(aliases[0]),
            "profile": state["current"].get("profile") if state["current"] else None,
            "alias": aliases[0],
        }
    return JSONResponse({
        "ui_backend": "running",
        "server": server_status,
        "llama_upstream": runtime,
        "runtime": {
            "context": runtime["context"],
            "active": runtime["context"].get("active"),
            "last_completion": runtime["last_completion"],
            "last_health": runtime["last_health"],
        },
        "served_aliases": aliases,
        "upstream_base": LLAMA_BASE,
        "upstream_error": upstream_error,
        "current": state["current"],
        "switching_to": state["switching_to"],
        "switch": {
            "phase": state["switch_phase"],
            "target": state["switching_to"],
            "error": state["switch_error"],
            "started_at": state["switch_started_at"],
            "elapsed_s": time.time() - state["switch_started_at"] if state["switch_started_at"] else None,
        },
        "switch_error": state["switch_error"],
        "switch_started_at": state["switch_started_at"],
        "control_token": _CONTROL_TOKEN,
    })


@app.get("/api/models")
async def api_models() -> JSONResponse:
    reg = load_registry()
    models = reg.get("models", {})
    out = []
    for mid, entry in models.items():
        out.append({
            "id": mid,
            "alias": entry.get("alias"),
            "n_layer": entry.get("n_layer"),
            "size_gb": entry.get("size_gb"),
            "recommended_profile": entry.get("recommended_profile"),
            "notes": entry.get("notes"),
            "has_mmproj": bool(entry.get("mmproj_url")),
        })
    return JSONResponse({"default": reg.get("default"), "models": out})


@app.get("/api/profiles")
async def api_profiles() -> JSONResponse:
    return JSONResponse({"profiles": [
        {"id": k, **v} for k, v in PROFILES.items()
    ]})


@app.post("/api/switch")
async def api_switch(req: Request) -> JSONResponse:
    _assert_local(req)
    body = await req.json()
    model_id = (body.get("model") or "").strip()
    profile = (body.get("profile") or "").strip()

    reg = load_registry()
    if model_id not in reg.get("models", {}):
        raise HTTPException(400, f"unknown model '{model_id}'")
    if profile not in PROFILES:
        raise HTTPException(400, f"unknown profile '{profile}'")

    async with _switch_lock:
        if state["switching_to"] is not None:
            raise HTTPException(409, f"already switching to {state['switching_to']}")
        expected_alias = reg["models"][model_id]["alias"]
        state["switching_to"] = {"model_id": model_id, "profile": profile}
        state["switch_started_at"] = time.time()
        state["switch_phase"] = "queued"
        state["switch_error"] = None
        asyncio.create_task(perform_switch(model_id, profile, expected_alias))

    return JSONResponse({"accepted": True, "target": state["switching_to"]}, status_code=202)


@app.post("/api/clear-context")
async def api_clear_context(req: Request) -> JSONResponse:
    """Erase the KV cache of all llama-server slots so context usage drops to 0."""
    _assert_local(req)
    async with llama_client(timeout=httpx.Timeout(10.0, connect=5.0)) as client:
        slots_raw, slots_error, _ = await get_json(client, "/slots")
        if slots_error or not isinstance(slots_raw, list):
            return JSONResponse(
                {"ok": False, "error": slots_error or "slots endpoint unavailable"},
                status_code=502,
            )
        erased, errors = 0, []
        for slot in slots_raw:
            slot_id = slot.get("id")
            if slot_id is None:
                continue
            try:
                r = await client.post(
                    f"{LLAMA_BASE}/slots/{slot_id}",
                    json={"action": "erase"},
                    timeout=5.0,
                )
                if r.status_code == 200:
                    erased += 1
                else:
                    errors.append(f"slot {slot_id}: HTTP {r.status_code}")
            except Exception as e:
                errors.append(f"slot {slot_id}: {e}")
        return JSONResponse({"ok": True, "erased": erased, "errors": errors})


@app.post("/api/health")
async def api_health(req: Request) -> JSONResponse:
    _assert_local(req)
    started = time.time()
    async with llama_client(timeout=httpx.Timeout(90.0, connect=5.0)) as client:
        runtime = await collect_runtime(client)
        if not runtime["reachable"]:
            result = {
                "ok": False,
                "checked_at": time.time(),
                "wall_ms": int((time.time() - started) * 1000),
                "error": runtime["error"],
                "upstream": runtime,
            }
            state["last_health"] = result
            return JSONResponse(result, status_code=503)

        aliases = runtime["served_aliases"]
        model = state.get("current", {}).get("alias") if state.get("current") else None
        if not model and aliases:
            model = aliases[0]
        body = {
            "model": model or "default",
            "messages": [
                {"role": "user", "content": "Reply with OK only."},
            ],
            "temperature": 0.0,
            "max_tokens": 8,
            "stream": False,
            "timings_per_token": True,
            "chat_template_kwargs": {"enable_thinking": False},
        }
        try:
            r = await client.post(f"{LLAMA_BASE}/v1/chat/completions", json=body, timeout=90.0)
            data = r.json()
            timings = data.get("timings") or {}
            usage = data.get("usage") or {}
            content = (
                data.get("choices", [{}])[0]
                .get("message", {})
                .get("content", "")
            )
            result = {
                "ok": r.status_code == 200,
                "checked_at": time.time(),
                "wall_ms": int((time.time() - started) * 1000),
                "status_code": r.status_code,
                "model": data.get("model") or model,
                "response": content,
                "usage": usage,
                "timings": timings,
                "prompt_tps": timings.get("prompt_per_second"),
                "generation_tps": timings.get("predicted_per_second"),
                "error": None if r.status_code == 200 else data.get("error") or data,
            }
            state["last_health"] = result
            if r.status_code != 200:
                return JSONResponse(result, status_code=502)
            return JSONResponse(result)
        except Exception as e:
            result = {
                "ok": False,
                "checked_at": time.time(),
                "wall_ms": int((time.time() - started) * 1000),
                "model": model,
                "error": f"{type(e).__name__}: {e}",
            }
            state["last_health"] = result
            return JSONResponse(result, status_code=502)


# ----- /v1/* proxy to llama-server -----------------------------------------

# Headers we strip in either direction (httpx + Starlette handle them).
HOP_BY_HOP = {
    "connection", "keep-alive", "proxy-authenticate", "proxy-authorization",
    "te", "trailers", "transfer-encoding", "upgrade", "host",
}


@app.api_route("/v1/{path:path}", methods=["GET", "POST", "OPTIONS", "DELETE", "PUT"])
async def proxy_v1(path: str, req: Request) -> Response:
    url = f"{LLAMA_BASE}/v1/{path}"
    if req.url.query:
        url += f"?{req.url.query}"
    headers = {k: v for k, v in req.headers.items() if k.lower() not in HOP_BY_HOP}
    body = await req.body()

    # Streaming responses (SSE) need pass-through — detect via body's stream flag.
    wants_stream = False
    if body and req.headers.get("content-type", "").startswith("application/json"):
        try:
            wants_stream = bool(json.loads(body).get("stream"))
        except Exception:
            pass

    timeout = httpx.Timeout(600.0, connect=10.0)

    if wants_stream:
        # Keep client alive for the lifetime of the generator; close in its finally block.
        # Catch all httpx errors before handing the generator to Starlette so the client
        # is never left open on a failed send().
        client = llama_client(timeout=timeout)
        stream_obs = {
            "started_at": time.time(),
            "stream": True,
            "path": path,
            "output_chars": 0,
        }
        try:
            upstream = await client.send(
                client.build_request(req.method, url, content=body, headers=headers),
                stream=True,
            )
        except httpx.ConnectError:
            await client.aclose()
            raise HTTPException(503, f"llama-server at {LLAMA_BASE} is not reachable")
        except httpx.HTTPError as exc:
            await client.aclose()
            raise HTTPException(502, f"upstream error: {exc}")

        async def iter_stream():
            buf = ""
            try:
                async for chunk in upstream.aiter_raw():
                    if path == "chat/completions":
                        try:
                            buf += chunk.decode("utf-8", errors="ignore")
                            lines = buf.split("\n")
                            buf = lines.pop()
                            for line in lines:
                                if line.startswith("data: "):
                                    observe_sse_line(stream_obs, line[6:])
                        except Exception:
                            pass
                    yield chunk
            finally:
                if path == "chat/completions":
                    record_completion(stream_obs)
                await upstream.aclose()
                await client.aclose()

        resp_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP}
        return StreamingResponse(
            iter_stream(),
            status_code=upstream.status_code,
            headers=resp_headers,
            media_type=upstream.headers.get("content-type"),
        )

    # Non-streaming: async with guarantees close on every exit path.
    try:
        async with llama_client(timeout=timeout) as client:
            upstream = await client.request(req.method, url, content=body, headers=headers)
            resp_headers = {k: v for k, v in upstream.headers.items() if k.lower() not in HOP_BY_HOP}
            if path == "chat/completions" and upstream.headers.get("content-type", "").startswith("application/json"):
                try:
                    data = upstream.json()
                    record_completion({
                        "started_at": time.time(),
                        "stream": False,
                        "model": data.get("model"),
                        "finish_reason": data.get("choices", [{}])[0].get("finish_reason"),
                        "usage": data.get("usage") or {},
                        "timings": data.get("timings") or {},
                        "output_chars": len(
                            data.get("choices", [{}])[0]
                            .get("message", {})
                            .get("content", "")
                        ),
                    })
                except Exception:
                    pass
            return Response(
                content=upstream.content,
                status_code=upstream.status_code,
                headers=resp_headers,
                media_type=upstream.headers.get("content-type"),
            )
    except httpx.ConnectError:
        raise HTTPException(503, f"llama-server at {LLAMA_BASE} is not reachable")
    except httpx.HTTPError as exc:
        raise HTTPException(502, f"upstream error: {exc}")


# ----- Static UI ------------------------------------------------------------

@app.get("/")
async def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")
