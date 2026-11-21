// Input validation for new guestbook entries. Lengths are counted in characters (code points), not bytes.

export const NAME_MAX = 40;
export const MESSAGE_MAX = 280;

export type EntryInput = { name: string; message: string };
export type ValidationResult =
  | { ok: true; value: EntryInput }
  | { ok: false; errors: Partial<Record<'name' | 'message', string>> };

// Control characters other than tab/newline (and Unicode bidi overrides, which can spoof text direction).
const FORBIDDEN = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F‪-‮⁦-⁩]/u;

function clean(v: unknown, field: 'name' | 'message', max: number, singleLine: boolean): string | { error: string } {
  if (typeof v !== 'string') return { error: `${field} is required` };
  let s = v.normalize('NFC').replace(/\r\n?/g, '\n').trim();
  if (singleLine) s = s.replace(/\s+/g, ' ');
  if (s.length === 0) return { error: `${field} is required` };
  if ([...s].length > max) return { error: `${field} must be at most ${max} characters` };
  if (FORBIDDEN.test(s)) return { error: `${field} contains control characters` };
  return s;
}

export function validateEntry(body: unknown): ValidationResult {
  const b = (body && typeof body === 'object' ? body : {}) as Record<string, unknown>;
  const name = clean(b.name, 'name', NAME_MAX, true);
  const message = clean(b.message, 'message', MESSAGE_MAX, false);
  const errors: Partial<Record<'name' | 'message', string>> = {};
  if (typeof name !== 'string') errors.name = name.error;
  if (typeof message !== 'string') errors.message = message.error;
  if (typeof name === 'string' && typeof message === 'string') return { ok: true, value: { name, message } };
  return { ok: false, errors };
}
