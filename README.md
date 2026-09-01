# tuonelang-postgresql

A PostgreSQL client for [tuonelang](https://github.com/FistOfTheNorthStar/tuonelang),
written **in tuonelang** against the v0 runnable core.

It speaks the PostgreSQL frontend/backend protocol version 3.0 directly over a
TCP socket — no C library, no `libpq`, no bindings. The wire protocol is
implemented from the specification, and the whole pure layer is proven by
colocated executable specs.

```tuo
module app;

fn main() -> Int {
    let opened = pg::conn::connect("127.0.0.1", 5432, "postgres", "app", "", 30000);
    if !pg::conn::is_ok_int(opened) {
        return 1;
    }
    let db = pg::conn::unwrap_ok_int(opened);

    let result = pg::query::run(db, "SELECT id, name FROM users ORDER BY id", 30000);
    if !pg::query::is_ok_result(result) {
        let _ = std::rt::write_string(1, pg::query::render_error(result));
        let _ = pg::conn::shutdown(db);
        return 1;
    }
    let rows = pg::query::unwrap_ok_result(result);

    var i = 0;
    while i < pg::query::row_count(rows) {
        let _ = std::rt::write_string(1, pg::query::cell(rows, i, 1));
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    let _ = pg::conn::shutdown(db);
    0
}
```

## Status

**Working today**, against a real PostgreSQL 16 server:

- ✅ Startup handshake, `ParameterStatus`/`BackendKeyData` drain, `ReadyForQuery`
- ✅ Simple query protocol (`Query`)
- ✅ Extended query protocol (`Parse`/`Bind`/`Describe`/`Execute`/`Sync`) with
  **out-of-band parameters** — the injection-safe path
- ✅ `RowDescription` decoding: column names, type OIDs, format codes
- ✅ `DataRow` decoding, including **SQL NULL** kept distinct from `''`
- ✅ Text-format decoders for int, float, bool, text, and the type-OID
  classification behind them
- ✅ `ErrorResponse` → typed errors carrying the server's **SQLSTATE**
- ✅ Bounded waits on every read and connect (ADR-0017) — no unbounded hang
- ✅ Connection stays usable after a server error (the stream is drained)
- ✅ Trust and cleartext-password authentication

**Blocked on the language, and refused rather than faked:**

- ⛔ `md5` authentication — needs `std::crypto::md5`
- ⛔ SCRAM-SHA-256 authentication — needs SHA-256, HMAC, PBKDF2
- ⛔ TLS — out of scope for ADR-0014/0017/0019 alike

Both auth methods are **fully wired up to the point crypto is needed**: the
message framing is encoded byte-exactly and spec-checked, and the two functions
that need a digest carry their final signatures and return a typed error naming
the blocker and the operator's fix. See [Authentication](#authentication).

Not implemented (and reported as `kind_unsupported` rather than mis-handled):
COPY, LISTEN/NOTIFY delivery, cursors/portal suspension, binary format,
multi-statement result separation, connection pooling.

## Requirements

- The `tuo` compiler from the tuonelang workspace
- A reachable PostgreSQL server (protocol 3.0 — any version from 7.4 on)
- **A numeric host address.** tuonelang v0 has no DNS resolver (ADR-0017 leaves
  it to be written in tuonelang on the UDP primitives), so pass `"127.0.0.1"`,
  not `"localhost"`.

## Running

```bash
# Everything that needs no server: front end, 61 specs, formatting
./run-tests.sh

# Also run the two live oracles against a real PostgreSQL
./run-tests.sh --live
```

Or drive the compiler directly:

```bash
tuo verify src/pg/*.tuo                        # 61 specs, no server required
tuo run examples/live_check.tuo src/pg/*.tuo   # protocol oracle
tuo run examples/crud_check.tuo src/pg/*.tuo   # the guide's patterns
```

Both live programs exit 0 only when the wire agrees with the pure model, and
each failure has its own exit code so a CI log says exactly what broke:
`live_check` cross-checks eight protocol properties, and `crud_check` verifies
the usage patterns `docs/GUIDE.md` teaches — so the documentation cannot drift
away from what the library does.

`run-tests.sh` honours `TUO=/path/to/tuo` if the binary is not on your PATH.

## Architecture

Seven modules, layered so each depends only on those above it:

| Module | Tier | What it does |
|--------|------|--------------|
| `pg::bytes` | pure | Big-endian encode/decode, C strings. The byte-order layer. |
| `pg::proto` | pure | Protocol constants and every **frontend** message encoder. |
| `pg::message` | pure | **Backend** message decoding — field accessors over payload bytes. |
| `pg::value` | pure | Type OIDs and text-format value decoders. |
| `pg::error` | pure | Typed errors: kind + message + SQLSTATE. |
| `pg::auth` | pure | Authentication policy, and the crypto seam. |
| `pg::conn` | **effect** | The socket: connect, framed read/write, handshake. |
| `pg::query` | **effect** | `run` / `run_params` / `execute` / `scalar`, and `ResultSet`. |

The **pure/effect split** is the same one `tuo-stdlib` uses, and it is load
bearing: a spec cannot touch an effect (`R0007`), so all the logic worth
proving — framing, decoding, NULL handling, error mapping, auth policy — lives
in the pure tier and carries **61 executable specs**. The effect tier is thin
by design and is pinned by `examples/live_check.tuo` against a real server.

### Design decisions worth knowing

**A connection is an `Int`.** v0 has no `Box` and no destructors, so a
connection is the descriptor the OS calls it. Nothing pretends to manage its
lifetime; you call `pg::conn::shutdown` (or `close`) yourself.

**A result set is a flat array.** There is no `Array[Array[String]]` in v0, so
`ResultSet` holds every cell in one row-major `Array[String]` plus the column
count. `pg::query::cell(rs, r, c)` does the indexing. NULLs live in a parallel
`Array[Int]` of flags, so NULL and `''` never collapse into each other.

**Errors are values with a kind.** A string is enough to print and useless to
act on, so `PgError` carries a `kind_*` tag *and* the server's SQLSTATE.
`pg::error::is_sqlstate(e, pg::error::sqlstate_unique_violation())` is how you
branch on a duplicate key without matching English text.

**Text format everywhere.** The adapter requests text format for all columns:
one decoder serves both protocols, the renderings are specified and stable, and
no bitwise operations are required to parse them.

## Authentication

| Server demands | Adapter |
|----------------|---------|
| `trust` (`AuthenticationOk`) | ✅ works |
| `password` (cleartext) | ✅ works |
| `md5` | ⛔ typed error naming the fix |
| `scram-sha-256` | ⛔ typed error naming the fix |

The two blocked methods need hashing that tuonelang v0 **cannot express** —
not "has not implemented", but cannot: SHA-256 is *defined* in terms of `^`,
`>>`, and `&`, and v0 has no bitwise operators at all. That is precisely the
gap [ADR-0019](https://github.com/FistOfTheNorthStar/tuonelang) closes: Stage A
adds the six operators, Stage B adds `std::crypto` (`md5`, `sha256`,
`hmac_sha256`, `pbkdf2_sha256`, `base64_*`) and `std::bits`.

Rather than pretend, the adapter **refuses** — the same rule the compiler
applies to itself — and the error says what to do:

```
auth: server requested md5 authentication, which this adapter cannot
perform: it needs hashing that tuonelang v0 has no bitwise operators for.
ADR-0019 adds them plus std::crypto; until then, either use trust or
password authentication for this host in pg_hba.conf, or connect over a
channel that has already authenticated.
```

To connect today, grant `trust` (or `password`) for your client host in
`pg_hba.conf`:

```
host  all  all  127.0.0.1/32  trust
```

### When ADR-0019 lands

The migration is deliberately small, because the seam was built for it:

1. `pg::auth::md5_response` and `scram_client_first` — replace the `Err` body
   with the real computation. **Signatures do not change.**
2. `pg::auth::is_supported` — let `plan_md5` and `plan_sasl` through. Its spec
   already pins that these two are the only ones that should flip.
3. `pg::conn::respond_to_auth` — add the two branches.
4. `pg::bytes` — bodies become one-liners over `std::bits`; every signature and
   all 6 specs stay as they are.

No caller changes, and the SASL message framing in `pg::proto` is already
encoded and spec-checked.

## Documentation

- [`docs/GUIDE.md`](docs/GUIDE.md) — the full API walkthrough with worked
  examples: connecting, querying, parameters, decoding, transactions, errors.
- [`docs/AGENTS.md`](docs/AGENTS.md) — a dense brief for LLM code generation:
  the exact API surface, the v0 constraints that bite, and the anti-patterns
  that do not compile.
- [`examples/live_check.tuo`](examples/live_check.tuo) — the protocol acceptance
  oracle, and the best worked example of the API in use.
- [`examples/crud_check.tuo`](examples/crud_check.tuo) — transactions, unique
  violations by SQLSTATE, and OID classification, all proven live.

## License

[MIT](LICENSE)
