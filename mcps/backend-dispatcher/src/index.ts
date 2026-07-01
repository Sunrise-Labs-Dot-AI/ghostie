#!/usr/bin/env bun

const ROLE_ALIASES: Record<string, string> = {
  "imessage-drafts-mcp": "imessage-mcp",
  "imessage-mcp": "imessage-mcp",
  "ghostie-mcp": "ghostie-mcp",
  "imessage-drafts-daemon": "imessage-daemon",
  "imessage-daemon": "imessage-daemon",
  "whatsapp-drafts-mcp": "whatsapp-mcp",
  "whatsapp-mcp": "whatsapp-mcp",
  "whatsapp-drafts-daemon": "whatsapp-daemon",
  "whatsapp-daemon": "whatsapp-daemon",
  "wrapped-generator": "wrapped",
  "wrapped": "wrapped",
  "texting-analytics-generator": "texting-analytics",
  "texting-analytics": "texting-analytics",
  "birthday-generator": "birthday",
  "birthday": "birthday",
};

function resolveRole(argv: string[]): string {
  const explicitRole = ROLE_ALIASES[argv[2] ?? ""];
  if (explicitRole) {
    argv.splice(2, 1);
    return explicitRole;
  }

  const invoked = [process.execPath, argv[1], argv[0]]
    .map((p) => (p ?? "").split("/").pop() ?? "")
    .map((name) => ROLE_ALIASES[name])
    .find(Boolean);
  if (invoked) return invoked;

  throw new Error(
    "missing backend role; expected one of " +
      Object.keys(ROLE_ALIASES).sort().join(", "),
  );
}

const role = resolveRole(process.argv);

switch (role) {
  case "imessage-mcp":
    await import("../../imessage-drafts/src/index.ts");
    break;
  case "ghostie-mcp":
    await import("../../ghostie/src/index.ts");
    break;
  case "imessage-daemon":
    await import("../../imessage-drafts/src/daemon/index.ts");
    break;
  case "whatsapp-mcp":
    await import("../../whatsapp-drafts/src/index.ts");
    break;
  case "whatsapp-daemon":
    await import("../../whatsapp-drafts/src/daemon/index.ts");
    break;
  case "wrapped":
    await import("../../wrapped-generator/src/index.ts");
    break;
  case "texting-analytics":
    await import("../../wrapped-generator/src/texting-analytics-generator.ts");
    break;
  case "birthday":
    await import("../../birthday-generator/src/index.ts");
    break;
  default:
    throw new Error(`unknown backend role: ${role}`);
}
