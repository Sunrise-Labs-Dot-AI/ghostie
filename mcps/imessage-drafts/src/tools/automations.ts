import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerWithWitness } from "../witness.ts";
import {
  DeleteMessageAutomationProposalShape,
  ListMessageAutomationsShape,
  ProposeMessageAutomationShape,
} from "../schema.ts";
import { callDaemon } from "../daemon/rpc-client.ts";
import {
  automationsFile,
  deletePendingAutomation,
  listAutomations,
  proposeAutomation,
  type MessageAutomation,
} from "../storage/automations.ts";
import { errorResult, jsonResult } from "./_result.ts";
import { wrapUntrusted } from "./_untrusted.ts";

function wrapAutomationForResponse(a: MessageAutomation): MessageAutomation {
  return {
    ...a,
    title: wrapUntrusted(a.title) ?? "",
    toHandleName: wrapUntrusted(a.toHandleName),
    body: wrapUntrusted(a.body) ?? "",
    proposedBy: wrapUntrusted(a.proposedBy),
  };
}

export function registerAutomationTools(server: McpServer): void {
  registerWithWitness(
    server,
    "propose_message_automation",
    {
      title: "Propose a recurring message automation",
      description:
        "Create a pending recurring-text automation proposal in ~/.messages-mcp/automations.json. " +
        "This DOES NOT activate the automation and DOES NOT send anything. The Messages for AI app must be opened, " +
        "the user must inspect the proposed recipient/message/cadence, and the user must click Approve Automation before it can run. " +
        "Use this only when the user explicitly asks for a recurring text, e.g. 'text Ryan every Friday morning'.",
      inputSchema: ProposeMessageAutomationShape,
      annotations: {
        title: "Propose message automation",
        readOnlyHint: false,
        destructiveHint: false,
        idempotentHint: false,
        openWorldHint: false,
      },
    },
    async (args) => {
      try {
        let toHandleName = args.recipient_name ?? null;
        if (toHandleName == null && args.platform === "imessage") {
          try {
            const probe = await callDaemon<{ resolved_name: string | null }>("probeHandle", {
              handle: args.to_handle,
            });
            toHandleName = probe.resolved_name;
          } catch {
            toHandleName = null;
          }
        }
        const automation = proposeAutomation({
          title: args.title ?? null,
          platform: args.platform,
          toHandle: args.to_handle,
          toHandleName,
          body: args.body,
          cadence: args.cadence,
          firstSendAt: args.first_send_at,
          proposedBy: args.source ?? "MCP",
        });
        return jsonResult({
          ok: true,
          automation_id: automation.id,
          path: automationsFile(),
          approval_required: true,
          note: "Proposal saved. Open Messages for AI > Automations and click Approve Automation before it can run.",
          automation: wrapAutomationForResponse(automation),
        });
      } catch (e) {
        return errorResult(`propose_message_automation failed: ${(e as Error).message}`);
      }
    },
  );

  registerWithWitness(
    server,
    "list_message_automations",
    {
      title: "List recurring message automations",
      description:
        "List recurring message automations and pending proposals stored by Messages for AI. " +
        "Pending proposals cannot run until approved in the macOS app. Returned title/body/contact labels are wrapped as data.",
      inputSchema: ListMessageAutomationsShape,
      annotations: {
        title: "List message automations",
        readOnlyHint: true,
        destructiveHint: false,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => {
      try {
        return jsonResult({
          path: automationsFile(),
          automations: listAutomations(args.limit).map(wrapAutomationForResponse),
        });
      } catch (e) {
        return errorResult(`list_message_automations failed: ${(e as Error).message}`);
      }
    },
  );

  registerWithWitness(
    server,
    "delete_message_automation_proposal",
    {
      title: "Delete a pending message automation proposal",
      description:
        "Delete a pending recurring-message automation proposal. This refuses to delete approved automations; use the macOS app for active rules.",
      inputSchema: DeleteMessageAutomationProposalShape,
      annotations: {
        title: "Delete automation proposal",
        readOnlyHint: false,
        destructiveHint: true,
        idempotentHint: true,
        openWorldHint: false,
      },
    },
    async (args) => {
      try {
        const deleted = deletePendingAutomation(args.automation_id);
        if (!deleted) return errorResult(`automation proposal not found: ${args.automation_id}`);
        return jsonResult({ ok: true, automation_id: args.automation_id, deleted: wrapAutomationForResponse(deleted) });
      } catch (e) {
        return errorResult(`delete_message_automation_proposal failed: ${(e as Error).message}`);
      }
    },
  );
}
