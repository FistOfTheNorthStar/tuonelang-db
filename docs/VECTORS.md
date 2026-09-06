# The vector store — a brief for code-generating models

Paste this into context before asking a model to write tuonelang that stores or
searches embeddings. It states the **real** API surface, the v0 language
constraints that actually bite when writing this kind of code, and the
anti-patterns that do not compile.

Every signature below is copied from the source and is accepted by the
compiler. **If a function is not listed here, it does not exist — do not invent
a plausible name.**

This is the vector counterpart of [`AGENTS.md`](AGENTS.md), which covers the
PostgreSQL side. The two features are independent: a program can use either
alone.

Writing it yourself rather than generating it? [`VECTOR_GUIDE.md`](VECTOR_GUIDE.md)
is the same material as a walkthrough, with the reasoning left in.

---

## 1. THE 30-SECOND VERSION

```tuo
module app;

fn main() -> Int {
    // 1. Open a collection. 384 is the embedding width; cosine is the default.
    var store = vec::db::open("/tmp/docs.tvec", 384, vec::metric::metric_cosine());
    if !vec::db::is_ok(store) {
        let _ = std::rt::write_string(1, vec::db::error(store));
        return 1;
    }

    // 2. Add vectors. The payload is whatever you want back at query time.
    let _ = vec::db::add(store, embedding_of("the first document"), "doc-1", "the first document");

    // 3. Search. `hits` holds the k best, ordered best-first.
    let hits = vec::db::query(store, embedding_of("a query"), 5);

    var i = 0;
    while i < vec::search::hit_count(hits) {
        let line = vec::db::render_hit(store, hits, i);   // "doc-1  0.923"
        let _ = std::rt::write_string(1, line);
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    // 4. Persist.
    let _ = vec::db::save(store);
    0
}
```

Run it with:

```bash
tuo run app.tuo src/db/*.tuo src/vec/*.tuo
```

---

## 2. THE THREE RULES THAT PREVENT MOST ERRORS

**1. Inspect, then consume exactly once.** `is_ok` borrows; everything that
returns an owned `String` consumes what it reads. This is the same rule the
PostgreSQL side documents, and it is enforced by the compiler, not by
convention:

```tuo
if !vec::db::is_ok(store) { ... }        // borrows — safe to call first
let why = vec::db::error(store);          // consumes the error string once
```

**2. Bind a `String` before comparing it.** Comparing an expression that
produces an owned `String` inside `||` or `&&` fails MIR verification:

```tuo
// WRONG
if vec::search::hit_count(hits) != 1 || std::string::as_str(vec::db::hit_id(store, hits, 0)) != "x" { }

// RIGHT
let id = vec::db::hit_id(store, hits, 0);
if vec::search::hit_count(hits) != 1 || std::string::as_str(id) != "x" { }
```

**3. Never name a local after a module root** — `vec`, `db`, `pg`, or `std`.

This is the single easiest mistake to make here, because `db` is the obvious
name for a database handle. A local shadows the namespace, `tuo check` still
passes, and then one of two things happens:

- a spec fails at run time with `the interpreter only executes functions present
  in the lowered MIR`, pointing at the wrong line; or
- the build fails with `codegen: the program has no function named 'main' to
  compile` — even though `main` is plainly there.

```tuo
// WRONG — `db` shadows the `db::` namespace, so `db::math::near` below
// silently drops out and `main` fails to compile.
var store = vec::db::in_memory(3, vec::metric::metric_cosine());
if db::math::near(score, 1.0) { }

// RIGHT
var store = vec::db::in_memory(3, vec::metric::metric_cosine());
if db::math::near(score, 1.0) { }
```

Name the handle `store`, `index`, or `collection` — never `db`.

---

## 3. THE API YOU WILL ACTUALLY CALL

### The collection — `vec::db`

```tuo
fn open(in path: Str, take dim: Int, take metric: Int) -> Db
fn in_memory(take dim: Int, take metric: Int) -> Db
fn is_ok(in d: Db) -> Bool
fn error(in d: Db) -> String
fn as_error(in d: Db) -> db::error::PgError
fn path(in d: Db) -> String
fn count(in d: Db) -> Int
fn dim(in d: Db) -> Int
fn metric(in d: Db) -> Int

fn add(mut d: Db, take v: Array[Float], in id: Str, in payload: Str) -> Int
fn upsert(mut d: Db, take v: Array[Float], in id: Str, in payload: Str) -> Int
fn remove(mut d: Db, in id: Str) -> Bool
fn contains(in d: Db, in id: Str) -> Bool
fn save(in d: Db) -> Int
fn save_as(in d: Db, in path: Str) -> Int

fn query(in d: Db, take v: Array[Float], take k: Int) -> vec::search::Hits
fn query_above(in d: Db, take v: Array[Float], take k: Int, take threshold: Float) -> vec::search::Hits

fn hit_id(in d: Db, in hits: Hits, take i: Int) -> String
fn hit_payload(in d: Db, in hits: Hits, take i: Int) -> String
fn hit_vector(in d: Db, in hits: Hits, take i: Int) -> Array[Float]

fn id_at(in d: Db, take row: Int) -> String
fn payload_at(in d: Db, take row: Int) -> String
fn row_bound(in d: Db) -> Int
fn is_live(in d: Db, take row: Int) -> Bool

fn render_int(take n: Int) -> String
fn render_score(take x: Float) -> String        // "0.707"
fn render_hit(in d: Db, in hits: Hits, take i: Int) -> String   // "doc-1  0.923"
```

`add` returns the row index, or `-1` when the vector is not `dim` long **or
contains a NaN or an infinity**. Non-finite components are refused at the door:
a NaN compares false to everything, so a stored NaN can never be displaced from
a ranking and would silently outrank every real row.
`upsert` replaces any row with the same id — and when the replacement is
rejected for a wrong length, the **existing row is left intact**, so a `-1`
really does mean "nothing changed".

`save` returns the byte count, `0` for an in-memory collection, or a negative
value on failure: `-101` (`vec::disk::err_unrepresentable()`) means the store
holds a component too large for the file format (see §5), which only `l2` and
`dot` collections can reach; `-102` means the bytes did not read back as
written; anything else is the host's own error, such as `-2` for a path that
could not be opened.

`render_score` answers `"+inf"`, `"-inf"`, or `"nan"` for values it will not
spell out, so rendering a hit past the end of a result set is safe.

### Results — `vec::search`

```tuo
fn hit_count(in h: Hits) -> Int
fn hit_row(in h: Hits, take i: Int) -> Int        // -1 when out of range
fn hit_score(in h: Hits, take i: Int) -> Float
fn hit_distance(in h: Hits, take i: Int) -> Float // lower is closer, any metric
fn hit_metric(in h: Hits) -> Int
fn search(in s: Store, take query: Array[Float], take k: Int) -> Hits
fn search_threshold(in s: Store, take query: Array[Float], take k: Int, take threshold: Float) -> Hits
```

Hits are ordered **best-first**. `hit_score` is in the metric's own orientation
(higher is better for cosine and dot; lower is better for L2);
`hit_distance` normalizes that so lower is always closer.

### Metrics — `vec::metric`

```tuo
fn metric_cosine() -> Int    // 1 — the default for embeddings
fn metric_l2() -> Int        // 2 — squared Euclidean distance
fn metric_dot() -> Int       // 3 — inner product
fn metric_name(take m: Int) -> Str
fn is_metric(take m: Int) -> Bool
fn higher_is_closer(take m: Int) -> Bool
fn normalize_at(mut xs: Array[Float], take at: Int, take dim: Int)
fn norm_at(in a: Array[Float], take a_at: Int, take dim: Int) -> Float
fn dot_at(in a, take a_at: Int, in b, take b_at: Int, take dim: Int) -> Float
fn l2_squared_at(in a, take a_at: Int, in b, take b_at: Int, take dim: Int) -> Float
fn cosine_at(in a, take a_at: Int, in b, take b_at: Int, take dim: Int) -> Float
```

**Pick cosine unless you know otherwise.** Every mainstream embedding model is
trained for it, and a cosine collection normalizes on insert so each comparison
is a bare dot product.

### The rows — `vec::store`

Reach for this only when `vec::db` is not enough.

```tuo
fn empty(take dim: Int, take metric: Int) -> Store
fn add(mut s: Store, take v: Array[Float], in id: Str, in payload: Str) -> Int
fn remove(mut s: Store, take row: Int) -> Bool
fn remove_id(mut s: Store, in id: Str) -> Bool
fn compact(in s: Store) -> Store
fn count(in s: Store) -> Int          // includes tombstones
fn live_count(in s: Store) -> Int     // excludes them
fn is_live(in s: Store, take row: Int) -> Bool
fn dim(in s: Store) -> Int
fn metric(in s: Store) -> Int
fn id_at(in s: Store, take row: Int) -> String
fn payload_at(in s: Store, take row: Int) -> String
fn vector_at(in s: Store, take row: Int) -> Array[Float]
fn component_at(in s: Store, take row: Int, take c: Int) -> Float
fn row_of_id(in s: Store, in id: Str) -> Int      // -1 when absent
fn contains(in s: Store, in id: Str) -> Bool
fn offset_of(in s: Store, take row: Int) -> Int
fn score_row_at(in s: Store, take row: Int, in q: Array[Float], take metric: Int) -> Float
fn is_consistent(in s: Store) -> Bool
```

### Files — `vec::disk` and `vec::codec`

```tuo
fn save(in s: Store, in path: Str) -> Int
fn save_verified(in s: Store, in path: Str) -> Int
fn load(in path: Str) -> Store
fn load_error(in path: Str) -> String
fn exists(in path: Str) -> Bool
fn remove(in path: Str) -> Bool
fn write_bytes(in path: Str, in bytes: String) -> Int
fn read_bytes(in path: Str) -> String

fn encode(in s: Store) -> String
fn decode(in buf: String) -> Store
fn header_error(in buf: String) -> String
fn is_valid(in buf: String) -> Bool
```

---

## 4. BUILDING A VECTOR

There is no vector literal. Build one by pushing floats in order:

```tuo
fn v3(take a: Float, take b: Float, take c: Float) -> Array[Float] {
    var xs = std::array::empty();
    std::array::push(xs, a);
    std::array::push(xs, b);
    std::array::push(xs, c);
    xs
}
```

For a 384- or 1536-wide embedding, push in a loop from wherever the numbers come
from. The array must be **exactly** `dim` long or `add` returns `-1`.

`1.` and `.5` are **not** float literals — write `1.0` and `0.5`. There is no
unary minus on a literal in every position either; write `0.0 - 1.0`.

---

## 5. WHAT THIS LIBRARY DOES NOT DO

Stated plainly, so a model does not generate a call for something absent:

- **No embedding model.** This stores and searches vectors; producing them is
  someone else's job. Feed it output from whatever model you use.
- **No approximate index (HNSW/IVF).** Search is an exact linear scan. It is
  O(N·D) per query — excellent to roughly 10^5 vectors, and honest about it.
  There is no `vec::index` module; do not call one.
- **No metadata filtering.** A payload is an opaque string. Filter by scanning
  hits yourself.
- **No concurrency.** A `Db` is a value, not a shared server.
- **No non-finite components.** NaN and infinity are rejected by `add`, so
  every stored vector is finite and every ranking is totally ordered.
- **No IEEE float bytes on disk.** Components are stored as fixed-point
  integers (`round(x * 2^30)`), because v0 cannot reinterpret a float's bits.
  Round-trip error is ~5e-10 — far below the precision an embedding carries.
  Magnitudes above `vec::codec::max_magnitude()` (1e9) cannot be represented;
  `vec::disk::save_verified` refuses such a store with `-101` rather than
  writing a clamped, silently wrong file. Normalized (cosine) vectors never approach
  this.

---

## 6. ANTI-PATTERNS — these do not compile

```
WRONG                                    RIGHT
─────────────────────────────────────    ──────────────────────────────────────
store.query(v, 5)                        vec::db::query(store, v, 5)
hits[0].id                               vec::db::hit_id(store, hits, 0)
var vec = my_vector;                     var v = my_vector;        // see §2.3
let mut d = ...;                         var d = ...;
n += 1;                                  n = n + 1;
for h in hits { }                        while i < hit_count(hits) { }
xs.len()                                 std::array::len(xs)
std::math::sqrt(x)                       db::math::sqrt(x)   // no std::math
-1.0                                     0.0 - 1.0
1.                                       1.0
vec::db::add(store, v, id, p) after         bind the result: let row = ...;
  reading `v` again                        `v` is moved into the store
```

---

## 7. THE MOVE RULE THAT BITES HARDEST

v0 keeps **no hidden drop flags**. A value moved on one branch and left alive on
another has no statically known state where the branches join, and the compiler
rejects it with `O0008`:

```tuo
// WRONG — `v` is consumed only when the length matches
if std::array::len(v) == dim {
    let _ = vec::db::add(store, v, "id", "");
}

// RIGHT — take it unconditionally, then decide
var incoming = v;
let fits = std::array::len(incoming) == dim;
if fits {
    let _ = vec::db::add(store, incoming, "id", "");
} else {
    let _ = std::array::len(incoming);   // consumed on this path too
}
```

The same rule explains why `vec::db::opened` takes a `String` it does not use:
its caller must dispose of that value on every path.

---

## 8. A COMPLETE, WORKING PROGRAM

This compiles and runs. It is the shape most retrieval programs take.

```tuo
module notes;

/// Build a 3-D vector.
fn v3(take a: Float, take b: Float, take c: Float) -> Array[Float] {
    var xs = std::array::empty();
    std::array::push(xs, a);
    std::array::push(xs, b);
    std::array::push(xs, c);
    xs
}

fn main() -> Int {
    var store = vec::db::in_memory(3, vec::metric::metric_cosine());

    let _ = vec::db::add(store, v3(1.0, 0.0, 0.0), "red", "a note about red");
    let _ = vec::db::add(store, v3(0.0, 1.0, 0.0), "green", "a note about green");
    let _ = vec::db::add(store, v3(0.9, 0.1, 0.0), "crimson", "a note about crimson");

    // Everything close to "red", best first.
    let hits = vec::db::query(store, v3(1.0, 0.0, 0.0), 2);

    var i = 0;
    while i < vec::search::hit_count(hits) {
        let payload = vec::db::hit_payload(store, hits, i);
        let _ = std::rt::write_string(1, payload);
        let _ = std::rt::write(1, "  ");
        let score = vec::db::render_score(vec::search::hit_score(hits, i));
        let _ = std::rt::write_string(1, score);
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    // Persist it for next time.
    let _ = vec::db::save_as(store, "/tmp/notes.tvec");
    0
}
```

Output:

```
a note about red  1.000
a note about crimson  0.994
```
