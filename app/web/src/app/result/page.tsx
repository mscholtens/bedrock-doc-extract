'use client';

import { useEffect, useMemo, useState } from 'react';
import { useRouter } from 'next/navigation';
import { clearResult, loadResult } from '@/lib/storage';
import type { ExtractResultPayload } from '@/lib/types';

function csvEscape(value: string): string {
  return `"${String(value).replace(/"/g, '""')}"`;
}

function buildCsv(payload: ExtractResultPayload): string {
  const headers = payload.fields.map((f) => f.label);
  const values = payload.fields.map((f) => payload.values[f.key] ?? '');
  return `${headers.map(csvEscape).join(',')}\n${values.map(csvEscape).join(',')}\n`;
}

export default function ResultPage() {
  const router = useRouter();
  const [payload, setPayload] = useState<ExtractResultPayload | null>(null);

  useEffect(() => {
    const p = loadResult();
    if (!p) {
      router.replace('/');
      return;
    }
    setPayload(p);
  }, [router]);

  const subtitle = useMemo(() => {
    if (!payload) return '';
    return payload.testRun ? 'Test run (placeholders)' : 'Extraction result';
  }, [payload]);

  if (!payload) return null;

  return (
    <div className="card">
      <h1>Result</h1>
      <p className="lead">{subtitle}</p>

      <div className="muted" style={{ marginBottom: 10 }}>
        Filename (not exported to CSV): <span className="mono">{payload.filename}</span>
      </div>

      <table className="result-table" aria-label="extracted values">
        <tbody>
          {payload.fields.map((f) => (
            <tr key={f.key}>
              <th>{f.label}</th>
              <td className="mono">{payload.values[f.key] ?? ''}</td>
            </tr>
          ))}
        </tbody>
      </table>

      <div className="row" style={{ marginTop: 16 }}>
        <button
          className="primary"
          type="button"
          onClick={() => {
            const csv = buildCsv(payload);
            const blob = new Blob([csv], { type: 'text/csv;charset=utf-8' });
            const url = URL.createObjectURL(blob);
            const a = document.createElement('a');
            a.href = url;
            a.download = 'extracted.csv';
            a.click();
            URL.revokeObjectURL(url);
          }}
        >
          Export to CSV
        </button>
        <button
          className="danger"
          type="button"
          onClick={() => {
            clearResult();
            router.push('/');
          }}
        >
          Discard and Return
        </button>
      </div>
    </div>
  );
}
