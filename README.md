# tuonelang-db

Databases for [tuonelang](https://github.com/FistOfTheNorthStar/tuonelang),
written **in tuonelang** against the v0 runnable core.

Two features share one backend-neutral core:

| Feature | What it is |
|---------|------------|
| **`postgresql`** | A PostgreSQL client speaking protocol 3.0 directly over a TCP socket — no C library, no `libpq`, no bindings. |
| **`vector`** | An embedded vector store for embeddings: cosine/L2/dot search, string payloads, and a single-file format. No server, no dependencies. |

Both are implemented from their specifications, and both have their whole pure
layer proven by colocated executable specs — **160** of them.

```tuo
module app;

fn main() -> Int {
    let opened = pg::conn::connect("127.0.0.1", 5432, "postgres", "app", "secret", 30000);
    if !pg::conn::is_ok_int(opened) {
        return 1;
    }
    let conn = pg::conn::unwrap_ok_int(opened);

    let result = pg::query::run(conn, "SELECT id, name FROM users ORDER BY id", 30000);
    if !pg::query::is_ok_result(result) {
        let e = pg::query::unwrap_err_result(result);
        let _ = std::rt::write_string(1, db::error::render(e));
        if !db::error::is_fatal(e) {
            let _ = pg::conn::shutdown(conn); // a fatal error already closed it
        }
        return 1;
    }
    let rows = pg::query::unwrap_ok_result(result);

    var i = 0;
    while i < pg::query::row_count(rows) {
        let _ = std::rt::write_string(1, pg::query::cell(rows, i, 1));
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    let _ = pg::conn::shutdown(conn);
    0
}
```

And the vector store, which needs nothing running at all:

```tuo
module app;

/// Build a 3-D vector. Real embeddings are pushed in a loop.
fn v3(take a: Float, take b: Float, take c: Float) -> Array[Float] {
    var xs = std::array::empty();
    std::array::push(xs, a);
    std::array::push(xs, b);
    std::array::push(xs, c);
    xs
}

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
- ✅ `sqrt` over the native `std::float::sqrt`, with degenerate inputs clamped — proven
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
  **out-of-band parameters** — the injection-safe path — including SQL NULL
  as a parameter
- ✅ `RowDescription` decoding: column names, type OIDs, format codes
- ✅ `DataRow` decoding, including **SQL NULL** kept distinct from `''`
- ✅ Text-format decoders for int, float, bool, text, and the type-OID
  classification behind them
- ✅ `ErrorResponse` → typed errors carrying the server's **SQLSTATE**
- ✅ Bounded waits on every read and connect (ADR-0017) — no unbounded hang
- ✅ Connection stays usable after a server error (the stream is drained)
- ✅ A timeout or a lost connection **closes the descriptor** and the error
  says so (`db::error::is_fatal`), so a late reply can never be read as the
  next query's — and a server that announced why it was closing (`57P01`)
  is reported in its own words
- ✅ Results of any size: no message cap, and a million-row `SELECT` is one
  of the live oracle's checks
- ✅ Out-of-range cell reads are SQL NULL, never an index trap
- ✅ **SCRAM-SHA-256** authentication (PostgreSQL's default since 14),
  including the half that authenticates the *server*: a server that cannot
  produce its signature is refused
- ✅ `md5`, cleartext-password, and trust authentication

**Blocked on the language, and refused rather than faked:**

- ⛔ TLS — `std::tls` is the server side of a handshake with Ed25519
  certificates only; a client that could verify a real server's certificate
  chain is not expressible yet. So no `sslmode=require`, and no
  `SCRAM-SHA-256-PLUS` (channel binding needs the TLS channel)
- ⛔ Host names — there is no DNS resolver

See [Authentication](#authentication).

Not implemented: LISTEN/NOTIFY delivery, cursors/portal suspension, binary
format, connection pooling. Two things are **refused with `kind_unsupported`**,
with the stream drained so the connection stays usable: a query that returns
more than one result set (two `SELECT`s in one `run`; several statements with
at most one row-returning one are fine), and `COPY` to or from the client —
a `COPY … FROM STDIN` is answered with `CopyFail` rather than left hanging.
A query with more than 65535 parameters (the protocol's Int16 count) is
refused the same way, before anything is sent.

## Using the two together

The features are independent, but they are built to meet: an embedding
stored in PostgreSQL comes out of `pg::value::as_floats` as the
`Array[Float]` that `vec::db::add` takes, and a query vector goes back in
through `pg::value::array_literal` (for `float8[]`) or `vector_literal` (for
pgvector's `vector`).

```tuo
// Load every embedding in a table into an in-memory collection.
let rows = pg::query::unwrap_ok_result(pg::query::run(conn, "SELECT id, body, embedding FROM docs", 30000));
var store = vec::db::in_memory(384, vec::metric::metric_cosine());
var i = 0;
while i < pg::query::row_count(rows) {
    let raw = pg::query::cell(rows, i, 2);
    let id = pg::query::cell(rows, i, 0);
    let body = pg::query::cell(rows, i, 1);
    let _ = vec::db::add(store, pg::value::as_floats_or_empty(std::string::as_str(raw)), std::string::as_str(id), std::string::as_str(body));
    i = i + 1;
}
```

[`examples/bridge_check.tuo`](examples/bridge_check.tuo) is the live proof:
it writes vectors into a `float8[]` column through parameters, reads them
back, loads them into the store, and checks that a search ranks them exactly
as the originals do. `./run-tests.sh --live` runs it whenever both features
are selected. pgvector's `vector` type works the same way with
`vector_literal` and a `$1::vector` cast; its OID is per-install, so
`pg::value::vector_oid_query` is how a program learns it.

## Requirements

- The `tuo` compiler from the tuonelang workspace
- A reachable PostgreSQL server (protocol 3.0 — any version from 7.4 on)
- **A numeric host address.** tuonelang v0 has no DNS resolver (ADR-0017 leaves
  it to be written in tuonelang on the UDP primitives), so pass `"127.0.0.1"`,
  not `"localhost"`.
- **A server that accepts unencrypted connections** (`host`, not `hostssl`, in
  `pg_hba.conf`): there is no TLS. Most managed PostgreSQL services require
  it, so today this means a server you run.

## Running

```bash
# Everything that needs no server: front end, 160 specs, formatting
./run-tests.sh

# Also run the live oracles. The vector ones need only a writable /tmp and
# the SCRAM one needs nothing; the other PostgreSQL ones talk to a throwaway
# server in Docker, on a loopback port with credentials of its own.
examples/test-server.sh start
./run-tests.sh --live
examples/test-server.sh stop

# Just the vector store, end to end — no server required at all
./run-tests.sh --vector --live
```

Or drive the compiler directly:

```bash
tuo verify src/db/*.tuo src/pg/*.tuo src/vec/*.tuo            # 160 specs, nothing running
tuo run examples/scram_check.tuo src/db/*.tuo src/pg/*.tuo    # SCRAM vs RFC 7677, no server
tuo run examples/live_check.tuo src/db/*.tuo src/pg/*.tuo     # protocol oracle
tuo run examples/crud_check.tuo src/db/*.tuo src/pg/*.tuo     # the guide's patterns
tuo run examples/vector_check.tuo src/db/*.tuo src/vec/*.tuo  # vector oracle
```

Both live programs exit 0 only when the wire agrees with the pure model, and
each failure has its own exit code so a CI log says exactly what broke:
`live_check` cross-checks twelve protocol properties, and `crud_check` verifies
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
| `db::math` | core | pure | Float helpers: a clamped `sqrt`, NaN/infinity classification, tolerant comparison. |
| `db::text` | core | pure | Integers and floats as decimal text, for messages and literals. |
| `pg::proto` | postgresql | pure | Protocol constants and every **frontend** message encoder. |
| `pg::message` | postgresql | pure | **Backend** message decoding — field accessors over payload bytes. |
| `pg::value` | postgresql | pure | Type OIDs, text-format value decoders, and the float-array / pgvector codec. |
| `pg::auth` | postgresql | pure | Authentication policy, and the `md5` and SCRAM-SHA-256 computations. |
| `pg::conn` | postgresql | **effect** | The socket: connect, framed read/write, handshake. |
| `pg::query` | postgresql | **effect** | `run` / `execute` / `scalar` and their `_params` forms, `run_params_null` for SQL NULL, and `ResultSet`. |
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
the pure tier and carries **160 executable specs**. The effect tier is thin by
design and is pinned by `examples/live_check.tuo` against a real server and by
`examples/vector_check.tuo` against a real filesystem.

The standard library does the arithmetic, and this library does not repeat
it: byte order is `std::bits`, the square root is `std::float::sqrt`, and
every digest in the authentication exchange is `std::crypto`.

### Design decisions worth knowing

**A connection is an `Int`.** v0 has no destructors, so a
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
one decoder serves both protocols, and the renderings are specified and stable.

## Authentication

| Server demands | Adapter |
|----------------|---------|
| `trust` (`AuthenticationOk`) | ✅ works |
| `scram-sha-256` | ✅ works |
| `md5` | ✅ works |
| `password` (cleartext) | ✅ works |
| `scram-sha-256` over `hostssl`, Kerberos, GSSAPI, SSPI | ⛔ typed error naming the fix |

Nothing changes at the call site: `pg::conn::connect` takes the password and
answers whichever method the server asks for.

**SCRAM-SHA-256** is the one to use. The password never crosses the wire —
the client sends a proof derived from it — and the exchange runs in both
directions: the server's last message must carry a signature only something
holding the stored credentials can produce, and the adapter checks it in
constant time. A server that skips or fails that step is refused with a
`kind_auth` error even if it then says "authenticated", which is what stops
an impostor from collecting queries.

The cryptography is `std::crypto` (ADR-0019 Stage B) — SHA-256, HMAC, PBKDF2
— and its use here is checked three ways: the specs in `pg::auth` against
values computed independently, [`examples/scram_check.tuo`](examples/scram_check.tuo)
against the complete exchange RFC 7677 publishes, and
[`examples/auth_check.tuo`](examples/auth_check.tuo) against real servers
configured for each method.

What to know before relying on it:

- **There is no TLS.** Authentication proves who is at each end; it does not
  hide or protect what follows. Queries and results cross the network in the
  clear, so use a loopback, a private network, or a tunnel.
- **The adapter answers whatever the server asks.** Something in the path
  that can impersonate the server can ask for the cleartext password instead
  of SCRAM, and it will be sent. On a link you do not control, that is one
  more reason for a tunnel.
- **`md5`** works because servers still offer it; it is broken and PostgreSQL
  has deprecated it. **`password`** sends the secret as it is.
- **No SASLprep.** The password is used as the bytes given, which is exact
  for ASCII; a password whose Unicode normalization differs from its spelling
  will not authenticate.
- **The iteration count is the server's**, and the client does that much
  work: about 13 ms at PostgreSQL's default of 4096 in a `tuo run` (debug)
  build. A count above 1,000,000 — about three seconds — is refused rather
  than run, and that computation is not covered by the connect timeout.

A method the adapter cannot perform is refused with an error that says what
to do:

```
auth: server requested GSSAPI authentication, which this adapter does not
implement. Configure the server to offer scram-sha-256, md5, password, or
trust for this host in pg_hba.conf.
```

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
- [`examples/scram_check.tuo`](examples/scram_check.tuo) — SCRAM-SHA-256
  against RFC 7677's published exchange; needs no server.
- [`examples/auth_check.tuo`](examples/auth_check.tuo) — one authentication
  method against a server you point it at, including that a wrong password
  is refused.
- [`examples/vector_check.tuo`](examples/vector_check.tuo) — the vector
  acceptance oracle: real files, and a proof that persistence does not perturb
  search ranking.
- [`examples/guide_example.tuo`](examples/guide_example.tuo) — the worked
  program from the vector guide. `run-tests.sh` runs it and diffs its output
  against what the guide promises, so the documentation cannot drift.

## License

[MIT](LICENSE)
