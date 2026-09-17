import { expect, test } from "bun:test";
import { fileURLToPath } from "node:url";

// Decode the package path properly: a checkout under a directory with spaces must still spawn the host.
const packageDir = fileURLToPath(new URL("../", import.meta.url));

test("host exits when its app-owned stdin pipe closes", async () => {
  const child = Bun.spawn(["bun", "run", "src/remote-host.ts"], { cwd: packageDir, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  child.stdin.end();
  const timer = setTimeout(() => child.kill(), 3000);
  try { expect(await child.exited).toBe(0); } finally { clearTimeout(timer); }
});

test("host refuses a plaintext relay before connecting", async () => {
  const child = Bun.spawn(["bun", "run", "src/remote-host.ts"], { cwd: packageDir, stdin: "pipe", stdout: "pipe", stderr: "pipe" });
  child.stdin.write(JSON.stringify({ origin: "http://127.0.0.1", host: "A".repeat(43), credential: "B".repeat(43) }) + "\n");
  const timer = setTimeout(() => child.kill(), 3000);
  try {
    expect(await child.exited).toBe(1);
    expect(await new Response(child.stdout).text()).toBe('{"status":"error"}\n');
  } finally { clearTimeout(timer); }
});
