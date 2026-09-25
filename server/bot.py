"""Streaming Cartesia → OpenRouter → Cartesia voice pipeline."""

from pipecat.audio.vad.silero import SileroVADAnalyzer
from pipecat.audio.vad.vad_analyzer import VADParams
from pipecat.frames.frames import LLMRunFrame, TTSSpeakFrame
from pipecat.pipeline.pipeline import Pipeline
from pipecat.pipeline.worker import (
    PipelineParams,
    PipelineWorker,
    ProcessorUnusablePolicy,
)
from pipecat.processors.aggregators.llm_context import LLMContext
from pipecat.processors.aggregators.llm_response_universal import (
    LLMContextAggregatorPair,
    LLMUserAggregatorParams,
)
from pipecat.services.cartesia.stt import CartesiaSTTService
from pipecat.services.cartesia.tts import CartesiaTTSService
from pipecat.services.openrouter.llm import OpenRouterLLMService
from pipecat.transports.base_transport import TransportParams
from pipecat.transports.smallwebrtc.transport import SmallWebRTCTransport
from pipecat.utils.text.markdown_text_filter import MarkdownTextFilter
from pipecat.workers.runner import WorkerRunner

from config import Settings
from memory_store import summaries
from speech_guard import SpeechConfirmedCartesiaSTT


def make_services(settings: Settings):
    stt = SpeechConfirmedCartesiaSTT(
        api_key=settings.cartesia_key,
        settings=CartesiaSTTService.Settings(model=settings.stt_model),
    )
    llm = OpenRouterLLMService(
        api_key=settings.openrouter_key,
        settings=OpenRouterLLMService.Settings(
            model=settings.model,
            system_instruction=settings.system_prompt or None,
            # GLM's default is max; low keeps required reasoning while reducing voice latency.
            extra={"extra_body": {"reasoning": {"effort": settings.reasoning_effort}}},
        ),
    )
    tts = CartesiaTTSService(
        api_key=settings.cartesia_key,
        settings=CartesiaTTSService.Settings(model=settings.tts_model, voice=settings.voice),
        text_filters=[MarkdownTextFilter(params=MarkdownTextFilter.InputParams(filter_code=True))],
    )
    return stt, llm, tts


async def run_bot(connection, settings: Settings, owner=None):
    transport = SmallWebRTCTransport(
        connection, TransportParams(audio_in_enabled=True, audio_out_enabled=True)
    )
    stt, llm, tts = make_services(settings)
    imported = summaries(owner) if owner else []
    context = LLMContext(messages=list(imported))
    user, assistant = LLMContextAggregatorPair(
        context,
        user_params=LLMUserAggregatorParams(
            vad_analyzer=SileroVADAnalyzer(
                params=VADParams(confidence=0.8, start_secs=0.25, stop_secs=0.3)
            ),
        ),
    )
    pipeline = Pipeline([transport.input(), stt, user, llm, tts, transport.output(), assistant])
    worker = PipelineWorker(
        pipeline,
        params=PipelineParams(
            audio_in_sample_rate=16000,
            audio_out_sample_rate=24000,
            enable_metrics=True,
            enable_usage_metrics=True,
        ),
        idle_timeout_secs=1800,
        processor_unusable_policy=ProcessorUnusablePolicy.END,
    )
    runner = WorkerRunner(handle_sigint=False)
    await runner.add_workers(worker)
    greeted = False

    @worker.rtvi.event_handler("on_client_ready")
    async def ready(rtvi):
        nonlocal greeted
        if not greeted:
            greeted = True
            if imported:
                context.add_message(
                    {
                        "role": "user",
                        "content": "App status: My saved context is available above. Help me act on it: identify a "
                        "useful Game and Quest and propose one best starting Move with a time box and "
                        "definition of done. If current availability would change the choice, ask just "
                        "that question. Do not repeat the import offer.",
                    }
                )
                await worker.queue_frames([LLMRunFrame()])
            elif settings.greeting:
                await worker.queue_frames([TTSSpeakFrame(settings.greeting)])

    @transport.event_handler("on_client_disconnected")
    async def disconnected(transport, client):
        await runner.cancel()

    @worker.rtvi.event_handler("on_client_message")
    async def client_message(rtvi, message):
        if message.type == "stop-response":
            await rtvi.interrupt_bot()
        elif message.type == "exploration-ready" and isinstance(message.data, str):
            context.add_message({
                "role": "user",
                "content": "App status: The 30-second exploration demo delay has finished for this Game: "
                + message.data[:1000]
                + "\nUsing the conversation and any corrections since it was proposed, suggest a brief "
                "Quest and candidate Moves, then pick one best starting Move with a time box, "
                "definition of done and reason. This was a simulated delay, not external research. "
                "Do not repeat the Game label or invent exploration findings. If the user has rejected "
                "this Game or changed priorities, honor that instead.",
            })
            await worker.queue_frames([LLMRunFrame()])
        elif message.type == "import-pending":
            await rtvi.interrupt_bot()
            context.add_message(
                {
                    "role": "user",
                    "content": "App status: My imported answer has been saved and is being summarized in the background. "
                    "Please keep our conversation going while it runs. Briefly acknowledge this and ask one "
                    "useful, easy question about my current priorities or what I want help with today. "
                    "Use what I have already told you; don't repeat an answered question or ask me to wait. "
                    "You do not have the imported summary yet, so don't guess its contents.",
                }
            )
            await worker.queue_frames([LLMRunFrame()])
        elif message.type == "refresh-memory" and owner:
            latest = summaries(owner)
            added = False
            for item in latest:
                if item not in imported:
                    context.add_message(item)
                    imported.append(item)
                    added = True
            if added:
                context.add_message(
                    {
                        "role": "user",
                        "content": "App status: The imported context is now ready above. Extract the most useful Game, "
                        "Quest and candidate Moves, then recommend one best starting Move now, grounded in "
                        "what I said and my current constraints. State the action, a short time box, what done "
                        "looks like, and why it comes first. Keep it brief. If one missing fact would change "
                        "the recommendation, ask only that question; don't restart onboarding.",
                    }
                )
                await worker.queue_frames([LLMRunFrame()])

    await runner.run()
