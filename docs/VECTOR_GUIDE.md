# The tuonelang vector store guide

A walkthrough of the embedded vector store, from a first collection to
persistence, retrieval and the failure modes worth handling. Every code block
here is written against the real API; the complete programs are compiled and
run as part of validating this repository.

For a dense reference aimed at code-generating models, see
[`VECTORS.md`](VECTORS.md). For the design rationale, see the module headers —
each one opens with why it is shaped the way it is.

---

## 0. Before anything else

You need the `tuo` compiler and this repository. There is **no server to
start**, no daemon, no port: a collection is a value in your program and, when
you save it, one file on disk.

```bash
# Everything compiles and every spec runs, with nothing else running:
./run-tests.sh --vector --live
```

Run your own program by naming it first and the library after:

```bash
tuo run myprogram.tuo src/db/*.tuo src/vec/*.tuo
```

Both source directories are needed: `src/db/` is the backend-neutral core
(`db::bytes`, `db::error`, `db::math`) and `src/vec/` is the store itself. If
you only ever use vectors, `./build.sh --vector` compiles exactly that set and
no line of the PostgreSQL protocol.

---

## 1. Your first collection

A collection has two fixed properties, chosen when you create it and unchangeable
afterwards: the **dimensionality** of its vectors and the **metric** it ranks by.

```tuo
var store = vec::db::in_memory(3, vec::metric::metric_cosine());
```

That is a complete, usable database. It holds 3-dimensional vectors and ranks
by cosine similarity. Nothing is on disk yet.

To work with a file instead, use `open` — which creates the collection when the
file is not there yet, and loads it when it is:

```tuo
var store = vec::db::open("/tmp/docs.tvec", 384, vec::metric::metric_cosine());
if !vec::db::is_ok(store) {
    let _ = std::rt::write_string(1, vec::db::error(store));
    return 1;
}
```

**Always check `is_ok`.** A collection that failed to open still answers every
query — it is simply empty — so skipping the check turns a corrupt file into
silently missing results rather than an error. See §7.

> **Name the handle `store`, not `db`.** A local called `db` shadows the `db::`
> module namespace. The compiler accepts it and then fails much later with
> `codegen: the program has no function named 'main' to compile`. This is the
> single easiest mistake to make against this library.

---

## 2. Choosing a metric

| Metric | Ranks by | Use it when |
|--------|----------|-------------|
| `vec::metric::metric_cosine()` | angle between vectors — **higher is closer** | **The default.** Embeddings from any mainstream model. |
| `vec::metric::metric_l2()` | squared Euclidean distance — **lower is closer** | Coordinates, or anything where *magnitude* is meaningful. |
| `vec::metric::metric_dot()` | inner product — **higher is closer** | You have already normalized, or magnitude should boost a score. |

**Pick cosine unless you have a specific reason not to.** Text-embedding models
are trained so that direction carries the meaning and length does not, which is
exactly what cosine measures.

Cosine collections **normalize every vector on insert**. That is what makes a
query a bare dot product rather than a division by two magnitudes, and it means
a stored vector is not bit-identical to the one you handed over — only its
direction is preserved. If you need the original magnitude back, keep it in the
payload, or use `metric_dot`.

The metric is recorded in the file, and reopening with a *different* metric is
an error rather than a silent reinterpretation (§7) — the two rank in opposite
directions, so quietly serving the wrong one would return confidently ordered,
wrong results.

---

## 3. Adding vectors

There is no vector literal in tuonelang. Build one by pushing floats in order:

```tuo
fn v3(take a: Float, take b: Float, take c: Float) -> Array[Float] {
    var xs = std::array::empty();
    std::array::push(xs, a);
    std::array::push(xs, b);
    std::array::push(xs, c);
    xs
}
```

For a real 384- or 1536-wide embedding, push in a loop from wherever your
numbers come from. Then:

```tuo
let row = vec::db::add(store, v3(1.0, 0.0, 0.0), "doc-1", "the text of document 1");
```

Three things to know about `add`:

1. **It returns the row index, or `-1` on refusal.** It refuses a vector that is
   not exactly `dim` long, or that contains a NaN or an infinity. Check it if
   your vectors come from anywhere you do not fully control:

   ```tuo
   if vec::db::add(store, embedding, id, text) < 0 {
       // wrong width, or a non-finite component
   }
   ```

2. **The payload is yours.** It is an opaque string handed back at query time.
   Putting the source text there is what makes this enough to build retrieval on
   without a second store to join against. It can be empty, and it can be large.

3. **The id is not unique.** `add` will happily store the same id twice. Use
   `upsert` when you mean "replace if present":

   ```tuo
   let row = vec::db::upsert(store, embedding, "doc-1", "the new text");
   ```

   `upsert` inserts when the id is new, replaces when it is not, and — when the
   replacement is refused — **leaves the existing row untouched**, so a `-1`
   really does mean nothing changed.

### Non-finite components are rejected

A NaN compares false to everything, so a stored NaN can never be displaced from
a ranking: it would silently outrank every real row, and with `k = 1` evict the
true best answer entirely. Rather than let that into the index, `add` refuses
it. Extreme but *finite* vectors are fine — a `1e200`-magnitude vector
normalizes correctly and does not overflow.

---

## 4. Searching

```tuo
let hits = vec::db::query(store, v3(1.0, 0.0, 0.0), 5);
```

That scores every live row and returns the best 5, **ordered best-first**. Read
them back through the collection, which turns row indices into your ids and
payloads:

```tuo
var i = 0;
while i < vec::search::hit_count(hits) {
    let id = vec::db::hit_id(store, hits, i);
    let text = vec::db::hit_payload(store, hits, i);
    let score = vec::search::hit_score(hits, i);
    i = i + 1;
}
```

`vec::db::render_hit(store, hits, i)` gives you `"doc-1  0.923"` in one call
when you just want to print it.

### Scores, and which direction is "good"

`hit_score` is in the **metric's own orientation**: higher is better for cosine
and dot, lower is better for L2. If you would rather not think about that,
`vec::search::hit_distance(hits, i)` normalizes it so **lower is always closer**,
whatever the metric.

For cosine, a score is the cosine of the angle:

| Score | Meaning |
|-------|---------|
| `1.0` | identical direction |
| `0.0` | orthogonal — unrelated |
| `-1.0` | opposite direction |

### Filtering by relevance

`k` alone will happily return five bad matches when only one good one exists.
To cut by quality, give a threshold:

```tuo
let hits = vec::db::query_above(store, embedding, 10, 0.75);
```

The threshold is read in the metric's own orientation — a *minimum* similarity
for cosine and dot, a *maximum* squared distance for L2 — and a hit exactly at
the threshold is admitted. For cosine, `0.7`–`0.8` is a reasonable starting
point for "actually related", but it is corpus-dependent: measure it against
known-good pairs rather than trusting a number from a guide.

---

## 5. Removing and compacting

```tuo
let gone = vec::db::remove(store, "doc-1");   // true when a row went away
```

A removal is a **tombstone**: the row keeps its slot and is skipped by search.
That is deliberate — compacting would renumber every later row and invalidate
any index you were holding.

The space comes back when you compact, which happens automatically on save
(§6), or explicitly at the store layer:

```tuo
let fresh = vec::store::compact(inner);   // survivors renumbered, ids unchanged
```

Note the two counts this creates:

```tuo
vec::db::count(store)      // live rows — what a search will consider
vec::db::row_bound(store)  // rows including tombstones — the bound for a loop
```

To walk the whole collection, loop to `row_bound` and skip the dead:

```tuo
var i = 0;
while i < vec::db::row_bound(store) {
    if vec::db::is_live(store, i) {
        let id = vec::db::id_at(store, i);
    }
    i = i + 1;
}
```

---

## 6. Saving and loading

```tuo
let n = vec::db::save(store);              // to the path it was opened from
let n = vec::db::save_as(store, "/tmp/snapshot.tvec");   // to anywhere
```

Both return the byte count written, or a negative value on failure (§7). An
in-memory collection has no path, so `save` on one reports `0` and does
nothing — which lets you write one program and decide persistence at open time.

A save **drops tombstones**, so saving and reloading is also how you reclaim
space. Loading is just `open` again with the same dimension and metric.

Three properties worth knowing:

- **Ranking survives a round trip.** A search over reloaded vectors returns the
  same rows in the same order, with scores equal to within the encoding's
  precision. The acceptance oracle checks exactly this.
- **Saving is verified.** `save_verified` (which `save` uses) writes a
  temporary, reads it back, checks it decodes to the expected row count, and
  only then replaces the target. A failure leaves your existing file untouched.
- **Components are fixed-point, not IEEE bytes.** tuonelang v0 cannot
  reinterpret a float's bits, so a component is stored as `round(x * 2^30)`.
  Round-trip error is about `5e-10` — far below anything an embedding means —
  but values below roughly `9e-10` quantize to zero, and magnitudes above `1e9`
  cannot be represented at all (§7). Normalized cosine vectors, which live in
  `[-1, 1]`, are never near either edge.

---

## 7. When things go wrong

The library's rule is that **out of range is a value, not a crash**. Reading
past the end of a result set, indexing a row that does not exist, or querying a
collection that failed to open all produce a neutral answer rather than
aborting. What you must check explicitly is the following.

### Opening

```tuo
if !vec::db::is_ok(store) {
    let _ = std::rt::write_string(1, vec::db::error(store));
}
```

`error` explains which of these happened:

| Situation | Reported |
|-----------|----------|
| File is not there | opens clean and empty — this is not an error |
| Not a `TVEC` file | `"not a TVEC file: bad magic"` |
| Written by a newer format | `"unsupported TVEC format version"` |
| Wrong dimension requested | `"dimension mismatch: the file holds 3-dimensional vectors, but 4 was requested"` |
| Wrong metric requested | `"metric mismatch: the file was written for cosine, but l2 was requested"` |

`vec::db::as_error(store)` gives the same thing as a `db::error::PgError`, if
you are already branching on error kinds elsewhere in your program.

### Saving

`save` and `save_as` return a negative value on failure, and the value says what
went wrong:

| Value | Meaning |
|-------|---------|
| `-2` | the file could not be opened (bad path, no permission) |
| `vec::disk::err_unrepresentable()` (`-101`) | a component exceeds `1e9` and this format would silently clamp it |
| `vec::disk::err_verify_failed()` (`-102`) | the bytes did not read back as written |

The `-101` case is reachable only from `l2` and `dot` collections, which keep
magnitude deliberately; cosine normalizes everything to length 1. It is an
error rather than a silent clamp precisely because a clamped vector is a wrong
vector that reports success.

### Adding

`add` and `upsert` return `-1` for a wrong-width or non-finite vector. Nothing
is stored, and for `upsert` nothing existing is disturbed.

---

## 8. What this does not do

Stated plainly, because knowing the boundary is part of using it well:

- **No embedding model.** This stores and searches vectors; producing them is
  someone else's job.
- **No approximate index.** Search is an exact linear scan — O(N·D) per query.
  In practice that is excellent to roughly 10⁵ vectors (2000×384 with 100
  queries runs in about 0.2s) and honest beyond it. There is no HNSW or IVF
  here, so do not look for a `vec::index` module.
- **No metadata filtering.** A payload is opaque. Filter the hits yourself.
- **No concurrency.** A collection is a value, not a shared server.

---

## 9. A complete program

Retrieval end to end: build a collection, persist it, reload it, and query.

```tuo
module notes;

/// Build a 3-D vector. Real embeddings are pushed in a loop.
fn v3(take a: Float, take b: Float, take c: Float) -> Array[Float] {
    var xs = std::array::empty();
    std::array::push(xs, a);
    std::array::push(xs, b);
    std::array::push(xs, c);
    xs
}

fn main() -> Int {
    let path = "/tmp/notes.tvec";

    // Build and persist.
    var store = vec::db::open(path, 3, vec::metric::metric_cosine());
    if !vec::db::is_ok(store) {
        let _ = std::rt::write_string(1, vec::db::error(store));
        return 1;
    }

    let _ = vec::db::upsert(store, v3(1.0, 0.0, 0.0), "red", "a note about red");
    let _ = vec::db::upsert(store, v3(0.0, 1.0, 0.0), "green", "a note about green");
    let _ = vec::db::upsert(store, v3(0.9, 0.1, 0.0), "crimson", "a note about crimson");

    if vec::db::save(store) < 0 {
        let _ = std::rt::write(1, "could not save\n");
        return 1;
    }

    // Reload from disk and search it.
    var reloaded = vec::db::open(path, 3, vec::metric::metric_cosine());
    if !vec::db::is_ok(reloaded) {
        let _ = std::rt::write_string(1, vec::db::error(reloaded));
        return 1;
    }

    let hits = vec::db::query_above(reloaded, v3(1.0, 0.0, 0.0), 5, 0.5);

    var i = 0;
    while i < vec::search::hit_count(hits) {
        let line = vec::db::render_hit(reloaded, hits, i);
        let _ = std::rt::write_string(1, line);
        let _ = std::rt::write(1, "\n");
        i = i + 1;
    }

    let _ = vec::disk::remove(path);
    0
}
```

Run it:

```bash
tuo run notes.tuo src/db/*.tuo src/vec/*.tuo
```

Output — `green` is filtered out by the `0.5` threshold, being orthogonal to
the query:

```
red  1.000
crimson  0.994
```

---

## 10. Where to go next

- [`VECTORS.md`](VECTORS.md) — the full API surface, the language rules that
  bite, and the anti-patterns that do not compile. Read this before asking a
  model to generate tuonelang against the library.
- [`examples/vector_check.tuo`](../examples/vector_check.tuo) — the acceptance
  oracle. It is also the most thorough worked example of the API under real
  conditions, including every failure path in §7.
- The module headers in [`src/vec/`](../src/vec/) — each explains why its layer
  is shaped the way it is, which is usually the fastest answer to "why can't I
  just…".
