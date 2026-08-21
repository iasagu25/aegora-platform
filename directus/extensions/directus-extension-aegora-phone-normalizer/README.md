# Aegora Phone Normalizer

Directus hook extension that normalizes phone numbers server-side.

Managed collections:

- `contact_phones.phone_number` → `contact_phones.phone_normalized`
- `employees.phone` → `employees.phone_normalized`

Default country code for national numbers: Spain (`+34`).

The extension accepts international numbers in E.164-compatible form and also converts numbers starting with `00` to `+`.
