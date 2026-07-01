import { test, expect, afterEach } from "bun:test";
import { _setContactsForTesting, _resetContactsCache } from "../../imessage-drafts/src/chatdb/contacts.ts";
import { resolveNames } from "./resolve-names.ts";

afterEach(() => _resetContactsCache());

test("resolveNames: resolves 1:1 handles, leaves names + group titles alone", () => {
  _setContactsForTesting(
    new Map([
      ["4045550147", "Avery Example"], // canonHandle stores phone tails
      ["sam@example.com", "Sam Sample"],
    ]),
    [],
  );
  const analysis: any = {
    top_people: [
      { name: "+14045550147", count: 100 },
      { name: "sam@example.com", count: 50 },
      { name: "Already A Name", count: 10 }, // not handle-like → untouched
    ],
    top_people_l30: [{ name: "+14045550147", count: 5 }],
    talk_listen: {
      per_thread: [{ name: "+14045550147", you_words: 1, them_words: 1, your_share_pct: 50 }],
      highlights: {
        most_balanced: { name: "sam@example.com", your_share_pct: 50 },
        most_you_talk: null,
        most_you_listen: { name: "+14045550147", your_share_pct: 40 },
      },
    },
    // named group (no raw chat id) → no db read triggered, title untouched
    group_contribution: {
      worst_offender: { thread_label: "Friendship is the Best Ship", total: 100, user_count: 0 },
      per_thread: [{ thread_label: "Friendship is the Best Ship", total: 100, user_count: 0 }],
    },
  };

  resolveNames(analysis, "/nonexistent.db"); // db only opened if a raw chat-id label exists

  expect(analysis.top_people.map((p: any) => p.name)).toEqual(["Avery Example", "Sam Sample", "Already A Name"]);
  expect(analysis.top_people_l30[0].name).toBe("Avery Example");
  expect(analysis.talk_listen.per_thread[0].name).toBe("Avery Example");
  expect(analysis.talk_listen.highlights.most_balanced.name).toBe("Sam Sample");
  expect(analysis.talk_listen.highlights.most_you_listen.name).toBe("Avery Example");
  expect(analysis.group_contribution.worst_offender.thread_label).toBe("Friendship is the Best Ship");
});

test("resolveNames: unknown handle stays as the handle", () => {
  _setContactsForTesting(new Map(), []);
  const analysis: any = { top_people: [{ name: "+19998887777", count: 3 }] };
  resolveNames(analysis, "/nonexistent.db");
  expect(analysis.top_people[0].name).toBe("+19998887777");
});
