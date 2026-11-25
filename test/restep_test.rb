# Self-contained test of the gem: a small Restep API (one collection of books) on an in-memory
# SQLite database, served by Restep::Envelope + Restep::RackApp and exercised with Rack::Test.
#
#   bundle exec rake test
#
# The gem targets PostgreSQL (casts such as ::bigint, COLLATE "C", FOR UPDATE NOWAIT for
# idempotency). SQLite covers what this test uses: discovery, lists, string and enum filters,
# sort, cursors, errors, ETags and a plain POST and PATCH.
require "minitest/autorun"
require "rack/test"

require_relative "library"

class RestepTest < Minitest::Test
  include Rack::Test::Methods

  def app
    @app ||= Rack::Builder.new do
      use Restep::Envelope
      run Restep::RackApp.new
    end.to_app
  end

  def json = JSON.parse(last_response.body)

  def test_version
    assert_match(/\A\d+\.\d+\.\d+\z/, Restep::VERSION)
  end

  def test_discovery
    get "/"
    assert_equal 200, last_response.status
    assert_equal "application/json", last_response.content_type
    assert_includes last_response.headers["link"], %(<https://w3id.org/restep/1/>; rel="profile")
    doc = json
    assert_equal "/books", doc.dig("collections", "books", "path")
    assert_equal %w[title], doc.dig("collections", "books", "sort")
    assert_equal %w[eq ne in], doc.dig("collections", "books", "filter", "genre", "ops")
    assert_equal %w[title genre pages], doc.dig("collections", "books", "schemas", "create", "required")
  end

  def test_list
    get "/books"
    assert_equal 200, last_response.status
    doc = json
    assert_equal 5, doc["items"].size
    assert_nil doc["next"]
    first = doc["items"].first
    assert_equal "1", first["id"]
    assert_equal "Bleak House", first["title"]
    assert_match(/\A"[0-9a-f]{32}"\z/, first["_etag"])
  end

  def test_filter_and_sort
    get "/books?filter[genre]=poetry&sort=title"
    assert_equal 200, last_response.status
    assert_equal ["Ariel", "Leaves of Grass"], json["items"].map { |b| b["title"] }
  end

  def test_cursor
    get "/books?limit=2&sort=-title"
    assert_equal 200, last_response.status
    titles = json["items"].map { |b| b["title"] }
    next_link = json["next"]
    refute_nil next_link
    while next_link
      get next_link
      assert_equal 200, last_response.status
      titles += json["items"].map { |b| b["title"] }
      next_link = json["next"]
    end
    assert_equal ["The Myth of Sisyphus", "Middlemarch", "Leaves of Grass", "Bleak House", "Ariel"], titles
  end

  def test_unknown_filter_is_a_problem
    get "/books?filter[pages]=100"
    assert_equal 400, last_response.status
    assert_equal "application/problem+json", last_response.content_type
    assert_equal "https://w3id.org/restep/1/errors#unsupported_parameter", json["type"]
    assert_equal "filter[pages]", json["parameter"]
  end

  def test_not_found_is_a_problem
    get "/books/999"
    assert_equal 404, last_response.status
    assert_equal "application/problem+json", last_response.content_type
    assert_equal "not_found", json["code"]
  end

  def test_method_not_allowed
    delete "/books"
    assert_equal 405, last_response.status
    assert_equal "GET, HEAD, POST", last_response.headers["allow"]
  end

  def test_etag_and_if_none_match
    get "/books/2"
    assert_equal 200, last_response.status
    etag = last_response.headers["etag"]
    assert_equal json["_etag"], etag
    get "/books/2", {}, "HTTP_IF_NONE_MATCH" => etag
    assert_equal 304, last_response.status
    assert_empty last_response.body
  end

  # 4.2: a subcollection on Active Record, scoped by parent_column.
  def test_subcollection_on_active_record
    get "/books/1/reviews?sort=text&limit=2"
    assert_equal 200, last_response.status, last_response.body
    assert_equal %w[Dense. Endless.], json["items"].map { |r| r["text"] }
    get json["next"]
    assert_equal %w[Vast.], json["items"].map { |r| r["text"] }
    get "/books/1/reviews?filter[text][prefix]=E"
    assert_equal %w[Endless.], json["items"].map { |r| r["text"] }
    id = Review.find_by(text: "Vast.").id
    get "/books/1/reviews/#{id}"
    assert_equal "Vast.", json["text"]
    get "/books/2/reviews/#{id}"
    assert_equal 404, last_response.status
    get "/books/999/reviews"
    assert_equal 404, last_response.status
    post "/books/2/reviews", JSON.generate({ "text" => "Short." }), "CONTENT_TYPE" => "application/json"
    assert_equal 201, last_response.status, last_response.body
    assert_match %r{\A/books/2/reviews/\d+\z}, last_response.headers["location"]
    assert_equal 2, Review.find(json["id"].to_i).book_id
    delete last_response.headers["location"]
    assert_equal 204, last_response.status
  ensure
    Review.where(text: "Short.").delete_all
  end

  def test_create_and_conditional_patch
    post "/books", JSON.generate({ "title" => "Walden", "genre" => "essay", "pages" => 352 }), "CONTENT_TYPE" => "application/json"
    assert_equal 201, last_response.status
    location = last_response.headers["location"]
    assert_match(%r{\A/books/\d+\z}, location)
    etag = last_response.headers["etag"]

    patch location, JSON.generate({ "pages" => 1 }), "CONTENT_TYPE" => "application/merge-patch+json", "HTTP_IF_MATCH" => '"stale"'
    assert_equal 412, last_response.status

    patch location, JSON.generate({ "pages" => 353 }), "CONTENT_TYPE" => "application/merge-patch+json", "HTTP_IF_MATCH" => etag
    assert_equal 200, last_response.status
    assert_equal 353, json["pages"]

    post "/books", JSON.generate({ "title" => "", "genre" => "memoir" }), "CONTENT_TYPE" => "application/json"
    assert_equal 422, last_response.status
    assert_equal %w[/genre /pages /title], json["errors"].map { |e| e["pointer"] }.sort
  ensure
    Book.where(title: "Walden").delete_all
  end
end
