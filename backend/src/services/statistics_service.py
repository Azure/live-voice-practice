# ---------------------------------------------------------------------------------------------
#  Copyright (c) Microsoft Corporation. All rights reserved.
#  Licensed under the MIT License. See LICENSE in the project root for license information.
# --------------------------------------------------------------------------------------------

"""Server-side aggregation of trainee practice statistics for trainers.

All numeric rollups for the admin Statistics tab are computed here so the
frontend never re-aggregates raw conversation rows. The service loads analyzed
conversations within a capped time window, normalizes the evaluation out of the
two stored shapes (authenticated ``assessment.ai_assessment`` vs. the anonymous
top-level ``evaluation``), applies the shared request filters, and produces the
overview series consumed by the dashboard.
"""

import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Callable, Dict, Iterable, List, Optional

from src.services.database import conversation_store

logger = logging.getLogger(__name__)

DEFAULT_WINDOW_DAYS = 90
_PAGE_SIZE = 200
_MAX_RECORDS = 5000


class StatisticsFilters:
    """Normalized filter set shared by every statistics endpoint."""

    def __init__(
        self,
        date_from: Optional[datetime] = None,
        date_to: Optional[datetime] = None,
        scenario_ids: Optional[Iterable[str]] = None,
        rubric_ids: Optional[Iterable[str]] = None,
        include_in_progress: bool = False,
    ) -> None:
        self.date_from = date_from
        self.date_to = date_to
        self.scenario_ids = set(scenario_ids) if scenario_ids else None
        self.rubric_ids = set(rubric_ids) if rubric_ids else None
        self.include_in_progress = include_in_progress


def parse_iso(value: Optional[str]) -> Optional[datetime]:
    """Parse an ISO-8601 timestamp into an aware UTC datetime, or None."""
    if not value:
        return None
    try:
        text = value.replace("Z", "+00:00")
        parsed = datetime.fromisoformat(text)
    except ValueError:
        logger.warning("Could not parse timestamp: %s", value)
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def _extract_evaluation(conversation: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Return the rubric evaluation from whichever stored shape is present."""
    assessment = conversation.get("assessment")
    if isinstance(assessment, dict):
        evaluation = assessment.get("ai_assessment")
        if isinstance(evaluation, dict):
            return evaluation
    evaluation = conversation.get("evaluation")
    if isinstance(evaluation, dict):
        return evaluation
    return None


def _score_percent(evaluation: Dict[str, Any]) -> Optional[float]:
    """Normalize an overall score to a percentage of the rubric scale max."""
    overall = evaluation.get("overall_score")
    scale_max = evaluation.get("scale_max")
    if not isinstance(overall, (int, float)):
        return None
    try:
        scale_max_value = float(scale_max)
    except (TypeError, ValueError):
        scale_max_value = 0.0
    if scale_max_value <= 0:
        return None
    return round((float(overall) / scale_max_value) * 100.0, 1)


class StatisticsService:
    """Loads and aggregates analyzed conversations for trainer dashboards."""

    def __init__(self, store: Any = conversation_store) -> None:
        self._store = store

    def _load_window(self, window_days: int) -> Dict[str, Any]:
        """Page through all conversations, capped by record count.

        Returns a dict with ``items`` (raw conversation dicts) and
        ``window_capped`` (True when the record cap was hit).
        """
        items: List[Dict[str, Any]] = []
        offset = 0
        window_capped = False
        while True:
            page = self._store.list_all_conversations(limit=_PAGE_SIZE, offset=offset)
            page_items = page.get("items", []) if isinstance(page, dict) else []
            if not page_items:
                break
            items.extend(page_items)
            offset += _PAGE_SIZE
            total = page.get("total", 0) if isinstance(page, dict) else 0
            if len(items) >= _MAX_RECORDS:
                window_capped = True
                items = items[:_MAX_RECORDS]
                break
            if offset >= total:
                break
        return {"items": items, "window_capped": window_capped}

    def _normalize(self, conversation: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Project a raw conversation into a normalized statistics record."""
        created_at = parse_iso(conversation.get("created_at"))
        if created_at is None:
            return None
        evaluation = _extract_evaluation(conversation)
        return {
            "id": conversation.get("id"),
            "user_id": conversation.get("user_id", ""),
            "scenario_id": conversation.get("scenario_id", ""),
            "status": conversation.get("status", ""),
            "created_at": created_at,
            "metadata": conversation.get("metadata") or {},
            "evaluation": evaluation,
            "rubric_id": evaluation.get("rubricId") if isinstance(evaluation, dict) else None,
            "score_percent": _score_percent(evaluation) if isinstance(evaluation, dict) else None,
            "passed": evaluation.get("passed") if isinstance(evaluation, dict) else None,
        }

    def _matches_non_status(self, record: Dict[str, Any], filters: StatisticsFilters) -> bool:
        """Return True when a record satisfies all filters except status."""
        created_at = record["created_at"]
        if filters.date_from and created_at < filters.date_from:
            return False
        if filters.date_to and created_at > filters.date_to:
            return False
        if filters.scenario_ids and record["scenario_id"] not in filters.scenario_ids:
            return False
        if filters.rubric_ids and record["rubric_id"] not in filters.rubric_ids:
            return False
        return True

    def _collect(self, filters: StatisticsFilters, window_days: int) -> Dict[str, Any]:
        """Load all in-window records matching non-status filters (any status)."""
        window_start = datetime.now(timezone.utc) - timedelta(days=window_days)
        loaded = self._load_window(window_days)
        eligible: List[Dict[str, Any]] = []
        for conversation in loaded["items"]:
            normalized = self._normalize(conversation)
            if normalized is None:
                continue
            if normalized["created_at"] < window_start:
                continue
            if self._matches_non_status(normalized, filters):
                eligible.append(normalized)
        return {"eligible": eligible, "window_capped": loaded["window_capped"]}

    def load_records(self, filters: StatisticsFilters, window_days: int = DEFAULT_WINDOW_DAYS) -> Dict[str, Any]:
        """Load and filter normalized records within the capped window."""
        collected = self._collect(filters, window_days)
        records = [r for r in collected["eligible"] if filters.include_in_progress or r["status"] == "analyzed"]
        return {"records": records, "window_capped": collected["window_capped"]}

    def overview(self, filters: StatisticsFilters, window_days: int = DEFAULT_WINDOW_DAYS) -> Dict[str, Any]:
        """Build the overview payload (KPIs, over-time series, cohort drill-down)."""
        collected = self._collect(filters, window_days)
        eligible = collected["eligible"]
        records = [r for r in eligible if filters.include_in_progress or r["status"] == "analyzed"]

        analyzed = [r for r in records if r["evaluation"] is not None]
        scored = [r for r in analyzed if r["score_percent"] is not None]
        passed = [r for r in analyzed if r["passed"] is True]
        unique_trainees = {r["user_id"] for r in records if r["user_id"]}

        avg_score = round(sum(r["score_percent"] for r in scored) / len(scored), 1) if scored else None
        pass_rate = round((len(passed) / len(analyzed)) * 100.0, 1) if analyzed else None

        practices_by_day: Dict[str, int] = {}
        score_sum_by_day: Dict[str, float] = {}
        score_count_by_day: Dict[str, int] = {}
        for record in records:
            day = record["created_at"].date().isoformat()
            practices_by_day[day] = practices_by_day.get(day, 0) + 1
            if record["score_percent"] is not None:
                score_sum_by_day[day] = score_sum_by_day.get(day, 0.0) + record["score_percent"]
                score_count_by_day[day] = score_count_by_day.get(day, 0) + 1

        practices_over_time = [{"date": day, "count": practices_by_day[day]} for day in sorted(practices_by_day)]
        avg_score_over_time = [
            {"date": day, "avgScorePercent": round(score_sum_by_day[day] / score_count_by_day[day], 1)}
            for day in sorted(score_sum_by_day)
        ]

        # Cohort drill-down series operate on all analyzed rows in scope; drop-off
        # additionally needs the in-progress rows, so it reads from ``eligible``.
        analyzed_all = [r for r in eligible if r["status"] == "analyzed" and r["evaluation"] is not None]

        return {
            "kpis": {
                "totalPractices": len(records),
                "analyzedPractices": len(analyzed),
                "uniqueTrainees": len(unique_trainees),
                "averageScorePercent": avg_score,
                "passRatePercent": pass_rate,
            },
            "practicesOverTime": practices_over_time,
            "averageScoreOverTime": avg_score_over_time,
            "performanceByScenario": _performance_by_scenario(analyzed_all),
            "weakestCriteria": _weakest_criteria(analyzed_all),
            "scoreDistribution": _score_distribution(analyzed_all),
            "dropOffByScenario": _drop_off_by_scenario(eligible),
            "windowDays": window_days,
            "windowCapped": collected["window_capped"],
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }

    def trainees(
        self,
        filters: StatisticsFilters,
        sort_by: str = "lastPracticeAt",
        sort_order: str = "desc",
        limit: int = 25,
        offset: int = 0,
        window_days: int = DEFAULT_WINDOW_DAYS,
    ) -> Dict[str, Any]:
        """Build per-trainee aggregates (paginated, sortable).

        Identities are returned raw here (``userId`` + ``displayName``); callers
        apply anonymization based on the ``SHOW_TRAINEE_IDENTITIES`` flag.
        """
        collected = self._collect(filters, window_days)
        records = [r for r in collected["eligible"] if filters.include_in_progress or r["status"] == "analyzed"]

        rows = _aggregate_trainees(records)

        sort_key = sort_by if sort_by in _TRAINEE_SORT_KEYS else "lastPracticeAt"
        reverse = sort_order.lower() != "asc"
        rows.sort(key=lambda row: _trainee_sort_value(row, sort_key), reverse=reverse)

        total = len(rows)
        safe_limit = max(1, min(100, limit))
        safe_offset = max(0, offset)
        page = rows[safe_offset : safe_offset + safe_limit]

        return {
            "items": page,
            "total": total,
            "limit": safe_limit,
            "offset": safe_offset,
            "windowDays": window_days,
            "windowCapped": collected["window_capped"],
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }

    def trainee_detail(
        self,
        filters: StatisticsFilters,
        identifier: str,
        resolver: Optional[Callable[[str, List[str]], Optional[str]]] = None,
        window_days: int = DEFAULT_WINDOW_DAYS,
    ) -> Optional[Dict[str, Any]]:
        """Build the detailed evolution payload for a single trainee.

        ``identifier`` may be a raw ``user_id`` or an opaque hash. When it is not
        a direct match and a ``resolver`` is supplied, the resolver maps the hash
        back to a user id against the in-scope candidates. Returns None when the
        trainee cannot be resolved or has no in-window practices.
        """
        collected = self._collect(filters, window_days)
        records = [r for r in collected["eligible"] if filters.include_in_progress or r["status"] == "analyzed"]

        candidates = sorted({r["user_id"] for r in records if r["user_id"]})
        target = identifier if identifier in candidates else None
        if target is None and resolver is not None:
            target = resolver(identifier, candidates)
        if target is None:
            return None

        user_records = [r for r in records if r["user_id"] == target]
        if not user_records:
            return None

        analyzed = [r for r in user_records if r["evaluation"] is not None]
        scored = [r for r in analyzed if r["score_percent"] is not None]
        passed = [r for r in analyzed if r["passed"] is True]

        display_name = _display_name(user_records[0]["metadata"], target)

        return {
            "userId": target,
            "displayName": display_name,
            "totals": {
                "practices": len(user_records),
                "analyzedPractices": len(analyzed),
                "avgScorePercent": round(sum(r["score_percent"] for r in scored) / len(scored), 1) if scored else None,
                "passRatePercent": round((len(passed) / len(analyzed)) * 100.0, 1) if analyzed else None,
            },
            "scoreTimeSeries": _score_time_series(analyzed),
            "criterionAverages": _weakest_criteria(analyzed, limit=50),
            "scenarioBreakdown": _performance_by_scenario(analyzed),
            "recommendations": _recent_recommendations(analyzed),
            "windowDays": window_days,
            "windowCapped": collected["window_capped"],
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }

    def export_rows(
        self,
        filters: StatisticsFilters,
        window_days: int = DEFAULT_WINDOW_DAYS,
    ) -> Dict[str, Any]:
        """Build flat per-practice rows for CSV export.

        Returns analyzed conversations within scope as flat dicts carrying the
        raw identity (``userId`` + ``displayName``) so callers can apply
        anonymization, plus a stable, sorted list of per-criterion column names
        (``criterionColumns``) covering every criterion seen across the rows.
        Per-criterion scores are exposed under ``criteria`` keyed by name.
        """
        collected = self._collect(filters, window_days)
        analyzed = [r for r in collected["eligible"] if r["status"] == "analyzed" and r["evaluation"] is not None]

        criterion_columns: List[str] = []
        seen_columns: set = set()
        rows: List[Dict[str, Any]] = []
        for record in analyzed:
            evaluation = record["evaluation"]
            criteria = _criterion_scores(evaluation)
            for name in criteria:
                if name not in seen_columns:
                    seen_columns.add(name)
                    criterion_columns.append(name)
            rows.append(
                {
                    "userId": record["user_id"],
                    "displayName": _display_name(record["metadata"], record["user_id"]),
                    "conversationId": record["id"],
                    "scenarioId": record["scenario_id"],
                    "rubricId": record["rubric_id"],
                    "createdAt": record["created_at"].isoformat(),
                    "overallScore": evaluation.get("overall_score"),
                    "scaleMax": evaluation.get("scale_max"),
                    "scorePercent": record["score_percent"],
                    "passed": record["passed"],
                    "criteria": criteria,
                }
            )

        rows.sort(key=lambda row: row["createdAt"], reverse=True)
        criterion_columns.sort()
        return {
            "rows": rows,
            "criterionColumns": criterion_columns,
            "windowDays": window_days,
            "windowCapped": collected["window_capped"],
            "generatedAt": datetime.now(timezone.utc).isoformat(),
        }


def _criterion_scores(evaluation: Dict[str, Any]) -> Dict[str, Any]:
    """Map criterion display name -> raw score for a single evaluation."""
    metadata = evaluation.get("criteria_metadata", {})
    scores: Dict[str, Any] = {}
    for criterion_id, entry in (evaluation.get("criteria_scores", {}) or {}).items():
        if not isinstance(entry, dict):
            continue
        score = entry.get("score")
        name = criterion_id
        if isinstance(metadata, dict) and isinstance(metadata.get(criterion_id), dict):
            name = metadata[criterion_id].get("name") or criterion_id
        scores[name] = score
    return scores


_TRAINEE_SORT_KEYS = {
    "displayName",
    "practices",
    "lastPracticeAt",
    "avgScorePercent",
    "passRatePercent",
}


def _trainee_sort_value(row: Dict[str, Any], key: str) -> Any:
    """Return a sortable value, coercing None to a low sentinel."""
    value = row.get(key)
    if value is None:
        return "" if key == "displayName" else -1
    if key == "displayName":
        return str(value).lower()
    return value


def _display_name(metadata: Dict[str, Any], user_id: str) -> str:
    """Resolve a human display name from conversation metadata."""
    if isinstance(metadata, dict):
        name = metadata.get("user_name") or metadata.get("user_email")
        if name:
            return str(name)
    return user_id


def _aggregate_trainees(records: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Aggregate per-user practice metrics with a recent-score trend."""
    by_user: Dict[str, Dict[str, Any]] = {}
    for record in records:
        user_id = record["user_id"]
        if not user_id:
            continue
        bucket = by_user.setdefault(
            user_id,
            {
                "userId": user_id,
                "displayName": _display_name(record["metadata"], user_id),
                "practices": 0,
                "lastPracticeAt": None,
                "scoreSum": 0.0,
                "scored": 0,
                "passed": 0,
                "analyzed": 0,
                "scoreHistory": [],
            },
        )
        bucket["practices"] += 1
        created_at = record["created_at"]
        if bucket["lastPracticeAt"] is None or created_at > bucket["lastPracticeAt"]:
            bucket["lastPracticeAt"] = created_at
        if record["evaluation"] is not None:
            bucket["analyzed"] += 1
            if record["passed"] is True:
                bucket["passed"] += 1
            if record["score_percent"] is not None:
                bucket["scoreSum"] += record["score_percent"]
                bucket["scored"] += 1
                bucket["scoreHistory"].append((created_at, record["score_percent"]))

    rows: List[Dict[str, Any]] = []
    for bucket in by_user.values():
        scored = bucket["scored"]
        analyzed = bucket["analyzed"]
        history = sorted(bucket["scoreHistory"], key=lambda item: item[0])
        recent = [score for _, score in history[-3:]]
        trend_delta = round(recent[-1] - recent[0], 1) if len(recent) >= 2 else None
        rows.append(
            {
                "userId": bucket["userId"],
                "displayName": bucket["displayName"],
                "practices": bucket["practices"],
                "lastPracticeAt": bucket["lastPracticeAt"].isoformat() if bucket["lastPracticeAt"] else None,
                "avgScorePercent": round(bucket["scoreSum"] / scored, 1) if scored else None,
                "passRatePercent": round((bucket["passed"] / analyzed) * 100.0, 1) if analyzed else None,
                "recentScores": recent,
                "trendDelta": trend_delta,
            }
        )
    return rows


def _performance_by_scenario(analyzed: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Aggregate average score % and pass rate per scenario."""
    by_scenario: Dict[str, Dict[str, Any]] = {}
    for record in analyzed:
        scenario_id = record["scenario_id"] or "unknown"
        bucket = by_scenario.setdefault(
            scenario_id, {"scenarioId": scenario_id, "scoreSum": 0.0, "scored": 0, "passed": 0, "count": 0}
        )
        bucket["count"] += 1
        if record["score_percent"] is not None:
            bucket["scoreSum"] += record["score_percent"]
            bucket["scored"] += 1
        if record["passed"] is True:
            bucket["passed"] += 1

    result: List[Dict[str, Any]] = []
    for bucket in by_scenario.values():
        scored = bucket["scored"]
        count = bucket["count"]
        result.append(
            {
                "scenarioId": bucket["scenarioId"],
                "count": count,
                "avgScorePercent": round(bucket["scoreSum"] / scored, 1) if scored else None,
                "passRatePercent": round((bucket["passed"] / count) * 100.0, 1) if count else None,
            }
        )
    result.sort(key=lambda item: item["avgScorePercent"] if item["avgScorePercent"] is not None else -1)
    return result


def _weakest_criteria(analyzed: List[Dict[str, Any]], limit: int = 8) -> List[Dict[str, Any]]:
    """Aggregate average normalized score per criterion, weakest first."""
    by_criterion: Dict[str, Dict[str, Any]] = {}
    for record in analyzed:
        evaluation = record["evaluation"]
        scale_max = evaluation.get("scale_max")
        try:
            scale_max_value = float(scale_max)
        except (TypeError, ValueError):
            continue
        if scale_max_value <= 0:
            continue
        metadata = evaluation.get("criteria_metadata", {})
        for criterion_id, entry in (evaluation.get("criteria_scores", {}) or {}).items():
            if not isinstance(entry, dict):
                continue
            score = entry.get("score")
            if not isinstance(score, (int, float)):
                continue
            name = ""
            if isinstance(metadata, dict) and isinstance(metadata.get(criterion_id), dict):
                name = metadata[criterion_id].get("name", "")
            bucket = by_criterion.setdefault(
                criterion_id,
                {"criterionId": criterion_id, "name": name or criterion_id, "percentSum": 0.0, "count": 0},
            )
            bucket["percentSum"] += (float(score) / scale_max_value) * 100.0
            bucket["count"] += 1

    result = [
        {
            "criterionId": bucket["criterionId"],
            "name": bucket["name"],
            "avgScorePercent": round(bucket["percentSum"] / bucket["count"], 1),
            "count": bucket["count"],
        }
        for bucket in by_criterion.values()
        if bucket["count"] > 0
    ]
    result.sort(key=lambda item: item["avgScorePercent"])
    return result[:limit]


def _score_distribution(analyzed: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Bucket analyzed scores into ten 10%-wide histogram bins."""
    buckets = [0] * 10
    for record in analyzed:
        percent = record["score_percent"]
        if percent is None:
            continue
        index = min(9, max(0, int(percent // 10)))
        buckets[index] += 1
    return [{"bucket": f"{i * 10}-{i * 10 + 10}", "count": buckets[i]} for i in range(10)]


def _drop_off_by_scenario(eligible: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Compute started vs. analyzed (drop-off) counts per scenario."""
    by_scenario: Dict[str, Dict[str, int]] = {}
    for record in eligible:
        scenario_id = record["scenario_id"] or "unknown"
        bucket = by_scenario.setdefault(scenario_id, {"started": 0, "analyzed": 0})
        bucket["started"] += 1
        if record["status"] == "analyzed":
            bucket["analyzed"] += 1

    result: List[Dict[str, Any]] = []
    for scenario_id, bucket in by_scenario.items():
        started = bucket["started"]
        analyzed_count = bucket["analyzed"]
        dropped = started - analyzed_count
        result.append(
            {
                "scenarioId": scenario_id,
                "started": started,
                "analyzed": analyzed_count,
                "dropOffPercent": round((dropped / started) * 100.0, 1) if started else 0.0,
            }
        )
    result.sort(key=lambda item: item["dropOffPercent"], reverse=True)
    return result


def _score_time_series(analyzed: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Return each analyzed practice's score over time (oldest first)."""
    ordered = sorted(analyzed, key=lambda record: record["created_at"])
    return [
        {
            "date": record["created_at"].isoformat(),
            "scorePercent": record["score_percent"],
            "scenarioId": record["scenario_id"],
            "conversationId": record["id"],
        }
        for record in ordered
        if record["score_percent"] is not None
    ]


def _recent_recommendations(analyzed: List[Dict[str, Any]], limit: int = 10) -> List[str]:
    """Collect deduplicated improvement recommendations, most recent first."""
    ordered = sorted(analyzed, key=lambda record: record["created_at"], reverse=True)
    seen: set[str] = set()
    recommendations: List[str] = []
    for record in ordered:
        evaluation = record["evaluation"] or {}
        for improvement in evaluation.get("improvements", []) or []:
            if not isinstance(improvement, dict):
                continue
            text = str(improvement.get("recommendation", "")).strip()
            if not text or text.lower() in seen:
                continue
            seen.add(text.lower())
            recommendations.append(text)
            if len(recommendations) >= limit:
                return recommendations
    return recommendations


# Singleton instance
statistics_service = StatisticsService()
