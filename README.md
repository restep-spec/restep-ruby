# restep (Ruby)

[Restep 1](https://w3id.org/restep/1/) for Ruby (draft 7: discovery declares
`"restep": "1.0-draft.7"`), on Rack. It is the protocol part, with no domain: you declare your
collections, their subcollections and where their data comes from (a **source**: an Active Record
model, or lambdas over whatever your domain computes); the gem parses each request in the order of
§5.4 and answers discovery, lists with filters, sort, cursors and `include`, reads, writes, ETags
and conditional requests, idempotency and problem+json errors. Use it as a single Rack application
or inside Rails controllers. Discovery is generated from the catalog, or served from a document you
write, which the gem validates at boot and then enforces.

```bash
gem install restep
```

or in your `Gemfile`:

```ruby
gem "restep"
gem "json_schemer"   # only to serve a hand-written discovery document (validated against its schema)
```

Ruby 3.4 or later and Rack 3. Active Record 8 is optional: it is needed only by
`Restep::Sources::ActiveRecord` and `Restep::Idempotency::ActiveRecordStore`, and the SQL they write is
for **PostgreSQL** (see [Limits](#limits)).

## Declare the collections

A collection says its fields, what can be filtered and sorted, and its source. With Active Record:

```ruby
require "restep"
require "active_record"

GENRES = %w[essay novel poetry].freeze

BOOKS = Restep::Collection.new(
  name: "books", path: "/books", model: "Book",          # shorthand for source: Restep::Sources::ActiveRecord.new("Book")
  description: "Books in the library.",
  max_limit: 50, default_limit: 20,
  fields: [
    Restep::Fields.f(name: "id", type: "id", read_only: true),
    Restep::Fields.f(name: "title", type: "string", required: true, max_length: 120),
    Restep::Fields.f(name: "genre", type: "enum", values: GENRES, required: true),
    Restep::Fields.f(name: "pages", type: "integer", required: true, range: 1..5000),
    Restep::Fields.f(name: "created_at", type: "datetime", read_only: true),
    Restep::Fields.f(name: "updated_at", type: "datetime", read_only: true)
  ],
  filters: {
    "title" => { "type" => "string", "ops" => %w[eq ne lt le gt ge in], sql: "title" },
    "genre" => { "type" => "enum", "values" => GENRES, "ops" => %w[eq ne in] }   # without sql:, the field's column
  },
  sort: { "title" => { sql: "title", type: "string" } }
)
```

### A subcollection

A subcollection's path is a URI template whose variables take, in order, the ids of the parent
items, and it names its `parent` (§4.2). The gem finds each parent under the one before, so
`/company_groups/9/policies/7/drafts` is 404 unless policy 7 belongs to company group 9, and hands
the parents to the source:

```ruby
POLICIES = Restep::Collection.new(
  name: "policies", path: "/company_groups/{company_group}/policies", parent: "company_groups",
  source: Restep::Sources::ActiveRecord.new("Policy", parent_column: "company_group_id"),
  fields: [...]
)

DRAFTS = Restep::Collection.new(
  name: "drafts", path: "/company_groups/{company_group}/policies/{policy}/drafts", parent: "policies",
  source: Restep::Sources::ActiveRecord.new("Draft", parent_column: "policy_id"),
  fields: [...]
)
```

Item paths, `Location`, `next`, `_actions` and `Cache-Groups` carry the parents' ids
(`/company_groups/9/policies/7/drafts/3`); cursors are bound to them. A singleton can hang from an
item too: `path: "/readers/{reader}/settings", parent: "readers", singleton: true`.

### A resource that is not a table

`Restep::Sources::Computed` takes lambdas instead of a model, for resources your domain computes.
Ids are whatever strings your domain uses (document keys, slugs, UUIDs), as long as they are made of
unreserved characters (§3). A record is a Hash or any object with readers. The gem filters, sorts and
pages the records in memory with the rules of §6 (types, absent values, code points, nulls last):

```ruby
SECTIONS = Restep::Collection.new(
  name: "sections", path: "/documents/{document}/sections", parent: "documents",
  description: "Sections of a document, computed from its source.",
  max_limit: 50,
  source: Restep::Sources::Computed.new(
    all: ->(parents) { Documents.load(parents["document"]).sections },   # every item under the parents
    find: ->(id, parents) { Documents.load(parents["document"]).section(id) },     # optional
    create: ->(attrs, parents) { Documents.add_section(parents["document"], attrs) }, # each write is optional:
    update: ->(record, changes) { Documents.change_section(record, changes) },      # the methods follow
    delete: ->(record) { Documents.remove_section(record) }
  ),
  fields: [
    Restep::Fields.f(name: "id", type: "id", read_only: true),
    Restep::Fields.f(name: "heading", type: "string", required: true),
    Restep::Fields.f(name: "level", type: "integer", range: 1..6, default: 1)
  ],
  filters: { "level" => { "type" => "integer", "ops" => %w[eq le] } },       # compares the field of that name
  named_filters: { "top" => { "description" => "Level 1.", match: ->(record, _value) { record.level == 1 } } },
  sort: { "heading" => {} }
)
```

Without `create`, `update` or `delete`, the collection does not declare `POST`, `PATCH` or `DELETE`
and answers them with 405 (§4.3). A filter on a computed value says `value: ->(record) { ... }`.
`transaction: ->(&write) { MUTEX.synchronize(&write) }` (or your domain's transaction) makes
evaluating `If-Match` and applying the write atomic (§7.2); `locate:` and `parent_ids:` let a
relationship point to an item of the collection when it is a subcollection.

For anything else, subclass `Restep::Source` and implement what you offer: `list(query, parents)`
(returning `[records, next_position, total]`; the position is any JSON value, an offset or a keyset,
which the gem encrypts into the cursor), `find(id, parents)`, `find_singleton(parents)`,
`create(attrs, parents)`, `update(record, changes)`, `delete(record)`, and, if writes must be atomic
with their preconditions, `transaction` and `lock(record, parents)`. `query` gives `filters`,
`named`, `sort`, `limit`, `count` and `position`, already validated.
`Restep::Sources::InMemory.page(source, records, query)` applies the in-memory rules to records you
already hold.

### Configure

```ruby
Restep.configure do |c|
  c.collections = { "books" => BOOKS, "policies" => POLICIES, "drafts" => DRAFTS }
  c.cursor_secret = ENV.fetch("RESTEP_CURSOR_SECRET")           # required, shared by every replica
  c.principal = ->(request) { request.env["rack.session"]&.dig("user_id")&.to_s }  # nil: anonymous
  c.idempotency_model = "IdempotencyKey"                        # or idempotency_store: (§7.1)
  c.max_body_bytes = 5 * 1024 * 1024                            # 413 above it (64 KiB by default)
  c.docs_path = "DOCS.md"                                       # served at /docs (optional)
  c.root_path = "/v1"                                           # links include it, discovery paths do not
end
```

`Restep.check!` validates all of it and raises `Restep::ConfigurationError` listing every problem:
a missing cursor secret, a missing idempotency store where there are `POST`s, a path template whose
variables do not match its parents, a filter without its SQL or lambda, and a discovery document
(generated or yours) that breaks the rules of draft 7. `Restep::RackApp.new` and the Rails railtie
call it at boot.

## With Rack

```ruby
# config.ru
require_relative "app"   # the declarations above

use Restep::Envelope     # 501 for unknown methods, profile link, CORS
run Restep::RackApp.new(logger: Logger.new($stderr))
```

`Restep::RackApp` is a single entry point: it resolves the resource itself, subcollections
included, and reports errors within the precedences of §5.4 (404, 405, 400, 415, 413, 406, then 412,
422 and 409; a replay or a 409 `request_in_progress` in place of 412 and of the errors that depend on
the stored item).

## With Rails

```ruby
# config/application.rb
require "restep/rails"   # the concern, restep_action routes and the railtie

config.middleware.delete Rack::ETag               # Restep sets its own validators
config.middleware.delete Rack::ConditionalGet
config.middleware.insert_before 0, Restep::Envelope, cors: false, credentials: true,  # a same-origin, cookie API
                                  path: "/v1"   # only the API: the app's HTML pages keep their params
config.exceptions_app = Restep::Rails::Controller.exceptions_app

# app/controllers/drafts_controller.rb: any route shape, nested or not
class DraftsController < ApplicationController
  include Restep::Rails::Controller
  before_action { @restep = restep_context_for(restep_target) }   # 404 (parents included), 405, then 400-406

  def index = render_restep(Restep::Operations.list(@restep))
  def show = render_restep(Restep::Operations.show(@restep))
  def create = render_restep(Restep::Operations.create(@restep))
  def update = render_restep(Restep::Operations.update(@restep))
  def destroy = render_restep(Restep::Operations.destroy(@restep))
end
```

`restep_target` resolves the raw path with the gem, whatever the route looks like, so
`resources :company_groups { resources :policies { resources :drafts } }` works as is. The railtie
derives the cursor secret from `secret_key_base` with the application's `key_generator` unless
`cursor_secret` is set, and runs `Restep.check!` after boot. The concern adds the 414 and exact-path
checks as `before_action`s, turns `Restep::Problem` and any other exception into problem+json, and
writes the operation's status, headers and body as they are (`render_restep`). Restep reads the raw
query string and body, not `params`. `restep_action :books, :archive` in `config/routes.rb` routes a
§11.1 action (`/books/7:archive`), which the Rails router cannot express on its own; anything without
a route should go to a fallback controller that calls `restep_target`, so that 404 comes before 405.

## A hand-written discovery document

When your discovery document is the contract, give it to the gem instead of letting it generate one:

```ruby
Restep.configure do |c|
  c.discovery = "config/discovery.json"    # or a Hash
  c.collections = {
    # What discovery declares (path, parent, description, filter, named_filters, sort, max_limit,
    # count, methods, relations, include_depth, the actions' on, method, safe, idempotent and effects)
    # comes from the document; the code gives fields, the source and how to run each filter and action.
    "drafts" => Restep::Collection.new(name: "drafts", source: DRAFTS_SOURCE, fields: DRAFT_FIELDS,
                                       named_filters: { "published" => { sql: ->(_) { ["published_at IS NOT NULL"] } } },
                                       actions: [Restep::Fields.action("publish", on: "item", run: ->(draft, _) { draft.publish! })])
  }
end
```

At boot, `Restep.check!` validates the document against
[`discovery.json`](https://w3id.org/restep/1/schema/discovery.json) (with the `json_schemer` gem) and
against the rules of draft 7 the schema cannot express (subcollection templates and parents,
operators by type, named filters that clash with filters, relations to declared collections,
singleton paths...), then binds the catalog to it and fails on any disagreement: a collection,
filter, sort key or action in one and not the other, a value the code says differently, a source
without the writes a declared method needs, inline schemas whose properties are not the fields, or
something the gem does not implement (`sync`, `upload`, `upsert`, `batch`...). The document is then
served as written, and every request is answered by what it declares.

## Choices that depend on your application

| Concern | How |
|---|---|
| Principal (§2) | `c.principal = ->(request) { ... }` returns who the request acts for, a string, or `nil` for the anonymous principal. Idempotency keys and cursors belong to it, and reads become `Cache-Control: private` (§5.1). `c.idempotency_anonymous = false` refuses `Idempotency-Key` without one (§7.1) |
| Cursor secret (§6.4) | `c.cursor_secret` (or `RESTEP_CURSOR_SECRET`; in Rails, derived from `secret_key_base`). Never generated: one per process would break cursors across replicas, so `Restep.check!` fails without it |
| Body limit | `c.max_body_bytes`, or `max_body_bytes:` on one collection |
| CORS (§5.8) | `use Restep::Envelope` (`cors: "*"`, the default), `cors: false` for a same-origin API, or `cors: ["https://editor.example"]` to name origins, with `Vary: Origin`. With `credentials: true` (cookies), unsafe requests a browser sends from any other origin get 403, as §5.8 requires; allowed origins also get `Access-Control-Allow-Credentials`. `exempt: ->(env) { ... }` names the requests the application authenticates only with a token a browser never attaches on its own, which §5.8 does not cover: `exempt: Restep::Envelope.method(:token_authorization?)` takes any `Authorization` scheme but Basic, Digest, Negotiate and NTLM |
| Where the API is | `path: "/v1"` (or a list) on `Restep::Envelope`: only requests under it get the envelope (501, profile link, CORS, the origin check, and Rails' parameter parsing turned off); the rest of the application is left untouched |
| Idempotency store (§7.1) | `c.idempotency_model = "IdempotencyKey"` (PostgreSQL table, see `Restep::Idempotency::ActiveRecordStore`), or `c.idempotency_store = Restep::Idempotency::MemoryStore.new` for one process. `Restep::Idempotency::ActiveRecordStore.new("IdempotencyKey", unique_by: ..., purge_every: 3600)`: the unique index on `(principal, http_method, path, key)` is found by its columns (or pass its name), and every expired key is deleted once per `purge_every` seconds (`nil`: never; call `store.purge` from a job) |

## Relations and language maps

A relation field is a to-one relationship whose object carries `id` and, when its target is a
subcollection, `href` (§3). Saying whether it can be expanded declares the API's relationships and
announces the `relations` profile (§9):

```ruby
Restep::Fields.f(name: "author", type: "relation", column: "author_id", relation: "people", include: true)
```

Then `include=author` fills the object with the related item, `fields=title,author.name` projects
into it, `include_depth:` on the collection allows dotted includes, and a relationship that leads to
a subcollection is declared with `relations: { "reviews" => { "to" => "reviews", "many" => true,
"path" => "/books/{book}/reviews" } }`. To link an item of a subcollection, a write sends its `href`.

A language map (§3) holds the same text in several languages:

```ruby
Restep::Fields.f(name: "title", type: "language_map", languages: %w[en es-es])   # languages: nil accepts any tag
```

It is always an object (`{}` when empty), validated key by key (`format` for a tag that is not
well-formed and lowercase, `type`, `unknown` for a language the field does not take), merged by key
in a `PATCH` (`null` deletes a translation, `{"title": null}` empties it), declared in
`language_maps`, and filtered or sorted by translation (`"title.es-es" => { "type" => "string", ... }`).

## Documents: object and array fields

A field may hold any JSON object or array that the item carries (§3, §4.3): its shape goes in the
`schemas` of discovery, never in the types of §4.2, which are for filters.

```ruby
Restep::Fields.f(name: "layout", type: "object", nullable: true,
                 schema: { "properties" => { "columns" => { "type" => "integer" } } },   # merged into {"type": "object"}
                 validate: ->(value, pointer) { value["columns"].is_a?(Integer) ? nil : [{ "pointer" => "#{pointer}/columns", "code" => "type", "detail" => "An integer." }] })
Restep::Fields.f(name: "tags", type: "array", default: [], schema: { "items" => { "type" => "string" } })
```

- A body's value is checked as an I-JSON message: a string (or a member name) with U+0000 or a
  noncharacter gives `422` with a `format` entry at that string (at `""` for a member name), and a
  number a double cannot hold without losing digits gives `range`; it is never rounded. Numbers
  with a fraction are stored as `Float`, integers stay exact.
- In a `PATCH`, an object merges member by member (RFC 7396: `null` deletes a member) and is then
  validated whole; an array is replaced. A value equal as JSON to the current one changes nothing.
- `validate:` runs on the value after its type (and, in a `PATCH`, after merging) and returns the
  `422` entries, or `nil`. It works on any field.
- The update schema gives an object field only its type, since a merge patch may leave any member
  out or set it to `null`. A filter or sort key never names the whole field: declare a dotted path to
  a member (`layout.columns`) with its own `sql:` or `value:` (§6.1).

## API

### `Restep::Collection.new`

| Argument | What it is |
|---|---|
| `name`, `path`, `description` | Name in discovery, path relative to the API root (a URI template for a subcollection), description |
| `parent` | For a subcollection, or a singleton under an item: the collection (or singleton) it hangs from |
| `model` or `source` | An Active Record model (or its name), or any `Restep::Source` |
| `fields` | `Restep::Fields.f(name:, type:, ...)`: `column`, `values`, `nullable`, `required`, `default`, `read_only` (a field only the server sets, other than `id`: a POST ignores it whatever its value, a PATCH accepts only its current value, §5.1), `max_length`, `pattern`, `range`, `scale`, `relation`, `include`, `languages`, `schema` (object and array fields), `validate`, `description`. Types: `id`, `string`, `enum`, `integer`, `decimal` (with `scale`), `boolean`, `date`, `datetime`, `relation`, `language_map`, `object`, `array` |
| `filters` | `{ "field" => { "type", "ops" } }` plus how to run it: `sql:` (Active Record), `value:` (computed); `"required" => true` for a filter every list request must carry (§6.1). Operators: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `in`, `nin`, `null`, and `prefix` and `contains` on strings (by code points) |
| `named_filters` | `{ "name" => { "description", sql: ->(value) { ["SQL ?", value] } } }`, or `match: ->(record, value) { ... }` on a computed source (§6.1); a switch (no `"type"`) may declare `"default" => true`, and any named filter `"required" => true` |
| `sort` | `{ "field" => { sql: "column", type: "string" } }` (`{}` takes the field's column and type) |
| `max_limit`, `default_limit`, `count` | Page size limits (§6.4) and `"exact"` (the default), `"estimated"` or `nil` (§6.5) |
| `methods`, `item_methods` | What the collection and its items support (§4.3); by default, what the source implements |
| `relations`, `include_depth` | Relationships declared only in discovery, such as one to a subcollection, and how deep `include` goes (§9) |
| `conflicts` | `{ unique: ->(rec) { Problem }, foreign_key: ->(rec) { Problem } }`: the 409 for a database constraint |
| `actions` | `Restep::Fields.action(name, on: "item" \| "collection", method:, safe:, idempotent:, input:, output:, effects:, available:, unavailable:, run:)` (§11.1). A collection action's `run` gets the source's scope for the parents (an Active Record relation, or the parents) |
| `singleton`, `method_effects` | `true` for a singleton, and the effects of its `PATCH` (§4.3, §5.9) |
| `max_body_bytes` | This collection's body limit |

### Actions (§11.1)

`Restep::Fields.action` checks the declaration when the domain loads: only a safe action uses
`GET`, a safe one is also idempotent, `new` is reserved for the safe `GET` collection action that
gives the starting values of a new item, `changes` is reserved, and `effects` takes `destroys`,
`external` and `charges` (a safe action, only `charges`). `output` is the schema of a safe action's
result. At run time, what each kind answers is what §11.1 allows, and anything else is a 500, as a
programming error:

- an unsafe item action's `run` changes the item, and the gem answers 200 with the item, its new
  `ETag` and `Content-Location`, or, with `Prefer: return=minimal`, 204 without `ETag`. If `run`
  returns `Restep::Created.new(location)` (or `Restep::Created.new(location, body)`), the answer is
  201 with that `Location`, such as a new version; if it returns `Restep::NO_CONTENT`, 204;
- an unsafe collection action's `run` returns `Restep::Created.new(location)` (201 with `Location`)
  or `[204, nil]`: a collection has no representation of its own, so never 200, and a 201 always
  carries the `Location` of what it created;
- a safe action's `run` returns `[status, result]`: 200 with the result (on a collection, only with a
  declared `output`), or `[204, nil]`; never 201. With `GET` it is a read, with `ETag` and 304. A safe
  action may use `POST` to take an `input` in its body: that is the way to compute something from
  data the client sends (a diff, a quote), whose 200 is `no-store`, after `If-Match` against the item
  (412) and before the input's 422;

```ruby
Restep::Fields.action("diff", on: "item", safe: true, idempotent: true,          # POST /drafts/7:diff
                      input: [Restep::Fields.f(name: "with", type: "object", required: true)],
                      output: { "type" => "object" },
                      run: ->(draft, input) { [200, draft.diff(input["with"])] })
Restep::Fields.action("publish", on: "item", effects: [],                         # POST /drafts/7:publish
                      run: ->(draft, _) { Restep::Created.new(Restep.url("/versions/#{draft.publish!.id}")) })
```

- an action declared `idempotent: true` ignores `Idempotency-Key`, a malformed one too;
- a `GET` action takes no `params`, so it answers any query parameter with `400
  unsupported_parameter` (§5.3, §11.1);
- a replay of an action's `200` (or of a `201`) after the item changed carries the item's current
  representation, with its `ETag`, `_etag` and `Content-Location`, never the stored body with
  validators that are no longer true (§7.1);
- a replay of a response without a body (a `201` with `Prefer: return=minimal`) keeps its status
  and `Location` but carries no `ETag`, even when the item still exists (§7.3).

Integer filter operands follow the number grammar of RFC 8259 §6, exponent included: `20`, `20.0`
and `2e1` are the same operand, and `+20`, `.5`, `020`, `0x14` and `20.5` give `400
invalid_parameter` (§6.1). An operand of more than 8192 digits is over the gem's limit (§5.3) and
gives `invalid_parameter` too, with the limit in `detail`.

### Pieces

| Constant | What it does |
|---|---|
| `Restep::RackApp` | Single-entry-point Rack application |
| `Restep::Envelope` | Outer middleware: 501, profile link, CORS and the §5.8 origin check |
| `Restep::Source`, `Restep::Sources::ActiveRecord`, `Restep::Sources::Computed`, `Restep::Sources::InMemory` | Where the data comes from |
| `Restep::Rails::Controller` | Concern for Rails controllers: `restep_target`, `restep_context`, `render_restep`, `rescue_from`, `exceptions_app` |
| `Restep::Rails::Routes` | `restep_action` for `config/routes.rb` |
| `Restep::Operations` | `discovery`, `list`, `show`, `create`, `update`, `destroy`, `action`, `status`, `docs`: each returns `[status, headers, body]` |
| `Restep::Resolver` | Steps 1 and 2 of §5.4: which resource a path names, with its parents (404), and which methods it allows (405) |
| `Restep::Context` | Steps 3 and 4: reserved parameters, headers, body and `Accept` (400, 415, 413, 406), and 414 |
| `Restep::Problem` | A Restep error; `raise Restep::Problem.new(409, "conflict", reason: "...", detail: "...")`. The codes are the closed table of §5.4 (`Restep::Problem::CODES`); a status it does not list takes `http_` and its digits, and a code that does not go with its status raises `ArgumentError`. Every problem is `no-store` |
| `Restep::Rules`, `Restep::Discovery` | The rules of draft 7 for a discovery document, its JSON Schema, and the document itself |
| `Restep::Query`, `Restep::Cursor`, `Restep::Conditional`, `Restep::Idempotency`, `Restep::Parents` | Query parsing, encrypted cursor, preconditions, idempotency, the parents of a request |
| `Restep::Body` | `parse(raw, decimal_class: BigDecimal)` parses a raw body as an I-JSON message (400, or an `Unpaired` whose 422 `object!` raises), with no `Restep::Request`; `media_type!(content_type, types)` gives the 415; `read(request, types, accept_ok:, decimal_class:)` does both for anything with `raw_body` and `content_type`; `object!` gives the 422 of a body that is not an object. `decimal_class: nil` gives `Float` |
| `Restep::Conditional` | `parse(name, value)` gives `:any`, a list of entity tags or 400; an empty header is an empty list (RFC 9110 §5.6.1), which no ETag matches. `evaluate(if_match, if_none_match, etag, safe:)` gives `nil`, `:not_modified` or 412 |
| `Restep::QueryString` | `parse(query_string)` keeps repeated names and brackets as received; a `%` that starts no escape gives 400 (RFC 3986 §2.1). `well_formed?`, `decode` |
| `Restep::MergePatch` | `apply(target, patch)`: JSON Merge Patch (RFC 7396) |
| `Restep::Created`, `Restep::NO_CONTENT` | What an action's `run` returns for a 201 with `Location`, or a 204 |

## Namespace

The gem owns the top-level constant `Restep` and every constant under it (`Restep::Problem`,
`Restep::Query`, `Restep::Cursor`, `Restep::Discovery`, `Restep::Rails`...). An application must
not define its own `Restep::*` constants: with Zeitwerk, an `app/*/restep/problem.rb` would be
autoloaded into the gem's module, and since `Restep::Problem` is already defined, Zeitwerk ignores
the file (it is "shadowed") and the application gets the gem's class instead. There is no setting
that avoids this without renaming one of the two, so if your application has a `Restep` namespace,
rename it (for example to `RestepApi` or under your application's own module, such as
`MyApp::Restep`, which Ruby keeps apart from the top-level `::Restep`). Inside such a module,
refer to the gem as `::Restep`.

## Limits

- **PostgreSQL** for Active Record. Filters and cursors write PostgreSQL casts (`::bigint`,
  `::numeric`, `::date`, `::timestamptz`), and the idempotency table locks its record with
  `FOR UPDATE NOWAIT`. Text columns should use `COLLATE "C"`, because discovery declares the
  `codepoint` collation for string filters and sorts. On SQLite, string and enum filters (`prefix`
  and `contains` included), sort, cursors, subcollections, reads and writes work (that is what the
  tests use); integer, decimal, date and datetime filters and the idempotency table do not.
- Profiles `core`, `query`, `writes`, `cache` and `relations`, and the `actions` extension. No
  `sync`, `batch`, `filter-expr`, `query-method`, `oauth` or `inherit`; no localized fields, local
  date-times, durations, `upload`, `upsert` or `reusable_ids`; filters do not go through to-many
  relationships (`quantifier`); relations are to-one and point to one collection; actions take no
  `params`.
- Ids are assigned by the server (`id_from` is `server`).
- Draft 7 only: an API pinned to draft 6 cannot use this version.

## Tests

```bash
bundle install
bundle exec rake test
```

The tests serve two small APIs with `Restep::Envelope` and `Restep::RackApp`: books, journals and
the reviews of a book on an in-memory SQLite database (`test/library.rb`), and shelves of notes kept
in memory with `Restep::Sources::Computed`, with a subcollection, a subcollection of it, a singleton
under an item, relations and language maps (`test/workspace.rb`). Inside the site's repository,
`test/checker_test.rb` also runs [restep-check](https://w3id.org/restep/tools/restep-check/)
`--writes` against the second one, on Puma in the same process. To run the checker by hand:

```bash
bundle exec puma -p 9292 test/workspace.ru
npx restep-check http://localhost:9292/ --writes
```

## Code and issues

Code and issues: <https://github.com/restep-spec/restep-ruby>. That repository is generated from the Restep
site, where the tool is developed alongside the [specification](https://w3id.org/restep/1/) and the reference
server.

MIT licensed.
