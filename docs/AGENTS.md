# tuonelang-db — a brief for code-generating models

Paste this into context before asking a model to write tuonelang that talks to
PostgreSQL. It states the **real** API surface, the v0 language constraints
that actually bite when writing this kind of code, and the anti-patterns that
do not compile.

Every signature below is copied from the source and is accepted by the
compiler. **If a function is not listed here, it does not exist — do not invent
a plausible name.**

---

## 1. THE 30-SECOND VERSION

```tuo
module app;

fn main() -> Int {
    // 1. Connect. The host MUST be numeric — v0 has no DNS.
    //    The password is answered however the server asks: SCRAM, md5, cleartext.
    let opened = pg::conn::connect("127.0.0.1", 5432, "postgres", "mydb", "secret", 30000);
    if !pg::conn::is_ok_int(opened) {
        return 1;
    }
    let conn = pg::conn::unwrap_ok_int(opened);

    // 2. Query.
    let result = pg::query::run(conn, "SELECT id, name FROM users", 30000);
    if !pg::query::is_ok_result(result) {
        let e = pg::query::unwrap_err_result(result);
        let _ = std::rt::write_string(1, db::error::render(e));
        if !db::error::is_fatal(e) {
            let _ = pg::conn::shutdown(conn); // a fatal error already closed it
        }
        return 1;
    }
    let rows = pg::query::unwrap_ok_result(result);

    // 3. Read cells: (row, column), both 0-based.
    var i = 0;
    while i < pg::query::row_count(rows) {
        let id = pg::query::cell_int(rows, i, 0, 0);
        let name = pg::query::cell(rows, i, 1);
        i = i + 1;
    }

    // 4. Close.
    let _ = pg::conn::shutdown(conn);
    0
}
```

---

## 2. THE RESULT PATTERN — get this right and most errors disappear

Every fallible call returns `Result[T, db::error::PgError]`. v0 has **no `?`
operator**, and a `match` on an owned value **moves it**. So the one correct
shape is always:

```tuo
let r = pg::query::run(conn, sql, 30000);   // 1. call
if !pg::query::is_ok_result(r) {          // 2. inspect  (BORROWS, binds nothing)
    let text = pg::query::render_error(r); // 3a. consume ONCE on the error path
    return 1;                              //     ... and never read `r` again
}
let rows = pg::query::unwrap_ok_result(r); // 3b. or consume ONCE on the ok path
```

**The rule: inspect with `is_ok_*`, then consume exactly once.** Never call two
consuming functions on the same `Result`, and never read a `Result` after
passing it to one.

Getting this wrong produces `M0005: reads _N after it was moved out` at the
codegen stage. If you see that error, look for a `Result` (or any `String` /
`Array` / struct) consumed in one branch and read again below.

| Result type | inspect (borrow) | unwrap ok (consume) | unwrap err (consume) |
|-------------|------------------|---------------------|----------------------|
| `Result[Int, PgError]` | `pg::conn::is_ok_int` | `pg::conn::unwrap_ok_int` | `pg::conn::unwrap_err_int` |
| `Result[String, PgError]` | `pg::conn::is_ok_string` | `pg::conn::unwrap_ok_string` | `pg::conn::unwrap_err_string` |
| `Result[ResultSet, PgError]` | `pg::query::is_ok_result` | `pg::query::unwrap_ok_result` | `pg::query::unwrap_err_result` |

`pg::query::render_error(r)` consumes `r` and gives you the printable text —
use it instead of `db::error::render(unwrap_err_result(r))`, which reads better
but is the same single consumption.

---

## 3. THE API YOU WILL ACTUALLY CALL

### Connecting — `pg::conn`

```tuo
fn connect(in host: Str, take port: Int, in user: Str, in database: Str,
           in password: Str, take timeout_ms: Int) -> Result[Int, db::error::PgError]
fn open(in host: Str, take port: Int, take timeout_ms: Int) -> Result[Int, db::error::PgError]
fn handshake(take fd: Int, in user: Str, in database: Str, in password: Str,
             take timeout_ms: Int) -> Result[Int, db::error::PgError]
fn shutdown(take fd: Int) -> Int      // Terminate + close. Prefer this.
fn close(take fd: Int) -> Int
fn is_open(take outcome: Int) -> Bool
fn default_port() -> Int              // 5432
fn default_timeout_ms() -> Int        // 30000
```

`connect` = `open` + `handshake`, and closes the descriptor if the handshake
fails. **Use `connect`.** A connection is just the `Int` descriptor.

### Querying — `pg::query`

```tuo
fn run(take fd: Int, in sql: Str, take timeout_ms: Int) -> Result[ResultSet, PgError]
fn run_params(take fd: Int, in sql: Str, in params: Array[String],
              take timeout_ms: Int) -> Result[ResultSet, PgError]
fn run_params_null(take fd: Int, in sql: Str, in params: Array[String],
                   in nulls: Array[Int], take timeout_ms: Int) -> Result[ResultSet, PgError]
fn execute(take fd: Int, in sql: Str, take timeout_ms: Int) -> Result[Int, PgError]
fn execute_params(take fd: Int, in sql: Str, in params: Array[String],
                  take timeout_ms: Int) -> Result[Int, PgError]
fn scalar(take fd: Int, in sql: Str, take timeout_ms: Int) -> Result[String, PgError]
fn scalar_params(take fd: Int, in sql: Str, in params: Array[String],
                 take timeout_ms: Int) -> Result[String, PgError]
fn scalar_int(take fd: Int, in sql: Str, take fallback: Int,
              take timeout_ms: Int) -> Result[Int, PgError]
fn scalar_int_params(take fd: Int, in sql: Str, in params: Array[String],
                     take fallback: Int, take timeout_ms: Int) -> Result[Int, PgError]

fn push_param(mut params: Array[String], mut nulls: Array[Int], in text: Str)
fn push_null(mut params: Array[String], mut nulls: Array[Int])
fn affected_of(take r: Result[ResultSet, PgError]) -> Result[Int, PgError]
fn first_row(take r: Result[ResultSet, PgError]) -> Result[ResultSet, PgError]
fn first_cell(take r: Result[ResultSet, PgError]) -> Result[String, PgError]
fn first_cell_int(take r: Result[ResultSet, PgError], take fallback: Int) -> Result[Int, PgError]
```

- `run` — you want the rows.
- `run_params` — you have user input. **Always** for untrusted values.
- `run_params_null` — `run_params` where some parameters are SQL NULL (§4).
- `execute` / `execute_params` — INSERT/UPDATE/DELETE/DDL; returns the
  affected-row count.
- `scalar` / `scalar_int` and their `_params` forms — one value, e.g.
  `SELECT count(*)`. `scalar` is an error (`kind_decode`), not `""`, when
  there are no rows **or the value is NULL**; `scalar_int` gives its
  `fallback` for NULL. For a nullable column use `run` + `is_null`.
- `affected_of` / `first_cell` / `first_cell_int` — what the `_params` forms
  are made of. Apply them to a `run_params_null` result to get the affected
  count or one value of a query with NULL parameters.
- `push_param` / `push_null` — build the `params` + `nulls` pair (§4).

### Reading a `ResultSet` — `pg::query`

```tuo
fn row_count(in rs: ResultSet) -> Int
fn column_count(in rs: ResultSet) -> Int
fn affected(in rs: ResultSet) -> Int
fn tag(in rs: ResultSet) -> String                       // "SELECT 3"
fn column_name(in rs: ResultSet, take c: Int) -> String
fn column_oid(in rs: ResultSet, take c: Int) -> Int
fn column_index(in rs: ResultSet, in name: Str) -> Int   // -1 when absent
fn cell(in rs: ResultSet, take r: Int, take c: Int) -> String
fn is_null(in rs: ResultSet, take r: Int, take c: Int) -> Bool
fn cell_int(in rs: ResultSet, take r: Int, take c: Int, take fallback: Int) -> Int
fn cell_float(in rs: ResultSet, take r: Int, take c: Int, take fallback: Float) -> Float
fn cell_bool(in rs: ResultSet, take r: Int, take c: Int) -> Bool
fn has_cell(in rs: ResultSet, take r: Int, take c: Int) -> Bool
fn has_column(in rs: ResultSet, take c: Int) -> Bool
fn empty_result() -> ResultSet
```

Indices are **0-based**, `(row, column)`. A NULL cell reads as `""` from
`cell`, so **check `is_null` first** whenever NULL and `''` mean different
things. An index outside the result never traps: `cell` reads `""`,
`is_null` reads `true`, the typed accessors give their fallback — so a `-1`
from `column_index` behaves like a NULL. `has_cell` is the explicit check.

### Errors — `db::error`

```tuo
fn kind(in e: PgError) -> Int
fn message(in e: PgError) -> String
fn sqlstate(in e: PgError) -> String
fn render(in e: PgError) -> String          // "server: ... (SQLSTATE 42601)"
fn is_sqlstate(in e: PgError, in code: Str) -> Bool
fn is_retryable(in e: PgError) -> Bool      // 40001 / 40P01
fn is_fatal(in e: PgError) -> Bool          // kind_timeout or kind_connection
fn new(take kind: Int, in message: Str) -> PgError
fn server(in message: Str, in sqlstate: Str) -> PgError
fn with_sqlstate(take kind: Int, in message: Str, in sqlstate: Str) -> PgError
fn kind_name(take k: Int) -> Str
```

**A fatal error has already closed the descriptor.** `kind_timeout` and
`kind_connection` from any `pg::conn` or `pg::query` call mean the adapter
closed `fd` before returning (the stream's position was unknown). On that
path **do not call `shutdown`/`close`** — the number may already belong to
another descriptor — reconnect instead. Every other kind leaves the
connection usable. A server that announced why it was closing keeps its
SQLSTATE (`57P01`) on the `kind_connection` error.

Kinds: `kind_connection` 1, `kind_timeout` 2, `kind_auth` 3, `kind_server` 4,
`kind_protocol` 5, `kind_decode` 6, `kind_unsupported` 7. Two things produce
`kind_unsupported`, and the connection stays usable after both: two
row-returning statements in one `run`, and any `COPY` to or from the client.
Do not generate `COPY … FROM STDIN`; generate `INSERT … VALUES ($1, …)` in a
loop or a multi-row `VALUES` list instead.

Named SQLSTATEs: `sqlstate_unique_violation` (23505),
`sqlstate_foreign_key_violation` (23503), `sqlstate_not_null_violation`
(23502), `sqlstate_syntax_error` (42601), `sqlstate_undefined_table` (42P01),
`sqlstate_invalid_password` (28P01), `sqlstate_serialization_failure` (40001).

### Value decoding — `pg::value`

```tuo
fn as_int(in raw: Str) -> Result[Int, Str]
fn as_int_or(in raw: Str, take fallback: Int) -> Int
fn as_float(in raw: Str) -> Result[Float, Str]
fn as_float_or(in raw: Str, take fallback: Float) -> Float
fn as_bool(in raw: Str) -> Bool          // 't' is true; everything else false
fn is_integer(take oid: Int) -> Bool
fn is_float(take oid: Int) -> Bool
fn is_text(take oid: Int) -> Bool
fn is_temporal(take oid: Int) -> Bool
fn is_float_array(take oid: Int) -> Bool     // float8[] 1022, float4[] 1021
fn as_floats(in raw: Str) -> Result[Array[Float], Str]   // "{0.1,0.2}" or "[0.1,0.2]"
fn as_floats_or_empty(in raw: Str) -> Array[Float]
fn array_literal(in xs: Array[Float]) -> String          // "{0.1,0.2}"  for $1::float8[]
fn vector_literal(in xs: Array[Float]) -> String         // "[0.1,0.2]"  for $1::vector
fn vector_oid_query() -> Str                             // pgvector's OID is per-install
```

Type OIDs: `oid_bool` 16, `oid_int8` 20, `oid_int2` 21, `oid_int4` 23,
`oid_text` 25, `oid_float4` 700, `oid_float8` 701, `oid_varchar` 1043,
`oid_date` 1082, `oid_timestamp` 1114, `oid_timestamptz` 1184, `oid_numeric`
1700, `oid_uuid` 2950, `oid_jsonb` 3802.

Dates/times/UUID/JSON come back as **text**; there is no date type in v0.

**Embeddings.** A `float8[]` or pgvector `vector` cell is text; decode it
with `as_floats` to get the `Array[Float]` that `vec::db::add` takes. Send a
vector the other way as `array_literal(v)` bound to `$1::float8[]`, or
`vector_literal(v)` bound to `$1::vector`. Never build the literal by
string concatenation — the renderer guarantees plain decimal with no
exponent, which is what the server's parser expects.

---

## 4. PARAMETERS — the injection-safe path

```tuo
var params = std::array::empty();
std::array::push(params, std::string::from_str("ada"));
std::array::push(params, std::string::from_str("42"));

let r = pg::query::run_params(conn, "SELECT * FROM users WHERE name = $1 AND age > $2", params, 30000);
```

Placeholders are `$1`, `$2`, … in push order. Every parameter is sent as text
and the server infers its type.

**To send SQL NULL**, use `run_params_null` with an `Array[Int]` of flags
aligned to `params`: a non-zero flag means "send NULL, ignore the text". An
empty string is a value, not NULL, so this is the only way to spell it. Build
the pair with `push_param` / `push_null`, which append to both arrays at once:

```tuo
var params = std::array::empty();
var nulls = std::array::empty();
pg::query::push_param(params, nulls, "ada");
pg::query::push_null(params, nulls);           // the note is NULL

let r = pg::query::run_params_null(conn, "INSERT INTO users (name, note) VALUES ($1, $2)", params, nulls, 30000);
```

A `nulls` array shorter than `params` treats the rest as values, so it may be
left empty when nothing is NULL.

One query carries at most `pg::query::max_params()` (65535) parameters; more
is refused with `kind_unsupported` before anything is sent. For a bulk
insert, batch the rows so `rows × columns` stays under that.

**For a statement's affected count or a single value with parameters**, use
`execute_params`, `scalar_params`, or `scalar_int_params` — the same shapes as
`execute`, `scalar`, and `scalar_int`, taking `params` after `sql`. With NULL
parameters, compose instead of looking for a `_null` variant (there is none):

```tuo
let n = pg::query::affected_of(pg::query::run_params_null(conn, sql, params, nulls, 30000));
let v = pg::query::first_cell(pg::query::run_params_null(conn, sql, params, nulls, 30000));
```

**Never build SQL by concatenating values.** There is deliberately no helper in
this library that would make that convenient.

---

## 5. TRANSACTIONS

There is no transaction object — send the SQL, which is all any client does:

```tuo
let _ = pg::query::execute(conn, "BEGIN", 30000);
// ... work ...
let _ = pg::query::execute(conn, "COMMIT", 30000);   // or "ROLLBACK"
```

After an error inside a transaction the server rejects everything until you
`ROLLBACK`; that state is visible as SQLSTATE `25P02`.

---

## 6. LANGUAGE CONSTRAINTS THAT BITE IN THIS CODE

These are v0 rules that specifically trip up database code.

**No `?`, no exceptions.** Errors are values. See §2.

**`match` on an owned value moves it.** Bind nothing (`Ok { value: _ }`) to
inspect a borrow; bind a name only when you mean to consume.

**Binding a non-`Copy` field out of an `in` parameter is a move** (`O0003`).
`Int`/`Bool`/`Float` are `Copy`; `String`, `Array[T]`, and structs are not. This
is why the inspect/consume split exists at all.

**Never name a local `db`, `pg`, `vec`, or `std`.** A local shadows the
module namespace of the same name: `tuo check` still passes, and then the
build fails with `lowering: 'main' was not lowered`. With `let db = …` in
scope, `db::error::render(e)` is that failure — so the handle is `conn` in
every example here.

**`mut` is declared, never written at the call site.**
`std::string::push_byte(buf, 0)` — not `push_byte(mut buf, 0)`.

**No compound assignment.** Write `x = x + 1`. Integer overflow **traps**; it
does not wrap — `std::int::wrapping_add` and friends are the explicit form.

**`Str` vs `String`.** `Str` is a borrowed view (literals, slices); `String` is
an owned heap buffer. Convert with `std::string::from_str(s)` and
`std::string::as_str(owned)`. Compare with `==` only between two `Str`.

**The whole standard library is in scope by full path, with no `import`:**
`std::str` (including `parse_int`, `to_string`, `split`, `find`),
`std::string`, `std::array`, `std::map`, `std::io::println`, `std::math`,
`std::bits`, `std::crypto`, `std::process::arg`, `std::time`. Run
`tuo cheatsheet` for every signature — if a function is not listed there, it
does not exist. The examples here write output with `std::rt::write(1, s)` /
`std::rt::write_string(1, owned)`; `std::io::println` works equally.

---

## 7. ANTI-PATTERNS — these do not compile

```
WRONG                                    RIGHT
─────────────────────────────────────    ──────────────────────────────────────
conn.query("SELECT 1")                   pg::query::run(conn, "SELECT 1", 30000)
rs.rows[0]["name"]                       pg::query::cell(rs, 0, c)
let r = try run(...)                     inspect with is_ok_result, then unwrap
"WHERE id = " + user_input               run_params with $1
connect("localhost", ...)                connect("127.0.0.1", ...)   // no DNS
Some(x) / Option<Int>                    Some { value: x } / Option[Int]
let mut n = 0;                           var n = 0;
n += 1;                                  n = n + 1;
for row in rows { }                      while i < row_count(rs) { }
xs.len()                                 std::array::len(xs)
if a < b < c                             if a < b && b < c
match r { Ok(v) => ... }                 match r { Ok { value } => ... }
defer conn.close()                       let _ = pg::conn::shutdown(conn);
```

---

## 8. AUTHENTICATION — nothing to write

Pass the password to `connect`. The adapter answers whichever method the
server's `pg_hba.conf` demands — **`scram-sha-256`, `md5`, `password`
(cleartext), or `trust`** — and you write no authentication code at all.

```tuo
let opened = pg::conn::connect("127.0.0.1", 5432, "app", "appdb", "secret", 30000);
if !pg::conn::is_ok_int(opened) {
    let e = pg::conn::unwrap_err_int(opened);
    if db::error::is_sqlstate(e, "28P01") {
        // wrong password — the server's own error, kind_server
    } else if db::error::kind(e) == db::error::kind_auth() {
        // the adapter refused: an unimplemented method (Kerberos, GSSAPI),
        // or a server that failed to prove itself under SCRAM
    }
    return 1;
}
```

Do not call `pg::auth::*` yourself; `connect` drives it. Under SCRAM the
server must prove it knows the password too, and `connect` fails with
`kind_auth` if it does not.

**There is no TLS.** Authentication does not encrypt the session: SQL and
results cross the network in the clear, and under `password` so does the
secret. A server that requires `hostssl` cannot be reached. Do not write
`sslmode`, a connection URL, or a host name — none exists; the host is a
numeric address.

---

## 9. A COMPLETE, WORKING PROGRAM

This compiles and runs against a live server.

```tuo
module report;

fn main() -> Int {
    let opened = pg::conn::connect("127.0.0.1", 5432, "postgres", "app", "secret", 30000);
    if !pg::conn::is_ok_int(opened) {
        let _ = std::rt::write(1, "cannot connect\n");
        return 1;
    }
    let conn = pg::conn::unwrap_ok_int(opened);

    // Create and populate a table.
    let _ = pg::query::execute(conn, "CREATE TEMP TABLE t (id int, name text)", 30000);

    var params = std::array::empty();
    std::array::push(params, std::string::from_str("ada"));
    let ins = pg::query::run_params(conn, "INSERT INTO t VALUES (1, $1)", params, 30000);
    if !pg::query::is_ok_result(ins) {
        let e = pg::query::unwrap_err_result(ins);
        let _ = std::rt::write_string(1, db::error::render(e));
        if !db::error::is_fatal(e) {
            let _ = pg::conn::shutdown(conn); // a fatal error already closed it
        }
        return 1;
    }
    let _ = pg::query::unwrap_ok_result(ins);

    // Read it back.
    let sel = pg::query::run(conn, "SELECT id, name FROM t ORDER BY id", 30000);
    if !pg::query::is_ok_result(sel) {
        let e = pg::query::unwrap_err_result(sel);
        let _ = std::rt::write_string(1, db::error::render(e));
        if !db::error::is_fatal(e) {
            let _ = pg::conn::shutdown(conn); // a fatal error already closed it
        }
        return 1;
    }
    let rows = pg::query::unwrap_ok_result(sel);

    var i = 0;
    while i < pg::query::row_count(rows) {
        if !pg::query::is_null(rows, i, 1) {
            let name = pg::query::cell(rows, i, 1);
            let _ = std::rt::write_string(1, name);
            let _ = std::rt::write(1, "\n");
        }
        i = i + 1;
    }

    let _ = pg::conn::shutdown(conn);
    pg::query::row_count(rows)
}
```

Run it with:

```bash
tuo run report.tuo src/db/*.tuo src/pg/*.tuo
```

Both source directories are needed: the library is split into a
backend-neutral core (`src/db/` — `db::bytes`, `db::error`) and the PostgreSQL
adapter (`src/pg/` — everything else), and a program that queries needs both.
`./build.sh --postgresql --command run --entry report.tuo` selects the same set
by feature rather than by glob.
