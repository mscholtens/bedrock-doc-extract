'use client';

import { useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { DEFAULT_FIELDS } from '@/lib/default-fields';
import type { FieldSpec } from '@/lib/types';
import { saveResult } from '@/lib/storage';

function newCustomKey(): string {
  const id = globalThis.crypto?.randomUUID?.() ?? `${Date.now()}`;
  return `custom_${id.replace(/-/g, '').slice(0, 12)}`;
}

function normalizeLabelKey(label: string): string {
  return label.trim().toLowerCase();
}

export default function HomePage() {
  const router = useRouter();
  const [file, setFile] = useState<File | null>(null);
  const [testRun, setTestRun] = useState(false);
  const [fields, setFields] = useState<FieldSpec[]>(DEFAULT_FIELDS);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [uploadPct, setUploadPct] = useState(0);

  const canExtract = useMemo(() => Boolean(file) && !busy, [file, busy]);

  function updateLabel(key: string, label: string) {
    setFields((prev) => prev.map((f) => (f.key === key ? { ...f, label } : f)));
  }

  function removeField(key: string) {
    setFields((prev) => prev.filter((f) => f.key !== key));
  }

  function addField() {
    setFields((prev) => {
      if (prev.length >= 20) return prev;
      return [...prev, { key: newCustomKey(), label: 'New field' }];
    });
  }

  function validateClient(): string | null {
    if (fields.length === 0) return 'Add at least one field.';
    if (fields.length > 20) return 'At most 20 fields allowed.';
    const seen = new Set<string>();
    for (const f of fields) {
      const lab = f.label.trim();
      if (!lab) return 'Field labels cannot be empty.';
      const k = normalizeLabelKey(lab);
      if (seen.has(k)) return `Duplicate field label: ${lab}`;
      seen.add(k);
    }
    return null;
  }

  async function onExtract() {
    setError(null);
    if (!file) {
      setError('Choose a PDF first.');
      return;
    }
    if (file.size > 1024 * 1024) {
      setError('PDF must be 1 MB or smaller.');
      return;
    }
    const v = validateClient();
    if (v) {
      setError(v);
      return;
    }

    if (testRun) {
      const values: Record<string, string> = {};
      for (const f of fields) {
        values[f.key] = `[Test run] ${f.label}`;
      }
      saveResult({
        filename: file.name,
        testRun: true,
        fields,
        values,
      });
      router.push('/result');
      return;
    }

    setBusy(true);
    setUploadPct(0);
    const form = new FormData();
    form.set('file', file);
    form.set('fields', JSON.stringify(fields));

    await new Promise<void>((resolve, reject) => {
      const xhr = new XMLHttpRequest();
      xhr.open('POST', '/api/extract');
      xhr.responseType = 'json';
      xhr.upload.onprogress = (evt) => {
        if (!evt.lengthComputable) return;
        const pct = Math.round((evt.loaded / evt.total) * 100);
        setUploadPct(pct);
      };
      xhr.onload = () => {
        if (xhr.status >= 200 && xhr.status < 300) {
          const body = xhr.response as { values?: Record<string, string>; error?: string };
          if (!body?.values) {
            reject(new Error(body?.error ?? 'Unexpected response'));
            return;
          }
          saveResult({
            filename: file.name,
            testRun: false,
            fields,
            values: body.values,
          });
          setUploadPct(100);
          resolve();
          return;
        }
        const body = xhr.response as { error?: string } | string | null;
        const msg =
          typeof body === 'object' && body && 'error' in body && typeof body.error === 'string'
            ? body.error
            : xhr.statusText;
        reject(new Error(msg || `Request failed (${xhr.status})`));
      };
      xhr.onerror = () => reject(new Error('Network error'));
      xhr.send(form);
    })
      .then(() => router.push('/result'))
      .catch((e: unknown) => {
        setError(e instanceof Error ? e.message : 'Extraction failed');
      })
      .finally(() => {
        setBusy(false);
      });
  }

  return (
    <div className="card">
      <h1>Extract fields from a claim letter</h1>
      <p className="lead">
        Upload one PDF (max 1 MB, max 5 pages). Configure the fields, then run extraction. This is a
        non-production demo.
      </p>

      <div className="row" style={{ marginTop: 10 }}>
        <label htmlFor="pdf">PDF</label>
        <input
          id="pdf"
          name="pdf"
          type="file"
          accept="application/pdf"
          disabled={busy}
          onChange={(e) => {
            const f = e.target.files?.[0] ?? null;
            setFile(f);
            setUploadPct(0);
            setError(null);
          }}
        />
      </div>

      <div className="row" style={{ marginTop: 14 }}>
        <label>
          <input
            type="checkbox"
            checked={testRun}
            disabled={busy}
            onChange={(e) => setTestRun(e.target.checked)}
          />{' '}
          Test run (no server call; placeholders on the next page)
        </label>
      </div>

      <div style={{ marginTop: 16 }}>
        <div className="row" style={{ justifyContent: 'space-between' }}>
          <strong>Fields</strong>
          <button type="button" onClick={addField} disabled={busy || fields.length >= 20}>
            Add field
          </button>
        </div>
        <div className="muted" style={{ marginTop: 6 }}>
          Up to 20 fields. Labels must be unique (case-insensitive). Default keys are fixed; new
          fields get generated keys.
        </div>

        <div className="field-grid">
          {fields.map((f) => (
            <div key={f.key} className="field-item">
              <input
                type="text"
                value={f.label}
                disabled={busy}
                onChange={(e) => updateLabel(f.key, e.target.value)}
                aria-label={`Label for ${f.key}`}
              />
              <button type="button" onClick={() => removeField(f.key)} disabled={busy}>
                Remove
              </button>
            </div>
          ))}
        </div>
      </div>

      {!testRun && (
        <div style={{ marginTop: 14 }}>
          <div className="muted">Upload progress (sends to server when you click Extract)</div>
          <div className="progress" aria-label="upload progress">
            <div style={{ width: `${uploadPct}%` }} />
          </div>
          <div className="muted" style={{ marginTop: 6 }}>
            {uploadPct}%
          </div>
        </div>
      )}

      {error ? <div className="error">{error}</div> : null}

      <div className="row" style={{ marginTop: 16 }}>
        <button className="primary" type="button" disabled={!canExtract} onClick={onExtract}>
          Extract
        </button>
        {file ? <span className="muted">Selected: {file.name}</span> : null}
      </div>
    </div>
  );
}
