import type { FieldSpec } from './types';

export const DEFAULT_FIELDS: FieldSpec[] = [
  { key: 'customer_name', label: 'Customer name' },
  { key: 'policy_number', label: 'Policy number' },
  { key: 'claim_type', label: 'Claim type' },
  { key: 'incident_date', label: 'Incident date' },
  { key: 'incident_description', label: 'Incident description' },
  { key: 'claimed_amount', label: 'Claimed amount' },
];
