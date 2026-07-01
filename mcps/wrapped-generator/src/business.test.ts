import { describe, expect, test } from "bun:test";
import {
  looksLikeBusiness,
  looksLikeBusinessHandle,
  looksLikeBusinessName,
} from "./business.ts";

describe("looksLikeBusinessHandle", () => {
  test("shortcodes, toll-free, and alpha senders are businesses", () => {
    expect(looksLikeBusinessHandle("262966")).toBe(true); // Amazon shortcode
    expect(looksLikeBusinessHandle("+18005551212")).toBe(true); // toll-free
    expect(looksLikeBusinessHandle("+18445550000")).toBe(true); // 844 toll-free
    expect(looksLikeBusinessHandle("CHASE")).toBe(true); // alpha sender
  });

  test("no-reply / notification emails are businesses; personal emails are not", () => {
    expect(looksLikeBusinessHandle("no-reply@onemedical.com")).toBe(true);
    expect(looksLikeBusinessHandle("notifications@github.com")).toBe(true);
    expect(looksLikeBusinessHandle("billing@pge.com")).toBe(true);
    expect(looksLikeBusinessHandle("partiful_mxmphj70_agent@rbm.goog")).toBe(true); // Google RBM agent
    expect(looksLikeBusinessHandle("united_airlines_x_agent@rbm.goog")).toBe(true);
    expect(looksLikeBusinessHandle("jane.doe@example.com")).toBe(false);
    expect(looksLikeBusinessHandle("frank@example.com")).toBe(false);
  });

  test("ordinary mobile numbers are not businesses", () => {
    expect(looksLikeBusinessHandle("+14155550123")).toBe(false);
    expect(looksLikeBusinessHandle("4045550001")).toBe(false);
  });
});

describe("looksLikeBusinessName", () => {
  test("brand and business names are caught", () => {
    expect(looksLikeBusinessName("DoorDash")).toBe(true);
    expect(looksLikeBusinessName("Amazon")).toBe(true);
    expect(looksLikeBusinessName("One Medical")).toBe(true);
    expect(looksLikeBusinessName("Walgreens Pharmacy")).toBe(true);
    expect(looksLikeBusinessName("Wells Fargo")).toBe(true);
    expect(looksLikeBusinessName("Bright Smiles Dental")).toBe(true);
    expect(looksLikeBusinessName("Appointment Reminders")).toBe(true);
  });

  test("word boundaries prevent surname false positives", () => {
    // The whole point: real people whose names CONTAIN a token substring.
    expect(looksLikeBusinessName("Tyler Banks")).toBe(false); // not "bank"
    expect(looksLikeBusinessName("Dana Healey")).toBe(false); // not "health"
    expect(looksLikeBusinessName("Priya Healey")).toBe(false);
    expect(looksLikeBusinessName("Robin Sample")).toBe(false);
    expect(looksLikeBusinessName("Delta Burke")).toBe(true); // 'Delta' as a whole word still trips (rare, accepted)
    expect(looksLikeBusinessName("Spencer United")).toBe(true); // 'United' whole word
  });

  test("ordinary people pass", () => {
    for (const n of ["Alex Sample", "Jordan Fixture", "Kim Sample", "Jamie Sample-Fixture", "Casey Fixture"]) {
      expect(looksLikeBusinessName(n)).toBe(false);
    }
  });

  test("null / empty names are not businesses", () => {
    expect(looksLikeBusinessName(null)).toBe(false);
    expect(looksLikeBusinessName(undefined)).toBe(false);
    expect(looksLikeBusinessName("")).toBe(false);
  });
});

describe("looksLikeBusiness (handle OR name)", () => {
  test("named business on an ordinary number is caught (the One Medical case)", () => {
    // counterpartyClass alone would pass this — a normal 415 line — but the name
    // tags it. This is exactly the gap the shared filter closes.
    expect(looksLikeBusiness("+14155550123", "One Medical")).toBe(true);
  });

  test("a real person on an ordinary number passes", () => {
    expect(looksLikeBusiness("+14155550123", "Frank Wang")).toBe(false);
  });

  test("a business handle is caught even with a personable name", () => {
    expect(looksLikeBusiness("262966", "Amazon Updates")).toBe(true);
  });
});
