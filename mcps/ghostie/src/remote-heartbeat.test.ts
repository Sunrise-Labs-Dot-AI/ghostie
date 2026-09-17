import { expect, test } from "bun:test";
import { createHeartbeat } from "./remote-heartbeat.ts";

test("sends numbered heartbeats on the interval and stays alive while echoes arrive", async () => {
  const sent: number[] = []; let died = 0;
  const heartbeat = createHeartbeat({ intervalMs: 20, timeoutMs: 15, send: n => { sent.push(n); setTimeout(() => heartbeat.echo(n), 5); }, dead: () => { died++; } });
  heartbeat.start();
  await Bun.sleep(110);
  heartbeat.stop();
  expect(sent.length).toBeGreaterThanOrEqual(4);
  expect(sent).toEqual(sent.map((_, index) => index + 1));
  expect(died).toBe(0);
});

test("declares the connection dead when an echo is missed, exactly once, and stops", async () => {
  const sent: number[] = []; let died = 0;
  const heartbeat = createHeartbeat({ intervalMs: 20, timeoutMs: 15, send: n => { sent.push(n); }, dead: () => { died++; } });
  heartbeat.start();
  await Bun.sleep(120);
  expect(died).toBe(1);
  expect(sent.length).toBe(1);
  expect(heartbeat.echo(1)).toBe(false);
});

test("ignores stale, foreign, or malformed echoes and a wrong-sequence echo does not rescue the connection", async () => {
  let died = 0; const sent: number[] = [];
  const heartbeat = createHeartbeat({ intervalMs: 20, timeoutMs: 15, send: n => { sent.push(n); heartbeat.echo(n + 1); heartbeat.echo("1"); heartbeat.echo(undefined); }, dead: () => { died++; } });
  heartbeat.start();
  await Bun.sleep(60);
  expect(died).toBe(1);
  expect(sent).toEqual([1]);
});

test("a send failure counts as a dead connection", async () => {
  let died = 0;
  const heartbeat = createHeartbeat({ intervalMs: 10, timeoutMs: 50, send: () => { throw new Error("closed"); }, dead: () => { died++; } });
  heartbeat.start();
  await Bun.sleep(40);
  expect(died).toBe(1);
});

test("stop cancels a pending deadline and start is idempotent", async () => {
  let died = 0; let sends = 0;
  const heartbeat = createHeartbeat({ intervalMs: 10, timeoutMs: 20, send: () => { sends++; }, dead: () => { died++; } });
  heartbeat.start(); heartbeat.start();
  await Bun.sleep(15);
  heartbeat.stop();
  await Bun.sleep(40);
  expect(sends).toBe(1);
  expect(died).toBe(0);
});
