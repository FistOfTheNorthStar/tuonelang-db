# tuonelang-db

Databases for [tuonelang](https://github.com/FistOfTheNorthStar/tuonelang),
written **in tuonelang** against the v0 runnable core.

Two features share one backend-neutral core:

| Feature | What it is |
|---------|------------|
| **`postgresql`** | A PostgreSQL client speaking protocol 3.0 directly over a TCP socket — no C library, no `libpq`, no bindings. |
| **`vector`** | An embedded vector store for embeddings: cosine/L2/dot search, string payloads, and a single-file format. No server, no dependencies. |

Both are implemented from their specifications, and both have their whole pure
layer proven by colocated executable specs — **130** of them.

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

And the vector store, which needs nothing running at all:

```tuo
module app;

fn main() -> Int {
    var store = vec::db::open("/tmp/docs.tvec", 3, vec::metric::metric_cosine());

    let _ = vec::db::add(store, v3(1.0, 0.0, 0.0), "red", "a note about red");
    let _ = vec::db::add(store, v3(0.9, 0.1, 0.0), "crimson", "a note about crimson");

    let hits = vec::db::query(store, v3(1.0, 0.0, 0.0), 2);
    var i = 0;
    while i < vec::search::hit_count(hits) {
        let _ = std::rt::write_string(1, vec::db::render_hit(store, hits, i));
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    let _ = vec::db::save(store);
    0
}
```

## Status

### The vector store

**Working today**, against a real filesystem:

- ✅ Cosine, squared-L2 and inner-product metrics, with the ranking direction
  of each in one place
- ✅ Exact k-nearest-neighbour search, ranked best-first, bounded to `k`
      without a sort
- ✅ Cosine collections normalize on insert, so a query is a bare dot product
- ✅ String ids and arbitrary payloads, so retrieval needs no second store
- ✅ Tombstoned deletes that keep row indices stable, and a `compact` that
      reclaims them
- ✅ A single-file format (`TVEC`) that round-trips a collection exactly, drops
      tombstones on save, and refuses a corrupt or truncated file rather than
      half-reading it
- ✅ `sqrt` written in tuonelang, because there is no `std::math` — proven
      against known roots *and* against its own definition

Deliberately **not** implemented, and documented as absent rather than faked:
an embedding model, an approximate index (HNSW/IVF), metadata filtering, and
concurrent access. Search is an exact linear scan — O(N·D) per query, which is
excellent to roughly 10^5 vectors and honest beyond it.

### The PostgreSQL adapter

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
# Everything that needs no server: front end, 130 specs, formatting
./run-tests.sh

# Also run the live oracles. The vector one needs only a writable /tmp;
# the two PostgreSQL ones need a running server.
./run-tests.sh --live

# Just the vector store, end to end — no server required at all
./run-tests.sh --vector --live
```

Or drive the compiler directly:

```bash
tuo verify src/db/*.tuo src/pg/*.tuo src/vec/*.tuo            # 130 specs, nothing running
tuo run examples/live_check.tuo src/db/*.tuo src/pg/*.tuo     # protocol oracle
tuo run examples/crud_check.tuo src/db/*.tuo src/pg/*.tuo     # the guide's patterns
tuo run examples/vector_check.tuo src/db/*.tuo src/vec/*.tuo  # vector oracle
```

Both live programs exit 0 only when the wire agrees with the pure model, and
each failure has its own exit code so a CI log says exactly what broke:
`live_check` cross-checks eight protocol properties, and `crud_check` verifies
the usage patterns `docs/GUIDE.md` teaches — so the documentation cannot drift
away from what the library does.

`vector_check` writes real files to `/tmp`, reads them back, and exits non-zero
the moment the disk disagrees with the pure model — including a check that a
search ranks **identically** before and after a save/load cycle.

`run-tests.sh` honours `TUO=/path/to/tuo` if the binary is not on your PATH.

## Building a subset

The library is split into **features**, and a build selects the ones it needs:

```bash
./build.sh --postgresql      # the backend-neutral core + the PostgreSQL adapter
./build.sh --vector          # the core + the embedded vector store
./build.sh --core            # the core alone, with no backend
./build.sh --all             # everything (the default)
./build.sh --list            # print the selected files without compiling
```

A program that only searches embeddings never compiles a line of the wire
protocol, and vice versa.

`run-tests.sh` takes the same feature flags (`./run-tests.sh --core`), and gets
its file list from `build.sh --list`, so the two cannot disagree about what a
feature contains.

**Why a script and not a compiler flag.** tuonelang has no feature system: a
`tdg.toml` has no `[features]` table (and silently ignores one), the language
has no `#[cfg]` — attributes are a fixed, compiler-known set of exactly one —
and `tuo` accepts no `--features`/`--cfg`. What it does have is the file-list
form of every command: *"all given files are checked as one program."* So the
unit of selection is the **file set**, and `build.sh` is what maps a flag onto
one. Note that package mode (a bare `tuo check` against `tdg.toml`) always
compiles **every** `.tuo` file under the module root, recursively — so a subset
build must use the file-list form, which is what these scripts pass.

## Architecture

A backend-neutral core (`db::*`) and one feature per backend — a PostgreSQL
adapter (`pg::*`) and an embedded vector store (`vec::*`) — each module
depending only on those above it.

| Module | Feature | Tier | What it does |
|--------|---------|------|--------------|
| `db::bytes` | core | pure | Big-endian encode/decode, C strings. The byte-order layer. |
| `db::error` | core | pure | Typed errors: kind + message + SQLSTATE. |
| `db::math` | core | pure | `sqrt` and float helpers — v0 has no `std::math`. |
| `pg::proto` | postgresql | pure | Protocol constants and every **frontend** message encoder. |
| `pg::message` | postgresql | pure | **Backend** message decoding — field accessors over payload bytes. |
| `pg::value` | postgresql | pure | Type OIDs and text-format value decoders. |
| `pg::auth` | postgresql | pure | Authentication policy, and the crypto seam. |
| `pg::conn` | postgresql | **effect** | The socket: connect, framed read/write, handshake. |
| `pg::query` | postgresql | **effect** | `run` / `run_params` / `execute` / `scalar`, and `ResultSet`. |
| `vec::metric` | vector | pure | Cosine / L2 / dot kernels over flat float slices. |
| `vec::store` | vector | pure | The rows: vectors, ids, payloads, tombstones. |
| `vec::search` | vector | pure | Bounded top-k ranking, and `Hits`. |
| `vec::codec` | vector | pure | The `TVEC` file format: encode, decode, validate. |
| `vec::disk` | vector | **effect** | The file: read, write, save, load. |
| `vec::db` | vector | **effect** | The front door: `open` / `add` / `query` / `save`. |

The vector feature is **not** a PostgreSQL client with vectors bolted on: it
shares only `db::bytes` (its file framing) and `db::math`, and compiles with no
part of the wire protocol present. Its own split mirrors the adapter's — the
format lives in `vec::codec` where specs can reach it, and `vec::disk` is the
thin effect tier that only carries bytes to a descriptor.

`db::bytes` and `db::error` are the two modules with nothing PostgreSQL-specific
in them — big-endian framing is how most database wire protocols are built, and
SQLSTATE is an ISO SQL standard rather than a PostgreSQL invention — so they are
the seam a second backend would be written against. Neither depends on any other
module in the library, which is what makes `--core` a build that stands alone.

The **pure/effect split** is the same one `tuo-stdlib` uses, and it is load
bearing: a spec cannot touch an effect (`R0007`), so all the logic worth
proving — framing, decoding, NULL handling, error mapping, auth policy, and on
the vector side every metric, the ranking, and the whole file format — lives in
the pure tier and carries **130 executable specs**. The effect tier is thin by
design and is pinned by `examples/live_check.tuo` against a real server and by
`examples/vector_check.tuo` against a real filesystem.

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
`db::error::is_sqlstate(e, db::error::sqlstate_unique_violation())` is how you
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

The two blocked methods need MD5 and SHA-256, which this adapter does not yet
implement. [ADR-0019](https://github.com/FistOfTheNorthStar/tuonelang) has
landed **Stage A**: `|`, `^`, `&`, `<<`, `>>`, and `~` all work today, so the
hashes are now *expressible* — masking to 32 bits (`(x + 1) & 0xFFFFFFFF`) and
composing a rotate from two shifts both behave correctly. What is still missing
is **Stage B**: `std::crypto` (`md5`, `sha256`, `hmac_sha256`,
`pbkdf2_sha256`, `base64_*`) and `std::bits` do not resolve yet, so the
primitives must either be hand-written over the new operators or wait for the
stdlib.

Rather than pretend, the adapter **refuses** — the same rule the compiler
applies to itself — and the error says what to do:

```
auth: server requested md5 authentication, which this adapter cannot
perform: it needs hashing that this adapter does not yet implement.
ADR-0019 Stage A landed the bitwise operators, but std::crypto (Stage B)
is not available yet; until then, either use trust or password
authentication for this host in pg_hba.conf, or connect over a channel
that has already authenticated.
```

To connect today, grant `trust` (or `password`) for your client host in
`pg_hba.conf`:

```
host  all  all  127.0.0.1/32  trust
```

### When ADR-0019 Stage B lands

The migration is deliberately small, because the seam was built for it (and
Stage A, the operator half, is already in place):

1. `pg::auth::md5_response` and `scram_client_first` — replace the `Err` body
   with the real computation. **Signatures do not change.**
2. `pg::auth::is_supported` — let `plan_md5` and `plan_sasl` through. Its spec
   already pins that these two are the only ones that should flip.
3. `pg::conn::respond_to_auth` — add the two branches.
4. `db::bytes` — bodies become one-liners over `std::bits`; every signature and
   all 6 specs stay as they are.

No caller changes, and the SASL message framing in `pg::proto` is already
encoded and spec-checked.

## Documentation

- [`docs/GUIDE.md`](docs/GUIDE.md) — the PostgreSQL walkthrough with worked
  examples: connecting, querying, parameters, decoding, transactions, errors.
- [`docs/AGENTS.md`](docs/AGENTS.md) — a dense brief for LLM code generation
  against the PostgreSQL adapter: the exact API surface, the v0 constraints that
  bite, and the anti-patterns that do not compile.
- [`docs/VECTOR_GUIDE.md`](docs/VECTOR_GUIDE.md) — **start here for the vector
  store.** A walkthrough from a first collection through metrics, searching,
  persistence and every failure worth handling.
- [`docs/VECTORS.md`](docs/VECTORS.md) — the code-generation brief for the
  vector store, including the three rules that prevent most generated-code
  errors and a complete worked program whose output is checked.
- [`examples/live_check.tuo`](examples/live_check.tuo) — the protocol acceptance
  oracle, and the best worked example of the API in use.
- [`examples/crud_check.tuo`](examples/crud_check.tuo) — transactions, unique
  violations by SQLSTATE, and OID classification, all proven live.
- [`examples/vector_check.tuo`](examples/vector_check.tuo) — the vector
  acceptance oracle: real files, and a proof that persistence does not perturb
  search ranking.
- [`examples/guide_example.tuo`](examples/guide_example.tuo) — the worked
  program from the vector guide. `run-tests.sh` runs it and diffs its output
  against what the guide promises, so the documentation cannot drift.

## License

[MIT](LICENSE)
