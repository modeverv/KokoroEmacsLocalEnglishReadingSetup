# Handoff: `my-read` Vocabulary / Phrase Capture to Org
at this pc, running emacs and kindle. use computer use if you need
## Goal

Add a lightweight vocabulary-capture feature to the existing Emacs `my-read` reading environment.

While reading English text in `my-read`, pressing **`u`** should save the current word or selected phrase into a persistent Org file together with the context in which it appeared.

The important behavior is:

- If there is an active region, save the selected text as a **phrase**.
- If there is no active region, save the **word at point**.
- The same word/phrase must **not create a second top-level entry**.
- If the word/phrase already exists, merge into the existing entry and append the newly encountered usage example.
- Repeated encounters should therefore accumulate multiple real examples from books the user has actually read.
- Keep the implementation simple and text-first. **Do not introduce SQLite yet.**
- The Org file is the canonical datastore.

The long-term idea is to grow a personal corpus/dictionary from actual reading history.

---

## Existing codebase: inspect before implementing

Before writing new code, inspect the existing `my-read` implementation and reuse its current mechanisms wherever possible.

In particular, locate:

1. the keymap used while reading;
2. the current book-title / document-title state;
3. the lookup implementation used for dictionary lookup;
4. the Google Translate / translation implementation;
5. sentence detection / current sentence movement logic, if already available;
6. any existing async callbacks, timers, buffers, or post-frame UI used by lookup/translation.

Do **not** create a second independent dictionary or translation stack if the project already has reusable functions.

Prefer small adapter functions around the existing implementation.

---

## User interaction

### Key

Bind:

```text
u
```

in the relevant `my-read` reading-mode keymap.

Do not make the binding global.

### Case A: no active region

When point is on a word:

```text
... she felt a strange anxiety about the situation ...
                       ^
```

pressing `u` captures:

```text
anxiety
```

### Case B: active region

If the user selects:

```text
in spite of
```

and presses `u`, capture the whole selected phrase:

```text
in spite of
```

Trim leading/trailing whitespace.

Multiline regions should be normalized sensibly, preferably by collapsing runs of whitespace to a single space.

---

## Data to save

For each captured word or phrase, save at least:

- word or phrase itself;
- its meaning / dictionary result;
- date/time encountered;
- book title;
- the complete English sentence containing it;
- Japanese translation of that sentence.

If a useful source position is already available cheaply, also save it, for example:

- Kindle page/location;
- source buffer position;
- chapter;
- URL/ASIN;
- other existing reading metadata.

Position information is optional for the first version. Do not invent a large location subsystem just for this feature.

---

## Canonical Org file

Introduce a configurable variable, for example:

```elisp
(defcustom my/read-vocabulary-file
  (expand-file-name "~/my-read/vocabulary.org")
  ...)
```

Use the project's existing naming conventions if they differ.

Create the file and parent directory when necessary.

The Org file must remain ordinary human-readable Org text and should be usable without the package.

---

## Org structure

Use **one top-level heading per unique word or phrase**.

Example:

```org
* anxiety
:PROPERTIES:
:TYPE: word
:CREATED: [2026-08-23 Sun 07:20]
:UPDATED: [2026-08-23 Sun 07:26]
:COUNT: 2
:END:

** Meaning
anxiety
不安、心配、不安感

** Examples

*** [2026-08-23 Sun 07:20] Some Light Novel Vol. 1
:PROPERTIES:
:BOOK: Some Light Novel Vol. 1
:END:

English:
She felt a strange anxiety about what would happen next.

Japanese:
彼女は次に何が起こるのか、妙な不安を感じていた。

*** [2026-08-23 Sun 07:26] Some Light Novel Vol. 2
:PROPERTIES:
:BOOK: Some Light Novel Vol. 2
:END:

English:
His anxiety vanished the moment she smiled.

Japanese:
彼女が微笑んだ瞬間、彼の不安は消えた。
```

Phrase example:

```org
* in spite of
:PROPERTIES:
:TYPE: phrase
:CREATED: [2026-08-23 Sun 08:10]
:UPDATED: [2026-08-23 Sun 08:10]
:COUNT: 1
:END:

** Meaning
〜にもかかわらず

** Examples

*** [2026-08-23 Sun 08:10] Some Light Novel Vol. 1

English:
In spite of everything, she decided to go.

Japanese:
あらゆる事情にもかかわらず、彼女は行くことに決めた。
```

Exact cosmetic formatting may be adjusted to match the existing project, but preserve the logical structure.

---

## Merge behavior

This is the most important requirement.

Do **not** simply append another top-level entry at EOF every time.

On `u`:

1. determine the capture key (word or selected phrase);
2. normalize it for lookup;
3. search the vocabulary Org file for an existing corresponding top-level heading;
4. if none exists:
   - create a new top-level entry;
   - write metadata;
   - write `Meaning`;
   - create `Examples`;
   - add the first example;
5. if one already exists:
   - reuse the existing heading;
   - increment `COUNT`;
   - update `UPDATED`;
   - append another example below `Examples`;
   - do not duplicate the top-level heading.

Conceptually:

```text
capture
   |
   +-- new term ------> create term + meaning + first example
   |
   `-- existing term -> increment metadata + append example
```

---

## Matching / normalization

Top-level uniqueness should be robust enough to avoid accidental duplicates.

Suggested normalization for the lookup key:

- trim surrounding whitespace;
- collapse internal whitespace for phrases;
- case-fold for matching;
- strip obvious surrounding punctuation;
- preserve the original captured spelling for display where practical.

For example, these should normally resolve to the same vocabulary entry:

```text
Anxiety
anxiety
anxiety,
```

Do not aggressively stem or lemmatize in v1.

For example:

```text
run
running
ran
```

may remain separate entries.

That behavior is preferable to adding unreliable NLP complexity now.

---

## Meaning lookup

For the word/phrase meaning, reuse the existing lookup functionality.

Desired behavior:

- word: obtain the same useful dictionary result that `my-read` currently shows to the user;
- phrase: use the existing lookup mechanism if it supports phrases;
- if phrase dictionary lookup is not useful, falling back to a translation/meaning of the selected phrase is acceptable.

The capture operation should not fail merely because dictionary lookup returns no result.

If no meaning is available, still create the entry and leave a clear placeholder or empty `Meaning` section.

Example:

```org
** Meaning
```

rather than aborting the capture.

---

## Sentence context

Capture the full sentence containing the selected word/phrase.

Prefer reusing existing sentence-boundary logic from `my-read`.

If none exists, implement a small helper using Emacs sentence functions such as:

```elisp
(bounds-of-thing-at-point 'sentence)
```

or an equivalent approach appropriate to the buffer contents.

Important:

- save the original English sentence;
- normalize accidental line breaks if the reading buffer wraps or OCR inserts newlines;
- do not accidentally capture the entire paragraph unless sentence detection genuinely fails.

If a phrase selection spans sentence boundaries, saving the selected surrounding text/context is acceptable, but ordinary one-sentence selections should produce one containing sentence.

---

## Japanese translation

Translate the captured English sentence using the translation path already used by `my-read`.

Save the resulting Japanese translation in the example entry.

Again, capture should degrade gracefully:

- if translation fails, save the English example anyway;
- do not lose the vocabulary item because a network call or translator failed.

---

## Book title

Reuse the book/document title already known by `my-read`.

Do not ask the user for the title on every capture.

If no title is available, use a stable fallback such as:

```text
Unknown source
```

but first inspect the project because the title is likely already stored somewhere.

---

## Suggested internal API

Names are illustrative; follow current project conventions.

A clean decomposition could look like:

```elisp
(my/read-vocab-capture)
(my/read-vocab-target-at-point)
(my/read-vocab-normalize-key text)
(my/read-vocab-current-sentence)
(my/read-vocab-current-book-title)
(my/read-vocab-lookup-meaning text callback)
(my/read-vocab-translate-sentence sentence callback)
(my/read-vocab-find-entry key)
(my/read-vocab-create-entry data)
(my/read-vocab-append-example entry data)
```

The public interactive command should preferably be just one function:

```elisp
M-x my/read-vocab-capture
```

and `u` should call it.

Do not expose unnecessary implementation commands.

---

## Async behavior

The existing lookup/translation code may be asynchronous.

If so, preserve that architecture rather than blocking Emacs unnecessarily.

A reasonable workflow is:

```text
u pressed
  -> collect term + sentence + title + timestamp
  -> obtain meaning
  -> obtain sentence translation
  -> update vocabulary.org
  -> show a short success message
```

If meaning and translation can be fetched independently, they may run independently and join before writing.

However, simplicity is more important than clever concurrency.

Most importantly, prevent a race where two rapid captures corrupt the Org file.

Use normal Emacs buffer editing and saving rather than raw concurrent file appends.

---

## Feedback to the user

After a successful capture, show a small minibuffer message, e.g.:

```text
Vocabulary saved: anxiety (3 examples)
```

For a new entry:

```text
Vocabulary added: anxiety
```

Do not switch the user's current window away from the reading buffer.

It is fine to use `find-file-noselect` / `with-current-buffer` and update the vocabulary file invisibly.

---

## Failure behavior

The command should handle common cases cleanly.

### No word at point

If there is no active region and no usable word at point:

```text
No word or phrase at point
```

and do nothing.

### Translation unavailable

Still save:

- term;
- date;
- title;
- English sentence;
- meaning if available.

### Lookup unavailable

Still save:

- term;
- date;
- title;
- sentence;
- translation if available.

### Vocabulary file malformed

Avoid silently destroying user data.

If the expected heading structure cannot be edited safely, report an error and leave the file intact.

---

## Do not overengineer v1

Explicitly avoid these for the initial implementation:

- SQLite;
- a database abstraction layer;
- Anki synchronization;
- spaced-repetition scheduling;
- automatic capture of every word on the page;
- stemming / lemmatization;
- embeddings;
- LLM classification;
- automatic difficulty scoring;
- background corpus indexing.

The purpose of v1 is simply:

```text
"I encountered this and want to remember it."
```

The human presses one key to mark that fact.

---

## Future compatibility

Although SQLite is intentionally not used now, keep the Org format regular enough that a later Python script can parse it.

Potential future analyses include:

- most frequently captured words;
- words repeatedly captured across different books;
- number of encounters per term;
- terms encountered recently;
- books producing the most vocabulary;
- phrase vs word counts;
- vocabulary growth over time.

The Org file is the source data; derived statistics can be produced later by Python.

---

## Tests

Add ERT tests where reasonable, especially for pure/text manipulation behavior.

At minimum test:

### 1. Target selection

- no region -> word at point;
- active region -> region text;
- whitespace normalization.

### 2. Key normalization

Input:

```text
 Anxiety,
```

matches an existing:

```text
anxiety
```

entry.

### 3. New entry

Capturing a previously unseen word creates exactly one top-level heading with:

- `TYPE`;
- `CREATED`;
- `UPDATED`;
- `COUNT: 1`;
- `Meaning`;
- one example.

### 4. Existing entry

Capturing the same word again:

- does not create a second top-level heading;
- increments `COUNT`;
- updates `UPDATED`;
- adds one new example.

### 5. Phrase

An active-region phrase creates a phrase entry and records it as `TYPE: phrase`.

### 6. Missing lookup/translation

Failure or empty result from either service must not prevent the Org capture.

---

## Acceptance criteria

The implementation is complete when all of the following are true:

- [ ] `u` is bound inside the appropriate `my-read` reading keymap.
- [ ] With no region, `u` captures the word at point.
- [ ] With an active region, `u` captures the selected phrase.
- [ ] The current English sentence is captured.
- [ ] The book title is captured from existing `my-read` state.
- [ ] The date/time is recorded.
- [ ] Existing lookup logic is reused for meaning where possible.
- [ ] Existing translation logic is reused to store a Japanese sentence translation.
- [ ] Data is stored in a configurable Org file.
- [ ] One top-level heading represents one normalized word/phrase.
- [ ] Repeated capture merges into the existing entry.
- [ ] Every repeated encounter appends another example.
- [ ] `COUNT` is incremented.
- [ ] `UPDATED` is refreshed.
- [ ] The reading window is not disrupted.
- [ ] Missing dictionary/translation results do not lose the capture.
- [ ] No SQLite dependency is introduced.
- [ ] Relevant ERT tests pass.
- [ ] Existing `my-read` lookup, translation, `j/k` navigation, and reading behavior remain working.

---

## Implementation preference

Keep the patch small and idiomatic Emacs Lisp.

Before modifying code:

1. inspect the repository;
2. identify existing functions/variables to reuse;
3. identify the correct keymap;
4. implement the smallest coherent solution;
5. add tests;
6. run the existing test suite as well as the new tests;
7. report which files were changed and any assumptions made.

Do not rewrite unrelated parts of `my-read`.

If the actual repository architecture conflicts with a function name or example in this handoff, preserve the **behavioral requirements** above rather than forcing the suggested names.
