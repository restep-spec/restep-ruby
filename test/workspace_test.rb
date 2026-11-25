# The in-memory test API of test/workspace.rb (no Active Record): subcollections, computed
# sources, relations, language maps, the principal, the body limit, CORS, the cursor secret and
# a hand-written discovery document.
require "minitest/autorun"
require "rack/test"
require "json"

require_relative "library" # the books API: restored after each test
require_relative "workspace"

class WorkspaceTest < Minitest::Test
  include Rack::Test::Methods

  JSON_CT = { "CONTENT_TYPE" => "application/json" }.freeze
  MERGE = { "CONTENT_TYPE" => "application/merge-patch+json" }.freeze

  def setup
    @saved = Workspace.install!
    @envelope_options = {}
  end

  def teardown = Restep.reset!(@saved)

  def app
    opts = @envelope_options
    @app ||= Rack::Builder.new do
      use Restep::Envelope, **opts
      run Restep::RackApp.new
    end.to_app
  end

  def json = JSON.parse(last_response.body)
  def store = Workspace.store
  def kitchen = store.shelves.values.find { |s| s["name"] == "Kitchen" }["id"]
  def garage = store.shelves.values.find { |s| s["name"] == "Garage" }["id"]
  def note_titled(t) = store.notes.values.find { |n| n["title"] == t }
  def notes_url(shelf = kitchen) = "/shelves/#{shelf}/notes"

  def assert_problem(status, code)
    assert_equal status, last_response.status, last_response.body
    assert_equal "application/problem+json", last_response.content_type
    assert_equal code, json["code"]
    json
  end

  def all(url)
    out = []
    while url
      get url
      assert_equal 200, last_response.status, last_response.body
      out += json["items"]
      url = json["next"]
    end
    out
  end

  # ---- 4.2 and 5.1: subcollections -------------------------------------------------------------

  def test_discovery_declares_subcollections_and_passes_the_rules
    get "/"
    doc = json
    assert_equal({ "path" => "/shelves/{shelf}/notes", "parent" => "shelves" }, doc["collections"]["notes"].slice("path", "parent"))
    assert_equal "/shelves/{shelf}/notes/{note}/comments", doc.dig("collections", "comments", "path")
    assert_equal({ "path" => "/shelves/{shelf}/settings", "parent" => "shelves" }, doc.dig("singletons", "settings").slice("path", "parent"))
    assert_equal %w[GET], doc.dig("collections", "people", "methods")
    assert_equal %w[GET POST], doc.dig("collections", "comments", "methods")
    assert_equal %w[GET DELETE], doc.dig("collections", "comments", "item_methods")
    assert_equal [], Restep::Rules.problems(doc)
    assert_equal [], Restep::Rules.schema_problems(doc)
  end

  def test_items_of_a_subcollection_live_under_their_parent
    items = all(notes_url)
    assert_equal 5, items.size
    flour = note_titled("Buy flour")
    get "#{notes_url}/#{flour["id"]}"
    assert_equal 200, last_response.status
    assert_equal "Buy flour", json["title"]
    # The same id under another parent, or under one that does not exist, names nothing.
    get "#{notes_url(garage)}/#{flour["id"]}"
    assert_problem 404, "not_found"
    get "/shelves/nope/notes/#{flour["id"]}"
    assert_problem 404, "not_found"
    get "/shelves/nope/notes"
    assert_problem 404, "not_found"
    get "/shelves/#{kitchen}/notes/#{flour["id"]}/"
    assert_problem 404, "not_found"
    get "/shelves/#{kitchen}/notes/a%2Fb"
    assert_problem 404, "not_found"
  end

  def test_a_subcollection_of_a_subcollection
    flour = note_titled("Buy flour")
    url = "#{notes_url}/#{flour["id"]}/comments"
    get url
    assert_equal ["Wholemeal?"], json["items"].map { |c| c["text"] }
    post url, JSON.generate({ "text" => "Rye too" }), JSON_CT
    assert_equal 201, last_response.status, last_response.body
    comment = last_response.headers["location"]
    assert_match %r{\A#{Regexp.escape(url)}/c-[0-9a-z]+\z}, comment
    assert_equal "#{url}, #{comment}", last_response.headers["cache-group-invalidation"].delete('"')
    # Under the note of another shelf, the comments do not exist.
    get "#{notes_url(garage)}/#{flour["id"]}/comments"
    assert_problem 404, "not_found"
    patch comment, "{}", MERGE # comments take no PATCH
    assert_problem 405, "method_not_allowed"
    assert_equal "GET, HEAD, DELETE", last_response.headers["allow"]
  end

  def test_create_patch_and_delete_under_a_parent
    post notes_url(garage), JSON.generate({ "title" => "Sweep" }), JSON_CT
    assert_equal 201, last_response.status, last_response.body
    loc = last_response.headers["location"]
    assert loc.start_with?("#{notes_url(garage)}/note-")
    assert_equal 3, json["priority"] # default
    assert_equal "#{loc}:pin", json.dig("_actions", "pin", "href")
    assert_equal garage, store.notes[loc.split("/").last]["shelf_id"]
    patch loc, JSON.generate({ "priority" => 5 }), MERGE.merge("HTTP_IF_MATCH" => last_response.headers["etag"])
    assert_equal 200, last_response.status, last_response.body
    assert_equal 5, json["priority"]
    post "#{loc}:pin"
    assert_equal 200, last_response.status, last_response.body
    assert_equal loc, last_response.headers["content-location"]
    assert_equal true, json["pinned"]
    delete loc
    assert_equal 204, last_response.status
    get loc
    assert_problem 404, "not_found"
  end

  def test_deleting_the_parent_removes_the_subcollection
    post "/shelves", JSON.generate({ "name" => "Shed" }), JSON_CT
    shelf = last_response.headers["location"]
    post "#{shelf}/notes", JSON.generate({ "title" => "Oil" }), JSON_CT
    note = last_response.headers["location"]
    delete shelf
    assert_equal 204, last_response.status
    [note, "#{shelf}/notes", "#{shelf}/settings"].each do |u|
      get u
      assert_problem 404, "not_found"
    end
  end

  def test_methods_follow_the_source
    put "/people/ada"
    assert_problem 405, "method_not_allowed"
    assert_equal "GET, HEAD", last_response.headers["allow"]
    post "/people", "{}", JSON_CT
    assert_equal "GET, HEAD", last_response.headers["allow"]
    delete notes_url
    assert_equal "GET, HEAD, POST", last_response.headers["allow"]
    post "#{notes_url}/#{note_titled("Buy flour")["id"]}/comments/x", "{}", JSON_CT
    assert_problem 404, "not_found"
  end

  def test_singleton_under_an_item
    get "/shelves/#{kitchen}/settings"
    assert_equal({ "color" => "white", "public" => false }, json.except("_etag"))
    patch "/shelves/#{kitchen}/settings", JSON.generate({ "color" => "red" }), MERGE
    assert_equal 200, last_response.status, last_response.body
    assert_equal "red", store.settings[kitchen]["color"]
    assert_equal "white", store.settings[garage]["color"]
    get "/shelves/nope/settings"
    assert_problem 404, "not_found"
  end

  def test_collection_action_under_a_parent
    get "#{notes_url}:stats"
    assert_equal({ "count" => 5 }, json)
    get "#{notes_url(garage)}:stats"
    assert_equal({ "count" => 0 }, json)
  end

  def test_cursor_is_bound_to_the_parent
    get "#{notes_url}?sort=title"
    nxt = json["next"]
    cursor = nxt[/cursor=([^&]+)/, 1]
    post notes_url(garage), JSON.generate({ "title" => "A" }), JSON_CT
    post notes_url(garage), JSON.generate({ "title" => "B" }), JSON_CT
    post notes_url(garage), JSON.generate({ "title" => "C" }), JSON_CT
    get "#{notes_url(garage)}?sort=title&cursor=#{cursor}"
    assert_equal "cursor", assert_problem(400, "invalid_parameter")["parameter"]
  end

  # ---- 6: the computed source filters, sorts and pages in memory ------------------------------

  def titles(query) = all("#{notes_url}?#{query}").map { |n| n["title"] }

  def test_filters_by_type_in_memory
    assert_equal ["Call Grace", "Fix the tap"], titles("filter[priority][ge]=4&sort=title")
    assert_equal ["Call Grace", "Fix the tap"], titles("filter[urgent]&sort=title")
    assert_equal ["Buy flour", "Call Grace"], titles("filter[due_on][lt]=2026-12-02&sort=title")
    assert_equal ["Defrost", "Fix the tap"], titles("filter[due_on][null]=true&sort=title")
    assert_equal ["Call Grace"], titles("filter[score][ge]=9")
    assert_equal ["Call Grace"], titles("filter[score][eq]=9.00")
    assert_equal ["Bake bread", "Buy flour"], titles("filter[author.id]=ada&sort=title")
    assert_equal ["Defrost"], titles("filter[author.id][null]=true")
    assert_equal ["Buy flour"], titles("filter[summary.en]=Flour")
    assert_equal ["Bake bread", "Buy flour"], titles("filter[title][prefix]=B&sort=title")
    assert_equal ["Fix the tap"], titles("filter[search]=TAP")
    assert_equal ["Buy flour", "Call Grace"], titles("filter[title][in]=Call Grace,Buy flour,Nothing&sort=title")
    get "#{notes_url}?filter[body]=x"
    assert_problem 400, "unsupported_parameter"
  end

  def test_sort_puts_nulls_last_and_pages_with_keysets
    assert_equal ["Fix the tap", "Call Grace", "Bake bread", "Buy flour", "Defrost"], titles("sort=-priority")
    # Nulls last in both directions (6.2).
    assert_equal ["Call Grace", "Buy flour", "Defrost", "Fix the tap", "Bake bread"], titles("sort=-score")
    assert_equal ["Defrost", "Buy flour", "Call Grace", "Fix the tap", "Bake bread"], titles("sort=score")
    get "#{notes_url}?sort=score&limit=3&count=true"
    assert_equal 3, json["items"].size
    assert_equal 5, json["total"]
  end

  def test_ids_are_document_keys
    get "/people/ada"
    assert_equal({ "id" => "ada", "name" => "Ada Lovelace" }, json.except("_etag"))
    get "/people/ADA"
    assert_problem 404, "not_found"
    assert_equal %w[Ada\ Lovelace Alan\ Turing Grace\ Hopper], all("/people?sort=name").map { |p| p["name"] }
  end

  # ---- 9: relations -----------------------------------------------------------------------------

  def test_include_and_dotted_fields
    flour = note_titled("Buy flour")
    get "#{notes_url}/#{flour["id"]}?include=author"
    assert_equal({ "id" => "ada", "href" => "/people/ada", "name" => "Ada Lovelace" }, json["author"].except("_etag"))
    refute_equal last_response.headers["etag"], json["_etag"]
    assert_includes last_response.headers["cache-groups"], %("/people/ada")
    get "#{notes_url}/#{flour["id"]}?include=author&fields=title,author.name"
    assert_equal %w[id title author _actions _etag].sort, json.keys.sort
    assert_equal %w[_etag href id name], json["author"].keys.sort
    get "#{notes_url}/#{flour["id"]}?fields=author.name"
    assert_equal "fields", assert_problem(400, "invalid_parameter")["parameter"]
    get "#{notes_url}/#{flour["id"]}?fields=summary.en"
    assert_problem 400, "invalid_parameter"
    get "#{notes_url}?include=author.name"
    assert_problem 400, "unsupported_parameter"
    get "/shelves?include=featured"
    assert_problem 400, "unsupported_parameter"
    get "/shelves/#{kitchen}/settings?include=x"
    assert_problem 400, "unsupported_parameter"
    patch "#{notes_url}/#{flour["id"]}?include=author", "{}", MERGE
    assert_problem 400, "unsupported_parameter"
    get "#{notes_url}?include=author"
    assert(json["items"].all? { |n| n["author"].nil? || n["author"]["name"] })
  end

  def test_relationship_to_a_subcollection_item_carries_href
    flour = note_titled("Buy flour")
    href = "#{notes_url}/#{flour["id"]}"
    get "/shelves/#{kitchen}"
    assert_equal({ "id" => flour["id"], "href" => href }, json["featured"])
    bread = note_titled("Bake bread")
    patch "/shelves/#{garage}", JSON.generate({ "featured" => { "id" => bread["id"] } }), MERGE
    body = assert_problem 422, "invalid"
    assert_equal [["/featured/href", "required"]], body["errors"].map { |e| [e["pointer"], e["code"]] }
    patch "/shelves/#{garage}", JSON.generate({ "featured" => { "id" => bread["id"], "href" => "/elsewhere/#{bread["id"]}" } }), MERGE
    assert_equal [["/featured/href", "format"]], assert_problem(422, "invalid")["errors"].map { |e| [e["pointer"], e["code"]] }
    patch "/shelves/#{garage}", JSON.generate({ "featured" => { "id" => bread["id"], "href" => "/shelves/#{garage}/notes/#{bread["id"]}" } }), MERGE
    assert_equal [["/featured/id", "unknown"]], assert_problem(422, "invalid")["errors"].map { |e| [e["pointer"], e["code"]] }
    patch "/shelves/#{garage}", JSON.generate({ "featured" => { "id" => bread["id"], "href" => "#{notes_url}/#{bread["id"]}" } }), MERGE
    assert_equal 200, last_response.status, last_response.body
    assert_equal "#{notes_url}/#{bread["id"]}", json.dig("featured", "href")
    # Sent back as read, it changes nothing; with the same id under another parent, it is checked.
    etag = json["_etag"]
    patch "/shelves/#{garage}", JSON.generate({ "featured" => json["featured"] }), MERGE
    assert_equal etag, json["_etag"]
    patch "/shelves/#{garage}", JSON.generate({ "featured" => { "id" => bread["id"], "href" => "/shelves/nope/notes/#{bread["id"]}" } }), MERGE
    assert_problem 422, "invalid"
  end

  # ---- 3: language maps -------------------------------------------------------------------------

  def test_language_maps_in_a_post
    post notes_url, JSON.generate({ "title" => "T", "summary" => { "en" => "x", "ES" => "y", "fr" => "z", "es-es" => 1 } }), JSON_CT
    body = assert_problem 422, "invalid"
    assert_equal [["/summary/ES", "format"], ["/summary/es-es", "type"], ["/summary/fr", "unknown"]],
                 body["errors"].map { |e| [e["pointer"], e["code"]] }.sort
    post notes_url, JSON.generate({ "title" => "T", "summary" => nil }), JSON_CT
    assert_equal [["/summary", "type"]], assert_problem(422, "invalid")["errors"].map { |e| [e["pointer"], e["code"]] }
    post notes_url, JSON.generate({ "title" => "T" }), JSON_CT
    assert_equal({}, json["summary"])
    post notes_url, JSON.generate({ "title" => "T", "summary" => { "es-es" => "" } }), JSON_CT
    assert_equal({ "es-es" => "" }, json["summary"])
  end

  def test_language_maps_merge_in_a_patch
    url = "#{notes_url}/#{note_titled("Buy flour")["id"]}"
    patch url, JSON.generate({ "summary" => { "en" => nil } }), MERGE
    assert_equal({ "es-es" => "Harina" }, json["summary"])
    patch url, JSON.generate({ "summary" => { "en" => "Flour", "fr" => nil } }), MERGE # deleting an unknown tag does nothing
    assert_equal({ "es-es" => "Harina", "en" => "Flour" }, json["summary"])
    etag = json["_etag"]
    patch url, JSON.generate({ "summary" => { "en" => "Flour" } }), MERGE # current: no change
    assert_equal etag, json["_etag"]
    patch url, JSON.generate({ "summary" => { "EN" => nil } }), MERGE
    assert_equal [["/summary/EN", "format"]], assert_problem(422, "invalid")["errors"].map { |e| [e["pointer"], e["code"]] }
    patch url, JSON.generate({ "summary" => nil }), MERGE
    assert_equal({}, json["summary"])
    get "/"
    assert_equal({ "summary" => {} }, json.dig("collections", "notes", "language_maps"))
    update = json.dig("collections", "notes", "schemas", "update", "properties", "summary")
    assert_equal %w[object null], update["type"]
  end

  def test_language_tags
    %w[en es-es es-419 zh-hant-tw sr-latn-rs de-ch-1996 x-private i-klingon en-a-bbb-x-a-ccc].each { |t| assert Restep::Language.tag?(t), t }
    %w[EN es_es e en- -en toolongtag1 en-gb-oed-x].each { |t| refute Restep::Language.tag?(t), t }
  end

  # ---- 2 and 7.1: the principal -----------------------------------------------------------------

  def test_idempotency_keys_belong_to_a_principal
    key = { "HTTP_IDEMPOTENCY_KEY" => '"k-1"' }
    post notes_url, JSON.generate({ "title" => "Once" }), JSON_CT.merge(key).merge("HTTP_X_USER" => "ada")
    assert_equal 201, last_response.status
    first = last_response.headers["location"]
    post notes_url, JSON.generate({ "title" => "Once" }), JSON_CT.merge(key).merge("HTTP_X_USER" => "ada")
    assert_equal "true", last_response.headers["idempotent-replayed"]
    assert_equal first, last_response.headers["location"]
    # Another principal with the same key and another body: its own key, not a mismatch.
    post notes_url, JSON.generate({ "title" => "Other" }), JSON_CT.merge(key).merge("HTTP_X_USER" => "alan")
    assert_equal 201, last_response.status, last_response.body
    refute_equal first, last_response.headers["location"]
    post notes_url, JSON.generate({ "title" => "Other" }), JSON_CT.merge(key).merge("HTTP_X_USER" => "ada")
    assert_problem 422, "idempotency_mismatch"
    # The anonymous principal is one more.
    post notes_url, JSON.generate({ "title" => "Anon" }), JSON_CT.merge(key)
    assert_equal 201, last_response.status
  end

  def test_cursor_and_reads_belong_to_the_principal
    get "#{notes_url}?sort=title", {}, "HTTP_X_USER" => "ada"
    assert_equal "private, no-cache", last_response.headers["cache-control"]
    cursor = json["next"][/cursor=([^&]+)/, 1]
    get "#{notes_url}?sort=title&cursor=#{cursor}", {}, "HTTP_X_USER" => "ada"
    assert_equal 200, last_response.status
    get "#{notes_url}?sort=title&cursor=#{cursor}", {}, "HTTP_X_USER" => "alan"
    assert_equal "cursor", assert_problem(400, "invalid_parameter")["parameter"]
    get "/"
    assert_equal "public, max-age=60", last_response.headers["cache-control"]
  end

  def test_anonymous_keys_can_be_refused
    Restep.config.idempotency_anonymous = false
    post notes_url, JSON.generate({ "title" => "x" }), JSON_CT.merge("HTTP_IDEMPOTENCY_KEY" => '"k"')
    body = assert_problem 400, "bad_request"
    assert_equal [{ "header" => "Idempotency-Key", "code" => "unknown" }], body["errors"].map { |e| e.slice("header", "code") }
    post notes_url, JSON.generate({ "title" => "x" }), JSON_CT.merge("HTTP_IDEMPOTENCY_KEY" => '"k"', "HTTP_X_USER" => "ada")
    assert_equal 201, last_response.status
    get "/"
    assert_equal false, json.dig("idempotency", "anonymous")
  end

  # ---- 5.3: the body limit ----------------------------------------------------------------------

  def test_body_limit_is_configurable
    big = JSON.generate({ "title" => "Big", "body" => "x" * 1500, "pad" => "y" * 200_000 })
    post notes_url, big, JSON_CT
    body = assert_problem 422, "invalid" # read whole: 5 MB allowed, so the unknown member is what fails
    assert_equal "/pad", body["errors"].first["pointer"]
    Restep.config.max_body_bytes = 1024
    post notes_url, big, JSON_CT
    assert_problem 413, "content_too_large"
    assert_includes json["detail"], "1024"
  end

  # ---- 6.4: the cursor secret -------------------------------------------------------------------

  def test_cursor_secret_is_required_and_never_generated
    Restep.config.cursor_secret = nil
    old = ENV.delete("RESTEP_CURSOR_SECRET")
    error = assert_raises(Restep::ConfigurationError) { Restep.check! }
    assert_includes error.message, "cursor_secret"
    Restep.config.cursor_secret = "short"
    assert_raises(Restep::ConfigurationError) { Restep.check! }
    Restep.config.cursor_secret = "a" * 32
    assert Restep.check!
    a = Restep::Cursor.issue({ "x" => 1 })
    Restep.config.cursor_secret = "b" * 32
    assert_nil Restep::Cursor.read(a) # another secret: the old cursor no longer opens
  ensure
    ENV["RESTEP_CURSOR_SECRET"] = old if old
  end

  def test_rails_derives_the_cursor_secret_from_its_key_generator
    require "restep/rails/cursor_secret"
    generator = Object.new
    def generator.generate_key(salt, length) = OpenSSL::KDF.pbkdf2_hmac("secret_key_base", salt: salt, iterations: 1, length: length, hash: "SHA256")
    app = Struct.new(:key_generator).new(generator)
    s = Restep::Rails.cursor_secret_from(app)
    assert_equal 64, s.size
    assert_equal s, Restep::Rails.cursor_secret_from(app)
  end

  def test_idempotency_store_is_required_where_posts_exist
    Restep.config.idempotency_store = nil
    assert_raises(Restep::ConfigurationError) { Restep.check! }
  end

  # ---- 5.8: CORS ---------------------------------------------------------------------------------

  def test_cors_off
    @envelope_options = { cors: false }
    get "/people", {}, "HTTP_ORIGIN" => "https://elsewhere.example"
    assert_nil last_response.headers["access-control-allow-origin"]
    options "/people"
    assert_problem 405, "method_not_allowed"
  end

  def test_cors_with_a_list_of_origins
    @envelope_options = { cors: ["https://editor.example"], credentials: true }
    get "/people", {}, "HTTP_ORIGIN" => "https://editor.example"
    assert_equal "https://editor.example", last_response.headers["access-control-allow-origin"]
    assert_equal "true", last_response.headers["access-control-allow-credentials"]
    assert_equal "Origin", last_response.headers["vary"]
    get "/people", {}, "HTTP_ORIGIN" => "https://evil.example"
    assert_nil last_response.headers["access-control-allow-origin"]
    assert_equal "Origin", last_response.headers["vary"]
    options "/people", {}, "HTTP_ORIGIN" => "https://editor.example"
    assert_equal 204, last_response.status
    assert_includes last_response.headers["access-control-allow-headers"], "Idempotency-Key"
  end

  def test_credentialed_writes_from_other_origins_are_refused
    @envelope_options = { cors: ["https://editor.example"], credentials: true }
    count = store.notes.size
    post notes_url, JSON.generate({ "title" => "csrf" }), JSON_CT.merge("HTTP_ORIGIN" => "https://evil.example")
    assert_problem 403, "forbidden"
    post "#{notes_url}/#{note_titled("Defrost")["id"]}:pin", "", "HTTP_ORIGIN" => "https://evil.example"
    assert_problem 403, "forbidden"
    post notes_url, JSON.generate({ "title" => "csrf" }), JSON_CT.merge("HTTP_SEC_FETCH_SITE" => "cross-site")
    assert_problem 403, "forbidden"
    assert_equal count, store.notes.size
    post notes_url, JSON.generate({ "title" => "ok" }), JSON_CT.merge("HTTP_ORIGIN" => "http://example.org")
    assert_equal 201, last_response.status, last_response.body # the API's own origin (Rack::Test's host)
    post notes_url, JSON.generate({ "title" => "ok" }), JSON_CT.merge("HTTP_ORIGIN" => "https://editor.example")
    assert_equal 201, last_response.status
    post notes_url, JSON.generate({ "title" => "ok" }), JSON_CT.merge("HTTP_ORIGIN" => "null", "HTTP_SEC_FETCH_SITE" => "same-origin")
    assert_equal 201, last_response.status
    get "/people", {}, "HTTP_ORIGIN" => "https://evil.example" # safe: not refused
    assert_equal 200, last_response.status
  end

  def test_cors_star_allows_no_origin_for_credentials
    @envelope_options = { credentials: true }
    post notes_url, JSON.generate({ "title" => "x" }), JSON_CT.merge("HTTP_ORIGIN" => "https://any.example")
    assert_problem 403, "forbidden"
    assert_equal "*", last_response.headers["access-control-allow-origin"]
    assert_nil last_response.headers["access-control-allow-credentials"]
  end

  # ---- 4.2: a hand-written discovery document ---------------------------------------------------

  def bare(c, **over)
    src = c.source.dup
    src.instance_variable_set(:@collection, nil)
    Restep::Collection.new(name: c.name, source: src, fields: c.fields.values.map(&:dup), singleton: c.singleton?,
                           actions: c.actions.values.map(&:dup), default_limit: c.default_limit,
                           named_filters: c.named_filters.transform_values { |d| d.reject { |k, _| k.is_a?(String) } }, **over)
  end

  def install_handwritten(doc, **over)
    colls = %w[people shelves notes comments].to_h { |n| [n, bare(Workspace.const_get(n.upcase), **over.fetch(n.to_sym, {}))] }
    single = bare(Workspace::SETTINGS)
    Restep.reset!
    Workspace.configure(Restep.config)
    Restep.config.collections = colls
    Restep.config.singletons = { "settings" => single }
    Restep.config.discovery = doc
    colls
  end

  def test_handwritten_discovery_is_the_contract
    doc = JSON.parse(JSON.generate(Restep::Discovery.generate))
    doc["collections"]["notes"]["description"] = "Notes, as the contract says."
    doc["collections"]["notes"]["filter"].delete("score")
    doc["collections"]["notes"]["sort"] -= ["score"]
    doc["collections"]["notes"]["max_limit"] = 2
    colls = install_handwritten(doc)
    Restep.check!
    notes = colls["notes"]
    assert_equal "/shelves/{shelf}/notes", notes.path
    assert_equal "Notes, as the contract says.", notes.description
    get "/"
    assert_equal JSON.generate(doc), last_response.body # served as written
    get "#{notes_url}?filter[score][ge]=1" # not in the contract: not offered
    assert_problem 400, "unsupported_parameter"
    get "#{notes_url}?limit=3"
    assert_problem 400, "invalid_parameter"
    assert_equal ["Call Grace", "Fix the tap"], all("#{notes_url}?filter[urgent]&sort=title").map { |n| n["title"] }
  end

  def test_handwritten_discovery_is_validated
    doc = JSON.parse(JSON.generate(Restep::Discovery.generate))
    doc["collections"]["notes"]["path"] = "/notes/{shelf}"
    doc["collections"]["notes"]["filter"]["pinned"]["ops"] = %w[eq lt]
    doc["collections"]["notes"]["x_custom"] = 1
    install_handwritten(doc)
    error = assert_raises(Restep::ConfigurationError) { Restep.check! }
    assert_includes error.message, "boolean filter"
    assert_includes error.message, "parent's path"
    assert_includes error.message, "discovery schema"
  end

  def test_handwritten_discovery_must_agree_with_the_code
    doc = JSON.parse(JSON.generate(Restep::Discovery.generate))
    doc["collections"]["notes"]["actions"].delete("pin")
    doc["collections"]["notes"]["sync"] = { "retention" => 60 }
    doc["profiles"] << "sync"
    doc["collections"].delete("people")
    install_handwritten(doc, notes: { filters: { "title" => { "type" => "integer" } } })
    error = assert_raises(Restep::ConfigurationError) { Restep.check! }
    assert_includes error.message, "action pin is in code but discovery does not declare it"
    assert_includes error.message, "sync is not implemented by this gem"
    assert_includes error.message, "profile sync is not implemented"
    assert_includes error.message, "people is in the catalog but discovery does not declare it"
    assert_includes error.message, "filter title: type is \"integer\" in code"
  end

  def test_discovery_schema_copy_matches_the_site
    site = [File.expand_path("../../../public/1/schema/discovery.json", __dir__),
            File.expand_path("../schema/discovery.json", __dir__)].find { |f| File.exist?(f) }
    skip "no copy of the site's schema here" unless site
    assert_equal File.read(site), File.read(Restep::Rules::SCHEMA_PATH), "lib/restep/schema/discovery.json is out of date: copy public/1/schema/discovery.json"
  end

  def test_rules_catch_what_the_schema_cannot
    doc = { "restep" => Restep::DRAFT, "collections" => {
      "books" => { "path" => "/books", "filter" => { "id" => { "type" => "string", "ops" => %w[lt] }, "x" => { "type" => "string", "ops" => %w[eq] } },
                   "named_filters" => { "x" => { "description" => "clash" } }, "relations" => { "author" => { "to" => "authors" } } },
      "reviews" => { "path" => "/books/{book}/{id}/reviews", "parent" => "books" },
      "orphans" => { "path" => "/x/{a}/y" }
    }, "singletons" => { "featured" => { "path" => "/books/featured" }, "bad" => { "path" => "/a/{b}/c" } } }
    problems = Restep::Rules.problems(doc).join("\n")
    ["id filter declares no order operators", "shares its name with a named filter", "to must name declared collections",
     "reviews: path /books/{book}/{id}/reviews must be its parent's path", "orphans: a path template needs parent",
     "singleton featured: path /books/featured is one that books", "singleton bad: a path template needs parent"].each do |p|
      assert_includes problems, p
    end
  end
end
