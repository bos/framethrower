# Apple Foundation Models Director prototype — November 12, 2026

The system framework is useful for bounded typed tools and native transcript
persistence. The on-device model did not pass the general Director editing
scenario. This evaluation does not add Apple Intelligence to the app's provider
picker or change any production startup, connection, or editing behavior.

## Environment and scope

- macOS 27.0.1 (26A434), Xcode's macOS 27.2 SDK, Swift 6.4.2.
- System model: `AFM 3 Core Advanced`; available; 8,192-token context.
- Framework-reported capabilities: tool calling, guided generation, vision.
- System-managed on-device inference; no cloud provider or account, downloaded
  runtime, CPU override, or user footage. Image tests generate red/blue pixels.
- Director tests use the existing real `EditorAutomationHost` and a disposable
  metadata-only recording. Live capture stays off and recorded-media processing
  stays suspended. All edits use ordinary validation, persistence and Undo.

These are small smoke tests, not a reliability benchmark. Raw results remain in
the ignored `build/AppleDirectorPrototype` directory.

## Observations

| Test | Observed result |
| --- | --- |
| Plain text response | `READY`; about 1.27 seconds, 66 input tokens, 3 output tokens. |
| General Director, eight tools, initial prompt | Initial transcript 1,709 tokens: 1,453 tokens for concise tool definitions, 302 for instructions (counts include different framing and are not additive). |
| General Director, camera fullscreen over two seconds | Failed across an initial instruction and clarification. Reached 4,214 tokens without applying an edit. Printed a malformed command and asked for confirmation again. |
| Same Director scenario with stronger execution instructions | Failed again across two turns. Reached 4,227 tokens, proposed camera-source changes instead of the requested overlay change, and asked for confirmation again. No edit was applied. |
| Purpose-built typed rename tool | Passed: exact title, unchanged edit state, one ordinary Undo entry. About 1.67 seconds; transcript grew from 149 to 456 tokens. |
| Rename transcript persistence | Framework `Transcript` encoded/decoded and rehydrated successfully. Correct read-only recall, no extra tool call; 487 tokens afterward. Ordinary Undo and Redo passed. |
| Guided edit-intent extraction, three independent requests | 2/3 passed. Start and duration were right in all three, but “expand the camera to full screen” repeatedly returned target `screen`. Explicit field guidance did not correct it. Failed case used only 263 context tokens. |
| Same camera target, plain text response | Correctly returned `camera`, using 95 input tokens and 3 output tokens. |
| Synthetic image, plain response | Correctly answered `Left` for the red half; 201 input tokens, 3 output tokens. Native `CGImage` attachment worked. |
| Same image, guided structured response | Failed with `ModelManagerServices.ModelManagerError error 1001`, despite reported vision/guided-generation capabilities. Root cause is unconfirmed; this is an observation on this OS/SDK/model combination. |
| Explicit context overflow | A 17,102-token prompt produced a reported 17,164-token context against the 8,192 limit. The framework threw a context-size error. With `preserveTranscript`, all 17,164 tokens remained; no app trimming, summaries, reset or cloud fallback. |

The general adapter uses Foundation Models' own tool loop and generated argument
schemas. It binds the current document in Swift and forwards calls into the same
editor API as other backends. The free-form nested mutation list still uses a
`commands_json` string after schema discovery; it is not a fully guided Swift
mutation representation. The separate rename test uses a native `@Generable`
argument type and a purpose-built tool instead. The outcomes therefore compare
two different interfaces, not just two prompts to an identical interface.

The general interface's two trials failed substantially below the context limit.
Context size is a serious ceiling, but it does not explain all the quality
problems. Guided generation guarantees an output shape, not correct intent.

## Decision

Keep this as a development-only evaluation. Do not replace Director's working
general-purpose backends or automatically select the system model from these
results. Narrow typed actions, plain image inspection, native tool orchestration
and transcript persistence remain promising. Broader adoption needs more varied
evaluation, including failure handling and semantic correctness.

The 8,192-token limit measured here belongs to this on-device model. It is not
the limit of the Foundation Models abstraction; supported server providers can
use their own larger models. Their authentication and billing are separate.

## Reproduce

Use a Mac with the existing Apple Intelligence model available. The prototype
does not install models or enable Apple Intelligence.

```sh
RUN_APPLE_FOUNDATION_MODELS=1 Tests/check-apple-foundation-models.sh

RUN_NATIVE_DIRECTOR_LIVE=1 FRAMETHROWER_VECTOR_PREVIEW=1 \
  Tests/check-native-director-live.sh --provider apple \
  --artifacts "$PWD/build/AppleDirectorPrototype/director-reproduction"

RUN_NATIVE_DIRECTOR_LIVE=1 FRAMETHROWER_VECTOR_PREVIEW=1 \
  Tests/check-native-director-live.sh --run-only --provider apple --narrow \
  --artifacts "$PWD/build/AppleDirectorPrototype/narrow-reproduction"
```

The basic suite and broad Director scenario intentionally exit nonzero when the
observed failures recur; they do not turn those failures into passing assertions.
The existing native fixture self-test also passed after adding this adapter:
actual scoped MCP/domain edits, camera timing, pointer, rename, review speed,
navigation and durable Undo/Redo, without model inference or capture.

Sources: [Foundation Models](https://developer.apple.com/foundation-models-framework/),
[native tool calling](https://developer.apple.com/documentation/foundationmodels/expanding-generation-with-tool-calling),
[session persistence](https://developer.apple.com/documentation/foundationmodels/languagemodelsession),
[image attachments](https://developer.apple.com/documentation/foundationmodels/analyzing-images-with-multimodal-prompting).
