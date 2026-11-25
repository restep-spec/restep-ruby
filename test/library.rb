# The test API: one collection of books on SQLite. Loaded by test/restep_test.rb, and by
# test/config.ru to serve it (for example, to run restep-check on it). The database is in memory
# unless RESTEP_TEST_DATABASE names a file: a server needs a file, because each thread of a Rack
# server gets its own connection, and each in-memory connection is a different, empty database.
require "restep"
require "active_record"

ENV["RESTEP_CURSOR_SECRET"] ||= "restep-ruby-test-secret"

ActiveRecord::Base.establish_connection(adapter: "sqlite3", database: ENV.fetch("RESTEP_TEST_DATABASE", ":memory:"))
ActiveRecord::Migration.verbose = false
ActiveRecord::Schema.define do
  create_table :books, force: true do |t|
    t.string :title, null: false
    t.string :genre, null: false
    t.integer :pages, null: false
    t.datetime :created_at, null: false, precision: 6
    t.datetime :updated_at, null: false, precision: 6
  end
  create_table :reviews, force: true do |t|
    t.integer :book_id, null: false
    t.string :text, null: false
    t.datetime :created_at, null: false, precision: 6
    t.datetime :updated_at, null: false, precision: 6
  end
  create_table :journals, force: true do |t|
    t.string :title, null: false
    t.boolean :active, null: false, default: true
    t.datetime :created_at, null: false, precision: 6
    t.datetime :updated_at, null: false, precision: 6
  end
end

class Book < ActiveRecord::Base; end
class Review < ActiveRecord::Base; end
class Journal < ActiveRecord::Base; end

module Library
  GENRES = %w[essay novel poetry].freeze

  BOOKS = Restep::Collection.new(
    name: "books", path: "/books", model: "Book",
    description: "Books in the library.",
    max_limit: 50, default_limit: 20,
    fields: [
      Restep::Fields.f(name: "id", type: "id", read_only: true),
      Restep::Fields.f(name: "title", type: "string", required: true, max_length: 120, description: "Title of the book."),
      Restep::Fields.f(name: "genre", type: "enum", values: GENRES, required: true, description: "Genre."),
      Restep::Fields.f(name: "pages", type: "integer", required: true, range: 1..5000, description: "Number of pages."),
      Restep::Fields.f(name: "created_at", type: "datetime", read_only: true),
      Restep::Fields.f(name: "updated_at", type: "datetime", read_only: true)
    ],
    filters: {
      "title" => { "type" => "string", "ops" => %w[eq ne lt le gt ge in nin prefix contains], sql: "title" },
      "created_at" => { "type" => "datetime", "ops" => %w[lt le gt ge], sql: "created_at" },
      "genre" => { "type" => "enum", "values" => GENRES, "ops" => %w[eq ne in], sql: "genre" }
    },
    sort: { "title" => { sql: "title", type: "string" } }
  )

  # A subcollection on Active Record: the reviews of a book, by its book_id (4.2).
  REVIEWS = Restep::Collection.new(
    name: "reviews", path: "/books/{book}/reviews", parent: "books",
    source: Restep::Sources::ActiveRecord.new("Review", parent_column: "book_id"),
    description: "Reviews of a book.",
    max_limit: 10,
    fields: [
      Restep::Fields.f(name: "id", type: "id", read_only: true),
      Restep::Fields.f(name: "text", type: "string", required: true, max_length: 200),
      Restep::Fields.f(name: "created_at", type: "datetime", read_only: true),
      Restep::Fields.f(name: "updated_at", type: "datetime", read_only: true)
    ],
    filters: { "text" => { "type" => "string", "ops" => %w[eq prefix] } }, # the column of the field: no sql: needed
    sort: { "text" => {} }
  )

  # Draft 7: a default switch (current), item actions with Content-Location, and collection
  # actions that check their statuses (11.1).
  JOURNAL_FIELDS = [
    Restep::Fields.f(name: "id", type: "id", read_only: true),
    Restep::Fields.f(name: "title", type: "string", required: true, max_length: 120),
    Restep::Fields.f(name: "active", type: "boolean", default: true),
    Restep::Fields.f(name: "created_at", type: "datetime", read_only: true),
    Restep::Fields.f(name: "updated_at", type: "datetime", read_only: true)
  ].freeze

  JOURNALS = Restep::Collection.new(
    name: "journals", path: "/journals", model: "Journal",
    description: "Journals, current ones by default.",
    max_limit: 10, default_limit: 2,
    fields: JOURNAL_FIELDS,
    filters: { "title" => { "type" => "string", "ops" => %w[eq], sql: "title" } },
    named_filters: {
      "current" => { "description" => "Journals still published. On by default.", "default" => true,
                     sql: ->(_) { ["active = ?", true] } }
    },
    actions: [
      Restep::Fields.action("archive", on: "item", effects: [], description: "Stop publishing the journal.",
                            available: ->(rec) { rec.active },
                            run: ->(rec, _) { rec.update!(active: false, updated_at: Time.now.utc) }),
      Restep::Fields.action("ping", on: "item", idempotent: true, run: ->(_rec, _) {}),
      Restep::Fields.action("bulk", on: "collection", effects: ["destroys"], run: ->(_model, _) { [204, nil] }),
      Restep::Fields.action("wrong", on: "collection", run: ->(_model, _) { [200, { "done" => true }] }),
      Restep::Fields.action("stats", on: "collection", method: "GET", safe: true, idempotent: true,
                            output: { "type" => "object", "properties" => { "count" => { "type" => "integer" } } },
                            run: ->(model, _) { [200, { "count" => model.count }] }),
      Restep::Fields.action("tally", on: "collection", method: "GET", safe: true, idempotent: true,
                            run: ->(model, _) { [200, { "count" => model.count }] })
    ]
  )

  # The same journals behind a required filter (6.1).
  PAPERS = Restep::Collection.new(
    name: "papers", path: "/papers", model: "Journal",
    description: "Journals, found only by title.",
    max_limit: 10, default_limit: 10,
    fields: JOURNAL_FIELDS,
    filters: { "title" => { "type" => "string", "ops" => %w[eq], "required" => true, sql: "title" } }
  )

  def self.seed
    now = Time.now.utc.floor(6)
    [["Bleak House", "novel", 1017], ["Leaves of Grass", "poetry", 145], ["Middlemarch", "novel", 880],
     ["Ariel", "poetry", 96], ["The Myth of Sisyphus", "essay", 212]].each do |title, genre, pages|
      Book.create!(title: title, genre: genre, pages: pages, created_at: now, updated_at: now)
    end
    [["Granta", true], ["Ploughshares", true], ["The Dial", false], ["Zyzzyva", true]].each do |title, active|
      Journal.create!(title: title, active: active, created_at: now, updated_at: now)
    end
    %w[Dense. Endless. Vast.].each { |text| Review.create!(book_id: 1, text: text, created_at: now, updated_at: now) }
  end
end

Restep.configure do |c|
  c.collections = { "books" => Library::BOOKS, "reviews" => Library::REVIEWS, "journals" => Library::JOURNALS, "papers" => Library::PAPERS }
  c.idempotency_store = Restep::Idempotency::MemoryStore.new
end
Library.seed
