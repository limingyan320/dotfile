#!/usr/bin/env python3
"""Expose iTerm2 background controls to local and SSH-hosted Neovim UIs."""

import asyncio
import base64
import binascii
import fcntl
import hashlib
import json
import logging
import math
import os
from pathlib import Path
import re
import secrets
import time
import traceback

import iterm2


CACHE_DIR = Path.home() / "Library" / "Caches" / "dotfiles"
IMAGE_CACHE_DIR = CACHE_DIR / "nvim-background-images"
SOCKET_PATH = CACHE_DIR / "iterm-background.sock"
LOCK_PATH = CACHE_DIR / "iterm-background.lock"
LOG_PATH = Path.home() / "Library" / "Logs" / "dotfiles-iterm-background.log"
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("DOTFILES_NVIM_BACKGROUND_PORT", "47790"))
MAX_IMAGE_BYTES = 32 * 1024 * 1024
MAX_REQUEST_BYTES = 48 * 1024 * 1024
IMAGE_CACHE_TTL_SECONDS = 30 * 24 * 60 * 60
IMAGE_EXTENSIONS = {
    "avif",
    "bmp",
    "gif",
    "heic",
    "jpeg",
    "jpg",
    "png",
    "tif",
    "tiff",
    "webp",
}
IMAGE_MODES = {
    "fill": iterm2.BackgroundImageMode.ASPECT_FILL,
    "fit": iterm2.BackgroundImageMode.ASPECT_FIT,
    "stretch": iterm2.BackgroundImageMode.STRETCH,
    "tile": iterm2.BackgroundImageMode.TILE,
}
CAPABILITIES = {
    "color": True,
    "image": True,
    "image_upload": True,
    "opacity": True,
    "blur": True,
}

LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
logging.basicConfig(
    filename=LOG_PATH,
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("dotfiles-iterm-background")


def bounded_number(value, low, high, name):
    try:
        number = float(value)
    except (TypeError, ValueError) as error:
        raise ValueError(f"{name} must be a number") from error
    if not math.isfinite(number):
        raise ValueError(f"{name} must be finite")
    return min(high, max(low, number))


def active_session(app):
    window = app.current_terminal_window
    if not window or not window.current_tab:
        return None
    return window.current_tab.current_session


async def require_active_session(app):
    await app.async_refresh_focus()
    if app.app_active is not True:
        raise RuntimeError("iTerm2 is not the active terminal")
    session = active_session(app)
    if session is None:
        raise RuntimeError("no active iTerm2 session")
    return session


async def profile_snapshot(session):
    profile = await session.async_get_profile()
    mode = profile.background_image_mode
    return {
        "image_path": profile.background_image_location or "",
        "image_mode": int(mode.value)
        if mode is not None
        else int(iterm2.BackgroundImageMode.ASPECT_FILL.value),
        "image_blend": profile.blend,
        "transparency": profile.transparency,
        "blur": profile.blur,
        "blur_radius": profile.blur_radius,
        "only_default_bg_transparent": profile.only_the_default_bg_color_uses_transparency,
        "use_transparency_initially": profile.use_transparency_initially,
    }


async def restore_profile(session, snapshot):
    change = iterm2.LocalWriteOnlyProfile()
    change.set_background_image_location(snapshot["image_path"])
    change.set_background_image_mode(iterm2.BackgroundImageMode(snapshot["image_mode"]))
    change.set_blend(snapshot["image_blend"])
    change.set_transparency(snapshot["transparency"])
    change.set_blur(snapshot["blur"])
    change.set_blur_radius(snapshot["blur_radius"])
    change.set_only_the_default_bg_color_uses_transparency(
        snapshot["only_default_bg_transparent"]
    )
    if snapshot["use_transparency_initially"] is not None:
        change.set_use_transparency_initially(snapshot["use_transparency_initially"])
    await session.async_set_profile_properties(change)


def validate_image_identity(digest, extension):
    digest = str(digest or "").lower()
    extension = str(extension or "").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", digest):
        raise ValueError("invalid image digest")
    if extension not in IMAGE_EXTENSIONS:
        raise ValueError("unsupported background image type")
    return digest, extension


def cached_image_path(digest, extension):
    digest, extension = validate_image_identity(digest, extension)
    return IMAGE_CACHE_DIR / f"{digest}.{extension}"


def cached_image_ref(path):
    if path.parent != IMAGE_CACHE_DIR or not re.fullmatch(
        r"[0-9a-f]{64}\.[a-z0-9]+", path.name
    ):
        raise ValueError("invalid cached image reference")
    return path.name


def resolve_cached_image(reference):
    reference = str(reference or "")
    if not re.fullmatch(r"[0-9a-f]{64}\.[a-z0-9]+", reference):
        raise ValueError("invalid cached image reference")
    digest, extension = reference.split(".", 1)
    path = cached_image_path(digest, extension)
    if not path.is_file():
        raise ValueError("cached background image is missing")
    return path


def clean_image_cache():
    cutoff = time.time() - IMAGE_CACHE_TTL_SECONDS
    try:
        for path in IMAGE_CACHE_DIR.iterdir():
            if path.is_file() and path.stat().st_mtime < cutoff:
                path.unlink()
    except OSError as error:
        log.warning("image cache cleanup failed: %s", error)


def store_uploaded_image(request):
    digest, extension = validate_image_identity(
        request.get("sha256"), request.get("extension")
    )
    encoded = request.get("data")
    if not isinstance(encoded, str):
        raise ValueError("uploaded image data is missing")
    try:
        data = base64.b64decode(encoded, validate=True)
    except (binascii.Error, ValueError) as error:
        raise ValueError("uploaded image is not valid base64") from error
    if not data or len(data) > MAX_IMAGE_BYTES:
        raise ValueError("uploaded image must be between 1 byte and 32 MiB")
    if hashlib.sha256(data).hexdigest() != digest:
        raise ValueError("uploaded image digest does not match")

    IMAGE_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(IMAGE_CACHE_DIR, 0o700)
    destination = cached_image_path(digest, extension)
    if not destination.is_file():
        temporary = (
            IMAGE_CACHE_DIR
            / f".{destination.name}.{os.getpid()}.{secrets.token_hex(4)}"
        )
        try:
            with temporary.open("xb") as file:
                file.write(data)
            os.chmod(temporary, 0o600)
            os.replace(temporary, destination)
        finally:
            try:
                temporary.unlink()
            except FileNotFoundError:
                pass
    clean_image_cache()
    return destination


def resolve_image_path(settings, transport):
    if settings.get("image_enabled") is not True:
        return ""
    image_ref = settings.get("image_ref")
    if image_ref:
        return str(resolve_cached_image(image_ref))
    if transport != "unix":
        raise ValueError("SSH background images must be uploaded to the Mac bridge")
    image_path = Path(str(settings.get("image_path") or "")).expanduser().resolve()
    if not image_path.is_file():
        raise ValueError("selected image is not readable on this Mac")
    return str(image_path)


async def apply_settings(session, settings, transport):
    image_path = resolve_image_path(settings, transport)
    image_mode = str(settings.get("image_mode") or "fill")
    if image_mode not in IMAGE_MODES:
        raise ValueError("unsupported image layout")
    image_blend = bounded_number(settings.get("image_blend", 0.35), 0, 1, "image_blend")
    transparency = bounded_number(settings.get("transparency", 0), 0, 1, "transparency")
    blur_radius = bounded_number(settings.get("blur_radius", 0), 0, 30, "blur_radius")

    change = iterm2.LocalWriteOnlyProfile()
    change.set_background_image_location(image_path)
    change.set_background_image_mode(IMAGE_MODES[image_mode])
    change.set_blend(image_blend)
    change.set_transparency(transparency)
    change.set_use_transparency_initially(transparency > 0)
    change.set_only_the_default_bg_color_uses_transparency(True)
    change.set_blur(blur_radius > 0)
    change.set_blur_radius(blur_radius)
    await session.async_set_profile_properties(change)


async def main(connection):
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    os.chmod(CACHE_DIR, 0o700)
    lock_file = LOCK_PATH.open("w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        log.info("another background daemon is already running")
        return

    servers = []
    try:
        SOCKET_PATH.unlink(missing_ok=True)
        app = await iterm2.async_get_app(connection)
        transactions = {}

        def transaction_record(request, required=False):
            transaction_id = str(request.get("transaction_id") or "")
            record = transactions.get(transaction_id)
            if (required or transaction_id) and record is None:
                raise ValueError("background transaction is missing")
            return transaction_id, record

        async def authorized_session(request):
            _, record = transaction_record(request)
            if record:
                session = app.get_session_by_id(record["session_id"])
                if session is None:
                    raise RuntimeError("iTerm2 session is no longer available")
                return session
            return await require_active_session(app)

        async def dispatch(request, transport):
            action = request.get("action")
            if action == "ping":
                await app.async_refresh_focus()
                return {
                    "ok": True,
                    "protocol": 1,
                    "renderer": "iterm2",
                    "active": app.app_active is True
                    and active_session(app) is not None,
                    "capabilities": CAPABILITIES,
                }

            if action == "begin":
                session = await require_active_session(app)
                transaction_id = secrets.token_urlsafe(18)
                transactions[transaction_id] = {
                    "session_id": session.session_id,
                    "snapshot": await profile_snapshot(session),
                    "lock": asyncio.Lock(),
                }
                return {
                    "ok": True,
                    "transaction_id": transaction_id,
                    "session_id": session.session_id,
                }

            if action == "image_status":
                await authorized_session(request)
                path = cached_image_path(
                    request.get("sha256"), request.get("extension")
                )
                return {
                    "ok": True,
                    "present": path.is_file(),
                    "image_ref": cached_image_ref(path),
                }

            if action == "upload_image":
                await authorized_session(request)
                path = store_uploaded_image(request)
                return {"ok": True, "image_ref": cached_image_ref(path)}

            if action == "apply":
                transaction_id, record = transaction_record(request)
                if record:
                    async with record["lock"]:
                        if transactions.get(transaction_id) is not record:
                            raise ValueError("background transaction is missing")
                        session = app.get_session_by_id(record["session_id"])
                        if session is None:
                            raise RuntimeError("iTerm2 session is no longer available")
                        await apply_settings(
                            session, request.get("settings") or {}, transport
                        )
                else:
                    session = await require_active_session(app)
                    await apply_settings(
                        session, request.get("settings") or {}, transport
                    )
                return {"ok": True, "session_id": session.session_id}

            if action == "restore":
                transaction_id, record = transaction_record(request, required=True)
                async with record["lock"]:
                    if transactions.get(transaction_id) is not record:
                        raise ValueError("background transaction is missing")
                    session = app.get_session_by_id(record["session_id"])
                    if session is None:
                        raise RuntimeError("iTerm2 session is no longer available")
                    await restore_profile(session, record["snapshot"])
                return {"ok": True, "session_id": record["session_id"]}

            if action in {"cancel", "commit"}:
                transaction_id, record = transaction_record(request, required=True)
                async with record["lock"]:
                    if transactions.get(transaction_id) is not record:
                        raise ValueError("background transaction is missing")
                    session = app.get_session_by_id(record["session_id"])
                    if action == "cancel" and session is not None:
                        await restore_profile(session, record["snapshot"])
                    transactions.pop(transaction_id, None)
                return {"ok": True, "session_id": record["session_id"]}

            raise ValueError("unsupported action")

        async def handle_client(reader, writer, transport):
            try:
                raw = await reader.readline()
                if len(raw) > MAX_REQUEST_BYTES:
                    raise ValueError("request is too large")
                request = json.loads(raw.decode("utf-8"))
                response = await dispatch(request, transport)
            except Exception as error:
                log.error(
                    "%s request failed: %s\n%s",
                    transport,
                    error,
                    traceback.format_exc(),
                )
                response = {"ok": False, "error": str(error)}
            writer.write(
                (json.dumps(response, ensure_ascii=False) + "\n").encode("utf-8")
            )
            try:
                await writer.drain()
            finally:
                writer.close()
                await writer.wait_closed()

        unix_server = await asyncio.start_unix_server(
            lambda reader, writer: handle_client(reader, writer, "unix"),
            path=str(SOCKET_PATH),
            limit=MAX_REQUEST_BYTES + 1,
        )
        os.chmod(SOCKET_PATH, 0o600)
        servers.append(unix_server)
        log.info("background daemon listening on %s", SOCKET_PATH)

        try:
            tcp_server = await asyncio.start_server(
                lambda reader, writer: handle_client(reader, writer, "tcp"),
                host=LISTEN_HOST,
                port=LISTEN_PORT,
                limit=MAX_REQUEST_BYTES + 1,
            )
            servers.append(tcp_server)
            log.info("background daemon listening on %s:%s", LISTEN_HOST, LISTEN_PORT)
        except OSError as error:
            log.error("TCP background bridge unavailable: %s", error)

        await asyncio.gather(*(server.serve_forever() for server in servers))
    finally:
        for server in servers:
            server.close()
            await server.wait_closed()
        SOCKET_PATH.unlink(missing_ok=True)
        lock_file.close()


if __name__ == "__main__":
    iterm2.run_forever(main)
