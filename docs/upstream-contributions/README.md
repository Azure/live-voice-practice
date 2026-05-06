# Upstream contributions

This folder contains drafts of issues and pull requests intended for upstream repositories on which this accelerator depends. Files here are **drafts**, prepared for review and ready to be filed by a maintainer; they are not automatically synchronized with the upstream repositories.

## Conventions

- One file per upstream artifact (issue or PR).
- File name: `<seq>-<short-slug>.md`, where `<seq>` is a zero-padded sequence number scoped to this folder.
- The first H1 of the file is the title that should be used when filing the issue or PR upstream.
- The body of the file is the body that should be used when filing.
- A horizontal rule separates the title block from the body.
- Status tracking (filed, merged, abandoned) lives in the index below.

## Why drafts live in this repo

The infrastructure of this accelerator is consumed from upstream repositories (notably [`Azure/AI-Landing-Zones`](https://github.com/Azure/AI-Landing-Zones)). Modifications needed for this accelerator's scenarios are filed upstream rather than carried as patches in this repository's submodule. Drafting the proposal here, in the same repository where the motivating scenario lives, keeps the design discussion close to the evidence that motivates it.

## Index

| Seq | Target repository | Title | Status |
|----:|-------------------|-------|--------|
| 001 | `Azure/AI-Landing-Zones` | Optional public ingress (Application Gateway) for ACA-internal scenarios that require browser-side device capabilities | Filed as [#104](https://github.com/Azure/AI-Landing-Zones/issues/104) |
