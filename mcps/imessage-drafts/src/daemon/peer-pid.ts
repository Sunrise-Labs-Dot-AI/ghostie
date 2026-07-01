// macOS-specific peer-identity lookups via bun:ffi.
// Verbatim copy of mcps/whatsapp-drafts/src/daemon/peer-pid.ts — pure
// libSystem FFI, no transport-specific logic.
//
// Three libc/libproc calls:
//   - getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid_out, &len)
//     → 32-bit PID of the peer process for a connected Unix socket
//   - proc_pidpath(pid, buf, buflen) from libproc
//     → absolute path to the binary the PID was launched as
//   - proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) from libproc
//     → struct proc_bsdinfo, from which we read the process START TIME
//       (pbi_start_tvsec/pbi_start_tvusec) to detect PID reuse mid-auth.
//
// Returns null on any FFI error. Callers (peer-auth.ts) treat null as
// "couldn't verify" → deny in production mode.

import { dlopen, FFIType, ptr } from "bun:ffi";

// macOS sys/un.h:
//   #define SOL_LOCAL     0
//   #define LOCAL_PEERPID 2
const SOL_LOCAL = 0;
const LOCAL_PEERPID = 2;

const PROC_PIDPATHINFO_MAXSIZE = 4096; // From <sys/proc_info.h>

// proc_pidinfo flavor + struct layout, from <sys/proc_info.h>.
//   #define PROC_PIDTBSDINFO 3
// struct proc_bsdinfo is 136 bytes; pbi_start_tvsec is a uint64_t at byte
// offset 120 and pbi_start_tvusec a uint64_t at offset 128. We only need the
// start-time tail, but proc_pidinfo writes the WHOLE struct, so we allocate
// the full size and read the two fields we care about.
const PROC_PIDTBSDINFO = 3;
const PROC_BSDINFO_SIZE = 136;
const PBI_START_TVSEC_OFFSET = 120;
const PBI_START_TVUSEC_OFFSET = 128;

type LibSymbols = {
  getsockopt: (fd: number, level: number, optname: number, optval: number, optlen: number) => number;
  proc_pidpath: (pid: number, buf: number, bufsize: number) => number;
  proc_pidinfo: (pid: number, flavor: number, arg: bigint, buf: number, bufsize: number) => number;
};

let _symbols: LibSymbols | null = null;
let _attempted = false;

function getLib(): LibSymbols | null {
  if (_symbols != null) return _symbols;
  if (_attempted) return null;
  _attempted = true;
  try {
    const handle = dlopen("libSystem.B.dylib", {
      getsockopt: {
        args: [FFIType.i32, FFIType.i32, FFIType.i32, FFIType.ptr, FFIType.ptr],
        returns: FFIType.i32,
      },
      proc_pidpath: {
        args: [FFIType.i32, FFIType.ptr, FFIType.u32],
        returns: FFIType.i32,
      },
      proc_pidinfo: {
        // int proc_pidinfo(int pid, int flavor, uint64_t arg, void *buffer, int buffersize)
        args: [FFIType.i32, FFIType.i32, FFIType.u64, FFIType.ptr, FFIType.i32],
        returns: FFIType.i32,
      },
    });
    _symbols = handle.symbols as unknown as LibSymbols;
    return _symbols;
  } catch (e) {
    process.stderr.write(`peer-pid: failed to dlopen libSystem: ${(e as Error).message}\n`);
    return null;
  }
}

/**
 * Get the PID of the process on the other end of a Unix-socket fd.
 * Returns null if the FFI call fails (fd invalid, not a Unix socket, etc.).
 */
export function getPeerPid(fd: number): number | null {
  const lib = getLib();
  if (lib == null) return null;

  const pidBuf = new ArrayBuffer(4);
  const pidView = new DataView(pidBuf);
  const lenBuf = new ArrayBuffer(4);
  const lenView = new DataView(lenBuf);
  lenView.setUint32(0, 4, true);

  const rc = lib.getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, Number(ptr(pidBuf)), Number(ptr(lenBuf)));
  if (rc !== 0) return null;
  return pidView.getUint32(0, true);
}

/** Resolve a PID to the absolute path of the binary it was launched as. */
export function pidToPath(pid: number): string | null {
  const lib = getLib();
  if (lib == null) return null;

  const buf = new ArrayBuffer(PROC_PIDPATHINFO_MAXSIZE);
  const written = lib.proc_pidpath(pid, Number(ptr(buf)), PROC_PIDPATHINFO_MAXSIZE);
  if (written <= 0) return null;
  return new TextDecoder().decode(new Uint8Array(buf, 0, written));
}

/**
 * Opaque, comparable identity of a *specific* process incarnation: its kernel
 * start time (seconds + microseconds since the epoch). A recycled PID gets a
 * fresh start time, so comparing this value before and after the codesign
 * check detects PID reuse mid-authentication (issue #79).
 *
 * Returned as a string "<sec>.<usec>" purely so callers can `===`-compare two
 * snapshots without juggling BigInt equality. Returns null on any FFI error
 * (no such pid, proc_pidinfo failed) — callers treat null as "couldn't
 * verify" and deny.
 */
export function getPeerStartTime(pid: number): string | null {
  const lib = getLib();
  if (lib == null) return null;

  const buf = new ArrayBuffer(PROC_BSDINFO_SIZE);
  const written = lib.proc_pidinfo(
    pid,
    PROC_PIDTBSDINFO,
    0n,
    Number(ptr(buf)),
    PROC_BSDINFO_SIZE,
  );
  // proc_pidinfo returns the number of bytes written; for PROC_PIDTBSDINFO a
  // success is a full-struct write. A short/zero write means the call failed
  // (process gone, EPERM, etc.).
  if (written < PROC_BSDINFO_SIZE) return null;
  const view = new DataView(buf);
  const sec = view.getBigUint64(PBI_START_TVSEC_OFFSET, true);
  const usec = view.getBigUint64(PBI_START_TVUSEC_OFFSET, true);
  return `${sec}.${usec}`;
}

/**
 * Best-effort fd extraction from a Node net.Socket. Bun stores the fd
 * in different places depending on Bun version; we probe a few.
 * Returns null if we can't find it.
 */
export function socketFd(sock: unknown): number | null {
  const s = sock as { _handle?: { fd?: number }; fd?: number } | null;
  if (s == null) return null;
  if (typeof s.fd === "number") return s.fd;
  if (s._handle != null && typeof s._handle.fd === "number") return s._handle.fd;
  return null;
}
