"""Local-development signaling server. Run on a trusted LAN only."""

import asyncio
from contextlib import asynccontextmanager
from uuid import UUID

from fastapi import FastAPI, HTTPException
from loguru import logger
from pipecat.transports.smallwebrtc.request_handler import (
    SmallWebRTCPatchRequest,
    SmallWebRTCRequest,
    SmallWebRTCRequestHandler,
)

import memory_store
from bot import run_bot
from config import Settings
from memory_store import ImportAnswer

handler = SmallWebRTCRequestHandler()
sessions: set[asyncio.Task] = set()
import_jobs: dict[int, asyncio.Task] = {}


@asynccontextmanager
async def lifespan(app):
    for job_id in memory_store.pending_ids():
        schedule_import(job_id)
    yield
    for task in import_jobs.values():
        task.cancel()
    await asyncio.gather(*list(import_jobs.values()), return_exceptions=True)
    await handler.close()
    active = list(sessions)
    for task in active:
        task.cancel()
    await asyncio.gather(*active, return_exceptions=True)


app = FastAPI(title="Orb voice server", lifespan=lifespan)


@app.get("/health")
async def health():
    try:
        Settings.load()
    except ValueError as error:
        return {"ready": False, "detail": str(error)}
    return {"ready": True}


async def serve_connection(connection, settings, owner=None):
    try:
        await run_bot(connection, settings, owner=owner)
    except asyncio.CancelledError:
        raise
    except Exception as error:  # noqa: BLE001 — session boundary must clean up every provider failure
        # Avoid logging provider response bodies, credentials, or conversation text.
        logger.error("Voice session failed ({})", type(error).__name__)
    finally:
        await connection.disconnect()


@app.post("/api/offer")
async def offer(request: SmallWebRTCRequest, owner: UUID | None = None):
    try:
        settings = Settings.load()
    except ValueError as error:
        raise HTTPException(503, str(error)) from error

    async def connected(connection):
        task = asyncio.create_task(serve_connection(connection, settings, owner))
        sessions.add(task)
        task.add_done_callback(sessions.discard)

    return await handler.handle_web_request(request=request, webrtc_connection_callback=connected)


@app.patch("/api/offer")
async def ice_candidate(request: SmallWebRTCPatchRequest):
    await handler.handle_patch_request(request)
    return {"status": "success"}


async def run_import(job_id):
    try:
        await memory_store.summarize_job(job_id, Settings.load())
    except asyncio.CancelledError:
        raise  # Durable pending jobs resume on server restart.
    except Exception as error:  # noqa: BLE001 — background job boundary
        memory_store.mark_failed(job_id)
        logger.warning("Context summarization failed ({})", type(error).__name__)
    finally:
        import_jobs.pop(job_id, None)


def schedule_import(job_id):
    if job_id not in import_jobs:
        import_jobs[job_id] = asyncio.create_task(run_import(job_id))


@app.post("/api/import", status_code=202)
async def import_context(answer: ImportAnswer):
    job = memory_store.enqueue(answer)
    if job["status"] == "pending":
        schedule_import(job["id"])
    return job


@app.get("/api/import/{job_id}")
async def import_status(job_id: int, owner: UUID):
    job = memory_store.job_for_owner(job_id, owner)
    if not job:
        raise HTTPException(404, "Import not found.")
    return job


@app.post("/api/import/{job_id}/retry", status_code=202)
async def retry_import(job_id: int, owner: UUID):
    job = memory_store.job_for_owner(job_id, owner)
    if not job:
        raise HTTPException(404, "Import not found.")
    memory_store.mark_pending(job_id, owner)
    job = memory_store.job_for_owner(job_id, owner)
    if job["status"] == "pending":
        schedule_import(job_id)
    return job
