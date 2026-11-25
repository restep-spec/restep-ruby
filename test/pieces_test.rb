# The public pieces an application can use on their own (Body.parse, Conditional, QueryString,
# MergePatch, Envelope with path: and exempt:, ActiveRecordStore) and, on the in-memory API of
# test/workspace.rb, fields of type object and array and the responses of actions (§11.1).
require "minitest/autorun"
require "rack/test"
require "json"

require_relative "library" # the books API: restored after each test
require_relative "workspace"

class PiecesTest < Minitest::Test
  include Rack::Test::Methods

  JSON_CT = { "CONTENT_TYPE" => "application/json" }.freeze
  MERGE = { "CONTENT_TYPE" => "application/merge-patch+json" }.freeze

  def setup
    @saved = Workspace.install!
    @envelope_options = {}
    @inner = nil
  end

  def teardown = Restep.reset!(@saved)

  def app
    opts = @envelope_options
    inner = @inner || Restep::RackApp.new
    @app ||= Rack::Builder.new do
      use Restep::Envelope, **opts
      run inner
    end.to_app
  end

  def json = JSON.parse(last_response.body)

  def assert_problem(status, code)
    assert_equal status, last_response.status, last_response.body
    assert_equal code, json["code"]
    json
  end

  def shelf = Workspace.store.shelves.values.find { |s| s["name"] == "Kitchen" }
  def notes_path = "/shelves/#{shelf["id"]}/notes"
  def flour = Workspace.store.notes.values.find { |n| n["title"] == "Buy flour" }
  def flour_path = "#{notes_path}/#{flour["id"]}"

  # ---- QueryString (finding 7) ------------------------------------------------------------

  def test_query_string_refuses_malformed_escapes
    %w[a=%zz a=100% a=%4 %G1=x].each do |qs|
      refute Restep::QueryString.well_formed?(qs), qs
      e = assert_raises(Restep::Problem) { Restep::QueryString.parse(qs) }
      assert_equal [400, "bad_request"], [e.status, e.code]
    end
    pairs = Restep::QueryString.parse("a=100%25&b=x+y&c=%5b%5D")
    assert_equal [["a", "100%"], ["b", "x y"], ["c", "[]"]], pairs.map { |p| [p.name, p.value] }
    # Rack::Test refuses such a URI, so the request goes in by hand.
    status, _, body = app.call(Rack::MockRequest.env_for("/shelves").merge("QUERY_STRING" => "filter[name]=100%zz"))
    assert_equal [400, "bad_request"], [status, JSON.parse(body.each.to_a.join)["code"]]
  end

  # ---- Conditional (finding 4) ------------------------------------------------------------

  def test_if_match_lists_may_be_empty
    p = ->(v) { Restep::Conditional.parse("If-Match", v) }
    assert_equal [], p.("")
    assert_equal [], p.(" , ,")
    assert_equal [[false, "a,,b"], [true, "c"]], p.(%("a,,b" , W/"c",))
    assert_equal :any, p.("*")
    [%("a""b"), %("a" "b"), %(*, "a"), "abc", %("a)].each do |v|
      assert_raises(Restep::Problem, v) { p.(v) }
    end
    # RFC 9110, section 13.1.1: no entity tag of an empty list matches.
    e = assert_raises(Restep::Problem) { Restep::Conditional.evaluate([], nil, %("x"), safe: false) }
    assert_equal 412, e.status
    assert_nil Restep::Conditional.evaluate(nil, [], %("x"), safe: true)
  end

  def test_empty_if_match_gives_412_and_empty_if_none_match_lets_the_write_go_on
    patch flour_path, "{}", MERGE.merge("HTTP_IF_MATCH" => "")
    assert_problem 412, "precondition_failed"
    patch flour_path, "{}", MERGE.merge("HTTP_IF_NONE_MATCH" => "")
    assert_equal 200, last_response.status
  end

  # ---- Body (finding 3) -------------------------------------------------------------------

  def test_body_parse_takes_a_raw_string
    assert_equal({ "a" => BigDecimal("1.5"), "b" => 2 }, Restep::Body.parse(%({"a": 1.5, "b": 2})))
    doc = Restep::Body.parse(%({"a": 1.5, "b": 2}), decimal_class: nil)
    assert_kind_of Float, doc["a"]
    assert_kind_of Integer, doc["b"]
    assert_equal [1, 2], Restep::Body.parse("[1, 2]") # not an object: object! decides
    ["", "{", %({"a": 1, "a": 2}), "\xFF".b].each do |raw|
      e = assert_raises(Restep::Problem, raw.inspect) { Restep::Body.parse(raw) }
      assert_equal 400, e.status
    end
    unpaired = Restep::Body.parse(%({"a": "\\ud800"}))
    assert_kind_of Restep::Body::Unpaired, unpaired
    assert_equal 422, assert_raises(Restep::Problem) { Restep::Body.object!(unpaired) }.status
  end

  def test_body_read_takes_any_request_with_raw_body_and_content_type
    req = Struct.new(:raw_body, :content_type).new(%({"n": 0.1}), "application/json; charset=utf-8")
    assert_equal({ "n" => 0.1 }, Restep::Body.read(req, %w[application/json], accept_ok: true, decimal_class: nil))
    e = assert_raises(Restep::Problem) { Restep::Body.media_type!("text/plain", %w[application/json]) }
    assert_equal 415, e.status
    assert_equal ["application/json", nil], Restep::Body.media_type!("Application/JSON", %w[application/json])
  end

  # ---- MergePatch --------------------------------------------------------------------------

  def test_merge_patch_follows_rfc_7396
    apply = ->(t, p) { Restep::MergePatch.apply(t, p) }
    assert_equal({ "a" => "z", "c" => { "d" => "e" } }, apply.({ "a" => "b", "c" => { "d" => "e", "f" => "g" } }, { "a" => "z", "c" => { "f" => nil } }))
    assert_equal({ "a" => [1] }, apply.({ "a" => [{ "b" => "c" }] }, { "a" => [1] }))
    assert_equal({ "a" => { "b" => "c" } }, apply.({ "a" => [1] }, { "a" => { "b" => "c", "d" => nil } }))
    assert_equal ["c"], apply.({ "a" => "b" }, ["c"])
    assert_equal({ "a" => "b" }, apply.(nil, { "a" => "b" }))
    assert_equal({}, apply.({ "a" => "b" }, { "a" => nil, "x" => nil }))
  end

  # ---- Fields of type object and array (finding 1) ----------------------------------------

  def test_object_and_array_fields_are_read_and_written
    get flour_path
    assert_equal(%w[shop], json["tags"])
    assert_equal({ "store" => { "name" => "Corner shop", "open" => true }, "qty" => 1.5 }, json["meta"])
    post notes_path, JSON.generate("title" => "Paint", "tags" => %w[home], "meta" => { "rooms" => [1, 2], "gloss" => 0.25, "note" => nil }), JSON_CT
    assert_equal 201, last_response.status, last_response.body
    assert_equal({ "rooms" => [1, 2], "gloss" => 0.25, "note" => nil }, json["meta"]) # a POST keeps null members
    post notes_path, JSON.generate("title" => "Sweep"), JSON_CT
    assert_equal [], json["tags"] # the default
    assert_nil json["meta"]
  end

  def test_patch_merges_an_object_and_replaces_an_array
    get flour_path
    etag = json["_etag"]
    patch flour_path, JSON.generate("meta" => { "store" => { "open" => nil, "city" => "Madrid" } }, "tags" => %w[a b]), MERGE
    assert_equal 200, last_response.status, last_response.body
    assert_equal({ "store" => { "name" => "Corner shop", "city" => "Madrid" }, "qty" => 1.5 }, json["meta"])
    assert_equal %w[a b], json["tags"]
    refute_equal etag, json["_etag"]
    # The same value written another way changes nothing.
    etag = json["_etag"]
    patch flour_path, JSON.generate("meta" => { "qty" => 1.50 }), MERGE
    assert_equal etag, json["_etag"]
    patch flour_path, JSON.generate("meta" => nil), MERGE # nullable: null deletes it
    assert_nil json["meta"]
  end

  def test_object_and_array_fields_are_validated
    patch flour_path, JSON.generate("meta" => [1], "tags" => { "a" => 1 }), MERGE
    body = assert_problem 422, "invalid"
    assert_equal [["/meta", "type"], ["/tags", "type"]], body["errors"].map { |e| [e["pointer"], e["code"]] }.sort
    raw = %({"meta": {"big": 1.00000000000000000001, "huge": 1e400, "s": "\\ufdd0", "\\ufdd1": 1}, "tags": ["ok", 7]})
    patch flour_path, raw, MERGE
    body = assert_problem 422, "invalid"
    assert_equal [["", "format"], ["/meta/big", "range"], ["/meta/huge", "range"], ["/meta/s", "format"], ["/tags/1", "type"]],
                 body["errors"].map { |e| [e["pointer"], e["code"]] }.sort
    patch flour_path, JSON.generate("tags" => nil), MERGE
    assert_problem 422, "invalid" # not nullable
  end

  def test_discovery_gives_their_schemas
    get "/"
    notes = json.dig("collections", "notes", "schemas")
    assert_equal({ "type" => %w[object null], "properties" => { "qty" => { "type" => "number" } }, "description" => "Whatever else the note needs to keep." },
                 notes.dig("item", "properties", "meta"))
    assert_equal %w[object null], notes.dig("update", "properties", "meta", "type")
    refute notes.dig("update", "properties", "meta").key?("properties") # a merge patch may leave any member out
    assert_equal({ "type" => "array", "items" => { "type" => "string" }, "maxItems" => 10, "description" => "Free labels.", "default" => [] },
                 notes.dig("create", "properties", "tags"))
  end

  def test_object_fields_are_declared_with_care
    f = Restep::Fields
    build = lambda do |fields, **kw|
      Restep::Collection.new(name: "docs", path: "/docs", source: Restep::Sources::Computed.new(all: ->(_) { [] }), fields: [f.f(name: "id", type: "id", read_only: true)] + fields, **kw)
    end
    doc = f.f(name: "doc", type: "object")
    assert_raises(ArgumentError) { build.([doc], filters: { "doc" => { "type" => "string", "ops" => %w[eq] } }) }
    assert_raises(ArgumentError) { build.([doc], sort: { "doc" => {} }) }
    assert_raises(ArgumentError) { build.([f.f(name: "n", type: "string", schema: {})]) }
    build.([doc], filters: { "doc.city" => { "type" => "string", "ops" => %w[eq], value: ->(r) { r.dig("doc", "city") } } })
  end

  # ---- Actions (finding 2) ----------------------------------------------------------------

  def test_safe_post_action_answers_its_result
    post "#{flour_path}:compare", JSON.generate("with" => { "title" => "Buy flour", "priority" => 9 }), JSON_CT
    assert_equal 200, last_response.status, last_response.body
    assert_equal({ "differs" => ["priority"] }, json)
    assert_equal "no-store", last_response.headers["cache-control"]
    assert_nil last_response.headers["etag"]
    assert_nil last_response.headers["content-location"]
    # §5.4: the 412 against the item ETag comes before the 422 of the input.
    post "#{flour_path}:compare", "", "HTTP_IF_MATCH" => %("nope")
    assert_problem 412, "precondition_failed"
    post "#{flour_path}:compare", ""
    assert_problem 422, "invalid"
    # Safe: it ignores Idempotency-Key, even a malformed one, and changes nothing.
    before = Workspace.store.notes[flour["id"]].dup
    post "#{flour_path}:compare", JSON.generate("with" => {}), JSON_CT.merge("HTTP_IDEMPOTENCY_KEY" => "malformed")
    assert_equal 200, last_response.status
    assert_equal before, Workspace.store.notes[flour["id"]]
    get "#{flour_path}:compare"
    assert_equal 405, last_response.status
  end

  def test_item_action_can_create_or_answer_nothing
    post "#{flour_path}:copy", "", "HTTP_IDEMPOTENCY_KEY" => %("copy-1")
    assert_equal 201, last_response.status, last_response.body
    location = last_response.headers["location"]
    assert_match %r{\A#{notes_path}/note-}, location
    assert_nil last_response.headers["etag"]
    assert_equal "", last_response.body
    get location
    assert_equal "Buy flour", json["title"]
    # §7.1: a replay gives the same status and Location, and runs nothing again.
    count = Workspace.store.notes.size
    post "#{flour_path}:copy", "", "HTTP_IDEMPOTENCY_KEY" => %("copy-1")
    assert_equal [201, location, "true"], [last_response.status, last_response.headers["location"], last_response.headers["idempotent-replayed"]]
    assert_equal count, Workspace.store.notes.size
    post "#{flour_path}:touch"
    assert_equal 204, last_response.status
    assert_nil last_response.headers["etag"]
    assert_includes last_response.headers["cache-group-invalidation"], flour_path
  end

  def test_collection_actions_answer_201_with_location_or_204
    calls = []
    results = {
      "created" => Restep::Created.new("/shelves/x/notes/n-9", { "id" => "n-9" }),
      "plain201" => [201, { "id" => "n-9" }],
      "ok200" => [200, { "done" => true }],
      "nothing" => [204, nil],
      "safe201" => [201, { "count" => 1 }]
    }
    f = Restep::Fields
    actions = results.map do |name, r|
      if name == "safe201"
        f.action(name, on: "collection", safe: true, idempotent: true, output: { "type" => "object" }, run: ->(*) { calls << name; r })
      else
        f.action(name, on: "collection", effects: [], run: ->(*) { calls << name; r })
      end
    end
    Restep.config.collections["people"] = Restep::Collection.new(
      name: "people", path: "/people", source: Restep::Sources::Computed.new(all: ->(_) { [] }),
      fields: [f.f(name: "id", type: "id", read_only: true)], actions: actions
    )
    post "/people:created"
    assert_equal [201, "/shelves/x/notes/n-9", { "id" => "n-9" }], [last_response.status, last_response.headers["location"], json]
    post "/people:nothing"
    assert_equal 204, last_response.status
    %w[plain201 ok200 safe201].each do |name| # a 201 needs its Location; never 200; a safe action never creates
      post "/people:#{name}"
      assert_problem 500, "internal"
    end
  end

  # ---- Envelope (finding 6) ---------------------------------------------------------------

  def test_envelope_path_leaves_other_requests_alone
    seen = []
    api = Restep::RackApp.new
    @inner = lambda do |env|
      if env["PATH_INFO"].match?(%r{\A/v1(/|\z)})
        env["PATH_INFO"] = env["PATH_INFO"].delete_prefix("/v1")
        env["SCRIPT_NAME"] = "/v1"
        next api.call(env)
      end
      seen << env.key?("action_dispatch.request.query_parameters")
      [200, { "content-type" => "text/html" }, ["<p>page</p>"]]
    end
    Restep.config.root_path = "/v1"
    @envelope_options = { path: "/v1", cors: false }
    get "/pages/about?x[y]=1"
    assert_equal [200, "<p>page</p>", [false]], [last_response.status, last_response.body, seen]
    refute_includes last_response.headers["link"].to_s, "rel=\"profile\""
    request "/pages/about", method: "BREW"
    assert_equal 200, last_response.status # not the API's 501
    get "/v1/shelves"
    assert_equal 200, last_response.status, last_response.body
    assert_includes last_response.headers["link"], "rel=\"profile\""
    get "/v1x"
    assert_equal "<p>page</p>", last_response.body # /v1x is not under /v1
    assert_raises(ArgumentError) { Restep::Envelope.new(nil, path: "v1") }
  end

  def test_envelope_exempts_requests_authenticated_by_token
    @envelope_options = { cors: ["https://editor.example"], credentials: true, exempt: Restep::Envelope.method(:token_authorization?) }
    body = JSON.generate("name" => "Cellar")
    post "/shelves", body, JSON_CT.merge("HTTP_ORIGIN" => "https://evil.example")
    assert_problem 403, "forbidden"
    post "/shelves", body, JSON_CT.merge("HTTP_ORIGIN" => "https://evil.example", "HTTP_AUTHORIZATION" => "Basic YTpi")
    assert_problem 403, "forbidden" # HTTP authentication is attached by the browser
    post "/shelves", body, JSON_CT.merge("HTTP_ORIGIN" => "https://evil.example", "HTTP_AUTHORIZATION" => "Bearer abc")
    assert_equal 201, last_response.status, last_response.body
    assert Restep::Envelope.token_authorization?("HTTP_AUTHORIZATION" => "DPoP abc")
    refute Restep::Envelope.token_authorization?({})
    assert_raises(ArgumentError) { Restep::Envelope.new(nil, exempt: ->(_) { true }) } # only with credentials
  end

  # ---- ActiveRecordStore (finding 5) ------------------------------------------------------

  class StoredKey < ActiveRecord::Base
    self.table_name = "stored_keys"
  end

  def test_active_record_store_purges_every_expired_key_and_takes_any_index_name
    ActiveRecord::Schema.define do
      create_table :stored_keys, force: true do |t|
        t.text :principal, null: false
        t.text :http_method, null: false
        t.text :path, null: false
        t.text :key, null: false
        t.text :request_hash, null: false
        t.boolean :completed, null: false, default: false
        t.integer :status
        t.json :headers
        t.text :body
        t.datetime :expires_at, null: false
        t.index %i[principal http_method path key], unique: true, name: "some_other_name"
      end
    end
    store = Restep::Idempotency::ActiveRecordStore.new(StoredKey)
    old = Time.now.utc - 10
    StoredKey.create!(principal: "p:a", http_method: "POST", path: "/x", key: "old", request_hash: "h", expires_at: old)
    StoredKey.create!(principal: "p:b", http_method: "POST", path: "/y", key: "live", request_hash: "h", expires_at: Time.now.utc + 3600)
    scope = { principal: "p:c", http_method: "POST", path: "/z", key: "k" }
    run = -> { store.run(scope, "h1", ttl: 86_400, precheck: -> {}, replay: ->(row) { [row.status, {}, row.body] }) { [201, { "location" => "/z/1" }, "{}"] } }
    assert_equal 201, run.call.first
    assert_equal %w[k live], StoredKey.order(:key).pluck(:key) # the other principal's expired key is gone
    assert_equal [201, {}, "{}"], run.call # replayed
    StoredKey.create!(principal: "p:d", http_method: "POST", path: "/w", key: "old2", request_hash: "h", expires_at: old)
    run.call
    assert_equal 3, StoredKey.count # purged at most once per purge_every
    assert_equal 1, store.purge
    assert_equal %w[k live], StoredKey.order(:key).pluck(:key)
    never = Restep::Idempotency::ActiveRecordStore.new(StoredKey, purge_every: nil)
    never.purge_if_due
    assert_equal 2, StoredKey.count
  ensure
    ActiveRecord::Base.connection.drop_table(:stored_keys, if_exists: true)
  end
end
