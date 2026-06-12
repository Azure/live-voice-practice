# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Server-side schema validation for admin-managed scenario and rubric documents.

The accepted shapes mirror ``samples/scenarios/scenario-001.json`` and
``samples/rubrics/rubric-001.json``. Validation is intentionally lightweight
(no extra dependencies): each validator returns a list of human-readable error
strings, empty when the document is valid.
"""

from typing import Any, Dict, List

# Field-type expectations shared by both validators.
_STRING_LIST_FIELDS_SCENARIO = (
    "customerBackground",
    "conversationGuidelines",
    "skillsToProbe",
    "openingLines",
    "exampleTranscripts",
)


def _is_string_list(value: Any) -> bool:
    return isinstance(value, list) and all(isinstance(item, str) for item in value)


def validate_scenario(document: Dict[str, Any]) -> List[str]:
    """Validate a scenario document, returning a list of error messages."""
    errors: List[str] = []

    if not isinstance(document, dict):
        return ["Scenario must be a JSON object"]

    scenario_id = document.get("scenarioId")
    if not isinstance(scenario_id, str) or not scenario_id.strip():
        errors.append("'scenarioId' is required and must be a non-empty string")

    title = document.get("title")
    if not isinstance(title, str) or not title.strip():
        errors.append("'title' is required and must be a non-empty string")

    intro = document.get("scenarioContextIntro")
    if intro is not None and not isinstance(intro, str):
        errors.append("'scenarioContextIntro' must be a string")

    for field in _STRING_LIST_FIELDS_SCENARIO:
        if field in document and not _is_string_list(document[field]):
            errors.append(f"'{field}' must be a list of strings")

    related = document.get("relatedMaterials")
    if related is not None:
        if not isinstance(related, list) or not all(isinstance(item, dict) for item in related):
            errors.append("'relatedMaterials' must be a list of objects")

    return errors


def validate_rubric(document: Dict[str, Any]) -> List[str]:
    """Validate a rubric document, returning a list of error messages."""
    errors: List[str] = []

    if not isinstance(document, dict):
        return ["Rubric must be a JSON object"]

    rubric_id = document.get("rubricId")
    if not isinstance(rubric_id, str) or not rubric_id.strip():
        errors.append("'rubricId' is required and must be a non-empty string")

    applies_to = document.get("appliesTo")
    if applies_to is not None:
        if not isinstance(applies_to, dict):
            errors.append("'appliesTo' must be an object")
        elif "scenarioIds" in applies_to and not _is_string_list(applies_to["scenarioIds"]):
            errors.append("'appliesTo.scenarioIds' must be a list of strings")

    if "referenceTranscripts" in document and not _is_string_list(document["referenceTranscripts"]):
        errors.append("'referenceTranscripts' must be a list of strings")

    criteria = document.get("criteria")
    if not isinstance(criteria, list) or not criteria:
        errors.append("'criteria' is required and must be a non-empty list")
    else:
        for index, criterion in enumerate(criteria):
            errors.extend(_validate_criterion(index, criterion))

    return errors


def _validate_criterion(index: int, criterion: Any) -> List[str]:
    """Validate a single rubric criterion entry."""
    errors: List[str] = []
    prefix = f"criteria[{index}]"

    if not isinstance(criterion, dict):
        return [f"{prefix} must be an object"]

    if not isinstance(criterion.get("criterionId"), str) or not criterion.get("criterionId", "").strip():
        errors.append(f"{prefix}.criterionId is required and must be a non-empty string")
    if not isinstance(criterion.get("name"), str) or not criterion.get("name", "").strip():
        errors.append(f"{prefix}.name is required and must be a non-empty string")

    levels = criterion.get("levels")
    if not isinstance(levels, list) or not levels:
        errors.append(f"{prefix}.levels is required and must be a non-empty list")
    else:
        for level_index, level in enumerate(levels):
            if not isinstance(level, dict):
                errors.append(f"{prefix}.levels[{level_index}] must be an object")
                continue
            if not isinstance(level.get("level"), int):
                errors.append(f"{prefix}.levels[{level_index}].level must be an integer")

    return errors
