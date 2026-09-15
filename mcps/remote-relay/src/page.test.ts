import { expect, test } from 'bun:test';
import { runInNewContext } from 'node:vm';
import { accountPage } from './page.ts';

test('Clerk session updates preserve an in-progress sign-in form', async () => {
  const html = accountPage('pk_fixture', 'https://clerk.example.test/clerk.js', 'fixture');
  const script = html.match(/<script nonce="fixture">([\s\S]+)<\/script>/)![1]!;
  const nodes = new Map<string, Record<string, unknown>>();
  const get = (id: string) => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id)!; };
  let mounted = 0, unmounted = 0;
  let listener!: () => Promise<void>;
  let loading!: Promise<void>;
  const clerk = {
    user: null as { id: string } | null,
    load: async () => {},
    mountSignIn: () => { mounted++; }, unmountSignIn: () => { unmounted++; },
    addListener: (callback: () => Promise<void>) => { listener = callback; },
  };
  runInNewContext(script, {
    window: { Clerk: clerk }, URLSearchParams,
    location: { pathname: '/pair', search: '?id=fixture' },
    document: { getElementById: get, createElement: () => ({ dataset: {} }),
      head: { appendChild: (element: { onload: () => Promise<void> }) => { loading = element.onload(); } } },
  });
  await loading;
  get('login').draftEmail = 'fixture@example.test';
  await listener(); await listener();
  expect(mounted).toBe(1);
  expect(unmounted).toBe(0);
  expect(get('login').draftEmail).toBe('fixture@example.test');
  clerk.user = { id: 'fixture-user' }; await listener();
  expect(unmounted).toBe(1);
  expect(get('account').hidden).toBe(false);
  clerk.user = null; await listener(); await listener();
  expect(mounted).toBe(2);
  expect(get('account').hidden).toBe(true);
});
