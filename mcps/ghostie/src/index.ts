#!/usr/bin/env bun
import { runStdio } from "./facade.ts";
runStdio().catch((err) => {
  process.stderr.write(`fatal: ${(err as Error).message}\n${(err as Error).stack ?? ""}\n`);
  process.exit(1);
});
