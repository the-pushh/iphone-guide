# Orb

A small native iOS voice + text app. A colored mark blooms into an orb on an empty screen, then moves into the bottom conversation controls. Spoken bot text appears on the left; final and interim user transcripts appear on the right. Typed messages use the same voice conversation and receive spoken replies.

## Run the server

Requires Python 3.11–3.13 and [uv](https://docs.astral.sh/uv/getting-started/installation/).

```sh
cd server
cp -n .env.example .env
# Fill OPENROUTER_API_KEY and CARTESIA_API_KEY in .env.
uv sync --python 3.12
LOGURU_LEVEL=INFO uv run uvicorn app:app --host 0.0.0.0 --port 7860
```

The `.env` file is ignored by Git. Provider keys stay on the server. `/health` reports whether both keys are configured; it does not validate them with the providers.

Edit **[server/system_prompt.md](server/system_prompt.md)** to define the bot’s behavior. It contains the context-extraction instructions and an optional ChatGPT/Claude import question within the first two questions. Each new session rereads it. `GREETING` in `.env` is a separate opening line, spoken once after the client is ready. Set it to an empty value for no greeting. Messages now support copyable prompt blocks and Open ChatGPT/Open Claude buttons. The handoff uses native app links and video-call PiP. The prompt requires confirmed app actions before reporting them as completed.

## Run the iPhone app

Open **[ios/Orb.xcodeproj](ios/Orb.xcodeproj)** in Xcode. Swift packages resolve automatically. Select the Orb scheme and an iPhone simulator, then Run. For a physical iPhone, select your development team in Signing & Capabilities.

- Simulator: the default server URL is `http://localhost:7860`.
- iPhone: in the app’s connection settings, use `http://YOUR_MAC_LAN_IP:7860`. Keep both devices on the same network and allow the local-network permission.
- The conversation connects after the entrance animation, requesting microphone permission the first time. If denied, you can still type and hear replies. Use **Start a conversation** to retry a failed connection.
- The microphone button mutes/unmutes audio capture. Use End conversation to end the session. Voice continues while the app is in the background.
- Reconnecting starts a fresh conversation. The on-screen transcript remains until you choose New chat. Chats are not persisted.

The server is for local development on a trusted network. Before internet deployment, add authenticated session creation, HTTPS, rate limits, and TURN connectivity for mobile networks. Never place the provider keys in the app.

## Stack and latency

- Native SwiftUI, iOS 17+, Pipecat iOS SDK 1.3.0, SmallWebRTC transport 1.3.0.
- Pipecat Python 1.11.0; dependencies pinned in `server/uv.lock`.
- OpenRouter **`z-ai/glm-5.3-flash`**, streaming with low reasoning effort (this model requires reasoning).
- Cartesia **Sonic 3** synthesis and **Ink Whisper** streaming transcription, both configurable in `.env`.
- Silero voice activity detection with a 250 ms speech onset and 300 ms silence threshold. Pipecat coordinates turn completion, barge-in, context, and RTVI text events. Actual response latency also depends on transcription finalization, provider timing, and server location; see the measured voice latency below.
- Bot messages stream directly from the LLM, preserving Markdown, whitespace, and code fences. The opening greeting uses speech timestamps. Cartesia receives filtered narration: Markdown styling is removed and fenced code/prompt blocks are omitted from speech.

The orb is drawn in SwiftUI and reused during the entrance and conversation. It responds to audio levels and respects Reduce Motion. No image assets are needed for it.

## Chat controls

- MarkdownUI renders headings, bold/italic text, lists, quotes, tables, links, and code blocks.
- Each code/prompt block has its own Copy button; bot messages have Copy, Share, and timestamps. Long-press your own message to use it as a new draft.
- Chat options include search, sharing the transcript, and starting a new chat. Chats remain in memory; share a transcript to keep it.
- Scrolling up pauses following new messages. The down-arrow returns to the latest message.
- Stop interrupts a response without ending the voice session.
- Standalone `[Open ChatGPT](https://chatgpt.com/)` and `[Open Claude](https://claude.ai/)` links outside code blocks render as buttons below the bot message. They copy the first complete text/prompt block, then open the native app after starting call PiP. Incomplete responses disable handoff buttons to avoid copying partial prompts.
- Copy/share controls and timestamps appear only below assistant responses.
- Open ChatGPT / Open Claude copies the prompt, checks the native app URL scheme, starts call PiP when connected, and opens the installed app. It never silently falls back to Safari. ChatGPT’s `chatgpt://` scheme is checked at runtime; Claude uses the `claude://` scheme. Both native links must be checked against the installed app version.
- Voice continues in the background through WebRTC and the audio background mode. Chat options → Float call window also starts PiP. End conversation stops the microphone and PiP. iOS can interrupt audio when another app starts recording or a phone call arrives.
- Return after handoff to see the separate **Import answer** sheet, or open it from the download icon in the header. Paste the copied reply and tap **Save context**. The chat composer remains separate.
- Originals and generated summaries are stored in `server/.data/memory.sqlite3` (ignored by Git), scoped by a random per-installation identifier. Only summaries enter voice context and appear in chat. New sessions load the latest 20 summaries. Repeated identical imports reuse the saved summary. Save context returns immediately with a durable background job. A chat banner shows progress, and the bot asks a useful follow-up while the same OpenRouter model summarizes separately. Failed summaries keep the original and offer Retry; pending jobs resume after a server restart. The iPhone persists the job ID to resume polling after relaunch.
- This is still a trusted-LAN prototype: the installation identifier isolates storage but is not authentication. Deleting `server/.data/memory.sqlite3` removes all saved imports. Chat messages remain in memory.
- PiP requires a supported physical device and an active voice session. If iOS refuses to start it, Orb shows an error and keeps the current app open. Native app handoff and PiP were confirmed on the iPhone 14 Pro. The call view now requests 64×64 content, renders the same chat orb in BGRA video frames, and pulses while speaking. iOS owns the floating window size limits; the preference cannot guarantee a particular percentage of screen area. Pinch inward to shrink the window ([Apple instructions](https://support.apple.com/guide/iphone/multitask-with-picture-in-picture-iphcc3587b5d/ios)).

For a populated UI preview without API calls, launch a Debug build with the `--chat-preview` argument. `--pip-preview` displays the actual PiP video layer with a speaking-state toggle, without requesting microphone access. This fixture is disabled in Release builds.

## Checks

```sh
scripts/check-ios-models.sh
```

```sh
cd server
uv run pytest -q
uv run ruff check .
```

```sh
xcodebuild -project ios/Orb.xcodeproj -scheme Orb \
  -sdk iphonesimulator -configuration Debug \
  -derivedDataPath .build CODE_SIGNING_ALLOWED=NO build
```

If your command-line developer directory points to CommandLineTools, prefix the build with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`.

`ios/project.yml` is the XcodeGen source. After changing it, run `cd ios && xcodegen generate` and commit the generated project alongside the spec.

References: [Pipecat iOS transport](https://github.com/pipecat-ai/pipecat-client-ios-small-webrtc), [Cartesia STT integration](https://reference-server.pipecat.ai/en/latest/api/pipecat.services.cartesia.stt.html), [OpenRouter model catalog](https://openrouter.ai/api/v1/models).

## Speech and starting moves

Cartesia transcripts are accepted only after Silero confirms speech. Interim text has a 0.5-second grace period after speech ends; final text has 2 seconds for provider latency. This filter runs inside the STT service before either RTVI or the chat can see the text. Genuine spoken words are not blacklisted. VAD uses confidence 0.8, a 0.25-second onset, and a 0.3-second stop.

Imported context now extracts Games, Quests, candidate Moves and constraints. Completed imports help the bot suggest a Game. The current timing demo delays its Quest and Move breakdown by 30 seconds while conversation continues, then recommends a starting Move with a time box, definition of done and a reason to prioritize it. Reconnecting with saved context skips the repeated import offer.

PiP frames use IOSurface-backed BGRA buffers; ordinary CPU-only buffers rendered in Simulator but did not show the orb in the phone's PiP window. The user confirmed the orb is visible after the IOSurface change. Check the backing with `scripts/check-ios-video.sh`.

## Voice latency and audio resume

`OPENROUTER_REASONING_EFFORT` defaults to `low` for both conversation and background extraction. GLM 5.3 Flash requires reasoning and currently defaults to `max` at the provider; supported levels are `low`, `high`, and `max`. In a same-context check, first visible text took 46 seconds with the provider default and 3 seconds at low; these are measurements, not a latency guarantee. Reasoning remains enabled.

The iPhone reactivates its audio session on reconnect, returning to Orb, and resumable audio interruptions. It keeps headphones selected and switches a built-in receiver route to the loudspeaker. Status changes to Writing when text starts and clears Thinking when generation finishes. Server-side WebRTC output was verified to carry non-silent speech for the saved-context response; phone audibility still requires device verification.

### Game exploration timing demo

The assistant proposes a Game immediately using a standalone `**Game:** title` line. The iOS client starts a nonblocking 30-second demo delay, with a countdown above chat. Conversation remains available throughout. After the delay and a pause in the current voice turn, the client asks the server to propose Quests, candidate Moves and a best starting Move using the latest conversation. The delay simulates exploration; no main-app Game/Quest engine or external research is implemented here. Disconnecting or starting a new chat cancels the demo. Repeated suggestions of the same title do not restart it during a session.
