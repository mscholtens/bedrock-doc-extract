import type { ExtractResultPayload } from './types';

export const STORAGE_KEY = 'bedrockDocExtractResult';

export function saveResult(payload: ExtractResultPayload): void {
  if (typeof window === 'undefined') return;
  sessionStorage.setItem(STORAGE_KEY, JSON.stringify(payload));
}

export function loadResult(): ExtractResultPayload | null {
  if (typeof window === 'undefined') return null;
  const raw = sessionStorage.getItem(STORAGE_KEY);
  if (!raw) return null;
  try {
    return JSON.parse(raw) as ExtractResultPayload;
  } catch {
    return null;
  }
}

export function clearResult(): void {
  if (typeof window === 'undefined') return;
  sessionStorage.removeItem(STORAGE_KEY);
}
