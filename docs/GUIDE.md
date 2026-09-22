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
    "",            // password (unused under trust)
    30000,         // timeout in milliseconds
);
if !pg::conn::is_ok_int(opened) {
    let _ = std::rt::write_string(1, db::error::render(pg::conn::unwrap_err_int(opened)));
    return 1;
}
let db = pg::conn::unwrap_ok_int(opened);
```

`connect` opens the socket **and** completes the startup handshake: it sends
the startup packet, answers or refuses the authentication request, drains the
`ParameterStatus` and `BackendKeyData` messages the server sends, and returns
once `ReadyForQuery` arrives. If the handshake fails it closes the descriptor
for you, so there is nothing to leak.

The value you get back is the **descriptor** — an `Int`. v0 has no destructors,
so closing is explicit:

```tuo
let _ = pg::conn::shutdown(db);   // sends Terminate, then closes
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

---

## 2. Running a query

```tuo
let result = pg::query::run(db, "SELECT id, name FROM users ORDER BY id", 30000);
if !pg::query::is_ok_result(result) {
    let _ = std::rt::write_string(1, pg::query::render_error(result));
    let _ = pg::conn::shutdown(db);
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
let deleted = pg::query::execute(db, "DELETE FROM users WHERE id = 1", 30000);
// Ok { value: <rows affected> }
```

`execute` returns the affected-row count, parsed from the server's command tag
(`"DELETE 1"`, `"INSERT 0 3"`, `"UPDATE 2"`). Single values are easier still:

```tuo
let total = pg::query::scalar_int(db, "SELECT count(*) FROM users", 0, 30000);
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
    db,
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

let r = pg::query::run_params_null(db, "INSERT INTO users (name, note) VALUES ($1, $2)", params, nulls, 30000);
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

let n = pg::query::execute_params(db, "DELETE FROM users WHERE id = $1::int", ids, 30000);
let name = pg::query::scalar_params(db, "SELECT name FROM users WHERE id = $1::int", ids, 30000);
let total = pg::query::scalar_int_params(db, "SELECT count(*) FROM users WHERE id > $1::int", ids, 0, 30000);
```

Same results as `execute`, `scalar`, and `scalar_int`, over the extended
protocol. They are one-liners over two public reducers, `affected_of` and
`first_cell`, so a query that needs NULL parameters composes the same way
instead of needing yet another variant:

```tuo
let n = pg::query::affected_of(pg::query::run_params_null(db, sql, params, nulls, 30000));
```

---

## 4. Errors

Every fallible call returns `Result[T, PgError]`. There is no exception
channel; an error is a value you branch on.

```tuo
let r = pg::query::run(db, sql, 30000);
if !pg::query::is_ok_result(r) {
    let e = pg::query::unwrap_err_result(r);
    if db::error::kind(e) == db::error::kind_server() {
        // the server rejected it — inspect the SQLSTATE
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
| `kind_connection` | The socket failed, or the server closed it. |
| `kind_timeout` | The peer did not answer in time. |
| `kind_auth` | An authentication method this adapter cannot perform. |
| `kind_server` | A real SQL error; carries a SQLSTATE. |
| `kind_protocol` | The bytes on the wire did not match the protocol. |
| `kind_decode` | A value would not decode, or no rows where one was needed. |
| `kind_unsupported` | A feature this adapter does not implement. |

`db::error::render(e)` produces `"server: syntax error … (SQLSTATE 42601)"`.

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
corrupted connection. After a failed statement you can keep using `db`.

---

## 5. Transactions

There is no transaction object, because none is needed — a transaction is SQL:

```tuo
let _ = pg::query::execute(db, "BEGIN", 30000);

let r = pg::query::run_params(db, "INSERT INTO users (name) VALUES ($1)", params, 30000);
if !pg::query::is_ok_result(r) {
    let _ = pg::query::execute(db, "ROLLBACK", 30000);
    let _ = pg::conn::shutdown(db);
    return 1;
}
let _ = pg::query::unwrap_ok_result(r);

let _ = pg::query::execute(db, "COMMIT", 30000);
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

`trust` and cleartext `password` work today. `md5` and `scram-sha-256` do not,
and the adapter says so rather than failing obscurely:

```
auth: server requested SCRAM-SHA-256 authentication, which this adapter
cannot perform: it needs hashing that this adapter does not yet
implement. ADR-0019 Stage A landed the bitwise operators, but
std::crypto (Stage B) is not available yet; until then, either use trust
or password authentication for this host in pg_hba.conf, or connect over
a channel that has already authenticated.
```

This used to be inexpressible rather than unwritten, because SHA-256 is
*defined* in terms of `^`, `>>`, and `&`. **ADR-0019 Stage A has landed**, so
those operators exist and the hashes could now be written by hand. Stage B —
`std::crypto` — has not: `std::crypto::sha256` still resolves to
`R0002: no 'crypto' in 'std'`. So this is now a matter of implementation work,
not a language limit.

One thing to be plain about: this adapter speaks **no TLS**, so under
`password` authentication the secret crosses the network in cleartext. Use it
only over loopback or a link you already trust, and prefer `trust` scoped to
the client's own address.

To connect today, grant trust for your client host in `pg_hba.conf` and reload:

```
host  all  all  127.0.0.1/32  trust
```

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
tuo verify src/db/*.tuo src/pg/*.tuo                       # 87 specs, no server needed
tuo run examples/live_check.tuo src/db/*.tuo src/pg/*.tuo  # the live oracle
```
