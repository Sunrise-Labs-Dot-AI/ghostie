// Suggestion verdict + a deliberately-generic templated opener.
//
// The GUI's value is identifying WHO to text; the opener is a placeholder the
// user edits (or replaces via the "Draft with Claude" path for a voice-correct
// message). Keep it plain — a clever-but-wrong template reads worse than an
// honest generic one.

export interface SuggestInput {
  relationship: string | null;
  pinned: boolean;
  muted: boolean;
  textsALot: boolean; // among the user's top-N most-texted contacts
  callsALot: boolean; // among the user's top-N most-called contacts
  wishedBefore: boolean;
}

export interface Suggestion {
  suggested: boolean;
  reasons: string[];
}

export function suggest(input: SuggestInput): Suggestion {
  const reasons: string[] = [];
  if (input.pinned) reasons.push("On your list");
  if (input.textsALot) reasons.push("You text them a lot");
  if (input.callsALot) reasons.push("You call them a lot");
  if (input.wishedBefore) reasons.push("You've wished them before");
  // "texts-a-lot OR calls-a-lot OR wished-before OR pinned", unless dismissed.
  const suggested =
    (input.pinned || input.textsALot || input.callsALot || input.wishedBefore) && !input.muted;
  return { suggested, reasons };
}

export function firstName(name: string): string {
  const first = name.trim().split(/\s+/)[0];
  return first && first.length > 0 ? first : name.trim();
}

export function suggestedMessage(name: string, relationship: string | null): string {
  const f = firstName(name);
  switch ((relationship ?? "").toLowerCase()) {
    case "partner":
      return `Happy birthday, ${f}! Hope your day is as wonderful as you are ❤️`;
    case "family":
      return `Happy birthday, ${f}! Hope you have a wonderful day.`;
    case "friend":
      return `Happy birthday, ${f}! Hope it's a great one 🎉`;
    case "colleague":
      return `Happy birthday, ${f}! Hope you have a great day.`;
    default:
      return `Happy birthday, ${f}! Hope you have a great one.`;
  }
}
