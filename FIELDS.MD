# Extracted fields

This demo extracts **string values** from **incoming insurance claim letters** (PDF). Values are **capped at 50 characters** on the server after the model returns them.

## Default fields (six)

These are the baseline fields for claim letters. Keys are stable; labels can be renamed in the UI.

| Key | Default label | Meaning |
| --- | --- | --- |
| `customer_name` | Customer name | Name of the insured / claimant as written in the letter. |
| `policy_number` | Policy number | Policy identifier, membership number, or similar reference. |
| `claim_type` | Claim type | Short category (for example motor, water damage, travel). |
| `incident_date` | Incident date | Date of loss / incident as stated in the letter. |
| `incident_description` | Incident description | Brief narrative of what happened. |
| `claimed_amount` | Claimed amount | Monetary demand as text (for example `"$100"` or `"EUR 250"`). |

## Custom fields

Users may **add**, **rename** (label only), or **remove** fields.

Constraints:

- **Maximum 20** fields total.
- **Labels must be non-empty** and **unique** (case-insensitive).
- Keys for newly added fields are generated server-side patterns like `custom_…` and should be treated as opaque identifiers.

## Missing values

If the letter does not contain a value for a field, the UI shows an **empty string** for that field.

## CSV export (client-side)

The CSV contains **two rows**:

1. Header row: field **labels** (not keys).
2. Data row: extracted **values** in the same column order.

The **PDF filename is shown on the results page only**; it is **not** included in the CSV.

After **Export to CSV**, the app clears the in-memory result and returns you to the **main (upload) page**, same as **Discard**.
