import type { FieldSpec } from './types';

const KEY_RE = /^[a-z][a-z0-9_]{0,63}$/;

export function parseFieldsJson(raw: string): FieldSpec[] {
  const parsed: unknown = JSON.parse(raw);
  if (!Array.isArray(parsed)) throw new Error('fields must be a JSON array');
  if (parsed.length > 20) throw new Error('At most 20 fields allowed');
  const fields: FieldSpec[] = [];
  const labelsLower = new Set<string>();
  for (const item of parsed) {
    if (!item || typeof item !== 'object') throw new Error('Invalid field entry');
    const rec = item as Record<string, unknown>;
    const key = String(rec.key ?? '');
    const label = String(rec.label ?? '').trim();
    if (!KEY_RE.test(key)) throw new Error(`Invalid field key: ${key}`);
    if (!label) throw new Error('Field labels cannot be empty');
    const dup = label.toLowerCase();
    if (labelsLower.has(dup)) throw new Error(`Duplicate field label: ${label}`);
    labelsLower.add(dup);
    fields.push({ key, label });
  }
  return fields;
}
