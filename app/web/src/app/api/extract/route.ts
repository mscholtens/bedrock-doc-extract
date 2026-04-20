import { NextResponse } from 'next/server';
import { parseFieldsJson } from '@/lib/validate-fields';
import { runExtraction } from '@/lib/extraction-server';
import type { FieldSpec } from '@/lib/types';

export const runtime = 'nodejs';
export const maxDuration = 120;

const MAX_BYTES = 1024 * 1024;
const MAX_PAGES = 5;

function isPdfBuffer(buf: Buffer): boolean {
  return buf.length >= 5 && buf.subarray(0, 5).toString('ascii') === '%PDF-';
}

export async function POST(request: Request) {
  const bucket = process.env.TEMP_BUCKET_NAME;
  const modelId = process.env.BEDROCK_MODEL_ID;
  const region = process.env.AWS_REGION ?? process.env.AWS_DEFAULT_REGION ?? 'eu-central-1';

  if (!bucket || !modelId) {
    return NextResponse.json(
      {
        error:
          'Server is missing TEMP_BUCKET_NAME or BEDROCK_MODEL_ID. For local dev, copy .env.example to .env.local and set values (see README).',
      },
      { status: 500 },
    );
  }

  let form: FormData;
  try {
    form = await request.formData();
  } catch {
    return NextResponse.json({ error: 'Invalid form data' }, { status: 400 });
  }

  const file = form.get('file');
  if (!(file instanceof File)) {
    return NextResponse.json({ error: 'file is required' }, { status: 400 });
  }

  const rawFields = form.get('fields');
  if (typeof rawFields !== 'string') {
    return NextResponse.json({ error: 'fields JSON string is required' }, { status: 400 });
  }

  let fields: FieldSpec[];
  try {
    fields = parseFieldsJson(rawFields);
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Invalid fields';
    return NextResponse.json({ error: msg }, { status: 400 });
  }

  if (file.type && file.type !== 'application/pdf') {
    return NextResponse.json({ error: 'Only application/pdf is allowed' }, { status: 400 });
  }

  const buf = Buffer.from(await file.arrayBuffer());
  if (buf.length > MAX_BYTES) {
    return NextResponse.json({ error: 'PDF must be 1 MB or smaller' }, { status: 400 });
  }
  if (!isPdfBuffer(buf)) {
    return NextResponse.json({ error: 'File does not look like a PDF' }, { status: 400 });
  }

let numpages = 1;
  try {
    console.log('PDF buffer size:', buf.length, 'bytes');
    console.log('PDF header:', buf.subarray(0, 20).toString('ascii'));
    const pdfParseLib = await import('pdf-parse');
    const pdfParse = pdfParseLib.default as (data: Buffer) => Promise<{
      numpages?: number;
    }>;
    console.log('pdf-parse imported successfully');
    const meta = await pdfParse(buf);
    console.log('pdfParse result:', { numpages: meta.numpages });
    numpages = meta.numpages ?? 1;
  } catch (e) {
    console.error('pdfParse error:', e);
    // Fallback for xref errors - assume single page
    numpages = 1;
  }
  if (numpages > MAX_PAGES) {
    return NextResponse.json({ error: 'PDF must be at most 5 pages' }, { status: 400 });
  }

  try {
    const values = await runExtraction({
      bucket,
      pdfBuffer: buf,
      fields,
      region,
      modelId,
    });
    return NextResponse.json({ values });
  } catch (e) {
    const msg = e instanceof Error ? e.message : 'Extraction failed';
    console.error(e);
    return NextResponse.json({ error: msg }, { status: 500 });
  }
}
