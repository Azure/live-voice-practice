# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Analysis components for conversation and pronunciation assessment."""

import asyncio
import base64
import io
import json
import logging
import wave
from pathlib import Path
from typing import Any, Dict, List, Optional

import azure.cognitiveservices.speech as speechsdk  # pyright: ignore[reportMissingTypeStubs]
import yaml
from azure.identity import DefaultAzureCredential, get_bearer_token_provider
from openai import AzureOpenAI

from src.config import config
from src.services.scenario_utils import determine_scenario_directory

logger = logging.getLogger(__name__)

# Constants
EVALUATION_FILE_SUFFIX = "*evaluation.prompt.yml"
EVALUATION_SUFFIX_REMOVAL = "-evaluation.prompt"
SCENARIO_DATA_DIR = "data/scenarios"
DOCKER_APP_PATH = "/app"

# Scoring constants
MAX_PROFESSIONAL_TONE_SCORE = 10
MAX_ACTIVE_LISTENING_SCORE = 10
MAX_ENGAGEMENT_QUALITY_SCORE = 10
MAX_NEEDS_ASSESSMENT_SCORE = 25
MAX_VALUE_PROPOSITION_SCORE = 25
MAX_OBJECTION_HANDLING_SCORE = 20
MAX_OVERALL_SCORE = 100
MAX_TONE_STYLE_SCORE = 30
MAX_CONTENT_SCORE = 70

# Audio processing constants
MIN_AUDIO_SIZE_BYTES = 48000
AUDIO_SAMPLE_RATE = 24000
AUDIO_CHANNELS = 1
AUDIO_SAMPLE_WIDTH = 2
AUDIO_BITS_PER_SAMPLE = 16

# Assessment constants
MAX_STRENGTHS_COUNT = 3

# Keywords that indicate criteria reference supporting documentation / policies
SUPPORT_MATERIAL_KEYWORDS = [
    "policy", "policies", "procedure", "procedures", "guideline", "guidelines",
    "supporting", "documentation", "compliance", "regulation", "protocol",
    "standard", "handbook", "manual", "reference", "knowledge base",
]

# Fallback evaluation prompt for custom scenarios
FALLBACK_EVALUATION_PROMPT = """You are an expert communication coach evaluating a role-play conversation.

Evaluate the user's performance based on:
- Communication clarity and professionalism
- Active listening and engagement
- Problem-solving and responsiveness
- Achievement of conversation objectives

Provide constructive feedback to help improve their skills."""


class ConversationAnalyzer:
    """Analyzes sales conversations using Azure OpenAI."""

    def __init__(self, scenario_dir: Optional[Path] = None, search_service: Optional[Any] = None):
        """
        Initialize the conversation analyzer.

        Args:
            scenario_dir: Directory containing evaluation scenario files
            search_service: Optional SupportMaterialsSearchService for retrieving supporting materials
        """
        self.scenario_dir = determine_scenario_directory(scenario_dir)
        self.evaluation_scenarios = self._load_evaluation_scenarios()
        self.openai_client = self._initialize_openai_client()
        self.search_service = search_service

    def _load_evaluation_scenarios(self) -> Dict[str, Any]:
        """
        Load evaluation scenarios from YAML files.

        Returns:
            Dict[str, Any]: Dictionary of evaluation scenarios keyed by ID
        """
        scenarios: Dict[str, Any] = {}

        if not self.scenario_dir.exists():
            logger.warning("Scenarios directory not found: %s", self.scenario_dir)
            return scenarios

        for file in self.scenario_dir.glob(EVALUATION_FILE_SUFFIX):
            try:
                with open(file, encoding="utf-8") as f:
                    scenario = yaml.safe_load(f)
                    scenario_id = file.stem.replace(EVALUATION_SUFFIX_REMOVAL, "")
                    scenarios[scenario_id] = scenario
                    logger.info("Loaded evaluation scenario: %s", scenario_id)
            except Exception as e:
                logger.error("Error loading evaluation scenario %s: %s", file, e)

        logger.info("Total evaluation scenarios loaded: %s", len(scenarios))
        return scenarios

    def _initialize_openai_client(self) -> Optional[AzureOpenAI]:
        """
        Initialize the Azure OpenAI client.

        Returns:
            Optional[AzureOpenAI]: Initialized client or None if configuration missing
        """
        try:
            endpoint = config["azure_openai_endpoint"]
            api_key = config["azure_openai_api_key"]

            if not endpoint:
                logger.error("Azure OpenAI endpoint not configured")
                return None

            if api_key:
                client = AzureOpenAI(
                    api_version=config["api_version"],
                    azure_endpoint=endpoint,
                    api_key=api_key,
                )
                logger.info("ConversationAnalyzer initialized with API key auth and endpoint: %s", endpoint)
                return client

            token_provider = get_bearer_token_provider(
                DefaultAzureCredential(),
                "https://cognitiveservices.azure.com/.default",
            )

            client = AzureOpenAI(
                api_version=config["api_version"],
                azure_endpoint=endpoint,
                azure_ad_token_provider=token_provider,
            )

            logger.info("ConversationAnalyzer initialized with managed identity auth and endpoint: %s", endpoint)
            return client

        except Exception as e:
            logger.error("Failed to initialize OpenAI client: %s", e)
            return None

    async def analyze_conversation(
        self, scenario_id: str, transcript: str, rubric: Optional[Dict[str, Any]] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Analyze a conversation transcript.

        When a rubric is provided its criteria drive the evaluation scoring (1-5 per criterion).
        Otherwise the legacy fixed-weight scoring is used.

        Args:
            scenario_id: The scenario identifier.
                         For AI generated scenario, use "graph_generated"
            transcript: The conversation transcript to analyze
            rubric: Optional evaluation rubric loaded from Cosmos DB

        Returns:
            Optional[Dict[str, Any]]: Analysis results or None if analysis fails
        """
        logger.info("Starting conversation analysis for scenario: %s", scenario_id)

        evaluation_scenario = self.evaluation_scenarios.get(scenario_id)
        if not evaluation_scenario:
            logger.info("Using fallback evaluation for scenario: %s", scenario_id)
            evaluation_scenario = {"messages": [{"content": FALLBACK_EVALUATION_PROMPT}]}

        if not self.openai_client:
            logger.error("OpenAI client not configured")
            return None

        if rubric and rubric.get("criteria"):
            return await self._call_rubric_evaluation_model(evaluation_scenario, transcript, rubric)

        return await self._call_evaluation_model(evaluation_scenario, transcript)

    def _build_evaluation_prompt(
        self, scenario: Dict[str, Any], transcript: str, supporting_materials: str = ""
    ) -> str:
        """Build the evaluation prompt."""
        base_prompt = scenario["messages"][0]["content"]

        materials_section = ""
        if supporting_materials:
            materials_section = f"""

SUPPORTING MATERIALS (use these as reference when evaluating policy adherence and accuracy):
{supporting_materials}
"""

        return f"""{base_prompt}

        EVALUATION CRITERIA:

        **SPEAKING TONE & STYLE ({MAX_TONE_STYLE_SCORE} points total):**
        - professional_tone: 0-{MAX_PROFESSIONAL_TONE_SCORE} points for confident, consultative, appropriate business language
        - active_listening: 0-{MAX_ACTIVE_LISTENING_SCORE} points for acknowledging concerns and asking clarifying questions
        - engagement_quality: 0-{MAX_ENGAGEMENT_QUALITY_SCORE} points for encouraging dialogue and thoughtful responses

        **CONVERSATION CONTENT QUALITY ({MAX_CONTENT_SCORE} points total):**
        - needs_assessment: 0-{MAX_NEEDS_ASSESSMENT_SCORE} points for understanding customer challenges and goals
        - value_proposition: 0-{MAX_VALUE_PROPOSITION_SCORE} points for clear benefits with data/examples/reasoning
        - objection_handling: 0-{MAX_OBJECTION_HANDLING_SCORE} points for addressing concerns with constructive solutions

        Calculate overall_score as the sum of all individual scores (max {MAX_OVERALL_SCORE}).

        For EACH criterion, provide:
        - A numeric score within the specified range
        - A one-sentence explanation justifying WHY you assigned that score

        You are evaluating the conversation from perspective of the user (Starting the conversation)
        DO NOT rate the conversation of the 'assistant'!

        Provide maximum of {MAX_STRENGTHS_COUNT} strengths.
        For areas of improvement, provide a recommendation for EVERY criterion that did not receive a
        perfect score. Each improvement must reference the specific criterion name, include its score,
        and provide an actionable recommendation. Sort by lowest score first.
        {materials_section}
        CONVERSATION TO EVALUATE:
        {transcript}
        """

    async def _call_evaluation_model(self, scenario: Dict[str, Any], transcript: str) -> Optional[Dict[str, Any]]:
        """
        Call OpenAI with structured outputs for evaluation.

        Args:
            scenario: The evaluation scenario configuration
            transcript: The conversation transcript

        Returns:
            Optional[Dict[str, Any]]: Evaluation results or None if call fails
        """

        if not self.openai_client:
            logger.error("OpenAI client not configured")
            return None
        openai_client = self.openai_client

        try:
            supporting_materials = await self._fetch_supporting_materials_for_scenario(scenario)
            evaluation_prompt = self._build_evaluation_prompt(scenario, transcript, supporting_materials)

            completion = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: openai_client.chat.completions.create(
                    model=config["model_deployment_name"],
                    messages=self._build_evaluation_messages(evaluation_prompt),  # pyright: ignore[reportArgumentType]
                    response_format=self._get_response_format(),  # pyright: ignore[reportArgumentType]
                ),
            )

            if completion.choices[0].message.content:
                evaluation_json = json.loads(completion.choices[0].message.content)
                return self._process_evaluation_result(evaluation_json)

            logger.error("No content received from OpenAI")
            return None

        except Exception as e:
            logger.error("Error in evaluation model: %s", e)
            return None

    def _build_evaluation_messages(self, evaluation_prompt: str) -> List[Dict[str, str]]:
        """Build the messages for the evaluation API call."""
        return [
            {
                "role": "system",
                "content": "You are an expert sales conversation evaluator. "
                "Analyze the provided conversation and return a structured evaluation.",
            },
            {"role": "user", "content": evaluation_prompt},
        ]

    def _get_response_format(self) -> Dict[str, Any]:
        """Get the structured response format for OpenAI."""
        scored_criterion = {
            "type": "object",
            "properties": {
                "score": {"type": "integer"},
                "explanation": {"type": "string"},
            },
            "required": ["score", "explanation"],
            "additionalProperties": False,
        }

        improvement_item = {
            "type": "object",
            "properties": {
                "criterion": {"type": "string"},
                "score": {"type": "integer"},
                "max_score": {"type": "integer"},
                "recommendation": {"type": "string"},
            },
            "required": ["criterion", "score", "max_score", "recommendation"],
            "additionalProperties": False,
        }

        return {
            "type": "json_schema",
            "json_schema": {
                "name": "sales_evaluation",
                "strict": True,
                "schema": {
                    "type": "object",
                    "properties": {
                        "speaking_tone_style": {
                            "type": "object",
                            "properties": {
                                "professional_tone": scored_criterion,
                                "active_listening": scored_criterion,
                                "engagement_quality": scored_criterion,
                                "total": {"type": "integer"},
                            },
                            "required": [
                                "professional_tone",
                                "active_listening",
                                "engagement_quality",
                                "total",
                            ],
                            "additionalProperties": False,
                        },
                        "conversation_content": {
                            "type": "object",
                            "properties": {
                                "needs_assessment": scored_criterion,
                                "value_proposition": scored_criterion,
                                "objection_handling": scored_criterion,
                                "total": {"type": "integer"},
                            },
                            "required": [
                                "needs_assessment",
                                "value_proposition",
                                "objection_handling",
                                "total",
                            ],
                            "additionalProperties": False,
                        },
                        "overall_score": {"type": "integer"},
                        "strengths": {
                            "type": "array",
                            "items": {"type": "string"},
                        },
                        "improvements": {
                            "type": "array",
                            "items": improvement_item,
                        },
                        "specific_feedback": {"type": "string"},
                    },
                    "required": [
                        "speaking_tone_style",
                        "conversation_content",
                        "overall_score",
                        "strengths",
                        "improvements",
                        "specific_feedback",
                    ],
                    "additionalProperties": False,
                },
            },
        }

    @staticmethod
    def _extract_score(value: Any) -> int:
        """Extract numeric score from a criterion value (handles both int and {score, explanation} formats)."""
        if isinstance(value, dict):
            return int(value.get("score", 0))
        return int(value)

    def _process_evaluation_result(self, evaluation_json: Dict[str, Any]) -> Dict[str, Any]:
        """Process and validate evaluation results."""
        tone = evaluation_json["speaking_tone_style"]
        tone["total"] = sum(
            [
                self._extract_score(tone["professional_tone"]),
                self._extract_score(tone["active_listening"]),
                self._extract_score(tone["engagement_quality"]),
            ]
        )

        content = evaluation_json["conversation_content"]
        content["total"] = sum(
            [
                self._extract_score(content["needs_assessment"]),
                self._extract_score(content["value_proposition"]),
                self._extract_score(content["objection_handling"]),
            ]
        )

        logger.info("Evaluation processed with score: %s", evaluation_json.get("overall_score"))
        return evaluation_json

    # ------------------------------------------------------------------
    # Rubric-based evaluation
    # ------------------------------------------------------------------

    async def _call_rubric_evaluation_model(
        self, scenario: Dict[str, Any], transcript: str, rubric: Dict[str, Any]
    ) -> Optional[Dict[str, Any]]:
        """Run evaluation using rubric criteria and structured output."""
        if not self.openai_client:
            logger.error("OpenAI client not configured")
            return None
        openai_client = self.openai_client

        try:
            supporting_materials = await self._fetch_supporting_materials(
                scenario, rubric
            )
            prompt = self._build_rubric_evaluation_prompt(
                scenario, transcript, rubric, supporting_materials
            )
            response_format = self._get_rubric_response_format(rubric)

            completion = await asyncio.get_event_loop().run_in_executor(
                None,
                lambda: openai_client.chat.completions.create(
                    model=config["model_deployment_name"],
                    messages=[
                        {
                            "role": "system",
                            "content": (
                                "You are an expert conversation evaluator. "
                                "Score the trainee's performance using the rubric criteria provided. "
                                "Return a structured evaluation."
                            ),
                        },
                        {"role": "user", "content": prompt},
                    ],  # pyright: ignore[reportArgumentType]
                    response_format=response_format,  # pyright: ignore[reportArgumentType]
                ),
            )

            if completion.choices[0].message.content:
                result = json.loads(completion.choices[0].message.content)
                return self._process_rubric_evaluation_result(result, rubric)

            logger.error("No content received from OpenAI (rubric evaluation)")
            return None
        except Exception as e:
            logger.error("Error in rubric evaluation model: %s", e)
            return None

    def _build_rubric_evaluation_prompt(
        self, scenario: Dict[str, Any], transcript: str, rubric: Dict[str, Any],
        supporting_materials: str = "",
    ) -> str:
        """Build a prompt that incorporates the rubric criteria."""
        base_prompt = scenario["messages"][0]["content"]
        scoring = rubric.get("scoring", {})
        scale = scoring.get("scale", "1-5")
        pass_threshold = scoring.get("passThreshold", 3.5)

        criteria_lines: List[str] = []
        for criterion in rubric.get("criteria", []):
            cid = criterion.get("criterionId", "unknown")
            name = criterion.get("name", cid)
            description = criterion.get("description", "")
            levels_text = ""
            for level in criterion.get("levels", []):
                levels_text += f"  - {level.get('level')}: {level.get('label')} — {level.get('description')}\n"
            criteria_lines.append(
                f"**{name}** (`{cid}`, scale {scale}):\n{description}\n{levels_text}"
            )

        criteria_block = "\n".join(criteria_lines)

        materials_section = ""
        if supporting_materials:
            materials_section = f"""

SUPPORTING MATERIALS (use these as reference when evaluating policy adherence and accuracy):
{supporting_materials}
"""

        return f"""{base_prompt}

EVALUATION RUBRIC (score each criterion on a {scale} scale):

{criteria_block}

SCORING RULES:
- Score each criterion independently using the level descriptions above.
- The overall_score is the average of all criterion scores (scale {scale}).
- A score >= {pass_threshold} is considered passing.
- You are evaluating the conversation from the perspective of the user/trainee.
- DO NOT rate the conversation of the 'assistant' (the customer avatar).

Provide a maximum of {MAX_STRENGTHS_COUNT} strengths.
For areas of improvement, provide a recommendation for EVERY criterion that did not receive a
perfect score. Each improvement must reference the specific criterion name, include its score,
and provide an actionable recommendation. Sort by lowest score first.
{materials_section}
CONVERSATION TO EVALUATE:
{transcript}
"""

    def _get_rubric_response_format(self, rubric: Dict[str, Any]) -> Dict[str, Any]:
        """Build a structured-output JSON schema driven by the rubric criteria."""
        criteria = rubric.get("criteria", [])

        criterion_props: Dict[str, Any] = {}
        criterion_required: List[str] = []
        for criterion in criteria:
            cid = criterion.get("criterionId", "unknown")
            criterion_props[cid] = {
                "type": "object",
                "properties": {
                    "score": {"type": "integer"},
                    "justification": {"type": "string"},
                },
                "required": ["score", "justification"],
                "additionalProperties": False,
            }
            criterion_required.append(cid)

        return {
            "type": "json_schema",
            "json_schema": {
                "name": "rubric_evaluation",
                "strict": True,
                "schema": {
                    "type": "object",
                    "properties": {
                        "criteria_scores": {
                            "type": "object",
                            "properties": criterion_props,
                            "required": criterion_required,
                            "additionalProperties": False,
                        },
                        "overall_score": {"type": "number"},
                        "passed": {"type": "boolean"},
                        "strengths": {"type": "array", "items": {"type": "string"}},
                        "improvements": {
                            "type": "array",
                            "items": {
                                "type": "object",
                                "properties": {
                                    "criterion": {"type": "string"},
                                    "score": {"type": "integer"},
                                    "max_score": {"type": "integer"},
                                    "recommendation": {"type": "string"},
                                },
                                "required": ["criterion", "score", "max_score", "recommendation"],
                                "additionalProperties": False,
                            },
                        },
                        "specific_feedback": {"type": "string"},
                    },
                    "required": [
                        "criteria_scores",
                        "overall_score",
                        "passed",
                        "strengths",
                        "improvements",
                        "specific_feedback",
                    ],
                    "additionalProperties": False,
                },
            },
        }

    def _process_rubric_evaluation_result(
        self, result: Dict[str, Any], rubric: Dict[str, Any]
    ) -> Dict[str, Any]:
        """Validate and enrich rubric evaluation results."""
        criteria_scores = result.get("criteria_scores", {})
        scores = [entry.get("score", 0) for entry in criteria_scores.values() if isinstance(entry, dict)]

        if scores:
            result["overall_score"] = round(sum(scores) / len(scores), 2)

        scoring = rubric.get("scoring", {})
        pass_threshold = scoring.get("passThreshold", 3.5)
        scale_str = scoring.get("scale", "1-5")
        try:
            scale_max = int(scale_str.split("-")[-1])
        except (ValueError, IndexError):
            scale_max = 5

        # Normalize max_score in improvements to match the rubric scale
        for improvement in result.get("improvements", []):
            if isinstance(improvement, dict):
                improvement["max_score"] = scale_max

        result["passed"] = result["overall_score"] >= pass_threshold
        result["pass_threshold"] = pass_threshold
        result["scale_max"] = scale_max
        result["rubricId"] = rubric.get("rubricId")
        result["evaluation_type"] = "rubric"

        logger.info(
            "Rubric evaluation processed — overall: %s, passed: %s",
            result.get("overall_score"),
            result.get("passed"),
        )
        return result

    # ------------------------------------------------------------------
    # Supporting materials retrieval from AI Search
    # ------------------------------------------------------------------

    @staticmethod
    def _criteria_mention_support_materials(criteria_texts: List[str]) -> bool:
        """Check if any criteria text mentions policy/supporting documentation keywords."""
        combined = " ".join(criteria_texts).lower()
        return any(kw in combined for kw in SUPPORT_MATERIAL_KEYWORDS)

    async def _fetch_supporting_materials(
        self, scenario: Dict[str, Any], rubric: Dict[str, Any]
    ) -> str:
        """Fetch supporting materials from AI Search when criteria reference policies."""
        if not self.search_service:
            return ""

        try:
            criteria_texts = []
            for criterion in rubric.get("criteria", []):
                criteria_texts.append(criterion.get("name", ""))
                criteria_texts.append(criterion.get("description", ""))

            if not self._criteria_mention_support_materials(criteria_texts):
                return ""

            base_prompt = scenario.get("messages", [{}])[0].get("content", "")
            query = f"{base_prompt[:200]} {' '.join(criteria_texts[:5])}"

            materials = await self.search_service.search_supporting_materials(query)
            if not materials:
                return ""

            sections = []
            for mat in materials:
                title = mat.get("title", "Untitled")
                content = mat.get("content", "")
                if content:
                    sections.append(f"--- {title} ---\n{content}")

            return "\n\n".join(sections)
        except Exception as e:
            logger.warning("Failed to fetch supporting materials: %s", e)
            return ""

    async def _fetch_supporting_materials_for_scenario(
        self, scenario: Dict[str, Any]
    ) -> str:
        """Fetch supporting materials for the legacy (non-rubric) evaluation."""
        if not self.search_service:
            return ""

        try:
            base_prompt = scenario.get("messages", [{}])[0].get("content", "")
            if not self._criteria_mention_support_materials([base_prompt]):
                return ""

            query = base_prompt[:300]
            materials = await self.search_service.search_supporting_materials(query)
            if not materials:
                return ""

            sections = []
            for mat in materials:
                title = mat.get("title", "Untitled")
                content = mat.get("content", "")
                if content:
                    sections.append(f"--- {title} ---\n{content}")

            return "\n\n".join(sections)
        except Exception as e:
            logger.warning("Failed to fetch supporting materials for scenario: %s", e)
            return ""


class PronunciationAssessor:
    """Assesses pronunciation using Azure Speech Services."""

    def __init__(self):
        """Initialize the pronunciation assessor."""
        self.speech_key = config["azure_speech_key"]
        self.speech_endpoint = config.get("azure_speech_endpoint")
        self.speech_region = config["azure_speech_region"]

    def _create_wav_audio(self, audio_bytes: bytearray) -> bytes:
        """Create WAV format audio from raw PCM bytes."""
        with io.BytesIO() as wav_buffer:
            wav_file: wave.Wave_write = wave.open(wav_buffer, "wb")  # type: ignore
            with wav_file:
                wav_file.setnchannels(AUDIO_CHANNELS)
                wav_file.setsampwidth(AUDIO_SAMPLE_WIDTH)
                wav_file.setframerate(AUDIO_SAMPLE_RATE)
                wav_file.writeframes(audio_bytes)

            wav_buffer.seek(0)
            return wav_buffer.read()

    def _log_assessment_info(self, wav_audio: bytes, reference_text: Optional[str]) -> None:
        """Log information about the assessment being performed."""
        logger.info("Starting pronunciation assessment with audio size: %s bytes", len(wav_audio))
        logger.info("Reference text: %s", reference_text or "None")
        logger.info("Speech key configured: %s", "Yes" if self.speech_key else "No")
        logger.info("Speech endpoint configured: %s", "Yes" if self.speech_endpoint else "No")
        logger.info("Speech region: %s", self.speech_region)

    def _create_speech_config(self) -> speechsdk.SpeechConfig:
        """Create speech configuration."""
        if self.speech_key:
            speech_config = speechsdk.SpeechConfig(subscription=self.speech_key, region=self.speech_region)
        elif self.speech_endpoint:
            speech_config = speechsdk.SpeechConfig(
                token_credential=DefaultAzureCredential(),
                endpoint=self.speech_endpoint,
            )
        else:
            raise ValueError("Azure Speech authentication is not configured")

        speech_config.speech_recognition_language = config["azure_speech_language"]
        return speech_config

    def _create_pronunciation_config(self, reference_text: Optional[str]) -> speechsdk.PronunciationAssessmentConfig:
        """Create pronunciation assessment configuration."""
        pronunciation_config = speechsdk.PronunciationAssessmentConfig(
            reference_text=reference_text or "",
            grading_system=speechsdk.PronunciationAssessmentGradingSystem.HundredMark,
            granularity=speechsdk.PronunciationAssessmentGranularity.Phoneme,
            enable_miscue=True,
        )
        pronunciation_config.enable_prosody_assessment()
        return pronunciation_config

    def _create_audio_config(self, wav_audio: bytes) -> speechsdk.audio.AudioConfig:
        """Create audio configuration from WAV data."""
        audio_format = speechsdk.audio.AudioStreamFormat(
            samples_per_second=AUDIO_SAMPLE_RATE,
            bits_per_sample=AUDIO_BITS_PER_SAMPLE,
            channels=AUDIO_CHANNELS,
            wave_stream_format=speechsdk.audio.AudioStreamWaveFormat.PCM,
        )

        push_stream = speechsdk.audio.PushAudioInputStream(stream_format=audio_format)
        push_stream.write(wav_audio)
        push_stream.close()

        return speechsdk.audio.AudioConfig(stream=push_stream)

    def _build_assessment_result(
        self,
        pronunciation_result: speechsdk.PronunciationAssessmentResult,
        result: speechsdk.SpeechRecognitionResult,
    ) -> Dict[str, Any]:
        """Build the final assessment result."""
        return {
            "accuracy_score": pronunciation_result.accuracy_score,
            "fluency_score": pronunciation_result.fluency_score,
            "completeness_score": pronunciation_result.completeness_score,
            "prosody_score": getattr(pronunciation_result, "prosody_score", None),
            "pronunciation_score": pronunciation_result.pronunciation_score,
            "words": self._extract_word_details(result),
        }

    async def assess_pronunciation(
        self, audio_data: List[Dict[str, Any]], reference_text: Optional[str] = None
    ) -> Optional[Dict[str, Any]]:
        """
        Assess pronunciation of audio data.

        Args:
            audio_data: List of audio chunks with metadata
            reference_text: Optional reference text for comparison

        Returns:
            Optional[Dict[str, Any]]: Pronunciation assessment results or None if assessment fails
        """
        if not self.speech_key and not self.speech_endpoint:
            logger.error("Azure Speech auth not configured (set AZURE_SPEECH_KEY or AZURE_SPEECH_ENDPOINT with MSI)")
            return None

        try:
            combined_audio = await self._prepare_audio_data(audio_data)
            if not combined_audio:
                logger.error("No audio data to assess")
                return None

            logger.info("Combined audio size: %s bytes", len(combined_audio))

            if len(combined_audio) < MIN_AUDIO_SIZE_BYTES:
                logger.warning("Audio might be too short: %s bytes", len(combined_audio))

            wav_audio = self._create_wav_audio(combined_audio)
            return await self._perform_assessment(wav_audio, reference_text)

        except Exception as e:
            logger.error("Error in pronunciation assessment: %s", e)
            return None

    async def _prepare_audio_data(self, audio_data: List[Dict[str, Any]]) -> bytearray:
        """Prepare and combine audio chunks."""
        combined_audio = bytearray()

        for chunk in audio_data:
            if chunk.get("type") == "user":
                try:
                    audio_bytes = base64.b64decode(chunk["data"])
                    combined_audio.extend(audio_bytes)
                except Exception as e:
                    logger.error("Error decoding audio chunk: %s", e)

        return combined_audio

    async def _perform_assessment(self, wav_audio: bytes, reference_text: Optional[str]) -> Optional[Dict[str, Any]]:
        """Perform the actual pronunciation assessment."""
        self._log_assessment_info(wav_audio, reference_text)

        speech_config = self._create_speech_config()
        pronunciation_config = self._create_pronunciation_config(reference_text)
        audio_config = self._create_audio_config(wav_audio)

        speech_recognizer = speechsdk.SpeechRecognizer(
            speech_config=speech_config,
            audio_config=audio_config,
            language=config["azure_speech_language"],
        )
        pronunciation_config.apply_to(speech_recognizer)

        result = await asyncio.get_event_loop().run_in_executor(None, speech_recognizer.recognize_once)

        pronunciation_result = speechsdk.PronunciationAssessmentResult(result)
        return self._build_assessment_result(pronunciation_result, result)

    def _extract_word_details(self, result: speechsdk.SpeechRecognitionResult) -> List[Dict[str, Any]]:
        """Extract word-level pronunciation details."""
        try:
            json_result = json.loads(
                result.properties.get(
                    speechsdk.PropertyId.SpeechServiceResponse_JsonResult,
                    "{}",
                )  # pyright: ignore[reportUnknownMemberType]  # pyright: ignore[reportUnknownArgumentType]
            )

            words: List[Dict[str, Any]] = []
            if "NBest" in json_result and json_result["NBest"]:
                for word_info in json_result["NBest"][0].get("Words", []):
                    words.append(
                        {
                            "word": word_info.get("Word", ""),
                            "accuracy": word_info.get("PronunciationAssessment", {}).get("AccuracyScore", 0),
                            "error_type": word_info.get("PronunciationAssessment", {}).get("ErrorType", "None"),
                        }
                    )

            return words
        except Exception as e:
            logger.error("Error extracting word details: %s", e)
            return []
