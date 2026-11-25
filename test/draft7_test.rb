# What draft 7 of Restep changed for servers (Appendix C), on the test API of test/library.rb.
require "minitest/autorun"
require "rack/test"

require_relative "library"

class Draft7Test < Minitest::Test
  include Rack::Test::Methods

  # In the site the schema is public/1/schema/; in the gem's mirror it ships in schema/.
  PROBLEM_SCHEMA = [File.expand_path("../../../public/1/schema/problem.json", __dir__),
                    File.expand_path("../schema/problem.json", __dir__)].find { |f| File.exist?(f) }
  JSON_CT = { "CONTENT_TYPE" => "application/json" }.freeze

  def app
    @app ||= Rack::Builder.new do
      use Restep::Envelope
      run Restep::RackApp.new
    end.to_app
  end

  def json = JSON.parse(last_response.body)

  def assert_problem(status, code)
    assert_equal status, last_response.status, last_response.body
    assert_equal "application/problem+json", last_response.content_type
    assert_equal code, json["code"]
    json
  end

  # ---- 1.1, 4.2 and 11.1: discovery --------------------------------------------------------

  def test_discovery_declares_draft_7
    get "/"
    doc = json
    assert_equal "1.0-draft.7", doc["restep"]
    actions = doc.dig("collections", "journals", "actions")
    assert_equal [], actions.dig("archive", "effects")
    assert_equal ["destroys"], actions.dig("bulk", "effects")
    refute actions["ping"].key?("effects")
    assert_equal({ "type" => "object", "properties" => { "count" => { "type" => "integer" } } }, actions.dig("stats", "output"))
    assert_equal({ "description" => "Journals still published. On by default.", "default" => true },
                 doc.dig("collections", "journals", "named_filters", "current"))
    assert_equal true, doc.dig("collections", "papers", "filter", "title", "required")
    assert_equal %w[eq ne lt le gt ge in nin prefix contains], doc.dig("collections", "books", "filter", "title", "ops")
  end

  # ---- 5.4: the closed table of codes ------------------------------------------------------

  def test_codes_match_problem_schema
    schema = JSON.parse(File.read(PROBLEM_SCHEMA))
    assert_equal schema.dig("properties", "code", "anyOf", 0, "enum"), Restep::Problem::CODES.keys
    schema["allOf"].each do |rule|
      codes = rule.dig("if", "properties", "code")
      status = rule.dig("then", "properties", "status", "const")
      next unless codes && status
      Array(codes["enum"] || codes["const"]).each { |c| assert_equal status, Restep::Problem::CODES.fetch(c).first, c }
    end
  end

  def test_status_outside_the_table_gets_http_code
    pr = Restep::Problem.new(418, nil, detail: "I am a teapot.")
    assert_equal "http_418", pr.body["code"]
    assert_equal "Error", pr.body["title"] # Rack 3 has no reason phrase for 418
    assert_equal "Request Header Fields Too Large", Restep::Problem.new(431, nil).body["title"]
    assert_equal "http_431", Restep::Problem.code_for(431)
    assert_equal "request_timeout", Restep::Problem.code_for(408)
    assert_equal "too_early", Restep::Problem.new(425, "too_early").body["code"]
    assert_equal "Gateway timeout", Restep::Problem.new(504, "gateway_timeout").body["title"]
    assert_raises(ArgumentError) { Restep::Problem.new(418, "teapot") }
    assert_raises(ArgumentError) { Restep::Problem.new(409, "not_found") }
    assert_raises(ArgumentError) { Restep::Problem.code_for(409) } # two codes: say which
  end

  def test_problems_are_no_store_without_shared_cache_fields
    %w[428 429 431 511].each do |status|
      pr = Restep::Problem.new(status.to_i, nil, headers: { "cache-control" => "private, max-age=60",
                                                             "CDN-Cache-Control" => "max-age=60", "retry-after" => "1" })
      h = pr.response_headers
      assert_equal "no-store", h["cache-control"], status
      refute h.keys.any? { |k| k.downcase == "cdn-cache-control" }, status
      assert_equal "1", h["retry-after"]
    end
  end

  # ---- 3: I-JSON bodies --------------------------------------------------------------------

  def test_duplicate_member_names_give_400
    post "/books", '{"title":"A","title":"B","genre":"essay","pages":10}', JSON_CT
    assert_problem 400, "bad_request"
    post "/books", '{"title":"A","genre":"essay","pages":10,"x":{"a":1,"a":1}}', JSON_CT
    assert_problem 400, "bad_request"
  end

  def test_unpaired_surrogate_gives_422_format
    post "/books", '{"title":"A\ud800","genre":"essay","pages":10}', JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [{ "pointer" => "", "code" => "format" }], body["errors"].map { |e| e.slice("pointer", "code") }
  end

  # Council decision 11: a body that also has a JSON syntax error gets 400, wherever the error is.
  def test_unpaired_surrogate_with_a_syntax_error_gives_400
    ['{"title":"A\ud800",}', '{"title":"A\ud800" "genre":"essay"}', '["\ud800"', '{"a":"\udc00","a":1}'].each do |raw|
      post "/books", raw, JSON_CT
      assert_problem 400, "bad_request"
    end
    # An escaped backslash before "ud800" is text, not a surrogate; a pair is a character.
    post "/books", '{"title":"A\\\\ud800\ud83d\ude00","genre":"essay","pages":10}', JSON_CT
    assert_equal 201, last_response.status, last_response.body
    assert_equal "A\\ud800\u{1F600}", json["title"]
    post "/books", '{"title":"A\ud800","genre":"essay","pages":10 }', JSON_CT
    assert_problem 422, "invalid"
  ensure
    Book.where("title LIKE 'A%ud800%'").delete_all
  end

  def test_unpaired_surrogate_waits_for_the_precondition
    patch "/books/1", '{"title":"A\ud800"}', "CONTENT_TYPE" => "application/merge-patch+json", "HTTP_IF_MATCH" => '"stale"'
    assert_problem 412, "precondition_failed"
  end

  def test_noncharacter_gives_422_format
    post "/books", JSON.generate({ "title" => "A\u{FFFE}", "genre" => "essay", "pages" => 10 }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["/title", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
  end

  # ---- 5.1: a POST ignores the fields only the server sets ---------------------------------

  def test_post_ignores_server_set_fields_whatever_their_value
    post "/books", JSON.generate({ "title" => "Walden", "genre" => "essay", "pages" => 352,
                                   "created_at" => "1999-01-01T00:00:00Z", "updated_at" => 7 }), JSON_CT
    assert_equal 201, last_response.status, last_response.body
    refute_equal "1999-01-01T00:00:00Z", json["created_at"]
    post "/books", JSON.generate({ "id" => "99", "title" => "Walden", "genre" => "essay", "pages" => 352 }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["/id", "read_only"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
  ensure
    Book.where(title: "Walden").delete_all
  end

  # Council decision 5: a field only the server sets is ignored in a POST whatever its value; in
  # a PATCH it is rejected unless it is the current value, so no client sets it.
  def test_server_set_fields_are_set_by_no_request
    get "/books/1"
    created = json["created_at"]
    patch "/books/1", JSON.generate({ "created_at" => "1999-01-01T00:00:00Z" }), "CONTENT_TYPE" => "application/merge-patch+json"
    body = assert_problem 422, "invalid"
    assert_equal [["/created_at", "read_only"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    patch "/books/1", JSON.generate({ "created_at" => created }), "CONTENT_TYPE" => "application/merge-patch+json"
    assert_equal 200, last_response.status, last_response.body
    get "/"
    assert_equal ["created_at", "updated_at"].sort,
                 (json.dig("collections", "books", "schemas", "item", "properties").keys -
                  json.dig("collections", "books", "schemas", "create", "properties").keys - ["id"]).sort
  end

  # ---- 3: a leap second in a request body (council decision 4) ----------------------------

  def test_leap_second_in_a_body_gives_422_format
    patch "/books/1", JSON.generate({ "created_at" => "2016-12-31T23:59:60Z" }), "CONTENT_TYPE" => "application/merge-patch+json"
    body = assert_problem 422, "invalid"
    assert_equal [["/created_at", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    errors = []
    f = Restep::Fields.f(name: "at", type: "datetime")
    assert_equal :error, Library::BOOKS.send(:coerce, f, "2016-12-31T23:59:60Z", "/at", errors)
    assert_equal [["/at", "format"]], errors.map { |e| [e["pointer"], e["code"]] }
    assert_kind_of Time, Library::BOOKS.send(:coerce, f, "2016-12-31T23:59:59Z", "/at", [])
    assert Restep::Types.leap_second?("2016-12-31t23:59:60.5+01:00")
    refute Restep::Types.leap_second?("2016-12-31T23:59:59Z")
    refute Restep::Types.leap_second?("2016-12-31T23:60:60Z")
  end

  # Council round 3, decision 4: a leap second in a field only the server sets is ignored in a
  # POST, like any other value there, not rejected.
  def test_leap_second_in_a_server_set_field_of_a_post_is_ignored
    post "/books", JSON.generate({ "title" => "Leap", "genre" => "essay", "pages" => 60,
                                   "created_at" => "2016-12-31T23:59:60Z" }), JSON_CT
    assert_equal 201, last_response.status, last_response.body
    refute_equal "2017-01-01T00:00:00Z", json["created_at"]
  ensure
    Book.where(title: "Leap").delete_all
  end

  # Council round 3, decision 10: a noncharacter in a member name gets pointer "", and the
  # response never carries it; an unpaired surrogate in a member name too.
  def test_unstorable_member_name_gives_an_empty_pointer
    post "/books", JSON.generate({ "title" => "A", "genre" => "essay", "pages" => 10, "x\u{FFFE}" => 1 }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    refute_includes last_response.body, "\u{FFFE}"
    patch "/books/1", JSON.generate({ "\u{10FFFF}" => 1 }), "CONTENT_TYPE" => "application/merge-patch+json"
    body = assert_problem 422, "invalid"
    assert_equal [["", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    post "/journals/1:archive", JSON.generate({ "\u{FDD0}" => 1 }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    post "/books", '{"title":"A","genre":"essay","pages":10,"x\ud800":1}', JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["", "format"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    # An unknown member with an ordinary name keeps its pointer.
    post "/books", JSON.generate({ "title" => "A", "genre" => "essay", "pages" => 10, "a/b" => 1 }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["/a~1b", "unknown"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
  end

  # ---- 4.3: Allow lists HEAD with GET ------------------------------------------------------

  def test_allow_lists_head
    put "/books/1"
    assert_problem 405, "method_not_allowed"
    assert_equal "GET, HEAD, PATCH, DELETE", last_response.headers["allow"]
    post "/journals:stats"
    assert_problem 405, "method_not_allowed"
    assert_equal "GET, HEAD", last_response.headers["allow"]
  end

  # ---- 6.1: operators, leap seconds, same filter ---------------------------------------------

  def test_nin_prefix_and_contains
    get "/books?filter[title][nin]=Ariel,Middlemarch&sort=title"
    assert_equal ["Bleak House", "Leaves of Grass", "The Myth of Sisyphus"], json["items"].map { |b| b["title"] }
    get "/books?filter[title][prefix]=Le"
    assert_equal ["Leaves of Grass"], json["items"].map { |b| b["title"] }
    get "/books?filter[title][prefix]=le" # code points: case-sensitive
    assert_equal [], json["items"]
    get "/books?filter[title][contains]=of"
    assert_equal ["Leaves of Grass", "The Myth of Sisyphus"], json["items"].map { |b| b["title"] }.sort
    get "/books?filter[title][contains]="
    assert_equal "filter[title][contains]", assert_problem(400, "invalid_parameter")["parameter"]
    get "/books?filter[title][nin]="
    assert_problem 400, "invalid_parameter"
    get "/books?filter[genre][nin]=essay"
    assert_problem 400, "unsupported_parameter"
  end

  def test_leap_second_operand_is_invalid
    get "/books?filter[created_at][lt]=2016-12-31T23:59:60Z"
    assert_equal "filter[created_at][lt]", assert_problem(400, "invalid_parameter")["parameter"]
  end

  # Council decision 3: an integer operand whose exact decimal value has no fractional part.
  def test_integer_operand_with_a_zero_fraction
    assert_equal [:ok, 20], Restep::Types.parse_filter_value("integer", "20.0")
    assert_equal [:ok, -7], Restep::Types.parse_filter_value("integer", "-7.000")
    assert_equal [:ok, 12345678901234567890], Restep::Types.parse_filter_value("integer", "12345678901234567890.00")
    assert_nil Restep::Types.parse_filter_value("integer", "20.5")
    assert_nil Restep::Types.parse_filter_value("integer", "20.")
  end

  # Council round 3, decision 7: the number grammar of RFC 8259 §6, exponent included.
  def test_integer_operand_follows_the_json_number_grammar
    { "2e1" => 20, "2E1" => 20, "2e+1" => 20, "1.5e1" => 15, "200e-1" => 20, "-2e1" => -20, "0" => 0, "-0" => 0,
      "0e-99999999999999999999" => 0, "0.0e5" => 0, "1e18" => 10**18, "1e30" => 10**30 }.each do |raw, value|
      assert_equal [:ok, value], Restep::Types.parse_filter_value("integer", raw), raw
    end
    %w[+20 .5 020 -007.000 0x14 20.5 2e-1 1e-99999999999999999999 2e 2e1.0 e1 1_000 20e0.5 --1 Infinity NaN].each do |raw|
      assert_nil Restep::Types.parse_filter_value("integer", raw), raw
    end
    # Over the gem's limit (§5.3): never materialized, whatever the exponent.
    assert_equal 8192, Restep::Types.parse_filter_value("integer", "1e8191")[1].to_s.length
    assert_nil Restep::Types.parse_filter_value("integer", "1e8192")
    assert_nil Restep::Types.parse_filter_value("integer", "1e99999999999999999999")
    # decimal keeps its own grammar.
    assert_nil Restep::Types.parse_filter_value("decimal", "2e1")
    books = Restep::Collection.new(name: "b", path: "/b", model: "Book", description: "", fields: Library::BOOKS.fields.values,
                                   filters: { "pages" => { "type" => "integer", "ops" => %w[eq lt in], sql: "pages" } })
    q = ->(qs) { Restep::Query.new(books, :collection, "GET", Restep::QueryString.parse(qs)) }
    assert_equal q.("filter[pages][lt]=200").binding_payload, q.("filter[pages][lt]=2e2").binding_payload
    assert_equal q.("filter[pages][in]=96,145").binding_payload, q.("filter[pages][in]=9.6e1,145").binding_payload
    # Council round 4, decision 6: an operand over the limit gives invalid_parameter with the limit in detail.
    assert Restep::Types.integer_over_limit?("1e99999999999999999999")
    assert Restep::Types.integer_over_limit?("-1e8192")
    refute Restep::Types.integer_over_limit?("1e8191")
    refute Restep::Types.integer_over_limit?("1e-99999999999999999999")
    %w[filter[pages][lt]=1e99999999999999999999 filter[pages][in]=96,1e8192 filter[pages][eq]=-1e8192].each do |qs|
      error = assert_raises(Restep::Problem) { q.(qs) }
      assert_equal "invalid_parameter", error.body["code"], qs
      assert_includes error.body["detail"], "at most 8192 digits", qs
    end
    %w[filter[pages][lt]=%2B200 filter[pages][in]=96,0145 filter[pages][lt]=0x14].each do |qs|
      error = assert_raises(Restep::Problem) { q.(qs) }
      assert_equal "invalid_parameter", error.body["code"], qs
    end
    books = Restep::Collection.new(name: "b", path: "/b", model: "Book", description: "", fields: Library::BOOKS.fields.values,
                                   filters: { "pages" => { "type" => "integer", "ops" => %w[eq lt in], sql: "pages" } })
    q = ->(qs) { Restep::Query.new(books, :collection, "GET", Restep::QueryString.parse(qs)) }
    assert_equal q.("filter[pages][lt]=200").binding_payload, q.("filter[pages][lt]=200.0").binding_payload
    assert_equal q.("filter[pages][in]=96,145").binding_payload, q.("filter[pages][in]=96.00,145").binding_payload
    error = assert_raises(Restep::Problem) { q.("filter[pages][lt]=200.5") }
    assert_equal "invalid_parameter", error.body["code"]
  end

  def test_equal_operands_are_the_same_filter_for_the_cursor
    q = ->(qs) { Restep::Query.new(Library::BOOKS, :collection, "GET", Restep::QueryString.parse(qs)).binding_payload }
    assert_equal q.("filter[created_at][lt]=2026-01-01T00:00:00Z"), q.("filter[created_at][lt]=2026-01-01T01:00:00%2B01:00")
    assert_equal q.("filter[created_at][lt]=2026-01-01T00:00:00Z"), q.("filter[created_at][lt]=2026-01-01t00:00:00.000z")
    refute_equal q.("filter[created_at][lt]=2026-01-01T00:00:00Z"), q.("filter[created_at][lt]=2026-01-01T00:00:01Z")
    assert_equal "20", Restep::Query.canonical("decimal", BigDecimal("20.0"))
    assert_equal "20.5", Restep::Query.canonical("decimal", BigDecimal("20.50"))
    assert_equal "0", Restep::Query.canonical("decimal", BigDecimal("-0.00"))
    assert_equal "7", Restep::Query.canonical("integer", Integer("007", 10))
  end

  def test_declarations_are_checked
    coll = ->(filters, named = {}) {
      Restep::Collection.new(name: "x", path: "/x", model: "Book", description: "x", fields: [], filters: filters, named_filters: named)
    }
    assert_raises(ArgumentError) { coll.({ "a" => { "type" => "string", "ops" => %w[eq like] } }) }
    assert_raises(ArgumentError) { coll.({ "a" => { "type" => "boolean", "ops" => %w[eq lt] } }) }
    assert_raises(ArgumentError) { coll.({ "a" => { "type" => "enum", "values" => %w[a], "ops" => %w[prefix] } }) }
    assert_raises(ArgumentError) { coll.({ "id" => { "type" => "string", "ops" => %w[contains], id_like: true } }) }
    assert_raises(ArgumentError) { coll.({ "id" => { "type" => "string", "ops" => %w[lt], id_like: true } }) }
    assert_raises(ArgumentError) { coll.({}, { "s" => { "type" => "string", "default" => true, "description" => "s" } }) }
  end

  # ---- 6.1 and 6.4: default and required filters ---------------------------------------------

  def test_default_switch_applies_unless_turned_off
    titles = ->(url) {
      out = []
      while url
        get url
        assert_equal 200, last_response.status, last_response.body
        out += json["items"].map { |j| j["title"] }
        url = json["next"]
      end
      out
    }
    assert_equal ["Granta", "Ploughshares", "Zyzzyva"], titles.("/journals")
    assert_equal ["Granta", "Ploughshares", "The Dial", "Zyzzyva"], titles.("/journals?filter[current]=false")
    assert_equal ["Granta", "Ploughshares", "Zyzzyva"], titles.("/journals?filter[current]")
    get "/journals?filter[current]=true"
    assert_equal "filter[current]", assert_problem(400, "invalid_parameter")["parameter"]
    # Never on reading an item.
    get "/journals/#{Journal.find_by(title: "The Dial").id}"
    assert_equal 200, last_response.status
  end

  def test_cursor_is_bound_to_the_default_filters
    get "/journals"
    cursor = json["next"][/cursor=([^&]+)/, 1]
    get "/journals?filter[current]=false&cursor=#{cursor}"
    assert_equal "cursor", assert_problem(400, "invalid_parameter")["parameter"]
    get "/journals?filter[current]&cursor=#{cursor}" # on explicitly: the same filters
    assert_equal 200, last_response.status
  end

  def test_required_filter
    get "/papers"
    assert_equal "filter[title]", assert_problem(400, "invalid_parameter")["parameter"]
    get "/papers?filter[title]=Granta"
    assert_equal 200, last_response.status
    assert_equal ["Granta"], json["items"].map { |j| j["title"] }
    get "/papers/#{Journal.first.id}"
    assert_equal 200, last_response.status
  end

  def test_post_preconditions_on_a_collection_with_a_required_filter
    body = JSON.generate({ "title" => "Tin House" })
    post "/papers", body, JSON_CT.merge("HTTP_IF_MATCH" => "*")
    assert_equal 201, last_response.status, last_response.body
    post "/papers", body, JSON_CT.merge("HTTP_IF_MATCH" => '"abc"')
    assert_problem 412, "precondition_failed"
    post "/papers", body, JSON_CT.merge("HTTP_IF_NONE_MATCH" => "*")
    assert_problem 412, "precondition_failed"
    post "/papers", body, JSON_CT.merge("HTTP_IF_NONE_MATCH" => '"abc"')
    assert_equal 201, last_response.status
  ensure
    Journal.where(title: "Tin House").delete_all
  end

  # ---- 7.2 and 11.1: actions -------------------------------------------------------------------

  def test_action_200_carries_content_location_and_new_etag
    j = Journal.create!(title: "Bomb", active: true, created_at: Time.now.utc, updated_at: Time.now.utc)
    post "/journals/#{j.id}:archive"
    assert_equal 200, last_response.status, last_response.body
    assert_equal "/journals/#{j.id}", last_response.headers["content-location"]
    assert_equal json["_etag"], last_response.headers["etag"]
    assert_equal false, json["active"]
    get "/journals/#{j.id}"
    assert_equal last_response.headers["etag"], json["_etag"]
    assert_equal({}, json["_actions"].slice("archive"))
  ensure
    j&.delete
  end

  def test_action_204_carries_no_etag
    j = Journal.create!(title: "Bomb", active: true, created_at: Time.now.utc, updated_at: Time.now.utc)
    post "/journals/#{j.id}:archive", "", "HTTP_PREFER" => "return=minimal"
    assert_equal 204, last_response.status
    assert_nil last_response.headers["etag"]
    assert_nil last_response.headers["content-location"]
    # A PATCH's minimal response still carries the ETag (7.3).
    patch "/journals/#{j.id}", '{"title":"Bomb!"}', "CONTENT_TYPE" => "application/merge-patch+json", "HTTP_PREFER" => "return=minimal"
    assert_equal 204, last_response.status
    refute_nil last_response.headers["etag"]
  ensure
    j&.delete
  end

  def test_idempotent_action_ignores_a_malformed_key
    post "/journals/#{Journal.first.id}:ping", "", "HTTP_IDEMPOTENCY_KEY" => "not a structured string"
    assert_equal 200, last_response.status, last_response.body
    post "/journals/#{Journal.first.id}:archive", "", "HTTP_IDEMPOTENCY_KEY" => "not a structured string"
    assert_problem 400, "bad_request"
  end

  def test_collection_action_statuses
    post "/journals:bulk"
    assert_equal 204, last_response.status
    post "/journals:wrong" # an unsafe collection action never answers 200
    assert_problem 500, "internal"
    get "/journals:stats"
    assert_equal 200, last_response.status
    assert_equal({ "count" => Journal.count }, json)
    get "/journals:tally" # a safe collection action without output answers 200 never
    assert_problem 500, "internal"
  end

  # Council decision 6: a GET action without params takes no query parameters at all.
  def test_get_action_without_params_rejects_every_parameter
    get "/journals:stats"
    assert_equal 200, last_response.status
    %w[x=1 limit=1 filter[title]=Granta $x=1].each do |qs|
      get "/journals:stats?#{qs}"
      body = assert_problem 400, "unsupported_parameter"
      assert_equal qs.split("=").first, body["parameter"]
    end
    head "/journals:stats?x=1"
    assert_equal 400, last_response.status
    # A POST action keeps ignoring parameters that are not reserved.
    post "/journals:bulk?x=1"
    assert_equal 204, last_response.status
  end

  def test_action_declarations_are_checked
    act = ->(name, **kw) { Restep::Fields.action(name, on: "collection", run: ->(*) {}, **kw) }
    assert_raises(ArgumentError) { act.("look", method: "GET", safe: true) } # safe without idempotent
    assert_raises(ArgumentError) { act.("look", method: "GET") } # GET without safe
    assert_raises(ArgumentError) { act.("new") } # new is the safe GET action
    act.("new", method: "GET", safe: true, idempotent: true)
    assert_raises(ArgumentError) { act.("changes") }
    assert_raises(ArgumentError) { act.("pay", effects: ["spends"]) }
    assert_raises(ArgumentError) { act.("look", method: "GET", safe: true, idempotent: true, effects: ["external"]) }
    assert_raises(ArgumentError) { act.("do", output: { "type" => "object" }) }
  end

  # ---- 5.2: links the server builds encode [ and ] ----------------------------------------------

  def test_next_encodes_brackets
    get "/books?filter[genre]=novel&limit=1&sort=title&x=a+b%2Bc"
    nxt = json["next"]
    refute_nil nxt
    refute_match(/[\[\]]/, nxt)
    assert nxt.start_with?("/books?filter%5Bgenre%5D=novel&limit=1&sort=title&x=a+b%2Bc&cursor="), nxt
    get nxt
    assert_equal 200, last_response.status
    assert_equal ["Middlemarch"], json["items"].map { |b| b["title"] }
    assert_equal "a-z%5B%5D%25zz%20%C3%A9", Restep::QueryString.link_form("a-z[]%zz é")
  end

  # ---- 5.8: CORS lists ---------------------------------------------------------------------------

  def test_cors_exposes_content_location
    get "/books/1"
    assert_includes last_response.headers["access-control-expose-headers"].split(", "), "Content-Location"
    assert_includes last_response.headers["access-control-expose-headers"].split(", "), "Accept-Post"
    options "/books"
    assert_includes last_response.headers["access-control-allow-headers"].split(", "), "Content-Disposition"
  end

  # ---- 3: a segment that does not decode to UTF-8 names no item ------------------------------

  def test_segment_without_utf8_is_404
    get "/books/%FF"
    assert_problem 404, "not_found"
  end

  # ---- 4.3 and 5.9: method_effects on a singleton (council decision 8) ----------------------

  def test_singleton_method_effects
    make = ->(**kw) { Restep::Collection.new(name: "s", path: "/s", model: "Book", description: "", fields: [], **kw) }
    assert_equal({ "PATCH" => [] }, Restep::Discovery.singleton(make.(singleton: true, method_effects: { "PATCH" => [] }))["method_effects"])
    refute Restep::Discovery.singleton(make.(singleton: true)).key?("method_effects")
    assert_raises(ArgumentError) { make.(singleton: true, method_effects: { "DELETE" => [] }) }
    assert_raises(ArgumentError) { make.(singleton: true, method_effects: { "PATCH" => ["mails"] }) }
    assert_raises(ArgumentError) { make.(method_effects: { "PATCH" => [] }) }
  end
end
