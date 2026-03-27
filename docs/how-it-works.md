# Live Voice Practice Platform — How It Works (Developer Guide)

This document explains **how this application works end-to-end**, where the key code lives, and how to contribute safely.

## 1) What this app does

Live Voice Practice is a **real-time voice training** web app. A trainee:

1. Opens the web UI.
2. Picks a training scenario.
3. Starts a real-time voice conversation with an AI “customer”.
4. Ends the session and requests an **evaluation** (scoring + feedback).

Under the hood, the app combines:

- **Real-time voice + avatar session** via Azure Voice Live (proxied through the backend WebSocket).
- **Post-session conversation evaluation** via Azure OpenAI (through Azure AI Foundry / AIServices endpoint).
- **Pronunciation assessment** via Azure Speech.

## 2) High-level architecture

The app is a single web endpoint:

- The **backend** (Flask) serves the static frontend assets and exposes API endpoints.
- The **frontend** (React) calls the backend APIs and opens a WebSocket to the backend.
- The backend WebSocket **proxies messages** between the browser and Azure Voice Live.

Mermaid overview:

```mermaid
flowchart LR
  Browser[Browser UI\nReact + TypeScript] -->|HTTP /api/*| Flask[Backend\nFlask API]
  Browser -->|WebSocket /ws/voice| Flask

  Flask -->|Voice session (SDK)| VoiceLive[Azure Voice Live]
  Flask -->|Chat eval| AOAI[Azure OpenAI\n(AI Foundry endpoint)]
  Flask -->|Pronunciation| Speech[Azure Speech]

  subgraph Azure
    VoiceLive
    AOAI
    Speech
  end
```

## 3) Repository tour (where things live)

### Backend (Python)

Folder: `backend/`

- `backend/src/app.py`
  - Flask entrypoint.
  - Serves the static UI on `/`.
  - Exposes REST endpoints under `/api/...`.
  - Exposes the WebSocket voice proxy at `/ws/voice`.

- `backend/src/config.py`
  - Loads environment variables via `python-dotenv`.
  - Central place for runtime configuration such as endpoints, model deployment name, speech settings.

- `backend/src/services/`
  - `managers.py`
    - `ScenarioManager`: loads scenario definitions from Azure Cosmos DB and maps them into runtime prompts.
    - `AgentManager`: creates “agents” (either local instruction-based agents or Azure AI Agent Service, depending on config).
  - `websocket_handler.py`
    - `VoiceProxyHandler`: implements the WebSocket bridge between browser and Azure Voice Live using the `azure.ai.voicelive` SDK.
  - `analyzers.py`
    - `ConversationAnalyzer`: post-session evaluation using Azure OpenAI chat completions and structured JSON output.
    - `PronunciationAssessor`: pronunciation assessment via Azure Speech SDK.
  - `graph_scenario_generator.py`
    - Generates a personalized scenario from Microsoft Graph-like data (currently from a canned JSON file).
  - `scenario_utils.py`
    - Helpers to locate scenario directories consistently in dev vs container.

### Frontend (React + TypeScript)

Folder: `frontend/`

- `frontend/src/app/App.tsx`
  - The main screen: scenario selection, session start, recording, and “Analyze” flow.

- `frontend/src/components/`
  - UI panels like chat, scenario list, assessment panel.

- `frontend/src/hooks/`
  - `useRealtime.ts`: opens the WebSocket to `/ws/voice`, sends the initial `session.update` message, and records transcripts/audio deltas.
  - `useWebRTC.ts`: handles WebRTC-related setup (ICE servers and SDP exchange) based on messages coming from the WebSocket.
  - `useRecorder.ts` / `useAudioPlayer.ts`: audio capture and playback.
  - `useScenarios.ts`: loads server-side scenarios from the backend.

- `frontend/src/services/api.ts`
  - Small API client for `/api/config`, `/api/scenarios`, `/api/agents/create`, `/api/analyze`, etc.

### Data

Folder: `samples/`

- `samples/scenarios/`
  - JSON scenario samples used to seed Cosmos DB.
  - Runtime scenario selection is served from Cosmos through the backend API.

- `data/graph-api-canned.json`
  - Sample input for graph-based scenario generation.

### Infrastructure (Azure)

Folder: `infra/`

- `infra/main.bicep` and `infra/resources.bicep`
  - Provision:
    - Azure AI Services (AI Foundry / OpenAI model deployments)
    - Azure Speech resource
    - Container Registry
    - Log Analytics + Application Insights
    - Azure Container Apps Environment + Container App

- `azure.yaml`
  - Azure Developer CLI (`azd`) project definition that ties services and infrastructure together.

## 4) Runtime behavior (request flows)

### 4.1 UI boot

1. Browser loads `/`.
2. Flask serves the static frontend bundle.
3. Frontend calls `GET /api/scenarios` to show the scenario list.

### 4.2 Starting a session (agent creation)

When the user clicks “Start”:

1. Frontend calls `POST /api/agents/create`.
  - Uses a server-side scenario by `scenario_id` from `GET /api/scenarios`.
2. Backend creates an agent entry and returns `{ agent_id }`.

### 4.3 Real-time voice conversation (WebSocket proxy)

1. Frontend opens a WebSocket to `/ws/voice`.
2. On open, frontend sends a message:
   - `type: "session.update"`
   - `session.agent_id: <agent_id>`

3. Backend receives that first message, extracts `agent_id`, and connects to Azure Voice Live.
4. Backend forwards messages in both directions:
   - Browser -> Backend -> Azure Voice Live
   - Azure Voice Live -> Backend -> Browser

The frontend listens for events like:

- `response.audio.delta` (audio streaming back)
- transcription completion events (user/assistant transcripts)
- session updates containing ICE servers used to establish media connectivity

### 4.4 Post-session analysis (evaluation + pronunciation)

When the user clicks “Analyze”:

1. Frontend builds a transcript from recorded conversation messages.
2. Frontend calls `POST /api/analyze` with:
   - `scenario_id`
   - `transcript`
   - `audio_data` (captured chunks)
   - `reference_text` (derived from user utterances)
3. Backend runs two tasks concurrently:
   - `ConversationAnalyzer.analyze_conversation(...)` (Azure OpenAI evaluation)
   - `PronunciationAssessor.assess_pronunciation(...)` (Azure Speech)
4. Backend returns a single JSON payload with both results.

## 5) Configuration (environment variables)

The backend reads configuration from environment variables (see `backend/src/config.py`). Common ones:

- `PORT`, `HOST`
- `AZURE_OPENAI_ENDPOINT`
- `MODEL_DEPLOYMENT_NAME`
- `PROJECT_ENDPOINT` (used for Azure AI Project client)
- `USE_AZURE_AI_AGENTS` (enables Agent Service mode when possible)
- `COSMOS_ENDPOINT`, `COSMOS_DATABASE_NAME`, `COSMOS_SCENARIOS_CONTAINER` (scenario source)
- Speech settings, voice/avatar defaults, etc.

In Azure, these are set by the Container App configuration inside the Bicep templates.

## 6) Local development

### Prerequisites

- Node.js + npm
- Python 3

### Run the app locally

From repo root:

1. Copy env file (if used by your workflow):
   - `cp .env.template .env`

2. Build:
   - `./scripts/build.sh`

3. Run backend:
   - `cd backend && python src/app.py`

4. Open:

- `http://localhost:8000`

## 7) Deploy to Azure (azd)

From repo root:

- `azd up`

This provisions infra and deploys the containerized backend+frontend bundle into Azure Container Apps.

## 8) Contributing (recommended workflow)

### Backend quality checks

From repo root:

- Format: `./scripts/format.sh`
- Lint: `./scripts/lint.sh`
- Tests: `./scripts/test.sh`

Or, for backend-only:

- `cd backend && black . --config pyproject.toml`
- `cd backend && flake8 . --config=.flake8`
- `cd backend && pytest`

### Frontend checks

From `frontend/`:

- `npm run format`
- `npm run lint`
- `npm run build`

## 9) Common troubleshooting

- WebSocket connects but no audio:
  - Check browser console for WebSocket close codes.
  - Verify the backend logs show a successful connection to Azure Voice Live.

- Analysis returns null/empty results:
  - Verify `AZURE_OPENAI_ENDPOINT` and `MODEL_DEPLOYMENT_NAME`.
  - Check Application Insights for exceptions.

- Scenario list empty:
  - Ensure Cosmos DB is reachable and the configured scenarios container contains items.
  - Check backend logs for Cosmos connectivity or query errors.
