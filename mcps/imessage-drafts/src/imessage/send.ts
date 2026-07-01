// Send an iMessage via the Messages.app AppleScript automation surface.
//
// This is the *only* outbound side of the iMessage MCP server. It is gated
// at three layers in defense-in-depth:
//
//   1) The MCP tool itself is annotated `destructiveHint: true` /
//      `idempotentHint: false` so any MCP client surfaces a confirmation
//      prompt before the call.
//   2) The tool refuses to fire ad hoc — it requires a draft_id pointing at
//      an already-staged draft. That forces every send through the
//      `stage_draft` step, so the draft text is observable in the
//      conversation transcript before the send tool is invoked.
//   3) Once `sent_at` is set on a draft, re-sending is rejected. The agent
//      cannot loop send-the-same-message on retry.
//
// macOS adds a fourth: the first AppleScript send triggers a TCC
// "Allow <parent app> to control Messages.app?" prompt. Whichever app
// spawned imessage-drafts-mcp must be granted that permission.
//
// ⛔ If this server is ever exposed over a network transport (HTTP / WS /
// tunnel), this tool MUST be removed from the public surface — the trust
// boundary collapses the moment a non-local caller can invoke it.

import { spawn } from "node:child_process";

export interface SendResult {
  ok: boolean;
  service: "iMessage" | "SMS" | null;
  error: string | null;
  duration_ms: number;
}

const SEND_TIMEOUT_MS = 20_000;

// Use multiple -e fragments rather than embedding a multiline string — keeps
// the script readable and dodges shell-quoting traps. argv is passed as
// trailing positional args (osascript routes them to `on run argv`).
//
// We try iMessage first; if Messages.app reports the buddy is unreachable
// via iMessage, we fall through to SMS (which requires iPhone Continuity to
// be configured). The `errNumber` in the AppleScript error catch identifies
// the failure mode; we return service=null on hard failure.
const SCRIPT = `
on run argv
  set theAddress to item 1 of argv
  set theMessage to item 2 of argv
  tell application "Messages"
    try
      set theService to first service whose service type is iMessage
      set theBuddy to buddy theAddress of theService
      send theMessage to theBuddy
      return "iMessage"
    on error errMsg number errNum
      try
        set smsService to first service whose service type is SMS
        set smsBuddy to buddy theAddress of smsService
        send theMessage to smsBuddy
        return "SMS"
      on error smsErr number smsNum
        return "ERROR: iMessage=" & errMsg & " (errNum=" & errNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
      end try
    end try
  end tell
end run
`;

// Attachment variant: `send (POSIX file …)` instead of a text string. Mirrors
// the menu bar app's first-party file-send path (DraftSender.buddyFileScript)
// so an MCP-staged draft and a hand-composed one deliver media the same way.
// The file is copied into Messages' own attachment store at send time, so the
// source path only needs to exist for the duration of this call.
const FILE_SCRIPT = `
on run argv
  set theAddress to item 1 of argv
  set theFile to POSIX file (item 2 of argv)
  tell application "Messages"
    try
      set theService to first service whose service type is iMessage
      set theBuddy to buddy theAddress of theService
      send theFile to theBuddy
      return "iMessage"
    on error errMsg number errNum
      try
        set smsService to first service whose service type is SMS
        set smsBuddy to buddy theAddress of smsService
        send theFile to smsBuddy
        return "SMS"
      on error smsErr number smsNum
        return "ERROR: iMessage=" & errMsg & " (errNum=" & errNum & "); SMS=" & smsErr & " (errNum=" & smsNum & ")"
      end try
    end try
  end tell
end run
`;

// Group chats are addressed by `chat id` (their GUID), not by buddy.
// The buddy cascade fails for group targets because the to_handle is a
// canonical binding ("imessage-group:<guid>"), not a real phone or email.
const GROUP_SCRIPT = `
on run argv
  set theChatId to item 1 of argv
  set theMessage to item 2 of argv
  tell application "Messages"
    try
      send theMessage to chat id theChatId
      return "iMessage"
    on error errMsg number errNum
      return "ERROR: chat send=" & errMsg & " (errNum=" & errNum & ")"
    end try
  end tell
end run
`;

// Group attachment send: a file (POSIX path) to a group chat id. Mirrors
// GROUP_SCRIPT but for media, so group drafts deliver attachments the same way
// direct drafts do.
const GROUP_FILE_SCRIPT = `
on run argv
  set theChatId to item 1 of argv
  set theFile to POSIX file (item 2 of argv)
  tell application "Messages"
    try
      send theFile to chat id theChatId
      return "iMessage"
    on error errMsg number errNum
      return "ERROR: chat file send=" & errMsg & " (errNum=" & errNum & ")"
    end try
  end tell
end run
`;

// Shared osascript runner for every Messages.app send variant (text, file, or
// group chat-id). Parses the "iMessage" / "SMS" / "ERROR: …" output contract
// into a SendResult.
function runOSAScript(script: string, args: string[]): Promise<SendResult> {
  const started = Date.now();
  return new Promise<SendResult>((resolve) => {
    const child = spawn("osascript", ["-e", script, ...args], { stdio: ["ignore", "pipe", "pipe"] });
    let stdout = "";
    let stderr = "";
    let done = false;

    const finish = (result: Omit<SendResult, "duration_ms">) => {
      if (done) return;
      done = true;
      clearTimeout(timer);
      resolve({ ...result, duration_ms: Date.now() - started });
    };

    const timer = setTimeout(() => {
      child.kill("SIGKILL");
      finish({ ok: false, service: null, error: `osascript timed out after ${SEND_TIMEOUT_MS}ms` });
    }, SEND_TIMEOUT_MS);

    child.stdout.on("data", (chunk: Buffer) => { stdout += chunk.toString(); });
    child.stderr.on("data", (chunk: Buffer) => { stderr += chunk.toString(); });
    child.on("error", (err) => { finish({ ok: false, service: null, error: `osascript spawn failed: ${err.message}` }); });
    child.on("close", (code) => {
      const out = stdout.trim();
      if (code !== 0) {
        finish({ ok: false, service: null, error: stderr.trim() || `osascript exited with code ${code}` });
        return;
      }
      if (out === "iMessage") { finish({ ok: true, service: "iMessage", error: null }); return; }
      if (out === "SMS") { finish({ ok: true, service: "SMS", error: null }); return; }
      finish({ ok: false, service: null, error: out || "unknown osascript output" });
    });
  });
}

/// Send an iMessage to an existing group chat by its chat GUID.
/// The GUID is the value stored after "imessage-group:" in a group draft's
/// to_handle (e.g. "iMessage;+;chat123456789"). Only works when the group
/// chat already exists in Messages.app — if not, send from Messages.app first.
export async function sendIMessageToGroup(chatGUID: string, body: string): Promise<SendResult> {
  return runOSAScript(GROUP_SCRIPT, [chatGUID, body]);
}

// Send a single file as an attachment to an existing group chat by its GUID.
export async function sendIMessageAttachmentToGroup(chatGUID: string, filePath: string): Promise<SendResult> {
  return runOSAScript(GROUP_FILE_SCRIPT, [chatGUID, filePath]);
}

export async function sendIMessage(toHandle: string, body: string): Promise<SendResult> {
  return runOSAScript(SCRIPT, [toHandle, body]);
}

// Send a single file as an iMessage/MMS attachment. `filePath` must be an
// absolute local path that exists at call time.
export async function sendIMessageAttachment(toHandle: string, filePath: string): Promise<SendResult> {
  return runOSAScript(FILE_SCRIPT, [toHandle, filePath]);
}
