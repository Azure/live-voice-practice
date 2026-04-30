"""Seed Cosmos DB scenarios and rubrics containers from local sample JSON files.

Authentication uses Microsoft Entra ID (DefaultAzureCredential): no keys.
Make sure the calling identity has the 'Cosmos DB Built-in Data Contributor'
data-plane role on the account (assigned via
  az cosmosdb sql role assignment create ...).

Usage example (PowerShell):
  $env:COSMOS_ENDPOINT = "https://<account>.documents.azure.com:443/"
  $env:COSMOS_DATABASE_NAME = "<database>"
  python scripts/seed_cosmos_samples.py --mode upsert
"""

from __future__ import annotations

import argparse
import json
import os
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Iterable

from azure.cosmos import CosmosClient, exceptions
from azure.identity import DefaultAzureCredential


@dataclass
class SeedStats:
    attempted: int = 0
    created: int = 0
    upserted: int = 0
    skipped: int = 0
    failed: int = 0


def _load_json_files(folder: Path) -> list[dict[str, Any]]:
    if not folder.exists():
        return []

    docs: list[dict[str, Any]] = []
    for file_path in sorted(folder.glob("*.json")):
        with file_path.open("r", encoding="utf-8") as f:
            payload = json.load(f)
            if not isinstance(payload, dict):
                raise ValueError(f"Expected JSON object in {file_path}")
            payload["_sourceFile"] = file_path.name
            docs.append(payload)
    return docs


def _normalize_item(doc: dict[str, Any], source_key: str) -> dict[str, Any]:
    if source_key not in doc:
        source_name = doc.get("_sourceFile", "<unknown>")
        raise ValueError(f"Missing required key '{source_key}' in {source_name}")

    normalized = dict(doc)
    normalized["id"] = str(doc[source_key])
    return normalized


def _seed_items(
    container: Any,
    docs: Iterable[dict[str, Any]],
    source_key: str,
    mode: str,
    dry_run: bool,
) -> SeedStats:
    stats = SeedStats()

    for doc in docs:
        stats.attempted += 1
        item = _normalize_item(doc, source_key)

        if dry_run:
            stats.skipped += 1
            print(f"[dry-run] {container.id}: {item['id']}")
            continue

        try:
            if mode == "create":
                container.create_item(item)
                stats.created += 1
                print(f"[created] {container.id}: {item['id']}")
            else:
                container.upsert_item(item)
                stats.upserted += 1
                print(f"[upserted] {container.id}: {item['id']}")
        except exceptions.CosmosResourceExistsError:
            stats.skipped += 1
            print(f"[exists] {container.id}: {item['id']}")
        except Exception as exc:  # pragma: no cover - safety net for operational script
            stats.failed += 1
            print(f"[failed] {container.id}: {item.get('id', '<unknown>')} -> {exc}")

    return stats


def _print_summary(label: str, stats: SeedStats) -> None:
    print(f"\n{label} summary")
    print(f"  attempted: {stats.attempted}")
    print(f"  created:   {stats.created}")
    print(f"  upserted:  {stats.upserted}")
    print(f"  skipped:   {stats.skipped}")
    print(f"  failed:    {stats.failed}")


def _get_required_env(name: str) -> str:
    value = os.getenv(name, "").strip()
    if not value:
        raise ValueError(f"Environment variable '{name}' is required")
    return value


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Seed Cosmos DB from samples folder")
    parser.add_argument("--mode", choices=["upsert", "create"], default="upsert")
    parser.add_argument("--samples-dir", default="samples")
    parser.add_argument("--database", default=os.getenv("COSMOS_DATABASE_NAME", ""))
    parser.add_argument("--scenarios-container", default=os.getenv("COSMOS_SCENARIOS_CONTAINER", "scenarios"))
    parser.add_argument("--rubrics-container", default=os.getenv("COSMOS_RUBRICS_CONTAINER", "rubrics"))
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()

    endpoint = _get_required_env("COSMOS_ENDPOINT")
    credential = DefaultAzureCredential()

    database_name = (args.database or "").strip()
    if not database_name:
        raise ValueError("Database name is required via --database or COSMOS_DATABASE_NAME")

    root = Path(args.samples_dir)
    scenarios_docs = _load_json_files(root / "scenarios")
    rubrics_docs = _load_json_files(root / "rubrics")

    if not scenarios_docs and not rubrics_docs:
        raise ValueError(f"No sample JSON files found under {root}")

    client = CosmosClient(endpoint, credential=credential)
    database = client.get_database_client(database_name)

    scenarios_container = database.get_container_client(args.scenarios_container)
    rubrics_container = database.get_container_client(args.rubrics_container)

    print("Starting seed operation")
    print(f"  database: {database_name}")
    print(f"  scenarios container: {args.scenarios_container}")
    print(f"  rubrics container: {args.rubrics_container}")
    print(f"  mode: {args.mode}")
    print(f"  dry-run: {args.dry_run}")

    scenario_stats = _seed_items(
        container=scenarios_container,
        docs=scenarios_docs,
        source_key="scenarioId",
        mode=args.mode,
        dry_run=args.dry_run,
    )
    rubric_stats = _seed_items(
        container=rubrics_container,
        docs=rubrics_docs,
        source_key="rubricId",
        mode=args.mode,
        dry_run=args.dry_run,
    )

    _print_summary("Scenarios", scenario_stats)
    _print_summary("Rubrics", rubric_stats)

    failed_total = scenario_stats.failed + rubric_stats.failed
    return 1 if failed_total else 0


if __name__ == "__main__":
    raise SystemExit(main())
