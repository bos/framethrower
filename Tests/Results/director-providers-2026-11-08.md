# Director provider comparison — audited first pass

**One repetition of 16 fixed synthetic scenarios per profile (80 scenario runs).** No private recording, private history, audio, or media frames were used. Inferences ran sequentially through the same frozen production planner/session/dispatcher. Model-specific prompts were not tuned. This is an application-backend comparison, not a general model-IQ ranking.

## Results

The product column includes all 16 requests. The comparable column excludes one shared production-router failure that withheld the required sequencing tool from every provider. Two test-fixture Undo failures are corrected by independent fresh-path audits, without any new inference. Original outputs, scores and reports remain unchanged.

| Profile | Model / effort | Audited product success | Comparable cases | Successful scenario p50 / p95 | Matched-case p50 / p95 | CLI failures |
|---|---|---:|---:|---:|---:|---:|
| localQwen | Qwen3-8B-Q4_K_M / thinking_off | 11/16 | 11/15 | 19.78s / 39.61s | 19.52s / 39.61s | 0 |
| claudeHaiku | claude-haiku-5-5 / low | 11/16 | 11/15 | 5.20s / 9.44s | 5.20s / 9.44s | 2 |
| claudeSonnet | claude-sonnet-5-5 / medium | 15/16 | 15/15 | 6.12s / 10.03s | 5.66s / 9.19s | 0 |
| openAIFast | gpt-6-luna / medium | 12/16 | 12/15 | 8.77s / 19.57s | 8.77s / 19.57s | 0 |
| openAIBalanced | gpt-6.1-sol / medium | 13/16 | 13/15 | 10.23s / 17.04s | 10.23s / 17.04s | 0 |

Sonnet completed all 15 provider-comparable cases in this pass. Its median on the nine cases passed by every profile was about 5.7 seconds; Qwen's was about 19.5 seconds. These are observed end-to-end backend results from this small corpus, not confidence bounds or a guarantee on other requests.

Latency is the sum of logical user-turn wall times from submit through the final host action/question. It includes actual CLI transport, model startup, validation and durable application; it excludes post-hoc grading and scripted manual-edit setup. Matched-case latency uses the same nine successful cases across profiles, avoiding faster-failure bias. Each CLI/local model request launches a fresh process; subsequent calls have unknown OS/provider cache state. Qwen uses native Metal. No generic startup duration was subtracted and called inference time.

| Profile | First observed transport | Subsequent transport p50 / p95 | Provider-reported API p50 | Observed resolved model | CLI version |
|---|---:|---:|---:|---|---|
| localQwen | 22.62s | 19.38s / 20.88s | — | not reported | not reported |
| claudeHaiku | 3.83s | 5.07s / 6.57s | 2.07s | claude-haiku-5-5 | 2.1.319 (Claude Code) |
| claudeSonnet | 5.05s | 4.88s / 6.01s | 2.40s | claude-sonnet-5-5 | 2.1.319 (Claude Code) |
| openAIFast | 6.06s | 8.60s / 10.11s | — | not reported | codex-cli 0.167.0 |
| openAIBalanced | 6.49s | 7.97s / 13.00s | — | not reported | codex-cli 0.167.0 |

Codex does not emit a resolved model identifier in these completions; the requested identifier and CLI version are recorded instead of inventing a resolution. Provider API timing is reported only when exposed, and is not asserted to be pure inference time. Raw usage/cache counts are retained with every response.

## Failure evidence

- **Retiming an existing edit:** Sonnet moved B, including its attached camera/anchor, to the requested time. Qwen and Luna created a new mark instead. Sol deleted B. Haiku computed the requested time but asked an extra clarification about the Ref/Zoom label kind. The application's literal guard skipped numeric “and” in “one and a half,” leaving opcodes unconstrained.
- **Naming through context:** Sol deleted Box 1 on the initial note request; Luna deleted it on the follow-up. Haiku asked another note confirmation. Sonnet and Qwen applied both notes correctly while retaining the actual intervening manual pointer change and Undo. Their raw Undo-audit failures were fixture-path collisions, corrected below.
- **Missing selection:** Qwen guessed a region and applied a zoom. The four cloud profiles asked for clarification.
- **Selected-box duration:** Qwen used a 0.4-second move followed by a 1.6-second hold rather than a two-second move.
- **Missing movement duration:** Sonnet and Sol asked, then used the supplied duration at the original frozen playhead. Haiku, Luna and Qwen guessed a duration without asking.
- **Shared routing failure:** “return to full frame over 0.8 seconds” was misread by the host's named-edit regex as an edit identifier. All profiles received only `frame_edits`, clarification and lookup tools; `plan_sequence` was unavailable. This remains a product failure for all five, and is excluded only from the secondary provider-comparable denominator. The four returned answers could not perform the requested sequence; Haiku instead had a CLI failure.
- **CLI availability:** Haiku had two normalized CLI exit-1 failures, one in owned-Undo confirmation and one in the shared-router case. No completion was fabricated, no fallback was used, and these are not labeled model-semantic errors.

All 103 received completions named a structurally valid offered tool, yet some applied the wrong operation. Structural tool validity alone did not establish instruction following. No case invoked the existing rejected-plan corrective retry: accepted wrong actions passed the old host guard. Audit-corrected successes were consequently first-attempt successes as well.

## Oracle audit

The benchmark tested ordinary Undo on an independent disposable editor after each mutation. Its two-turn context case reused the same `undo-oracle.framethrower` destination. On the second turn, a new editor correctly refused to overwrite the first turn's file. This was a test-fixture error, not a provider or application Undo defect.

For Sonnet and Qwen, the original canonical actual/expected mutation files already matched. The independent audit verified that saved metadata equaled the archived after-state, the latest Undo snapshot equaled the actual second request's authoritative state, and a unique-path copy successfully saved, Undid to that exact state, Redid to the actual final state, and reopened durably. The correction JSON and its source/checksum manifest are in `audit/`; no model was called again. `results.jsonl` and the original `report.md` are untouched.

## Method and limits

The corpus includes fresh paraphrases plus a historical noisy-transcript case, explicit and relative times, selected/missing targets, move/hold/return, stable identities, reference creation, box-linked deletion, keep/replace conflicts, frozen-anchor clarification, real tool-result/manual-change/Undo context, paginated history and an untrusted synthetic note. Oracles compare actual effective state, timing, identity relations, host transitions and durable history; prose is not keyword- or model-graded. Fresh UUIDs and redundant stationary holds are canonicalized; existing identities and unrelated metadata stay exact. New ramp values are free when the user did not specify them.

The same original production ChatCompletions request is preserved, but cloud CLIs package it in a common planner-only JSON-envelope instruction and strict structured-output schema; local Qwen uses its direct native tool protocol. Host routing/schema constraints solve part of the task: absolute start/duration/path are pinned, single literal create opcodes are narrowed, history ownership is guarded, and conflict follow-ups choose keep/replace against a frozen proposal. These product mechanisms must not be presented as raw model reasoning.

There is one observation per scenario/profile. p50/p95 use nearest-rank summaries; p95 can be the maximum. Effort labels are configured profile settings, not equal cross-vendor compute budgets. User-turn success latency excludes failures and must be read alongside success counts and the matched-case table. Cache, account/CLI service variability and this regression-oriented corpus limit generalization. No three-repetition claim is made.

## Pinned baseline and subsequent fixes

The baseline binary SHA-256 is `85c5530bdca75564441982a21523156ef369465bf37a63c7859722d1bb8fb4e9`, with source-graph fingerprint `cd2c460d0cd43b2f20cc7fb9ad329596bf750f99277abcc703422624b614f247`. The evaluator source SHA-256 is `35adc0d939038166b51a1e4f4b5ac02e0551fcfc946c2db610ef2c29a2c0ee47`; the CLI bridge SHA-256 is `020356788432e2619a5b868d2df75b64334c902f44fc0c4ca727605d1a443369`. These identify the initial five profiles tested here, rather than the current source tree.

After the cohort finished, narrow host fixes were added for numeric conjunctions exposing wrong management operations, literal Give/Add/Set box-note requests exposing deletion, and reserved framing words falsely identifying named edits. The future evaluator also uses a unique Undo-audit destination per mutation. Those changes were not present in this cohort, and no post-fix model accuracy is claimed. The router fix and management guards have separate deterministic regressions.

## Artifacts

Detailed synthetic requests/responses and metadata remain ignored local build artifacts, rather than committed data. On the benchmark machine they are under `/Users/bosullivan/dev/framethrower/build/DirectorProviderEvaluation/text-r1-20261108T180247Z-3421fcf7/`; paths below are relative to that directory. Another checkout will not contain these local files. The harness and this report are durable repository files; a future run creates a new directory and records its own baseline. The original pinned cohort was never rebuilt or rerun.

- `manifest.json`: fixed synthetic fixtures, corpus checksum, source build fingerprint, exact pinned helper path/hash and requested profiles.
- `baseline.json`: pinned binary/source/helper hashes.
- `schedule.json`: seeded interleaved order.
- `results.jsonl`, `report.md`: immutable raw cohort.
- `audited-results.jsonl`, `audited-summary.json`: explicit corrected records and shared-host classification.
- Per-scenario directories: original requests/responses, before/after metadata, canonical oracle states, actual conversation and host diagnostic events.
- `audit/oracle-corrections.json`: independent fresh-path Undo evidence, with no new inference.

## Static image transport check

A separate smoke check sends an original-size 1,000 × 600 synthetic PNG containing two filled rectangles. Each cloud profile identifies the blue rectangle through its native image-input path; the oracle compares normalized bounds against the known source pixels with a ten-pixel tolerance. Final checks passed for Haiku, Sonnet, Luna and Sol, each returning the exact expected bounds. This verifies attachment transport and a simple visual target, not OCR, real-window recognition or footage-editing accuracy. Local Qwen3-8B remains text-only.

Live tests exposed and fixed two Claude image-protocol issues: stream-json input requires stream-json output with verbose events, and Haiku can emit a harmless `thinking_tokens` system diagnostic. The text comparison used its original immutable helper snapshot; these image fixes do not revise those results. `Tests/evaluate-director-vision.py --run` reproduces the sequential synthetic check using the current helper. Initial failures and final smoke outputs remain under the ignored `build/DirectorProviderEvaluation/vision-smoke/` directory. No actual video was opened or processed.
