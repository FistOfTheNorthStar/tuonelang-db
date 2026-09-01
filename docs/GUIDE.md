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
    let _ = std::rt::write_string(1, pg::error::render(pg::conn::unwrap_err_int(opened)));
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
a client, it is a hang. A timeout surfaces as `pg::error::kind_timeout()`,
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

---

## 4. Errors

Every fallible call returns `Result[T, PgError]`. There is no exception
channel; an error is a value you branch on.

```tuo
let r = pg::query::run(db, sql, 30000);
if !pg::query::is_ok_result(r) {
    let e = pg::query::unwrap_err_result(r);
    if pg::error::kind(e) == pg::error::kind_server() {
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
if pg::error::is_sqlstate(e, pg::error::sqlstate_unique_violation()) {
    // 23505 — a duplicate key; probably not fatal
}
if pg::error::is_retryable(e) {
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

`pg::error::render(e)` produces `"server: syntax error … (SQLSTATE 42601)"`.

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

Classify a column by its OID when the shape is not known ahead of time:

```tuo
let oid = pg::query::column_oid(rows, c);
if pg::value::is_integer(oid) {
    let n = pg::query::cell_int(rows, r, c, 0);
} else if pg::value::is_text(oid) {
    let s = pg::query::cell(rows, r, c);
}
```

Note the `numeric` caveat: `is_float(oid_numeric())` is true because its *text*
form is a decimal literal, but decoding it through `cell_float` can lose
precision that `numeric` was chosen to preserve. Read it with `cell`.

---

## 7. Authentication

`trust` and cleartext `password` work today. `md5` and `scram-sha-256` do not,
and the adapter says so rather than failing obscurely:

```
auth: server requested SCRAM-SHA-256 authentication, which this adapter
cannot perform: it needs hashing that tuonelang v0 has no bitwise operators
for. ADR-0019 adds them plus std::crypto; until then, either use trust or
password authentication for this host in pg_hba.conf, or connect over a
channel that has already authenticated.
```

This is not an omission that could be patched in the library: SHA-256 is
*defined* in terms of `^`, `>>`, and `&`, and v0 has none of them, so the
function is inexpressible rather than merely unwritten. ADR-0019 adds the
operators (Stage A) and `std::crypto` (Stage B).

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
eight properties and is the best worked example of the whole API in use.

```bash
tuo verify src/pg/*.tuo                       # 61 specs, no server needed
tuo run examples/live_check.tuo src/pg/*.tuo  # the live oracle
```
