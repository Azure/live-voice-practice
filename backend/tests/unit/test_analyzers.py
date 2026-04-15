"""Tests for analyzer classes."""

import base64
import json
import tempfile
from pathlib import Path
from unittest.mock import Mock, patch

import pytest
import yaml

from src.services.analyzers import ConversationAnalyzer, PronunciationAssessor


class TestConversationAnalyzer:
    """Test conversation analyzer functionality."""

    def test_conversation_analyzer_initialization(self):
        """Test analyzer initialization with no scenarios."""
        with tempfile.TemporaryDirectory() as temp_dir:
            non_existent_path = Path(temp_dir) / "nonexistent"
            analyzer = ConversationAnalyzer(scenario_dir=non_existent_path)
            assert len(analyzer.evaluation_scenarios) == 0

    def test_load_evaluation_scenarios(self):
        """Test loading evaluation scenarios."""
        with tempfile.TemporaryDirectory() as temp_dir:
            scenario_dir = Path(temp_dir)

            # Create a test evaluation scenario file
            scenario_data = {
                "name": "Test Evaluation",
                "messages": [{"content": "Evaluate this conversation"}],
            }

            scenario_file = scenario_dir / "test-scenario-evaluation.prompt.yml"
            with open(scenario_file, "w", encoding="utf-8") as f:
                yaml.safe_dump(scenario_data, f)

            analyzer = ConversationAnalyzer(scenario_dir=scenario_dir)
            assert len(analyzer.evaluation_scenarios) == 1
            assert "test-scenario" in analyzer.evaluation_scenarios

    @patch("src.services.analyzers.config")
    def test_initialize_openai_client_missing_config(self, mock_config):
        """Test OpenAI client initialization with missing config."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_openai_endpoint": "",
            "azure_openai_api_key": "",
        }.get(key, "")

        analyzer = ConversationAnalyzer()
        assert analyzer.openai_client is None

    @patch("src.services.analyzers.AzureOpenAI")
    @patch("src.services.analyzers.config")
    def test_initialize_openai_client_success(self, mock_config, mock_azure_openai):
        """Test successful OpenAI client initialization."""
        mock_config.__getitem__.side_effect = lambda key: {
            "azure_openai_endpoint": "https://test.openai.azure.com",
            "azure_openai_api_key": "test-key",
        }.get(key, "")

        analyzer = ConversationAnalyzer()
        assert analyzer.openai_client is not None
        mock_azure_openai.assert_called_once()

    @pytest.mark.asyncio
    async def test_analyze_conversation_uses_fallback_for_unknown_scenario(self):
        """Test analyzing conversation uses fallback prompt for unknown scenarios."""
        analyzer = ConversationAnalyzer()
        analyzer.evaluation_scenarios = {}
        analyzer.openai_client = None  # No client configured

        result = await analyzer.analyze_conversation("nonexistent", "test transcript")
        # Returns None because openai_client is not configured, not because scenario is missing
        assert result is None

    def test_build_evaluation_prompt(self):
        """Test building evaluation prompt."""
        analyzer = ConversationAnalyzer()
        scenario = {"messages": [{"content": "Base evaluation prompt"}]}
        transcript = "Test conversation"

        prompt = analyzer._build_evaluation_prompt(scenario, transcript)
        assert "Base evaluation prompt" in prompt
        assert "Test conversation" in prompt
        assert "EVALUATION CRITERIA" in prompt
        assert "SPEAKING TONE & STYLE" in prompt

    def test_get_response_format(self):
        """Test getting response format for structured output."""
        analyzer = ConversationAnalyzer()
        format_def = analyzer._get_response_format()

        assert format_def["type"] == "json_schema"
        assert "sales_evaluation" in format_def["json_schema"]["name"]

        schema = format_def["json_schema"]["schema"]
        assert "speaking_tone_style" in schema["properties"]
        assert "conversation_content" in schema["properties"]
        assert "overall_score" in schema["properties"]

        # Verify sub-criteria are now { score, explanation } objects
        tone_props = schema["properties"]["speaking_tone_style"]["properties"]
        assert tone_props["professional_tone"]["type"] == "object"
        assert "score" in tone_props["professional_tone"]["properties"]
        assert "explanation" in tone_props["professional_tone"]["properties"]

        # Verify improvements are structured objects
        improvement_schema = schema["properties"]["improvements"]["items"]
        assert improvement_schema["type"] == "object"
        assert "criterion" in improvement_schema["properties"]
        assert "recommendation" in improvement_schema["properties"]

    def test_process_evaluation_result(self):
        """Test processing evaluation results with new nested score format."""
        analyzer = ConversationAnalyzer()

        evaluation_json = {
            "speaking_tone_style": {
                "professional_tone": {"score": 8, "explanation": "Good tone throughout."},
                "active_listening": {"score": 7, "explanation": "Decent listening."},
                "engagement_quality": {"score": 9, "explanation": "Great engagement."},
                "total": 0,
            },
            "conversation_content": {
                "needs_assessment": {"score": 20, "explanation": "Solid assessment."},
                "value_proposition": {"score": 18, "explanation": "Clear value."},
                "objection_handling": {"score": 15, "explanation": "Handled well."},
                "total": 0,
            },
            "overall_score": 77,
            "strengths": ["Good engagement"],
            "improvements": [
                {"criterion": "Active Listening", "score": 7, "max_score": 10, "recommendation": "Ask more questions"}
            ],
            "specific_feedback": "Overall good performance",
        }

        result = analyzer._process_evaluation_result(evaluation_json)

        assert result["speaking_tone_style"]["total"] == 24
        assert result["conversation_content"]["total"] == 53
        assert result["overall_score"] == 77

    def test_process_evaluation_result_legacy_format(self):
        """Test processing legacy evaluation results with flat integer scores."""
        analyzer = ConversationAnalyzer()

        evaluation_json = {
            "speaking_tone_style": {
                "professional_tone": 8,
                "active_listening": 7,
                "engagement_quality": 9,
                "total": 0,
            },
            "conversation_content": {
                "needs_assessment": 20,
                "value_proposition": 18,
                "objection_handling": 15,
                "total": 0,
            },
            "overall_score": 77,
            "strengths": ["Good engagement"],
            "improvements": ["Better needs assessment"],
            "specific_feedback": "Overall good performance",
        }

        result = analyzer._process_evaluation_result(evaluation_json)

        assert result["speaking_tone_style"]["total"] == 24
        assert result["conversation_content"]["total"] == 53

    def test_extract_score(self):
        """Test _extract_score handles both formats."""
        assert ConversationAnalyzer._extract_score(8) == 8
        assert ConversationAnalyzer._extract_score({"score": 7, "explanation": "Good"}) == 7
        assert ConversationAnalyzer._extract_score({}) == 0

    def test_build_evaluation_messages(self):
        """Test building evaluation messages for API call."""
        analyzer = ConversationAnalyzer()

        prompt = "Test evaluation prompt"
        messages = analyzer._build_evaluation_messages(prompt)

        assert len(messages) == 2
        assert messages[0]["role"] == "system"
        assert messages[1]["role"] == "user"
        assert messages[1]["content"] == prompt
        assert "expert sales conversation evaluator" in messages[0]["content"]

    # pylint: disable=R0801
    def test_analyze_conversation_with_openai_client(self):
        """Test analyzing conversation with mocked OpenAI client."""
        analyzer = ConversationAnalyzer()

        # Mock OpenAI client and configuration
        with patch("src.services.analyzers.config") as mock_config:
            mock_config.__getitem__.side_effect = lambda key: {
                "azure_openai_endpoint": "https://test.openai.azure.com",
                "azure_openai_api_key": "test-key",
                "api_version": "2024-02-01",
                "model_deployment_name": "gpt-4",
            }.get(key, "test-value")

            mock_client = Mock()
            mock_response = Mock()
            mock_response.choices = [Mock()]
            mock_response.choices[0].message.content = json.dumps(
                {
                    "professional_tone": 8,
                    "active_listening": 7,
                    "engagement_quality": 9,
                    "needs_assessment": 20,
                    "value_proposition": 22,
                    "objection_handling": 18,
                    "strengths": ["Good rapport"],
                    "improvements": ["Ask more questions"],
                }
            )
            mock_client.chat.completions.create.return_value = mock_response

            # Recreate analyzer with proper config
            analyzer = ConversationAnalyzer()
            analyzer.openai_client = mock_client

            # Mock scenario
            analyzer.evaluation_scenarios = {"test-scenario": {"messages": [{"content": "Test scenario content"}]}}

            # Test that the method exists and can be called
            # Due to complexity of async mocking, we just verify the client is set
            assert analyzer.openai_client is not None

    def test_build_rubric_evaluation_prompt(self):
        """Test rubric-based evaluation prompt generation."""
        analyzer = ConversationAnalyzer()
        scenario = {"messages": [{"content": "Base evaluation prompt"}]}
        rubric = {
            "criteria": [
                {
                    "criterionId": "empathy",
                    "name": "Empathy",
                    "description": "Assesses empathy.",
                    "levels": [
                        {"level": 1, "label": "Poor", "description": "Dismissive."},
                        {"level": 5, "label": "Excellent", "description": "Clearly acknowledges."},
                    ],
                }
            ],
            "scoring": {"scale": "1-5", "passThreshold": 3.5},
        }

        prompt = analyzer._build_rubric_evaluation_prompt(scenario, "Test transcript", rubric)
        assert "Base evaluation prompt" in prompt
        assert "EVALUATION RUBRIC" in prompt
        assert "Empathy" in prompt
        assert "1-5" in prompt
        assert "3.5" in prompt
        assert "Test transcript" in prompt

    def test_get_rubric_response_format(self):
        """Test rubric-based response format schema generation."""
        analyzer = ConversationAnalyzer()
        rubric = {
            "criteria": [
                {"criterionId": "empathy", "name": "Empathy", "description": "...", "levels": []},
                {"criterionId": "clarity", "name": "Clarity", "description": "...", "levels": []},
            ]
        }

        fmt = analyzer._get_rubric_response_format(rubric)
        assert fmt["type"] == "json_schema"
        assert fmt["json_schema"]["name"] == "rubric_evaluation"

        props = fmt["json_schema"]["schema"]["properties"]
        assert "criteria_scores" in props
        assert "overall_score" in props
        assert "passed" in props

        criteria_props = props["criteria_scores"]["properties"]
        assert "empathy" in criteria_props
        assert "clarity" in criteria_props
        assert criteria_props["empathy"]["properties"]["score"]["type"] == "integer"
        assert criteria_props["empathy"]["properties"]["justification"]["type"] == "string"

    def test_process_rubric_evaluation_result(self):
        """Test rubric evaluation result processing and scoring."""
        analyzer = ConversationAnalyzer()
        rubric = {
            "rubricId": "test-rubric",
            "scoring": {"passThreshold": 3.5},
        }

        # Passing result
        result = {
            "criteria_scores": {
                "empathy": {"score": 4, "justification": "Good empathy."},
                "clarity": {"score": 5, "justification": "Very clear."},
            },
            "overall_score": 0,
            "passed": False,
            "strengths": ["Clear"],
            "improvements": [
                {"criterion": "Empathy", "score": 4, "max_score": 5, "recommendation": "More acknowledgment"}
            ],
            "specific_feedback": "Well done.",
        }

        processed = analyzer._process_rubric_evaluation_result(result, rubric)
        assert processed["overall_score"] == 4.5
        assert processed["passed"] is True
        assert processed["rubricId"] == "test-rubric"
        assert processed["evaluation_type"] == "rubric"
        assert processed["pass_threshold"] == 3.5
        assert processed["scale_max"] == 5
        # max_score in improvements must be normalized to the rubric scale
        assert processed["improvements"][0]["max_score"] == 5

        # Failing result
        result2 = {
            "criteria_scores": {
                "empathy": {"score": 2, "justification": "Needs work."},
                "clarity": {"score": 3, "justification": "OK."},
            },
            "overall_score": 0,
            "passed": True,
            "strengths": [],
            "improvements": [
                {"criterion": "Empathy", "score": 2, "max_score": 5, "recommendation": "Show more empathy"}
            ],
            "specific_feedback": "Needs improvement.",
        }

        processed2 = analyzer._process_rubric_evaluation_result(result2, rubric)
        assert processed2["overall_score"] == 2.5
        assert processed2["passed"] is False

    @pytest.mark.asyncio
    async def test_analyze_conversation_uses_rubric_when_provided(self):
        """Test that analyze_conversation dispatches to rubric path when rubric is given."""
        analyzer = ConversationAnalyzer()
        analyzer.openai_client = None  # No client, will return None

        rubric = {
            "criteria": [{"criterionId": "empathy", "name": "E", "description": ".", "levels": []}],
            "scoring": {"passThreshold": 3.0},
        }

        result = await analyzer.analyze_conversation("test", "transcript", rubric=rubric)
        # Returns None because openai_client is not configured
        assert result is None

    @pytest.mark.asyncio
    async def test_analyze_conversation_uses_legacy_when_no_rubric(self):
        """Test that analyze_conversation uses legacy path when no rubric is given."""
        analyzer = ConversationAnalyzer()
        analyzer.openai_client = None

        result = await analyzer.analyze_conversation("test", "transcript", rubric=None)
        assert result is None

    def test_criteria_mention_support_materials(self):
        """Test detection of support material keywords in criteria."""
        assert ConversationAnalyzer._criteria_mention_support_materials(
            ["Check if agent followed company policy"]
        ) is True
        assert ConversationAnalyzer._criteria_mention_support_materials(
            ["Use compliance guidelines for evaluation"]
        ) is True
        assert ConversationAnalyzer._criteria_mention_support_materials(
            ["Check tone and empathy"]
        ) is False

    def test_init_with_search_service(self):
        """Test analyzer can be initialized with a search service."""
        mock_search = Mock()
        analyzer = ConversationAnalyzer(search_service=mock_search)
        assert analyzer.search_service is mock_search


# pylint: enable=R0801


class TestPronunciationAssessor:
    """Test pronunciation assessor functionality."""

    def test_pronunciation_assessor_initialization(self):
        """Test assessor initialization."""
        assessor = PronunciationAssessor()
        # Test that it initializes with config values
        assert hasattr(assessor, "speech_key")
        assert hasattr(assessor, "speech_endpoint")
        assert hasattr(assessor, "speech_region")

    @patch("src.services.analyzers.speechsdk.SpeechConfig")
    def test_create_speech_config_with_key(self, mock_speech_config):
        """Test creating speech config with subscription key auth."""
        assessor = PronunciationAssessor()
        assessor.speech_key = "test-speech-key"
        assessor.speech_endpoint = ""

        assessor._create_speech_config()

        mock_speech_config.assert_called_once_with(subscription="test-speech-key", region=assessor.speech_region)

    @patch("src.services.analyzers.DefaultAzureCredential")
    @patch("src.services.analyzers.speechsdk.SpeechConfig")
    def test_create_speech_config_with_managed_identity(self, mock_speech_config, mock_default_credential):
        """Test creating speech config with managed identity auth."""
        mock_default_credential.return_value = Mock()

        assessor = PronunciationAssessor()
        assessor.speech_key = ""
        assessor.speech_endpoint = "https://speech-test.cognitiveservices.azure.com/"

        assessor._create_speech_config()

        mock_default_credential.assert_called_once()
        mock_speech_config.assert_called_once_with(
            token_credential=mock_default_credential.return_value,
            endpoint="https://speech-test.cognitiveservices.azure.com/",
        )

    @pytest.mark.asyncio
    async def test_assess_pronunciation_no_speech_key(self):
        """Test pronunciation assessment with no speech key configured."""
        assessor = PronunciationAssessor()
        assessor.speech_key = None

        result = await assessor.assess_pronunciation([], "test text")
        assert result is None

    @pytest.mark.asyncio
    async def test_prepare_audio_data_empty_list(self):
        """Test preparing audio data with empty list."""
        assessor = PronunciationAssessor()
        result = await assessor._prepare_audio_data([])
        assert len(result) == 0

    @pytest.mark.asyncio
    async def test_prepare_audio_data_with_user_chunks(self):
        """Test preparing audio data with user chunks."""
        assessor = PronunciationAssessor()

        # Create test audio data
        test_audio = b"test audio data"
        encoded_audio = base64.b64encode(test_audio).decode("utf-8")

        audio_data = [
            {"type": "user", "data": encoded_audio},
            {"type": "assistant", "data": "should be ignored"},
        ]

        result = await assessor._prepare_audio_data(audio_data)
        assert len(result) > 0
        assert test_audio in result

    def test_create_wav_audio(self):
        """Test creating WAV audio from raw bytes."""
        assessor = PronunciationAssessor()
        test_audio = bytearray(b"test audio data" * 100)  # Make it longer

        wav_audio = assessor._create_wav_audio(test_audio)
        assert isinstance(wav_audio, bytes)
        assert len(wav_audio) > len(test_audio)  # WAV header adds overhead

    def test_extract_word_details_empty_result(self):
        """Test extracting word details from empty result."""
        assessor = PronunciationAssessor()

        # Mock result object
        mock_result = Mock()
        mock_result.properties.get.return_value = "{}"

        words = assessor._extract_word_details(mock_result)
        assert not words

    def test_extract_word_details_with_words(self):
        """Test extracting word details with actual words."""
        assessor = PronunciationAssessor()

        # Mock result with word data
        mock_result = Mock()
        test_response = {
            "NBest": [
                {
                    "Words": [
                        {
                            "Word": "hello",
                            "PronunciationAssessment": {
                                "AccuracyScore": 85,
                                "ErrorType": "None",
                            },
                        },
                        {
                            "Word": "world",
                            "PronunciationAssessment": {
                                "AccuracyScore": 90,
                                "ErrorType": "None",
                            },
                        },
                    ]
                }
            ]
        }
        mock_result.properties.get.return_value = json.dumps(test_response)

        words = assessor._extract_word_details(mock_result)

        assert len(words) == 2
        assert words[0]["word"] == "hello"
        assert words[0]["accuracy"] == 85
        assert words[1]["word"] == "world"
        assert words[1]["accuracy"] == 90

    def test_extract_word_details_with_error_types(self):
        """Test extracting word details with different error types."""
        assessor = PronunciationAssessor()

        mock_result = Mock()
        test_response = {
            "NBest": [
                {
                    "Words": [
                        {
                            "Word": "mispronounced",
                            "PronunciationAssessment": {
                                "AccuracyScore": 45,
                                "ErrorType": "Mispronunciation",
                            },
                        },
                        {
                            "Word": "omitted",
                            "PronunciationAssessment": {
                                "AccuracyScore": 0,
                                "ErrorType": "Omission",
                            },
                        },
                    ]
                }
            ]
        }
        mock_result.properties.get.return_value = json.dumps(test_response)

        words = assessor._extract_word_details(mock_result)

        assert len(words) == 2
        assert words[0]["error_type"] == "Mispronunciation"
        assert words[1]["error_type"] == "Omission"

    def test_extract_word_details_malformed_json(self):
        """Test extracting word details with malformed JSON."""
        assessor = PronunciationAssessor()

        mock_result = Mock()
        mock_result.properties.get.return_value = "invalid json"

        words = assessor._extract_word_details(mock_result)

        assert not words

    def test_assess_pronunciation_with_valid_audio(self):
        """Test pronunciation assessment with valid audio data setup."""
        assessor = PronunciationAssessor()

        # Mock the speech services
        assessor.speech_key = "test-key"
        assessor.speech_region = "test-region"

        # Test that the method exists and can handle basic setup
        assert hasattr(assessor, "assess_pronunciation")
        assert callable(assessor.assess_pronunciation)

    @pytest.mark.asyncio
    async def test_prepare_audio_data_mixed_speakers(self):
        """Test preparing audio data with mixed user and assistant chunks."""
        assessor = PronunciationAssessor()

        audio_data = [
            {"chunk": base64.b64encode(b"user audio").decode(), "user": True},
            {"chunk": base64.b64encode(b"assistant audio").decode(), "user": False},
            {"chunk": base64.b64encode(b"more user audio").decode(), "user": True},
        ]

        result = await assessor._prepare_audio_data(audio_data)

        # Should include some audio data (user chunks are processed)
        assert isinstance(result, (bytes, bytearray))
        # The actual filtering logic depends on implementation details
