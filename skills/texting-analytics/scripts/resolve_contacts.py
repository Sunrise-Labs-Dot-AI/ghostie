#!/usr/bin/env python3
"""Harness-only contact resolver: AddressBook .abcddb -> {handle_key: display_name}.

Keys are normalized to match normalized-contract sender_keys: phones as last-10 digits,
emails lowercased. In production this is the MCP's Contacts sidecar, not a DB read.
Metadata only (names), opened read-only + immutable.
"""
import argparse, json, sqlite3, sys


def norm_phone(num):
    if not num:
        return None
    d = "".join(c for c in num if c.isdigit())
    return d[-10:] if len(d) >= 10 else (d or None)


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--db", nargs="+", required=True)
    ap.add_argument("--output", default="-")
    a = ap.parse_args()

    m = {}
    for db in a.db:
        try:
            con = sqlite3.connect(f"file:{db}?mode=ro&immutable=1", uri=True)
        except Exception:
            continue
        con.row_factory = sqlite3.Row
        names = {}
        for r in con.execute("SELECT Z_PK, ZFIRSTNAME, ZLASTNAME, ZORGANIZATION FROM ZABCDRECORD"):
            full = " ".join(x for x in [r["ZFIRSTNAME"], r["ZLASTNAME"]] if x).strip()
            org = (r["ZORGANIZATION"] or "").strip()
            nm = full or org
            if nm:
                # org is a body-free signal that a contact is a business/service (e.g. an electrician)
                names[r["Z_PK"]] = {"name": nm, "org": org or None}
        try:
            for r in con.execute("SELECT ZFULLNUMBER, ZOWNER FROM ZABCDPHONENUMBER"):
                nm = names.get(r["ZOWNER"]); k = norm_phone(r["ZFULLNUMBER"])
                if nm and k:
                    m.setdefault(k, nm)
        except Exception:
            pass
        try:
            for r in con.execute("SELECT ZADDRESS, ZOWNER FROM ZABCDEMAILADDRESS"):
                nm = names.get(r["ZOWNER"]); addr = r["ZADDRESS"]
                if nm and addr:
                    m.setdefault(addr.strip().lower(), nm)
        except Exception:
            pass
        con.close()

    payload = json.dumps(m, ensure_ascii=False)
    if a.output == "-":
        print(payload)
    else:
        open(a.output, "w").write(payload)
    sys.stderr.write(f"[resolve_contacts] {len(m)} handle->name mappings\n")


if __name__ == "__main__":
    main()
