# Architecture and design notes (AIDOCS)

This document captures **architecture** and **design decisions** for the Bedrock document extraction demo.

## Goals

- Small **non-production** demo for extracting structured fields from **PDF claim letters**.
- **No persistent storage** of claims data beyond ephemeral processing artifacts.
- **Public** demo endpoint acceptable; infrastructure is **destroyed after use**.

## High-level architecture

- **Next.js** (App Router) hosts:
  - UI pages (`/` upload, `/result` review).
  - A synchronous HTTP API route (`POST /api/extract`) that orchestrates AWS calls.
- **Amazon Textract** performs OCR / text extraction from the uploaded PDF. For **PDF** inputs, Textract is invoked with a **document location in Amazon S3** (this is an AWS API requirement for the text-detection job flow we use). The application **deletes the object immediately** after the job completes; this is **not** archival storage of claims.
- **Amazon Bedrock** (Anthropic Claude Haiku) maps OCR text + requested field definitions into **strict JSON**.
- **AWS Elastic Beanstalk** runs the Node server bundle produced by Next **standalone** output.
- **AWS CDK** (TypeScript on Node) defines:
  - Temporary S3 bucket for upload hand-off to Textract (auto-delete objects, short lifecycle prefix on `uploads/`).
  - EB application + environment.
  - IAM roles/policies for Textract, Bedrock invoke, and S3 access.
  - Artifact S3 bucket for Elastic Beanstalk application version bundles (with a bucket policy allowing EB to read objects).

## Region and model

- Primary region: **`eu-central-1`** (configured in `scripts/config.env` and CDK).
- Default Bedrock model: **`anthropic.claude-3-haiku-20240307-v1:0`** (cost/quality tradeoff for structured JSON extraction).
- If model access is not enabled, pick another enabled model and update **`BEDROCK_MODEL_ID`** consistently in:
  - `scripts/config.env`
  - `.env.local` (local)
  - CDK context / EB environment variable (deployed)

## “Synchronous” extraction vs Textract internals

The user experience is **one request that waits** until extraction completes.

Implementation detail: multi-page PDF text extraction typically uses Textract **asynchronous** APIs internally (`StartDocumentTextDetection` + polling `GetDocumentTextDetection`) while still exposing a **single** HTTP request/response to the browser.

## Test run behavior

- **No server call** occurs when “Test run” is checked.
- The results page shows **clear placeholders** per field (`[Test run] <label>`).
- This supports UI flow testing without AWS charges.

## Field model and validation

- Default six fields ship with stable **keys** and editable **labels**.
- Users may add/remove fields up to **20** total.
- **Duplicate labels** are rejected (case-insensitive). **Empty labels** are rejected.
- Server validates keys with a conservative pattern (`^[a-z][a-z0-9_]{0,63}$`).

## Output contract (Bedrock)

- The server asks the model for **JSON only** (no markdown) mapping **exact keys** to string values.
- The server **truncates every value to 50 characters** even if the model exceeds the cap.

## PDF constraints

- **Max 1 MB** upload (enforced client-side for UX and server-side for safety).
- **Max 5 pages** (enforced server-side using `pdf-parse` metadata).

## CSV export

- **Client-side only** download.
- Two rows: headers (labels) + values.
- Filename is **not** exported.

## Deployment scripts

- `scripts/config.env` holds **non-secret** defaults (region, EB names, model id).
- `scripts/deploy.sh`:
  - Bootstraps CDK if `CDKToolkit` is missing.
  - Deploys CDK stack.
  - Builds Next standalone bundle, zips it, uploads to artifact bucket, creates EB application version, updates environment, prints URL.
- `scripts/destroy.sh` destroys the CDK stack (idempotent if stack missing).
- `scripts/status.sh` prints CloudFormation + EB status and a lightweight HTTP probe.

## Security stance (explicit)

This is intentionally **not** a hardened production system:

- No authentication/authorization.
- Public HTTP URL after deploy.
- Credentials for local development belong in **`.env.local`** (gitignored). **Elastic Beanstalk uses IAM instance role** for runtime AWS access.

## Test data generation

- `fixtures/claim-letter-samples.txt` contains five synthetic narratives separated by `<<<SAMPLE nn>>>` markers.
- `scripts/generate_test_pdfs.py` renders each narrative into a ~one-page PDF using ReportLab.
- `scripts/generatetestdata.sh` creates a local venv, installs `requirements-dev.txt`, and runs the generator.
