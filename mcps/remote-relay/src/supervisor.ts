/** Container process supervisor. Never print child inputs or environment. */
export {};
const origin = process.env.GHOSTIE_RELAY_ORIGIN;
let host: string;
try {
  const parsed = new URL(origin ?? '');
  if (parsed.protocol !== 'https:' || parsed.origin !== origin || parsed.username || parsed.password) throw new Error();
  host = parsed.host;
  if (!/^\d{1,5}$/.test(process.env.PORT ?? '8080') || Number(process.env.PORT ?? 8080) > 65535 || Number(process.env.PORT ?? 8080) < 1024) throw new Error();
} catch {
  process.stderr.write('Relay startup configuration invalid.\n');
  process.exit(1);
}
const children: Bun.Subprocess[] = [];
let stopping = false;
const stop = () => {
  if (stopping) return;
  stopping = true;
  for (const child of children) child.kill('SIGTERM');
  setTimeout(() => { for (const child of children) child.kill('SIGKILL'); }, 5000).unref();
};
process.on('SIGTERM', stop);
process.on('SIGINT', stop);
try {
  children.push(Bun.spawn(['bun', 'run', '/app/src/index.ts'], { stdin: 'ignore', stdout: 'ignore', stderr: 'ignore' }));
  children.push(Bun.spawn(['caddy', 'run', '--config', '/app/deploy/Caddyfile', '--adapter', 'caddyfile'], {
    env: { PATH: process.env.PATH, PORT: process.env.PORT ?? '8080', GHOSTIE_RELAY_HOST: host }, stdin: 'ignore', stdout: 'ignore', stderr: 'ignore',
  }));
  await Promise.race(children.map(child => child.exited));
  const requestedStop = stopping;
  stop();
  await Promise.all(children.map(child => child.exited));
  if (!requestedStop) process.stderr.write('Relay service stopped unexpectedly.\n');
  process.exit(requestedStop ? 0 : 1);
} catch {
  stop();
  process.stderr.write('Relay service could not start.\n');
  process.exit(1);
}
