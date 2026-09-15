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

test('account management never authorizes a connection, including with consent query parameters', async () => {
  const html = accountPage('pk_fixture', 'https://clerk.example.test/clerk.js', 'fixture');
  const script = html.match(/<script nonce="fixture">([\s\S]+)<\/script>/)![1]!;
  type Node = { hidden?: boolean; textContent?: string; onclick?: () => Promise<void> | void };
  const nodes = new Map<string, Node>();
  const get = (id: string) => { if (!nodes.has(id)) nodes.set(id, {}); return nodes.get(id)!; };
  let loading!: Promise<void>, listener!: () => Promise<void>;
  let profileOpened = 0, requests = 0;
  const clerk = {
    user: null as { id: string } | null,
    load: async () => {}, mountSignIn: () => {}, unmountSignIn: () => {},
    addListener: (callback: () => Promise<void>) => { listener = callback; },
    openUserProfile: () => { profileOpened++; },
  };
  runInNewContext(script, {
    window: { Clerk: clerk }, URLSearchParams,
    location: { pathname: '/account', search: '?id=fixture&client_id=fixture&redirect_uri=https://client.example.test' },
    fetch: () => { requests++; throw Error('Unexpected request'); },
    document: { getElementById: get, createElement: () => ({ dataset: {} }),
      head: { appendChild: (element: { onload: () => Promise<void> }) => { loading = element.onload(); } } },
  });
  await loading;
  expect(get('account').hidden).toBe(true);
  await get('manage').onclick!();
  expect(profileOpened).toBe(0);
  clerk.user = { id: 'fixture-user' }; await listener();
  expect(get('account').hidden).toBe(false);
  expect(get('connection').hidden).toBe(true);
  expect(get('heading').textContent).toBe('Your Ghostie account');
  await get('manage').onclick!();
  expect(profileOpened).toBe(1);
  await get('approve').onclick!(); await listener();
  expect(requests).toBe(0);
  expect(get('status').textContent).toContain('Security');
});
