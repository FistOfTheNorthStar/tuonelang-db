# The tuonelang PostgreSQL guide

A walkthrough of the adapter, from a first connection to error handling and
transactions. Every code block here is written against the real API; the
complete programs are compiled and run as part of validating this repository.

For a dense reference aimed at code-generating models, see
[`AGENTS.md`](AGENTS.md). For the design rationale, see the module headers —
each one opens with why it is shaped the way it is.

---

## 1. Connecting

```tuo
let opened = pg::conn::connect(
    "127.0.0.1",   // host — MUST be numeric; v0 has no DNS
    5432,          // port
    "postgres",    // user
    "mydb",        // database ("" uses the user name)
    "secret",      // password ("" is fine when the server asks for none)
    30000,         // timeout in milliseconds
);
if !pg::conn::is_ok_int(opened) {
    let _ = std::rt::write_string(1, db::error::render(pg::conn::unwrap_err_int(opened)));
    return 1;
}
let conn = pg::conn::unwrap_ok_int(opened);
```

`connect` opens the socket **and** completes the startup handshake: it sends
the startup packet, answers or refuses the authentication request, drains the
`ParameterStatus` and `BackendKeyData` messages the server sends, and returns
once `ReadyForQuery` arrives. If the handshake fails it closes the descriptor
for you, so there is nothing to leak.

The value you get back is the **descriptor** — an `Int`. v0 has no destructors,
so closing is explicit:

```tuo
let _ = pg::conn::shutdown(conn);   // sends Terminate, then closes
```

`shutdown` is preferred over `close`: it tells the server to release the
backend immediately rather than waiting for the socket to drop.

### Why the host must be numeric

tuonelang v0 deliberately has no name resolution — ADR-0017 leaves DNS to be
written *in* tuonelang on its UDP primitives. Pass `"127.0.0.1"` or `"::1"`;
IPv6 works with no separate spelling, because the address family is inferred
from the literal.

### Timeouts

Every wait in this adapter is bounded — the connect, the accept, and each byte
read. A database client that blocks forever on a peer that has gone away is not
a client, it is a hang. A timeout surfaces as `db::error::kind_timeout()`,
which is deliberately distinct from `kind_connection()`: "the server is slow"
and "the server is gone" call for different responses.

Both are **fatal to that descriptor**. After a timeout the reply may still be
on its way, and after a lost connection half of one may already have been
read, so the adapter closes the descriptor before returning the error —
otherwise the next query would read the previous query's rows as its own.
`db::error::is_fatal(e)` is true for exactly these two kinds. When it is,
reconnect, and do **not** `shutdown` the old descriptor: the number may
already belong to something else.

---

## 2. Running a query

```tuo
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
```

That inspect-then-consume shape is the single most important idiom in this
library, and §4 explains why it is the way it is.

### Reading rows

Cells are addressed `(row, column)`, both 0-based:

```tuo
var i = 0;
while i < pg::query::row_count(rows) {
    let id   = pg::query::cell_int(rows, i, 0, 0);     // Int, with a fallback
    let name = pg::query::cell(rows, i, 1);            // raw text as a String
    i = i + 1;
}
```

Address columns by name when the `SELECT` list might change:

```tuo
let c = pg::query::column_index(rows, "name");   // -1 when there is no such column
if c >= 0 {
    let name = pg::query::cell(rows, 0, c);
}
```

An index outside the result is a value, not a trap: `cell` reads `""`,
`is_null` reads `true`, and the typed accessors give their fallback — so the
`-1` of an absent column lands in the same branch a NULL does, and a row past
the end cannot end the process. `pg::query::has_cell(rows, r, c)` is the
explicit check when you want one.

### NULL

A NULL cell reads as the empty string, so whenever NULL and `''` mean different
things — which in SQL they always do — ask first:

```tuo
if pg::query::is_null(rows, i, 1) {
    // the column is SQL NULL
} else {
    let name = pg::query::cell(rows, i, 1);
}
```

The typed accessors take a fallback used for both NULL and unparsable text:

```tuo
let n = pg::query::cell_int(rows, i, 0, 0 - 1);      // -1 if NULL or not a number
let x = pg::query::cell_float(rows, i, 2, 0.0);
let b = pg::query::cell_bool(rows, i, 3);            // NULL reads as false
```

### Statements that are not queries

```tuo
let deleted = pg::query::execute(conn, "DELETE FROM users WHERE id = 1", 30000);
// Ok { value: <rows affected> }
```

`execute` returns the affected-row count, parsed from the server's command tag
(`"DELETE 1"`, `"INSERT 0 3"`, `"UPDATE 2"`). Single values are easier still:

```tuo
let total = pg::query::scalar_int(conn, "SELECT count(*) FROM users", 0, 30000);
```

`scalar` returns an error, not an empty string, when the query produced no
rows **or the value is NULL** — so "nothing came back" is never mistaken for
`''`, in either form it can take. Read a nullable column with `run` and
`is_null`. `scalar_int` is the exception by design: it has a fallback to give,
so a NULL yields that, which is what `SELECT max(x)` over an empty table
wants. Each of `execute`, `scalar`, and `scalar_int` has a `_params` form that
takes parameters after the SQL (§3).

---

## 3. Parameters, and why to always use them

```tuo
var params = std::array::empty();
std::array::push(params, std::string::from_str("ada"));

let result = pg::query::run_params(
    conn,
    "SELECT id FROM users WHERE name = $1",
    params,
    30000,
);
```

Placeholders are `$1`, `$2`, … in push order.

`run_params` uses the **extended query protocol**: `Parse` sends the SQL text,
`Bind` sends the values, and the two never meet in a parser. That is not a
convenience — it is the only structural guarantee that a value cannot be
interpreted as SQL. String-building a query with user input is how injection
happens, and this library deliberately provides no helper that would make it
convenient.

Parameters are sent as text and the server infers their types, which is why
`$1` works without the client knowing the column's type in advance. To force a
type, say so in the SQL: `WHERE id = $1::int`.

### Sending NULL

An empty string is a value. SQL NULL has no text form at all — on the wire it
is a parameter length of `-1` with no bytes — so it needs its own spelling: a
second array of flags, index-aligned with the texts. Build both with the push
helpers, which append to the two arrays together so they cannot drift apart:

```tuo
var params = std::array::empty();
var nulls = std::array::empty();
pg::query::push_param(params, nulls, "ada");
pg::query::push_null(params, nulls);           // the note is NULL

let r = pg::query::run_params_null(conn, "INSERT INTO users (name, note) VALUES ($1, $2)", params, nulls, 30000);
```

A non-zero flag sends that parameter as NULL and ignores its text. `nulls` may
be shorter than `params` — the missing tail counts as values — which is
exactly what `run_params` does with an empty one.

### How many parameters

The protocol counts a query's parameters in sixteen bits, so one call carries
at most 65535 of them (`pg::query::max_params()`). More is refused with
`kind_unsupported` before a byte reaches the server, and the connection is
untouched. A multi-row `INSERT` therefore batches at `rows × columns` under
that limit.

### The parameterized conveniences

```tuo
var ids = std::array::empty();
std::array::push(ids, std::string::from_str("42"));

let n = pg::query::execute_params(conn, "DELETE FROM users WHERE id = $1::int", ids, 30000);
let name = pg::query::scalar_params(conn, "SELECT name FROM users WHERE id = $1::int", ids, 30000);
let total = pg::query::scalar_int_params(conn, "SELECT count(*) FROM users WHERE id > $1::int", ids, 0, 30000);
```

Same results as `execute`, `scalar`, and `scalar_int`, over the extended
protocol. They are one-liners over two public reducers, `affected_of` and
`first_cell`, so a query that needs NULL parameters composes the same way
instead of needing yet another variant:

```tuo
let n = pg::query::affected_of(pg::query::run_params_null(conn, sql, params, nulls, 30000));
```

---

## 4. Errors

Every fallible call returns `Result[T, PgError]`. There is no exception
channel; an error is a value you branch on.

```tuo
let r = pg::query::run(conn, sql, 30000);
if !pg::query::is_ok_result(r) {
    let e = pg::query::unwrap_err_result(r);
    if db::error::is_fatal(e) {
        // the descriptor is already closed — reconnect; do not shutdown(conn)
    } else if db::error::kind(e) == db::error::kind_server() {
        // the server rejected it — inspect the SQLSTATE; conn is still usable
    }
    return 1;
}
let rows = pg::query::unwrap_ok_result(r);
```

### Inspect, then consume exactly once

v0's ownership rules make this the one correct shape, so it is worth
stating plainly:

- `is_ok_result(r)` **borrows** `r` and binds nothing, so it may be called
  freely;
- `unwrap_ok_result(r)`, `unwrap_err_result(r)`, and `render_error(r)` all
  **consume** `r`.

Call exactly one consuming function, on exactly one branch, and never read the
`Result` afterwards. A `match` that binds a name also consumes, which is why
the inspectors bind `_`.

If you violate this, the failure may not appear at the ownership check — it can
surface later as `M0005: reads _N after it was moved out` from the codegen
stage. That message means: something was moved in one branch and read below.

### SQLSTATE

The server's own error code survives into the error value, which is what lets
you branch on *what went wrong* rather than on English text:

```tuo
if db::error::is_sqlstate(e, db::error::sqlstate_unique_violation()) {
    // 23505 — a duplicate key; probably not fatal
}
if db::error::is_retryable(e) {
    // 40001 / 40P01 — serialization failure or deadlock; retrying is correct
}
```

Named codes: `sqlstate_unique_violation` (23505),
`sqlstate_foreign_key_violation` (23503), `sqlstate_not_null_violation`
(23502), `sqlstate_syntax_error` (42601), `sqlstate_undefined_table` (42P01),
`sqlstate_invalid_password` (28P01), `sqlstate_serialization_failure` (40001).
Any other code can be matched literally: `is_sqlstate(e, "22P02")`.

### Error kinds

| Kind | Means |
|------|-------|
| `kind_connection` | The socket failed, or the server closed it. **Fatal**: the descriptor has been closed. |
| `kind_timeout` | The peer did not answer in time. **Fatal**: the descriptor has been closed. |
| `kind_auth` | An authentication method this adapter cannot perform. |
| `kind_server` | A real SQL error; carries a SQLSTATE. |
| `kind_protocol` | The bytes on the wire did not match the protocol. |
| `kind_decode` | A value would not decode, or no rows where one was needed. |
| `kind_unsupported` | A feature this adapter does not implement. |

`db::error::render(e)` produces `"server: syntax error … (SQLSTATE 42601)"`.

`db::error::is_fatal(e)` is true for the two fatal kinds and nothing else.
A fatal error's message ends with "the connection has been closed and the
descriptor must not be used again", and when the server said why before it
closed — `pg_terminate_backend`, a shutdown — its words and SQLSTATE
(`57P01`) are kept on the `kind_connection` error.

### One result set per query

`run` accepts several `;`-separated statements — `"BEGIN; UPDATE …; COMMIT"`
runs as one implicit transaction, and the tag is the last statement's — but a
`ResultSet` holds one result, so two row-returning statements in one call are
refused with `kind_unsupported`. The stream is still drained, so the connection
is fine afterwards; run them as two calls.

### COPY is refused, not faked

`COPY … TO STDOUT` and `COPY … FROM STDIN` both come back as
`kind_unsupported`. The second is answered with a `CopyFail` on the wire so
the server stops waiting for rows, and the connection is usable immediately
afterwards. Bulk-load with parameterized `INSERT`s, or `COPY` to and from a
file the server can reach.

### The connection survives an error

An `ErrorResponse` is recorded, but the adapter keeps reading until
`ReadyForQuery` before returning. That matters: leaving an unread message on
the stream would desynchronize the *next* query, turning one failure into a
corrupted connection. After a failed statement you can keep using `conn`.

A *lost* connection is the opposite case. When a read times out or the
socket fails there is no `ReadyForQuery` to drain to, and the stream's
position is unknown; so the adapter closes the descriptor and returns an
error that `db::error::is_fatal` recognizes. Reconnect, and skip `shutdown`
for that descriptor — see [Timeouts](#timeouts).

---

## 5. Transactions

There is no transaction object, because none is needed — a transaction is SQL:

```tuo
let _ = pg::query::execute(conn, "BEGIN", 30000);

let r = pg::query::run_params(conn, "INSERT INTO users (name) VALUES ($1)", params, 30000);
if !pg::query::is_ok_result(r) {
    let _ = pg::query::execute(conn, "ROLLBACK", 30000);
    let _ = pg::conn::shutdown(conn);
    return 1;
}
let _ = pg::query::unwrap_ok_result(r);

let _ = pg::query::execute(conn, "COMMIT", 30000);
```

Once a statement fails inside a transaction, PostgreSQL rejects everything
until you `ROLLBACK` — those rejections carry SQLSTATE `25P02`. The handshake
also reports the current transaction status, and `pg::message::tx_status`
decodes it: `I` idle, `T` in a transaction, `E` in a failed one.

---

## 6. Types

The adapter requests **text format** for every column, so values arrive as
their human-readable renderings and one decoder serves both protocols.

| PostgreSQL | Read with | Note |
|------------|-----------|------|
| `int2` / `int4` / `int8` / `oid` | `cell_int` | Exact; `Int` is 64-bit. |
| `float4` / `float8` | `cell_float` | |
| `numeric` | `cell` | Decode as **text** to keep the precision `numeric` exists for. |
| `bool` | `cell_bool` | The server sends `t` / `f`. |
| `text` / `varchar` / `name` / `uuid` / `json` / `jsonb` | `cell` | Already text. |
| `date` / `time` / `timestamp` / `timestamptz` | `cell` | ISO-8601 text; v0 has no date type. |
| `bytea` | `cell` | Arrives in `\x…` hex form. |
| `float8[]` / `float4[]` | `cell`, then `pg::value::as_floats` | `{0.1,0.2}` → `Array[Float]`; see below. |
| pgvector `vector` | `cell`, then `pg::value::as_floats` | `[0.1,0.2]` → `Array[Float]`; the OID is per-install. |

Classify a column by its OID when the shape is not known ahead of time:

```tuo
let oid = pg::query::column_oid(rows, c);
if pg::value::is_integer(oid) {
    let n = pg::query::cell_int(rows, r, c, 0);
} else if pg::value::is_text(oid) {
    let s = pg::query::cell(rows, r, c);
}
```

### Vectors in and out

A `float8[]` column renders as `{0.1,0.2,0.3}` and a pgvector column as
`[0.1,0.2,0.3]`; `pg::value::as_floats` reads both into the `Array[Float]`
the vector store takes, and refuses anything malformed rather than returning a
shorter vector:

```tuo
let raw = pg::query::cell(rows, i, 2);
let embedding = pg::value::as_floats_or_empty(std::string::as_str(raw));
let _ = vec::db::add(store, embedding, id, body);
```

Going the other way, render a vector as a literal and bind it as text with a
cast in the SQL:

```tuo
std::array::push(params, pg::value::array_literal(query_vector));   // "{0.1,0.2}" for $1::float8[]
std::array::push(params, pg::value::vector_literal(query_vector));  // "[0.1,0.2]" for $1::vector
```

pgvector's `vector` type has no fixed OID; `pg::value::vector_oid_query()` is
the query that finds it on a given server. `is_float_array(oid)` names the
two built-in float array types. [`examples/bridge_check.tuo`](../examples/bridge_check.tuo)
runs this whole round trip live and checks that search ranks decoded vectors
exactly as it ranks the originals.

Note the `numeric` caveat: `is_float(oid_numeric())` is true because its *text*
form is a decimal literal, but decoding it through `cell_float` can lose
precision that `numeric` was chosen to preserve. Read it with `cell`.

---

## 7. Authentication

You pass a password to `connect`; the server decides what is done with it.
The adapter answers each method a `pg_hba.conf` line can demand over a plain
connection:

| `pg_hba.conf` method | What crosses the wire |
|----------------------|-----------------------|
| `scram-sha-256` | A proof derived from the password, and the server's proof in return. |
| `md5` | A salted MD5 digest. Deprecated by PostgreSQL; here because servers still ask. |
| `password` | The password itself, in the clear. |
| `trust` | Nothing. The password argument is ignored. |

Nothing differs at the call site, and a wrong password is the server's
error, with its SQLSTATE:

```tuo
let opened = pg::conn::connect("127.0.0.1", 5432, "app", "appdb", "not-it", 30000);
if !pg::conn::is_ok_int(opened) {
    let e = pg::conn::unwrap_err_int(opened);
    if db::error::is_sqlstate(e, "28P01") {
        // password authentication failed for user "app"
    }
    return 1;
}
```

Note the kind: a rejected password is `kind_server`, because the server said
so. `kind_auth` is the adapter's own refusal — a method it does not
implement, or a server that failed to prove itself.

### SCRAM-SHA-256 checks the server too

SCRAM is PostgreSQL's default since version 14, and it is mutual. After the
client proves it knows the password, the server must send a signature that
only something holding the stored credentials can compute. The adapter
verifies it, in constant time, before the connection is handed to you. A
server that sends a wrong signature, or announces success without sending
one, gets:

```
auth: the server did not prove it knows the password (its SCRAM signature
is wrong or missing); refusing the connection
```

That check is the reason to prefer `scram-sha-256` even on a network you
trust: with the other methods, anything that answers the socket can claim to
be your database.

### What authentication does not give you

This adapter speaks **no TLS**. Authenticating says who is at each end; it
does not encrypt or protect what follows, so SQL and results cross the
network readable. Three consequences worth being plain about:

- Use loopback, a private network, or a tunnel (SSH, WireGuard) for anything
  that matters. A server whose `pg_hba.conf` says `hostssl` cannot be reached
  at all.
- The adapter answers whichever method it is asked for. Something that can
  impersonate the server can ask for `password` instead of SCRAM, and will be
  sent the password in the clear.
- Channel binding (`SCRAM-SHA-256-PLUS`) is not offered, since it binds the
  exchange to a TLS channel.

Two smaller ones:

- **Passwords are used as the bytes given.** PostgreSQL normalizes Unicode
  passwords (SASLprep) and this adapter does not, so a non-ASCII password
  authenticates only if you spell it in the normalized form.
- **The server chooses how much work SCRAM costs.** The client runs PBKDF2
  for the iteration count the server names — 4096 by default, about 13 ms in
  a `tuo run` build. A count above `pg::auth::scram_max_iterations()`
  (1,000,000, about three seconds) is refused. This computation is the one
  wait `timeout_ms` does not bound.

### Methods that are refused

Kerberos, GSSAPI, and SSPI are not implemented, and the error names the fix
rather than failing obscurely:

```
auth: server requested GSSAPI authentication, which this adapter does not
implement. Configure the server to offer scram-sha-256, md5, password, or
trust for this host in pg_hba.conf.
```

### Proving a method against your own server

[`examples/auth_check.tuo`](../examples/auth_check.tuo) connects with the
password you give it, runs a query, and then checks that a wrong password is
refused with `28P01` — so a pass means the server really demanded the
method. It takes arguments, so build it rather than `tuo run` it:

```bash
tuo build -o /tmp/auth_check examples/auth_check.tuo src/db/*.tuo src/pg/*.tuo

# A throwaway server that demands md5 (drop both md5 settings for SCRAM):
docker run -d --rm --name pg-md5 -p 127.0.0.1:54331:5432 \
  -e POSTGRES_USER=app -e POSTGRES_DB=appdb -e POSTGRES_PASSWORD=secret \
  -e POSTGRES_HOST_AUTH_METHOD=md5 -e POSTGRES_INITDB_ARGS=--auth-host=md5 \
  postgres:16

/tmp/auth_check 127.0.0.1 54331 app appdb secret
```

The cryptography itself needs no server to check:
[`examples/scram_check.tuo`](../examples/scram_check.tuo) reproduces the
complete exchange RFC 7677 publishes, at its 4096 iterations.

---

## 8. Testing your own code

The pure layers of this adapter are spec-checked, and your code over them can
be too. Anything that does not touch the socket can carry specs:

```tuo
/// Build the SQL for a user lookup.
pub fn user_by_name_sql() -> Str {
    "SELECT id, name FROM users WHERE name = $1"
}

spec user_by_name_sql {
    then std::str::len(user_by_name_sql()) > 0;
}
```

Effectful code cannot appear in a spec (`R0007`), so pin it the way this
repository pins its own: a program that runs against a real server and exits
non-zero on any disagreement. See
[`examples/live_check.tuo`](../examples/live_check.tuo), which cross-checks
twelve properties and is the best worked example of the whole API in use.

```bash
tuo verify src/db/*.tuo src/pg/*.tuo                       # 98 specs, no server needed
tuo run examples/live_check.tuo src/db/*.tuo src/pg/*.tuo  # the live oracle
```
