import type { McpServer } from "@modelcontextprotocol/sdk/server/mcp.js";
import { registerWithWitness } from "../witness.ts";
import { HealthCheckShape } from "../schema.ts";
import { jsonResult, errorResult } from "./_result.ts";
import { callDaemon, DaemonUnavailableError } from "../daemon/rpc-client.ts";
import { getContactsSidecarDiagnostic } from "../storage/contacts-cache.ts";
import type { ChatDbDiagnostic } from "../chatdb/open.ts";
import type { AddressBookDiagnostic, ContactsLoadDiagnostic } from "../chatdb/contacts.ts";

// `health_check` exists to break a specific debugging deadlock: when
// `to_handle_name` keeps coming back null for a known contact, the user
// can't tell whether the daemon is down, whether Full Disk Access is
// missing on the Ghostie app, whether the AddressBook DB opened
// but is empty, whether the contact is genuinely absent, or whether the
// phone-number canonicalization mismatched. This tool answers all of that.
//
// Post-daemon-refactor: chat.db + AddressBook are FDA-gated, so the daemon
// (which holds FDA, inherited from the menu-bar app) performs them. The MCP
// reads only the contacts sidecar locally (no FDA). If the daemon is
// unreachable, the remediation points at launching the menu-bar app.
export function registerHealthTools(server: McpServer): void {
  registerWithWitness(
    server,
    "health_check",
    {
      title: "Diagnose imessage-drafts-mcp permissions and contact lookup",
      description:
        "Returns the live state of AddressBook and chat.db access (read by the " +
        "Ghostie daemon, which holds Full Disk Access). Pass `probe_handle` " +
        "to also report how a phone/email canonicalizes and whether it resolves to a " +
        "contact name. Use this when `to_handle_name` keeps coming back null for a " +
        "known contact, when read tools error, or to confirm the daemon + FDA are healthy.",
      inputSchema: HealthCheckShape,
    },
    async (args) => {
      try {
        const sidecar = getContactsSidecarDiagnostic();

        // chat.db + AddressBook are FDA-gated → the daemon performs them.
        let chatdb: ChatDbDiagnostic;
        let addressbook: AddressBookDiagnostic;
        let contacts_load: ContactsLoadDiagnostic;
        let daemon_reachable = true;
        try {
          const h = await callDaemon<{
            chatdb: ChatDbDiagnostic;
            addressbook: AddressBookDiagnostic;
            contacts_load: ContactsLoadDiagnostic;
          }>("health");
          chatdb = h.chatdb;
          addressbook = h.addressbook;
          contacts_load = h.contacts_load;
        } catch (e) {
          daemon_reachable = false;
          const reason =
            e instanceof DaemonUnavailableError ? "daemon_unreachable" : (e as Error).message;
          chatdb = {
            db_path: "~/Library/Messages/chat.db",
            db_path_exists: false,
            open_status: "error",
            open_error: reason,
          };
          addressbook = {
            db_path: null,
            db_path_exists: false,
            db_paths: [],
            open_status: "error",
            open_error: reason,
            contacts_loaded: 0,
            per_db: [],
          };
          contacts_load = {
            source: "none",
            count: 0,
            sidecar_present: sidecar.read_status === "ok",
          };
        }

        const contacts_source = contacts_load.source;
        const fda_likely_missing =
          chatdb.open_status === "permission_denied" ||
          (contacts_source !== "sidecar" && addressbook.open_status === "permission_denied");

        const probe = args.probe_handle
          ? await callDaemon<{ input: string; canonical: string; resolved_name: string | null }>(
              "probeHandle",
              { handle: args.probe_handle },
            ).catch(() => undefined)
          : undefined;

        // Pick the most actionable remediation. Order: daemon down (launch
        // the app) → contacts-sidecar issues → FDA missing → all good.
        const instructions = (() => {
          if (!daemon_reachable) {
            return "The Ghostie menu bar app isn't running — it hosts the daemon " +
              "that reads chat.db and AddressBook on this MCP's behalf. Launch " +
              "/Applications/Ghostie.app (it starts the daemon automatically). " +
              "If it's already open, the daemon may still be starting; retry shortly.";
          }
          if (sidecar.read_status === "missing") {
            return "Install/launch the menu bar app and grant Contacts permission when " +
              "prompted. It writes ~/.messages-mcp/contacts-cache.json, which this MCP reads " +
              "for contact names without needing Full Disk Access.";
          }
          if (sidecar.permission_status === "denied" || sidecar.permission_status === "restricted") {
            return "The menu bar app is installed but lacks Contacts permission. Open System " +
              "Settings → Privacy & Security → Contacts and enable 'Ghostie', then click " +
              "'Refresh contacts' in the menu bar popover.";
          }
          if (fda_likely_missing) {
            return "The daemon is running but can't read chat.db — Full Disk Access is missing " +
              "for the Ghostie app. Open System Settings → Privacy & Security → Full Disk " +
              "Access and ensure 'Ghostie' is enabled (remove + re-add it if it was just " +
              "rebuilt), then quit and reopen the menu bar app so the daemon re-spawns with the grant. " +
              "(Claude itself does NOT need Full Disk Access.)";
          }
          return "Permissions look good. If contact resolution still fails, the issue is likely " +
            "canonicalization — call this tool again with `probe_handle` set to the recipient's " +
            "number to see exactly what key the lookup uses.";
        })();

        return jsonResult({
          daemon_reachable,
          contacts_source,
          contacts_load,
          contacts_sidecar: sidecar,
          addressbook,
          chatdb,
          fda_likely_missing,
          remediation: {
            settings_url:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles",
            contacts_settings_url:
              "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts",
            // FDA is granted to the Ghostie .app bundle (the daemon
            // inherits it), not to this MCP binary or to Claude.
            app_path: "/Applications/Ghostie.app",
            instructions,
          },
          probe,
        });
      } catch (e) {
        return errorResult(`health_check failed: ${(e as Error).message}`);
      }
    }
  );
}
