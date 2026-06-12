"""Migrate baked-in sample transcripts (samples/transcripts/*.txt) into Blob Storage.

Phase 4 of issue #45 moves transcripts off the container image filesystem into
the ``transcripts`` blob container so trainers can manage them from /admin.
This one-time backfill uploads any local sample transcripts that are not yet
present in the blob container.

Authentication uses Microsoft Entra ID (DefaultAzureCredential); the calling
identity needs the ``Storage Blob Data Contributor`` role on the account.

Usage (PowerShell):
  $env:STORAGE_BLOB_ENDPOINT = "https://<account>.blob.core.windows.net/"
  python scripts/migrate_transcripts_to_blob.py
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path

from azure.identity import DefaultAzureCredential
from azure.storage.blob import BlobServiceClient, ContentSettings


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Backfill sample transcripts into Blob Storage")
    parser.add_argument("--endpoint", default=os.getenv("STORAGE_BLOB_ENDPOINT", ""))
    parser.add_argument("--container", default=os.getenv("TRANSCRIPTS_STORAGE_CONTAINER", "transcripts"))
    parser.add_argument("--source-dir", default="samples/transcripts")
    parser.add_argument("--overwrite", action="store_true", help="Overwrite existing blobs")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if not args.endpoint:
        raise SystemExit("STORAGE_BLOB_ENDPOINT (or --endpoint) is required")

    source = Path(args.source_dir)
    files = sorted(source.glob("*.txt")) if source.exists() else []
    if not files:
        print(f"No .txt transcripts found under {source}")
        return 0

    service = BlobServiceClient(account_url=args.endpoint, credential=DefaultAzureCredential())
    container = service.get_container_client(args.container)

    uploaded = skipped = 0
    for file_path in files:
        blob_name = file_path.name
        blob = container.get_blob_client(blob_name)
        if blob.exists() and not args.overwrite:
            skipped += 1
            print(f"[exists] {blob_name}")
            continue
        if args.dry_run:
            print(f"[dry-run] {blob_name}")
            continue
        blob.upload_blob(
            file_path.read_bytes(),
            overwrite=True,
            content_settings=ContentSettings(content_type="text/plain"),
        )
        uploaded += 1
        print(f"[uploaded] {blob_name}")

    print(f"\nDone. uploaded={uploaded} skipped={skipped} total={len(files)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
