import {
  TextractClient,
  StartDocumentTextDetectionCommand,
  GetDocumentTextDetectionCommand,
} from '@aws-sdk/client-textract';
import type { Block } from '@aws-sdk/client-textract';
import { BedrockRuntimeClient, InvokeModelCommand } from '@aws-sdk/client-bedrock-runtime';
import { DeleteObjectCommand, PutObjectCommand, S3Client } from '@aws-sdk/client-s3';
import { randomUUID } from 'crypto';
import type { FieldSpec } from './types';

const MAX_VALUE_LEN = 50;

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

export function truncate50(value: string): string {
  return (value ?? '').slice(0, MAX_VALUE_LEN);
}

function sortLineBlocks(blocks: Block[]): Block[] {
  const lines = blocks.filter((b) => b.BlockType === 'LINE' && b.Text);
  lines.sort((a, b) => {
    const pa = a.Page ?? 0;
    const pb = b.Page ?? 0;
    if (pa !== pb) return pa - pb;
    const ta = a.Geometry?.BoundingBox?.Top ?? 0;
    const tb = b.Geometry?.BoundingBox?.Top ?? 0;
    if (ta !== tb) return ta - tb;
    const la = a.Geometry?.BoundingBox?.Left ?? 0;
    const lb = b.Geometry?.BoundingBox?.Left ?? 0;
    return la - lb;
  });
  return lines;
}

async function collectTextractLines(
  textract: TextractClient,
  jobId: string,
): Promise<string> {
  const blocks: Block[] = [];
  let nextToken: string | undefined;
  do {
    const page = await textract.send(
      new GetDocumentTextDetectionCommand({
        JobId: jobId,
        NextToken: nextToken,
      }),
    );
    if (page.Blocks?.length) blocks.push(...page.Blocks);
    nextToken = page.NextToken;
  } while (nextToken);
  return sortLineBlocks(blocks)
    .map((b) => b.Text)
    .filter(Boolean)
    .join('\n');
}

async function pollTextractJob(textract: TextractClient, jobId: string): Promise<string> {
  for (let i = 0; i < 90; i += 1) {
    const status = await textract.send(
      new GetDocumentTextDetectionCommand({ JobId: jobId }),
    );
    const s = status.JobStatus;
    if (s === 'SUCCEEDED') {
      return collectTextractLines(textract, jobId);
    }
    if (s === 'FAILED' || s === 'PARTIAL_SUCCESS') {
      throw new Error(`Textract job ${s}: ${status.StatusMessage ?? 'unknown error'}`);
    }
    await sleep(1500);
  }
  throw new Error('Textract job timed out');
}

function buildPrompt(letterText: string, fields: FieldSpec[]): string {
  const fieldLines = fields.map((f) => `- ${JSON.stringify(f.key)} (label: ${JSON.stringify(f.label)})`).join('\n');
  return `You are extracting structured data from an insurance claim letter.

Letter text (from OCR; may contain noise):
---
${letterText.slice(0, 45000)}
---

Extract these fields. Return ONLY a single JSON object with exactly these keys (use the keys shown), string values only. If a value cannot be found, use an empty string "". Values must be at most ${MAX_VALUE_LEN} characters each (truncate mentally if needed).

Fields:
${fieldLines}

Rules:
- Output must be valid JSON, no markdown, no commentary.
- Keys must match exactly.
- claimed_amount is a string like "$1,250.00" if present.

JSON object:`;
}

function parseJsonObjectFromModelText(text: string): Record<string, string> {
  const trimmed = text.trim();
  const tryParse = (s: string) => JSON.parse(s) as unknown;
  let obj: unknown;
  try {
    obj = tryParse(trimmed);
  } catch {
    const start = trimmed.indexOf('{');
    const end = trimmed.lastIndexOf('}');
    if (start === -1 || end === -1 || end <= start) throw new Error('Model did not return JSON');
    obj = tryParse(trimmed.slice(start, end + 1));
  }
  if (!obj || typeof obj !== 'object' || Array.isArray(obj)) {
    throw new Error('Model JSON was not an object');
  }
  const out: Record<string, string> = {};
  for (const [k, v] of Object.entries(obj as Record<string, unknown>)) {
    if (typeof v === 'string') out[k] = truncate50(v);
    else if (v == null) out[k] = '';
    else out[k] = truncate50(String(v));
  }
  return out;
}

/**
 * Determines the model family from the model ID so we can build the correct
 * request body. The model ID may include a cross-region prefix (eu., us., ap.)
 * which we strip before matching.
 *
 * Supported families:
 *   - anthropic  → Claude models (anthropic.claude-*)
 *   - amazon     → Nova / Titan models (amazon.nova-*, amazon.titan-*)
 */
function getModelFamily(modelId: string): 'anthropic' | 'amazon' {
  // Strip cross-region inference profile prefix (eu., us., ap.)
  const bare = modelId.replace(/^(eu|us|ap)\./, '');
  if (bare.startsWith('anthropic.')) return 'anthropic';
  if (bare.startsWith('amazon.'))    return 'amazon';
  // Default to amazon format for unknown models — easier to debug than Claude format
  return 'amazon';
}

/**
 * Build the request body for the given model family.
 *
 * Anthropic Claude (via Bedrock):
 *   { anthropic_version, max_tokens, temperature, messages }
 *
 * Amazon Nova / Titan (Bedrock Converse-style native format):
 *   { messages, inferenceConfig }
 *   Note: Nova does NOT accept anthropic_version or top-level max_tokens.
 */
function buildRequestBody(prompt: string, modelFamily: 'anthropic' | 'amazon'): string {
  if (modelFamily === 'anthropic') {
    return JSON.stringify({
      anthropic_version: 'bedrock-2023-05-31',
      max_tokens: 2048,
      temperature: 0,
      messages: [
        {
          role: 'user',
          content: [{ type: 'text', text: prompt }],
        },
      ],
    });
  }

  // Amazon Nova native format
  return JSON.stringify({
    messages: [
      {
        role: 'user',
        content: [{ text: prompt }],
      },
    ],
    inferenceConfig: {
      maxTokens: 2048,
      temperature: 0,
    },
  });
}

/**
 * Extract the response text from the model's output.
 * Each model family returns a different response shape.
 */
function extractResponseText(raw: string, modelFamily: 'anthropic' | 'amazon'): string {
  if (modelFamily === 'anthropic') {
    const parsed = JSON.parse(raw) as {
      content?: Array<{ type?: string; text?: string }>;
    };
    const text = parsed.content?.find((c) => c.type === 'text')?.text;
    if (!text) throw new Error('Unexpected Bedrock response shape (Anthropic)');
    return text;
  }

  // Amazon Nova response shape:
  // { output: { message: { content: [{ text: string }] } } }
  const parsed = JSON.parse(raw) as {
    output?: { message?: { content?: Array<{ text?: string }> } };
  };
  const text = parsed.output?.message?.content?.[0]?.text;
  if (!text) throw new Error('Unexpected Bedrock response shape (Amazon)');
  return text;
}

export async function runExtraction(params: {
  bucket: string;
  pdfBuffer: Buffer;
  fields: FieldSpec[];
  region: string;
  modelId: string;
}): Promise<Record<string, string>> {
  const { bucket, pdfBuffer, fields, region, modelId } = params;
  const key = `uploads/${randomUUID()}.pdf`;

  const s3 = new S3Client({ region });
  const textract = new TextractClient({ region });
  const bedrock = new BedrockRuntimeClient({ region });

  const modelFamily = getModelFamily(modelId);

  await s3.send(
    new PutObjectCommand({
      Bucket: bucket,
      Key: key,
      Body: pdfBuffer,
      ContentType: 'application/pdf',
    }),
  );

  try {
    const start = await textract.send(
      new StartDocumentTextDetectionCommand({
        DocumentLocation: {
          S3Object: { Bucket: bucket, Name: key },
        },
      }),
    );
    const jobId = start.JobId;
    if (!jobId) throw new Error('Textract did not return a job id');

    const letterText = await pollTextractJob(textract, jobId);
    const prompt = buildPrompt(letterText, fields);
    const body = buildRequestBody(prompt, modelFamily);

    const invoke = await bedrock.send(
      new InvokeModelCommand({
        modelId,
        contentType: 'application/json',
        accept: 'application/json',
        body: Buffer.from(body, 'utf-8'),
      }),
    );

    const raw = new TextDecoder().decode(invoke.body);
    const text = extractResponseText(raw, modelFamily);
    const extracted = parseJsonObjectFromModelText(text);

    const result: Record<string, string> = {};
    for (const f of fields) {
      const v = extracted[f.key];
      result[f.key] = truncate50(typeof v === 'string' ? v : '');
    }
    return result;
  } finally {
    await s3
      .send(new DeleteObjectCommand({ Bucket: bucket, Key: key }))
      .catch(() => undefined);
  }
}