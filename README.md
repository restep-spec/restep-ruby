# restep (Ruby)

[Restep 1](https://w3id.org/restep/1/) for Ruby (draft 7: discovery declares
`"restep": "1.0-draft.7"`), on Rack and Active Record. It is the protocol part, with no domain:
you declare your collections and their Active Record models; the gem parses the request in the
order of §5.4 and answers discovery, lists with filters, sort and cursors, reads, writes, ETags and
conditional requests, idempotency and problem+json errors. Use it as a single Rack application or
inside Rails controllers.

```bash
gem install restep
```

or in your `Gemfile`:

```ruby
gem "restep"
```

Ruby 3.4 or later, Rack 3 and Active Record 8. The SQL it writes is for **PostgreSQL** (see
[Limits](#limits)).

## Declare the collections

```ruby
require "restep"

GENRES = %w[essay novel poetry].freeze

BOOKS = Restep::Collection.new(
  name: "books", path: "/books", model: "Book",          # the Active Record model, by name
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
    "genre" => { "type" => "enum", "values" => GENRES, "ops" => %w[eq ne in], sql: "genre" }
  },
  sort: { "title" => { sql: "title", type: "string" } }
)

Restep.configure do |c|
  c.collections = { "books" => BOOKS }
  c.idempotency_model = "IdempotencyKey"   # table of Idempotency-Key records (§7.1)
  c.cursor_key_path = "config/cursor.key"  # created on first use; or set RESTEP_CURSOR_SECRET
  c.docs_path = "DOCS.md"                  # served at /docs, linked from discovery (optional)
  c.root_path = "/v1"                      # API root; links include it, discovery paths do not
end
```

The model needs `created_at` and `updated_at`; the gem sets them. Field types: `id`, `string`,
`enum`, `integer`, `decimal` (with `scale`), `boolean`, `date`, `datetime` and `relation` (to-one,
with `relation:` naming the target collection and `column:` the foreign key).

## With Rack

```ruby
# config.ru
require_relative "app"   # the declarations above and the Active Record connection

use Restep::Envelope     # 501 for unknown methods, CORS preflight, profile link and CORS headers
run Restep::RackApp.new(logger: Logger.new($stderr))
```

`Restep::RackApp` is a single entry point: it resolves the resource itself and reports errors
within the precedences of §5.4 (404, 405, 400, 415, 413, 406, then 412, 422 and 409; a replay or a
409 `request_in_progress` in place of 412 and of the errors that depend on the stored item).

## With Rails

```ruby
# config/application.rb
require "restep/rails/controller"
require "restep/rails/routes"

config.middleware.delete Rack::ETag               # Restep sets its own validators
config.middleware.delete Rack::ConditionalGet
config.middleware.insert_before 0, Restep::Envelope
config.exceptions_app = Restep::Rails::Controller.exceptions_app

# app/controllers/books_controller.rb
class BooksController < ApplicationController
  include Restep::Rails::Controller
  before_action :set_record, only: %i[show update destroy]
  before_action { @restep = restep_context(kind: @record ? :item : :collection, collection: BOOKS, record: @record) }

  def index = render_restep(Restep::Operations.list(@restep))
  def show = render_restep(Restep::Operations.show(@restep))
  def create = render_restep(Restep::Operations.create(@restep))
  def update = render_restep(Restep::Operations.update(@restep))
  def destroy = render_restep(Restep::Operations.destroy(@restep))

  private

  def set_record = @record = Restep::Resolver.find!(BOOKS, params[:id])
end
```

The concern adds the 414 and exact-path checks as `before_action`s, turns `Restep::Problem` and any
other exception into problem+json, and writes the operation's status, headers and body as they are
(`render_restep`). Restep reads the raw query string and body, not `params`. In
`config/routes.rb`, `restep_action :books, :archive` routes a §11.1 action (`/books/7:archive`),
which the Rails router cannot express on its own; anything without a route should go to a fallback
controller that calls `Restep::Resolver.resolve` and raises `Restep::Resolver.method_not_allowed`,
so that 404 comes before 405.

## API

### `Restep.configure`

| Option | What it is |
|---|---|
| `collections` | `{ "name" => Restep::Collection }`: the collections of the API |
| `singletons` | `{ "name" => Restep::Collection }` built with `singleton: true` (§5.9) |
| `reasons` | Catalogue of domain reasons for 409 and 422 (§5.4), published in discovery |
| `idempotency_model` | Active Record model, or its name, that stores `Idempotency-Key` records (§7.1) |
| `cursor_key_path` | File with the cursor secret, created if missing. `RESTEP_CURSOR_SECRET` takes precedence |
| `docs_path` | Human documentation, served at `/docs` with `rel="service-doc"` (§4.2) |
| `root_path` | Path of the API root without the final slash: `""` (default) or `"/v1"` (§2) |

### `Restep::Collection.new`

| Argument | What it is |
|---|---|
| `name`, `path`, `description` | Name in discovery, path relative to the API root, description |
| `model` | Name of the Active Record model, resolved on first use |
| `fields` | `Restep::Fields.f(name:, type:, ...)`: `column`, `values`, `nullable`, `required`, `default`, `read_only` (a field only the server sets, other than `id`: a POST ignores it whatever its value, a PATCH accepts only its current value, so no request sets it, §5.1), `max_length`, `pattern`, `range`, `scale`, `relation`, `description` |
| `filters` | `{ "field" => { "type", "ops", sql: "column" } }`; `id_like: true` for ids compared as strings; `"required" => true` for a filter every list request must carry (§6.1). Operators: `eq`, `ne`, `lt`, `le`, `gt`, `ge`, `in`, `nin`, `null`, and `prefix` and `contains` on strings (by code points) |
| `named_filters` | `{ "name" => { "description", sql: ->(value) { ["SQL ?", value] } } }` (§6.1); a switch (no `"type"`) may declare `"default" => true`, which applies to every list request unless it sends `filter[name]=false`, and any named filter `"required" => true` |
| `sort` | `{ "field" => { sql: "column", type: "string" } }` |
| `max_limit`, `default_limit` | Page size limits (§6.4) |
| `conflicts` | `{ unique: ->(rec) { Problem }, foreign_key: ->(rec) { Problem } }`: the 409 for a database constraint |
| `actions` | `Restep::Fields.action(name, on: "item" \| "collection", method:, safe:, idempotent:, input:, output:, effects:, available:, unavailable:, run:)` (§11.1) |
| `singleton` | `true` for a singleton |
| `method_effects` | Only on a singleton: the effects of its `PATCH`, `{ "PATCH" => [] }` or a list out of `destroys`, `external` and `charges` (§4.3, §5.9); left out, a client counts all three |

### Actions (§11.1)

`Restep::Fields.action` checks the declaration when the domain loads: only a safe action uses
`GET`, a safe one is also idempotent, `new` is reserved for the safe `GET` collection action that
gives the starting values of a new item, `changes` is reserved, and `effects` takes `destroys`,
`external` and `charges` (a safe action, only `charges`). `output` is the schema of a safe action's
result. At run time:

- an item action's `run` changes the item, and the gem answers 200 with the item, its new `ETag` and
  `Content-Location`, or, with `Prefer: return=minimal`, 204 without `ETag`;
- a collection action's `run` returns `[status, body]`: an unsafe one answers 201 or 204, a safe one
  200 only with a declared `output` (anything else is a 500, as a programming error);
- an action declared `idempotent: true` ignores `Idempotency-Key`, a malformed one too;
- a `GET` action takes no `params`, so it answers any query parameter with `400
  unsupported_parameter` (§5.3, §11.1);
- a replay of an action's `200` (or of a `201`) after the item changed carries the item's current
  representation, with its `ETag`, `_etag` and `Content-Location`, never the stored body with
  validators that are no longer true (§7.1);
- a replay of a response without a body (a `201` with `Prefer: return=minimal`) keeps its status
  and `Location` but carries no `ETag`, even when the item still exists: the client reads the item
  at `Location` (§7.3).

Integer filter operands follow the number grammar of RFC 8259 §6, exponent included: `20`, `20.0`
and `2e1` are the same operand, and `+20`, `.5`, `020`, `0x14` and `20.5` give `400
invalid_parameter` (§6.1). An operand of more than 8192 digits is over the gem's limit (§5.3) and
gives `invalid_parameter` too, with the limit in `detail`; it is never replaced by another value.
Within it, an operand is compared exactly, even outside the field's range.

### Pieces

| Constant | What it does |
|---|---|
| `Restep::RackApp` | Single-entry-point Rack application |
| `Restep::Envelope` | Outer middleware: 501, CORS preflight, profile link and CORS on every response |
| `Restep::Rails::Controller` | Concern for Rails controllers: `restep_context`, `render_restep`, `rescue_from`, `exceptions_app` |
| `Restep::Rails::Routes` | `restep_action` for `config/routes.rb` |
| `Restep::Operations` | `discovery`, `list`, `show`, `create`, `update`, `destroy`, `action`, `status`, `docs`: each returns `[status, headers, body]` |
| `Restep::Resolver` | Steps 1 and 2 of §5.4: which resource a path names (404) and which methods it allows (405) |
| `Restep::Context` | Steps 3 and 4: reserved parameters, headers, body and `Accept` (400, 415, 413, 406), and 414 |
| `Restep::Problem` | A Restep error; `raise Restep::Problem.new(409, "conflict", reason: "...", detail: "...")`. The codes are the closed table of §5.4 (`Restep::Problem::CODES`); a status it does not list takes `http_` and its digits (`Restep::Problem.new(431, nil)`), and a code that does not go with its status raises `ArgumentError`. Every problem is `no-store` and never carries `CDN-Cache-Control` |
| `Restep::Query`, `Restep::Cursor`, `Restep::Conditional`, `Restep::Idempotency`, `Restep::Discovery` | Query parsing and SQL, encrypted keyset cursor, preconditions, idempotency, discovery |

## Limits

- **PostgreSQL.** Filters and cursors write PostgreSQL casts (`::bigint`, `::numeric`, `::date`,
  `::timestamptz`), and idempotency locks its record with `FOR UPDATE NOWAIT`. Text columns should
  use `COLLATE "C"`, because discovery declares the `codepoint` collation for string filters and
  sorts. On SQLite, string and enum filters (`prefix` and `contains` included), sort, cursors, reads and writes without
  `Idempotency-Key` work (that is what the tests use); integer, decimal, date and datetime filters
  and idempotency do not.
- Profiles `core`, `query`, `writes` and `cache`, and the `actions` extension. No `include`,
  subcollections, `sync`, `batch`, `filter-expr`, `query-method`, `oauth` or `inherit`; no language
  maps or localized fields, local date-times, durations, `upload`, `upsert` or `reusable_ids`;
  filters do not go through to-many relationships (`quantifier`); actions take no `params`.
- One anonymous principal: no authentication.
- Ids are generated by the database (`id_from` is `server`).

## Tests

```bash
bundle install
bundle exec rake test
```

The tests serve a small API (books, plus journals for what draft 7 added) on an in-memory SQLite database with
`Restep::Envelope` and `Restep::RackApp`, and check discovery, lists, filters, sort, cursors,
errors, ETags with `If-None-Match` and `If-Match`, and writes. `test/config.ru` serves the same API
to run [restep-check](https://w3id.org/restep/tools/restep-check/) against it:

```bash
RESTEP_TEST_DATABASE=/tmp/restep-test.sqlite3 bundle exec puma test/config.ru   # needs puma
npx restep-check http://localhost:9292/
```

## Code and issues

Code and issues: <https://github.com/restep-spec/restep-ruby>. That repository is generated from the Restep
site, where the tool is developed alongside the [specification](https://w3id.org/restep/1/) and the reference
server.

MIT licensed.
