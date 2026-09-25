"""Reject STT hallucinations before they reach RTVI or the conversation."""

import time

from pipecat.frames.frames import VADUserStartedSpeakingFrame, VADUserStoppedSpeakingFrame
from pipecat.services.cartesia.stt import CartesiaSTTService


class SpeechConfirmedCartesiaSTT(CartesiaSTTService):
    def __init__(self, **kwargs):
        super().__init__(**kwargs)
        self._speech_confirmed = False
        self._speech_ended_at = float("-inf")

    async def process_frame(self, frame, direction):
        # The user aggregator sends Silero VAD events upstream to this service.
        if isinstance(frame, VADUserStartedSpeakingFrame):
            self._speech_confirmed = True
        elif isinstance(frame, VADUserStoppedSpeakingFrame):
            self._speech_confirmed = False
            self._speech_ended_at = time.monotonic()
        await super().process_frame(frame, direction)

    async def _on_transcript(self, data):
        # Final results can legitimately arrive after the acoustic end of speech.
        grace = 2.0 if data.get("is_final") else 0.5
        if not self._speech_confirmed and time.monotonic() - self._speech_ended_at > grace:
            return
        await super()._on_transcript(data)
