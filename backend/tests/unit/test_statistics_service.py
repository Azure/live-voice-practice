# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Unit tests for the statistics service aggregation and anonymization."""

from datetime import datetime, timedelta, timezone
from typing import Any, Dict, List

from src.services.statistics_service import StatisticsFilters, StatisticsService


def _conversation(
    conversation_id: str,
    user_id: str,
    scenario_id: str,
    overall_score: float,
    scale_max: int,
    passed: bool,
    days_ago: int,
    status: str = "analyzed",
    rubric_id: str = "rubric-1",
) -> Dict[str, Any]:
    created = (datetime.now(timezone.utc) - timedelta(days=days_ago)).isoformat()
    return {
        "id": conversation_id,
        "user_id": user_id,
        "scenario_id": scenario_id,
        "status": status,
        "created_at": created,
        "metadata": {"user_name": "Jane", "user_email": "jane@example.com"},
        "assessment": {
            "ai_assessment": {
                "overall_score": overall_score,
                "scale_max": scale_max,
                "passed": passed,
                "rubricId": rubric_id,
            }
        },
    }


class _FakeStore:
    """Minimal stand-in returning a single page of conversations."""

    def __init__(self, items: List[Dict[str, Any]]) -> None:
        self._items = items

    def list_all_conversations(self, limit: int = 200, offset: int = 0, **_: Any) -> Dict[str, Any]:
        page = self._items[offset : offset + limit]
        return {"items": page, "total": len(self._items)}


def test_overview_happy_path_computes_kpis_and_series() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 2.5, 5, False, days_ago=1),
        _conversation("c3", "user-a", "s2", 5.0, 5, True, days_ago=2),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.overview(StatisticsFilters())

    kpis = payload["kpis"]
    assert kpis["totalPractices"] == 3
    assert kpis["analyzedPractices"] == 3
    assert kpis["uniqueTrainees"] == 2
    # (80 + 50 + 100) / 3 = 76.7
    assert kpis["averageScorePercent"] == 76.7
    # 2 of 3 passed
    assert kpis["passRatePercent"] == 66.7
    assert len(payload["practicesOverTime"]) == 2
    assert len(payload["averageScoreOverTime"]) == 2
    assert "generatedAt" in payload


def test_overview_empty_data() -> None:
    service = StatisticsService(store=_FakeStore([]))

    payload = service.overview(StatisticsFilters())

    assert payload["kpis"]["totalPractices"] == 0
    assert payload["kpis"]["averageScorePercent"] is None
    assert payload["kpis"]["passRatePercent"] is None
    assert payload["practicesOverTime"] == []


def test_filters_exclude_in_progress_by_default() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 0.0, 5, False, days_ago=1, status="in_progress"),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.overview(StatisticsFilters())
    assert payload["kpis"]["totalPractices"] == 1

    payload_incl = service.overview(StatisticsFilters(include_in_progress=True))
    assert payload_incl["kpis"]["totalPractices"] == 2


def test_filters_by_scenario_and_rubric() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1, rubric_id="r1"),
        _conversation("c2", "user-b", "s2", 3.0, 5, False, days_ago=1, rubric_id="r2"),
    ]
    service = StatisticsService(store=_FakeStore(items))

    by_scenario = service.overview(StatisticsFilters(scenario_ids=["s1"]))
    assert by_scenario["kpis"]["totalPractices"] == 1

    by_rubric = service.overview(StatisticsFilters(rubric_ids=["r2"]))
    assert by_rubric["kpis"]["totalPractices"] == 1


def test_score_normalization_across_scales() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 8.0, 10, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 4.0, 5, True, days_ago=1),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.overview(StatisticsFilters())
    # Both normalize to 80%
    assert payload["kpis"]["averageScorePercent"] == 80.0


def test_performance_by_scenario_and_distribution() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 5.0, 5, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 2.0, 5, False, days_ago=1),
        _conversation("c3", "user-a", "s2", 4.0, 5, True, days_ago=1),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.overview(StatisticsFilters())

    by_scenario = {row["scenarioId"]: row for row in payload["performanceByScenario"]}
    assert by_scenario["s1"]["count"] == 2
    assert by_scenario["s1"]["avgScorePercent"] == 70.0  # (100 + 40) / 2
    assert by_scenario["s1"]["passRatePercent"] == 50.0
    assert by_scenario["s2"]["avgScorePercent"] == 80.0

    # Sorted weakest scenario first.
    assert payload["performanceByScenario"][0]["scenarioId"] == "s1"

    distribution = payload["scoreDistribution"]
    assert len(distribution) == 10
    assert sum(bucket["count"] for bucket in distribution) == 3


def test_weakest_criteria_aggregation() -> None:
    item = _conversation("c1", "user-a", "s1", 3.0, 5, False, days_ago=1)
    item["assessment"]["ai_assessment"]["criteria_scores"] = {
        "clarity": {"score": 2},
        "empathy": {"score": 4},
    }
    item["assessment"]["ai_assessment"]["criteria_metadata"] = {
        "clarity": {"name": "Clarity"},
        "empathy": {"name": "Empathy"},
    }
    service = StatisticsService(store=_FakeStore([item]))

    payload = service.overview(StatisticsFilters())
    weakest = payload["weakestCriteria"]

    assert weakest[0]["criterionId"] == "clarity"
    assert weakest[0]["name"] == "Clarity"
    assert weakest[0]["avgScorePercent"] == 40.0  # 2/5
    assert weakest[1]["avgScorePercent"] == 80.0  # 4/5


def test_drop_off_by_scenario_uses_in_progress() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 0.0, 5, False, days_ago=1, status="in_progress"),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.overview(StatisticsFilters())
    drop_off = {row["scenarioId"]: row for row in payload["dropOffByScenario"]}

    assert drop_off["s1"]["started"] == 2
    assert drop_off["s1"]["analyzed"] == 1
    assert drop_off["s1"]["dropOffPercent"] == 50.0


def test_trainees_aggregation_and_trend() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 3.0, 5, False, days_ago=3),
        _conversation("c2", "user-a", "s1", 4.0, 5, True, days_ago=2),
        _conversation("c3", "user-a", "s2", 5.0, 5, True, days_ago=1),
        _conversation("c4", "user-b", "s1", 2.0, 5, False, days_ago=1),
    ]
    items[0]["metadata"] = {"user_name": "Alice"}
    items[1]["metadata"] = {"user_name": "Alice"}
    items[2]["metadata"] = {"user_name": "Alice"}
    items[3]["metadata"] = {"user_name": "Bob"}
    service = StatisticsService(store=_FakeStore(items))

    payload = service.trainees(StatisticsFilters(), sort_by="practices", sort_order="desc")
    rows = {row["userId"]: row for row in payload["items"]}

    assert payload["total"] == 2
    assert rows["user-a"]["practices"] == 3
    assert rows["user-a"]["displayName"] == "Alice"
    # scores 60, 80, 100 -> avg 80, trend 100 - 60 = 40
    assert rows["user-a"]["avgScorePercent"] == 80.0
    assert rows["user-a"]["recentScores"] == [60.0, 80.0, 100.0]
    assert rows["user-a"]["trendDelta"] == 40.0
    # user-a has 3, user-b has 1 -> sorted desc by practices
    assert payload["items"][0]["userId"] == "user-a"


def test_trainees_sorting_and_paging() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 5.0, 5, True, days_ago=1),
        _conversation("c2", "user-b", "s1", 2.0, 5, False, days_ago=1),
    ]
    service = StatisticsService(store=_FakeStore(items))

    payload = service.trainees(StatisticsFilters(), sort_by="avgScorePercent", sort_order="asc", limit=1)
    assert payload["limit"] == 1
    assert len(payload["items"]) == 1
    assert payload["items"][0]["userId"] == "user-b"  # lowest score first


def test_trainee_detail_happy_path() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 3.0, 5, False, days_ago=2),
        _conversation("c2", "user-a", "s2", 5.0, 5, True, days_ago=1),
        _conversation("c3", "user-b", "s1", 4.0, 5, True, days_ago=1),
    ]
    items[0]["metadata"] = {"user_name": "Alice"}
    items[0]["assessment"]["ai_assessment"]["improvements"] = [{"recommendation": "Speak more clearly."}]
    items[1]["assessment"]["ai_assessment"]["improvements"] = [
        {"recommendation": "Speak more clearly."},
        {"recommendation": "Show empathy."},
    ]
    service = StatisticsService(store=_FakeStore(items))

    detail = service.trainee_detail(StatisticsFilters(), "user-a")
    assert detail is not None
    assert detail["userId"] == "user-a"
    assert detail["displayName"] == "Alice"
    assert detail["totals"]["practices"] == 2
    assert len(detail["scoreTimeSeries"]) == 2
    assert detail["scoreTimeSeries"][0]["scorePercent"] == 60.0  # oldest first
    # Deduplicated recommendations, most recent practice first (in-order per practice).
    assert detail["recommendations"] == ["Speak more clearly.", "Show empathy."]


def test_trainee_detail_resolves_hash() -> None:
    items = [_conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1)]
    service = StatisticsService(store=_FakeStore(items))

    def resolver(value: str, candidates: list[str]) -> str | None:
        return "user-a" if value == "hashed-a" else None

    detail = service.trainee_detail(StatisticsFilters(), "hashed-a", resolver=resolver)
    assert detail is not None
    assert detail["userId"] == "user-a"


def test_trainee_detail_not_found() -> None:
    items = [_conversation("c1", "user-a", "s1", 4.0, 5, True, days_ago=1)]
    service = StatisticsService(store=_FakeStore(items))

    assert service.trainee_detail(StatisticsFilters(), "missing") is None


def test_export_rows_happy_path_and_criterion_columns() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 3.0, 5, False, days_ago=2),
        _conversation("c2", "user-b", "s2", 5.0, 5, True, days_ago=1),
    ]
    items[0]["assessment"]["ai_assessment"]["criteria_scores"] = {
        "c_clarity": {"score": 2},
        "c_empathy": {"score": 4},
    }
    items[0]["assessment"]["ai_assessment"]["criteria_metadata"] = {
        "c_clarity": {"name": "Clarity"},
        "c_empathy": {"name": "Empathy"},
    }
    service = StatisticsService(store=_FakeStore(items))

    result = service.export_rows(StatisticsFilters())

    assert result["criterionColumns"] == ["Clarity", "Empathy"]
    assert len(result["rows"]) == 2
    # Most recent practice first.
    assert result["rows"][0]["conversationId"] == "c2"
    first = result["rows"][1]
    assert first["conversationId"] == "c1"
    assert first["userId"] == "user-a"
    assert first["scenarioId"] == "s1"
    assert first["rubricId"] == "rubric-1"
    assert first["overallScore"] == 3.0
    assert first["scorePercent"] == 60.0
    assert first["criteria"] == {"Clarity": 2, "Empathy": 4}


def test_export_rows_excludes_unanalyzed() -> None:
    items = [
        _conversation("c1", "user-a", "s1", 3.0, 5, False, days_ago=1, status="in_progress"),
        _conversation("c2", "user-b", "s1", 4.0, 5, True, days_ago=1),
    ]
    service = StatisticsService(store=_FakeStore(items))

    result = service.export_rows(StatisticsFilters())

    assert [row["conversationId"] for row in result["rows"]] == ["c2"]


def test_export_rows_empty() -> None:
    service = StatisticsService(store=_FakeStore([]))

    result = service.export_rows(StatisticsFilters())

    assert result["rows"] == []
    assert result["criterionColumns"] == []
