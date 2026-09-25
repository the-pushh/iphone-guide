import asyncio
from unittest.mock import AsyncMock

import pytest
from fastapi.testclient import TestClient

import app
import config
import memory_store
from bot import make_services


@pytest.fixture
def settings(monkeypatch, tmp_path):
    monkeypatch.setattr(memory_store, "DB_PATH", tmp_path / "memory.sqlite3")
    monkeypatch.setattr(config, "ROOT", tmp_path)
    (tmp_path / "system_prompt.md").write_text("")
    monkeypatch.setenv("OPENROUTER_API_KEY", "test-openrouter")
    monkeypatch.setenv("CARTESIA_API_KEY", "test-cartesia")
    return config.Settings.load()


def test_empty_prompt_has_no_hidden_personality(settings):
    assert settings.system_prompt == ""
    assert settings.model == "z-ai/glm-5.3-flash"


def test_prompt_reloaded_for_new_session(settings, tmp_path):
    (tmp_path / "system_prompt.md").write_text("Keep answers short.")
    assert config.Settings.load().system_prompt == "Keep answers short."


def test_missing_credentials_reject_offer_without_creating_connection(settings, monkeypatch):
    monkeypatch.delenv("CARTESIA_API_KEY")
    connect = AsyncMock()
    monkeypatch.setattr(app.handler, "handle_web_request", connect)
    with TestClient(app.app) as client:
        assert client.get("/health").json()["ready"] is False
        response = client.post("/api/offer", json={"sdp": "unused", "type": "offer"})
        assert response.status_code == 503
        assert "CARTESIA_API_KEY" in response.json()["detail"]
        assert "test-openrouter" not in response.text
    connect.assert_not_awaited()


def test_health_never_returns_secrets(settings):
    with TestClient(app.app) as client:
        assert client.get("/health").json() == {"ready": True}


def test_pipeline_services_accept_pinned_api_and_requested_model(settings):
    async def check():
        stt, llm, tts = make_services(settings)
        assert llm._settings.model == "z-ai/glm-5.3-flash"
        assert stt._settings.model == "ink-whisper"
        assert tts._settings.model == "sonic-3"
        await llm._client.close()

    asyncio.run(check())


def test_connection_is_closed_when_provider_fails(settings, monkeypatch):
    monkeypatch.setattr(app, "run_bot", AsyncMock(side_effect=RuntimeError("provider failed")))
    connection = AsyncMock()
    asyncio.run(app.serve_connection(connection, settings))
    connection.disconnect.assert_awaited_once()


def test_connection_is_closed_on_server_shutdown(settings, monkeypatch):
    monkeypatch.setattr(app, "run_bot", AsyncMock(side_effect=asyncio.CancelledError))
    connection = AsyncMock()
    with pytest.raises(asyncio.CancelledError):
        asyncio.run(app.serve_connection(connection, settings))
    connection.disconnect.assert_awaited_once()


def test_real_webrtc_offer_connects_data_channel(settings, monkeypatch):
    """Exercise real SDP/ICE negotiation without calling paid providers."""
    from uuid import uuid4

    from aiortc import RTCConfiguration, RTCPeerConnection, RTCSessionDescription
    from httpx import ASGITransport, AsyncClient

    owner_id = uuid4()
    received_owners = []

    async def keep_session_alive(connection, settings, owner=None):
        received_owners.append(owner)
        await asyncio.Event().wait()

    monkeypatch.setattr(app, "run_bot", keep_session_alive)

    async def check():
        peer = RTCPeerConnection(RTCConfiguration(iceServers=[]))
        peer.addTransceiver("audio", direction="sendrecv")
        channel = peer.createDataChannel("rtvi")
        opened = asyncio.Event()
        channel.on("open", opened.set)
        try:
            await peer.setLocalDescription(await peer.createOffer())
            async with AsyncClient(
                transport=ASGITransport(app=app.app), base_url="http://test"
            ) as client:
                response = await client.post(
                    f"/api/offer?owner={owner_id}",
                    json={
                        "sdp": peer.localDescription.sdp,
                        "type": peer.localDescription.type,
                    },
                )
            assert response.status_code == 200
            answer = response.json()
            await peer.setRemoteDescription(
                RTCSessionDescription(sdp=answer["sdp"], type=answer["type"])
            )
            await asyncio.wait_for(opened.wait(), timeout=10)
            assert peer.connectionState == "connected"
            assert received_owners == [owner_id]
        finally:
            await peer.close()
            await app.handler.close()
            tasks = list(app.sessions)
            for task in tasks:
                task.cancel()
            await asyncio.gather(*tasks, return_exceptions=True)

    asyncio.run(check())


def test_keys_added_to_env_are_picked_up_without_restart(monkeypatch, tmp_path):
    monkeypatch.setattr(memory_store, "DB_PATH", tmp_path / "memory.sqlite3")
    monkeypatch.setattr(config, "ROOT", tmp_path)
    monkeypatch.delenv("OPENROUTER_API_KEY", raising=False)
    monkeypatch.delenv("CARTESIA_API_KEY", raising=False)
    (tmp_path / "system_prompt.md").write_text("")
    env_file = tmp_path / ".env"
    env_file.write_text("OPENROUTER_API_KEY=\nCARTESIA_API_KEY=\n")
    with pytest.raises(ValueError):
        config.Settings.load()
    env_file.write_text("OPENROUTER_API_KEY=new-router\nCARTESIA_API_KEY=new-voice\n")
    assert config.Settings.load().cartesia_key == "new-voice"


def test_glm_request_does_not_disable_required_reasoning(settings):
    async def check():
        _, llm, _ = make_services(settings)
        try:
            request = llm.build_chat_completion_params(
                {"messages": [{"role": "user", "content": "Hello"}]}
            )
            reasoning = request.get("extra_body", {}).get("reasoning", {})
            assert reasoning.get("effort") == "low"
            assert reasoning.get("enabled") is not False
            assert request.get("reasoning_effort") != "none"
        finally:
            await llm._client.close()

    asyncio.run(check())


def test_voice_filter_skips_copyable_prompt_but_keeps_instructions(settings):
    async def check():
        _, llm, tts = make_services(settings)
        try:
            speech_filter = tts._text_filters[0]
            chunks = [
                "Here is **your prompt**.\n\n",
                "```text\nSummarize my priorities. ",
                "Separate facts from guesses.\n```\n\n",
                "Paste it into the chat.\n\n[Open ChatGPT](https://chatgpt.com/)",
            ]
            spoken = "".join([await speech_filter.filter(chunk) for chunk in chunks])
            assert "Here is your prompt" in spoken
            assert "Paste it into the chat" in spoken
            assert "Summarize my priorities" not in spoken
            assert "```" not in spoken
            assert "https://" not in spoken
        finally:
            await llm._client.close()

    asyncio.run(check())


def test_import_returns_before_slow_summary_and_keeps_original_private(settings):
    from uuid import uuid4

    from httpx import ASGITransport, AsyncClient

    async def check():
        gate = asyncio.Event()
        original_summarize = memory_store.summarize_job

        async def slow_summary(job_id, settings):
            await gate.wait()
            with memory_store.database() as db:
                db.execute(
                    "UPDATE imports SET summary='A garden project', status='ready' WHERE id=?",
                    (job_id,),
                )

        memory_store.summarize_job = slow_summary
        try:
            owner = str(uuid4())
            async with AsyncClient(
                transport=ASGITransport(app=app.app), base_url="http://test"
            ) as client:
                payload = {
                    "owner": owner,
                    "source": "chatGPT",
                    "text": "PRIVATE ORIGINAL garden project",
                }
                response = await asyncio.wait_for(
                    client.post("/api/import", json=payload), timeout=0.5
                )
                assert response.status_code == 202
                job = response.json()
                assert job["status"] == "pending"
                assert "PRIVATE ORIGINAL" not in response.text
                assert memory_store.summaries(owner) == []
                with memory_store.database() as db:
                    assert (
                        db.execute("SELECT original FROM imports").fetchone()[0] == payload["text"]
                    )
                duplicate = await client.post("/api/import", json=payload)
                assert duplicate.json()["id"] == job["id"]
                assert len(app.import_jobs) == 1
                assert (
                    await client.get(f"/api/import/{job['id']}?owner={uuid4()}")
                ).status_code == 404
                gate.set()
                await asyncio.gather(*list(app.import_jobs.values()))
                ready = await client.get(f"/api/import/{job['id']}?owner={owner}")
                assert ready.json()["status"] == "ready"
                assert ready.json()["summary"] == "A garden project"
                assert "PRIVATE ORIGINAL" not in str(memory_store.summaries(owner))
        finally:
            gate.set()
            await asyncio.gather(*list(app.import_jobs.values()), return_exceptions=True)
            memory_store.summarize_job = original_summarize

    asyncio.run(check())


def test_failed_import_retains_original_and_can_retry(settings, monkeypatch):
    from uuid import uuid4

    from httpx import ASGITransport, AsyncClient

    failing = AsyncMock(side_effect=RuntimeError("private provider error"))
    monkeypatch.setattr(memory_store, "summarize_job", failing)

    async def check():
        owner = str(uuid4())
        async with AsyncClient(
            transport=ASGITransport(app=app.app), base_url="http://test"
        ) as client:
            payload = {"owner": owner, "source": "claude", "text": "   "}
            assert (await client.post("/api/import", json=payload)).status_code == 422
            payload["text"] = "Original to keep"
            job = (await client.post("/api/import", json=payload)).json()
            await asyncio.gather(*list(app.import_jobs.values()))
            failed = (await client.get(f"/api/import/{job['id']}?owner={owner}")).json()
            assert failed["status"] == "failed"
            assert "private provider error" not in str(failed)
            with memory_store.database() as db:
                assert db.execute("SELECT original FROM imports").fetchone()[0] == payload["text"]
            assert (
                await client.post(f"/api/import/{job['id']}/retry?owner={uuid4()}")
            ).status_code == 404

            async def success(job_id, settings):
                with memory_store.database() as db:
                    db.execute(
                        "UPDATE imports SET status='ready', summary='Saved gist' WHERE id=?",
                        (job_id,),
                    )

            monkeypatch.setattr(memory_store, "summarize_job", success)
            retry = await client.post(f"/api/import/{job['id']}/retry?owner={owner}")
            assert retry.status_code == 202
            await asyncio.gather(*list(app.import_jobs.values()))
            assert memory_store.job_for_owner(job["id"], owner)["summary"] == "Saved gist"

    asyncio.run(check())


def test_pending_imports_resume_on_server_restart(settings, monkeypatch):
    from uuid import uuid4

    job = memory_store.enqueue(
        memory_store.ImportAnswer(owner=uuid4(), source="claude", text="Resume me")
    )
    called = AsyncMock()
    monkeypatch.setattr(memory_store, "summarize_job", called)

    async def check():
        async with app.lifespan(app.app):
            await asyncio.gather(*list(app.import_jobs.values()))

    asyncio.run(check())
    called.assert_awaited_once()
    assert called.call_args.args[0] == job["id"]


def test_old_memory_database_migrates_without_losing_context(settings):
    import sqlite3
    from uuid import uuid4

    owner = uuid4()
    with sqlite3.connect(memory_store.DB_PATH) as db:
        db.execute(
            "CREATE TABLE imports (id INTEGER PRIMARY KEY, owner TEXT, source TEXT, original TEXT, summary TEXT, created_at TEXT, UNIQUE(owner, source, original))"
        )
        db.execute(
            "INSERT INTO imports VALUES (1, ?, 'claude', 'private', 'existing gist', 'today')",
            (str(owner),),
        )
    assert "existing gist" in memory_store.summaries(owner)[0]["content"]
    assert memory_store.job_for_owner(1, owner)["status"] == "ready"


def test_cartesia_does_not_emit_transcripts_without_confirmed_speech(settings):
    async def check():
        stt, llm, _ = make_services(settings)
        stt.push_frame = AsyncMock()
        await stt._on_transcript({"text": "whatever", "is_final": False})
        await stt._on_transcript({"text": "whatever", "is_final": True})
        stt.push_frame.assert_not_awaited()
        await llm._client.close()

    asyncio.run(check())


def test_confirmed_speech_and_late_final_are_allowed_but_silence_expires(settings, monkeypatch):
    from pipecat.frames.frames import VADUserStartedSpeakingFrame, VADUserStoppedSpeakingFrame
    from pipecat.processors.frame_processor import FrameDirection
    from pipecat.services.cartesia.stt import CartesiaSTTService

    import speech_guard

    async def check():
        stt, llm, _ = make_services(settings)
        stt.push_frame = AsyncMock()
        # Exercise the real VAD event handler without starting provider WebSockets.
        monkeypatch.setattr(CartesiaSTTService, "process_frame", AsyncMock())
        now = [100.0]
        monkeypatch.setattr(speech_guard.time, "monotonic", lambda: now[0])
        await stt.process_frame(VADUserStartedSpeakingFrame(), FrameDirection.UPSTREAM)
        await stt._on_transcript({"text": "whatever", "is_final": False})
        assert stt.push_frame.await_count == 1  # Never blacklist genuine words.
        await stt.process_frame(VADUserStoppedSpeakingFrame(), FrameDirection.UPSTREAM)
        now[0] += 1.0
        await stt._on_transcript({"text": "whatever I choose", "is_final": True})
        assert stt.push_frame.await_count == 2
        now[0] += 2.0
        await stt._on_transcript({"text": "whatever", "is_final": True})
        assert stt.push_frame.await_count == 2
        await llm._client.close()

    asyncio.run(check())
