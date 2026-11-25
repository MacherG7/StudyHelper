# API-Referenz der KI-Anbieter (Stand 2026-11-25)

Grundlage für Phase 2 (`StudyAI`). Alle Angaben aus der offiziellen Dokumentation (Quellen unten), nicht aus dem
Gedächtnis. Vor Änderungen an den Anbietern hier nachsehen und die Quellen erneut lesen; Abweichungen hier
nachtragen (Datum ändern).

## Anthropic (Claude) – `https://api.anthropic.com`

- Header: `x-api-key`, `anthropic-version: 2026-10-21` (aktuell), `content-type: application/json`.
- `POST /v1/messages`: `model`, `max_tokens`, `system` (String oder Textblöcke), `messages` (Rollen user/assistant;
  Inhalte: `text`, `image` mit `source {type: base64, media_type, data}`, `tool_use`, `tool_result`), `tools`
  (`name`, `description`, `input_schema`, optional `strict`), `stream`.
  - Reasoning: `thinking: {type: "adaptive", display: "summarized"}` + `output_config: {effort: low|medium|high|xhigh|max}`.
    „Aus“ je Modell: `{type: "disabled"}` (nur wenn unterstützt) bzw. `{type: "between_tools"}` (Sonnet 5.5, nur bis `high`).
    `budget_tokens` (`{type: "enabled"}`) nur noch bei alten Modellen (≥ 1024, < `max_tokens`).
  - Strukturausgabe: `output_config: {format: {type: "json_schema", schema: {...}}}`.
  - Seit Version 2026-10-21 führen `temperature`, `top_p`, `top_k` zu 400. Kein Assistant-Prefill bei aktuellen Modellen.
  - Forced `tool_choice` (`any`/`tool`) gibt bei Opus 5.5, Sonnet 5.5, Fable 5.1/5.2 einen 400 → nur `auto`.
  - `stop_reason`: `end_turn`, `max_tokens`, `tool_use`, `pause_turn`, `refusal` (dann `stop_details.category`).
- PDF als Eingabe: Content-Block `{"type":"document","source":{"type":"base64","media_type":"application/pdf",
  "data":"<base64>"}}` (weitere Quellen `url`/`file`; optional `cache_control`). Grenzen je Anfrage: 128 MB Nutzlast,
  600 Seiten (100 bei Kontextfenster unter 1 Mio.). Jede Seite geht als Bild und als extrahierter Text ein (Text
  ca. 1.500–3.000 Tokens je Seite, Bild bis 1.568 Tokens je Seite); braucht ein Modell mit Bildeingabe. In der App:
  `MessageContent.document(DocumentPayload)`, nur wo Bilder erlaubt sind (Phase 3f/4).
- Usage: `input_tokens`, `output_tokens`, `cache_creation_input_tokens`, `cache_read_input_tokens`,
  `output_tokens_details.thinking_tokens` (nullable).
- Streaming (SSE): `message_start` (Usage mit `input_tokens`) → je Block `content_block_start`, `content_block_delta`
  (`text_delta`, `thinking_delta`, `signature_delta`, `input_json_delta` mit `partial_json`), `content_block_stop`
  → `message_delta` (kumulierte `output_tokens`, `stop_reason`) → `message_stop`. `ping` jederzeit, `error`
  (`{"type":"error","error":{"type":"overloaded_error",...}}`). Unbekannte Events ignorieren.
- `GET /v1/models?limit=&after_id=`: `data[]` mit `id`, `display_name`, `max_input_tokens`, `max_tokens`,
  `capabilities` (`image_input.supported`, `thinking.types.{adaptive,between_tools,disabled,enabled}.supported`,
  `effort.{low,medium,high,xhigh,max}.supported`, `structured_outputs.supported`); `has_more`, `last_id`.
- Fehler: 400 invalid_request, 401 authentication, 402 billing, 403 permission, 404 not_found, 413, 429 rate_limit
  (`retry-after`; Spend-Limit `enforced_spend_limit_reached` nicht wiederholen), 500 api_error, 529 overloaded.
- Preise USD pro 1 Mio. Tokens (Input / Output; Cache-Lesen): Opus 5.5 4 / 20; 0,20 · Sonnet 5.5 2 / 10; 0,10 ·
  Haiku 5.5 0,10 / 0,50 (bis 100K Prompt) · Fable 5.2 8 / 40; 0,20 · Opus 5 5 / 25 · Sonnet 5 2 / 10 ·
  Opus 4.8/4.7/4.6 5 / 25 · Sonnet 4.6 3 / 15 · Haiku 4.5 1 / 5. Cache-Schreiben (5 Min.) = 1,25 × Input.
  Haiku 5.5: 0,10 / 0,50 bis 100K Prompt-Tokens, darüber 0,50 / 2,50 (Quelle: Anthropic Modellübersicht).

## OpenAI – `https://api.openai.com`

- Header: `Authorization: Bearer <key>`.
- Empfohlen: Responses API `POST /v1/responses` (Chat Completions bleibt, aber Function Calling fehlt dort bei
  manchen Reasoning-Modellen).
  - Felder: `model`, `input` (String oder Items; Bild als `{type: "input_image", image_url: "data:image/png;base64,..."}`,
    Text als `{type: "input_text", text}`), `instructions` (Systemprompt), `max_output_tokens` (inkl. Reasoning;
    bei Erreichen `status: incomplete`), `reasoning: {effort, summary: "auto"}`, `text: {format: {type: "json_schema",
    name, strict: true, schema}}`, `tools: [{type: "function", name, description, parameters, strict}]`, `stream`.
  - PDF als Eingabe: Content-Part `{type: "input_file", filename: "<name>.pdf", file_data:
    "data:application/pdf;base64,<base64>"}`, optional `detail: auto|low|high` (von der App nicht gesetzt). Unter 50 MB
    je Datei und in Summe je Anfrage; braucht ein Modell mit Bildeingabe (extrahierter Text und Seitenbilder werden
    beide verwendet).
  - `reasoning.effort`: `none`, `minimal`, `low`, `medium`, `high`, `xhigh`, `max` – je Modell nur eine Teilmenge
    (z. B. GPT-6 Astra lehnt `none` ab; GPT-6.1 Sol kein `none`/`minimal`). Keine API-Abfrage dafür.
  - Tool-Aufruf: Output-Item `{type: "function_call", call_id, name, arguments: "<JSON-String>"}`; Antwort als
    Input-Item `{type: "function_call_output", call_id, output}`; Reasoning-Items mit zurückgeben.
- Streaming (SSE): `response.output_text.delta`, `response.reasoning_summary_text.delta`,
  `response.output_item.added` / `response.function_call_arguments.delta` / `.done`, `response.completed` (mit
  `response.usage`), `error`.
- Usage: `input_tokens`, `input_tokens_details.cached_tokens`, `output_tokens` (enthält Reasoning),
  `output_tokens_details.reasoning_tokens`.
- `GET /v1/models`: `data[] {id, created, owned_by}` – **ohne Fähigkeiten** (Reasoning, Bilder).
- Fehler: `error {message, type, param, code}`; 401; 429 (`Retry-After`; `credit_balance_exhausted`,
  `*_spend_limit_exceeded`, `*_usage_limit_exceeded` nicht wiederholen); 500; 503 `server_is_overloaded`.
- Preise USD pro 1 Mio. (Input / Cache / Output): siehe Preistabelle in `StudyCore/Pricing.swift`
  (u. a. gpt-6.2-sol 2 / 0,10 / 10, gpt-6-luna 0,10 / 0,01 / 0,50, gpt-5.5 5 / 0,50 / 30).

## OpenAI-kompatibel (Ollama, LM Studio, llama.cpp, vLLM)

- `POST {base}/v1/chat/completions`: `messages` (Bilder nur base64-Content-Parts), `tools` (kein `tool_choice` bei
  Ollama), `stream`, `stream_options: {include_usage: true}`, `reasoning_effort` (Ollama auch `reasoning.effort`).
- Keine PDF-Eingabe: die App lehnt PDFs vor dem Senden ab („Dieses Modell kann keine PDFs verarbeiten.“); ebenso
  beim Apple-Modell.
- `GET {base}/v1/models`.
- Ollama nativ: `GET /api/tags` (`models[] {name, model, size, details}`), `POST /api/show {model}` →
  `capabilities` (z. B. `completion`, `vision`, `thinking`, `tools`) und optional `thinking.values`.

## Apple Foundation Models (On-Device)

- `SystemLanguageModel.default.availability`: `.available` / `.unavailable(.appleIntelligenceNotEnabled |
  .deviceNotEligible | .modelNotReady)` (iOS 26.0).
- `LanguageModelSession(model:tools:instructions:)`, `respond(to:options:)`, `streamResponse(to:options:)`,
  `respond(to:generating:)` mit `@Generable`/`@Guide` (Guided Generation), `Tool`-Protokoll.
- `contextSize` ab iOS 26.0 (back-deployed), `tokenCount(for:)` ab iOS 26.4, `session.usage` ab iOS 27,
  Bilder (`Attachment`, `ImageAttachmentContent`) ab iOS 27.

## Quellen

- Anthropic: https://platform.claude.com/docs/en/api/messages/create · …/build-with-claude/streaming ·
  …/api/models/list · …/api/versioning · …/build-with-claude/adaptive-thinking · …/build-with-claude/effort ·
  …/api/errors · …/about-claude/pricing · …/build-with-claude/pdf-support
- OpenAI: https://developers.openai.com/api/reference/resources/responses/methods/create ·
  …/responses/streaming-events/ · https://developers.openai.com/api/docs/guides/reasoning · …/guides/migrate-to-responses ·
  …/guides/structured-outputs · …/guides/function-calling · …/guides/streaming-responses · …/guides/error-codes ·
  …/guides/pdf-files · https://developers.openai.com/api/docs/pricing · https://developers.openai.com/api/reference/resources/models/methods/list
- Ollama: https://docs.ollama.com/api/openai-compatibility · https://docs.ollama.com/openapi.yaml ·
  https://docs.ollama.com/api/tags · https://docs.ollama.com/capabilities/thinking · https://docs.ollama.com/capabilities/vision
- Apple: https://developer.apple.com/documentation/foundationmodels (SystemLanguageModel, Availability, contextSize,
  LanguageModelSession, streamResponse, Generable, Tool, Usage, Attachment, ImageAttachmentContent)
