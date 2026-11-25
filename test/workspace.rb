# A second test API, with no Active Record at all: shelves of notes kept in memory and served
# through Restep::Sources::Computed. It has a subcollection (/shelves/{shelf}/notes), a
# subcollection of it (/shelves/{shelf}/notes/{note}/comments), a singleton under an item
# (/shelves/{shelf}/settings), ids that are document keys, relationships (one includable, one to a
# subcollection's item), language maps, a principal taken from a header and a 5 MB body limit.
# Loaded by test/workspace_test.rb and test/checker_test.rb, and by test/workspace.ru to serve it.
require "monitor"
require "restep"

module Workspace
  # The domain: plain hashes behind a lock, as a service computing them would hand them over.
  class Store
    attr_reader :people, :shelves, :notes, :comments, :settings

    def initialize
      @lock = Mutex.new
      @write_lock = Monitor.new
      @seq = 0
      @people, @shelves, @notes, @comments, @settings = {}, {}, {}, {}, {}
      seed
    end

    # Milliseconds: restep-check 0.10.0 parses instants with Date.parse, so it cannot tell apart two
    # that differ by microseconds, which the gem compares exactly (§6.1).
    def now = Time.now.utc.floor(3)
    # One write at a time; a Monitor lets a write nest another (an action that updates its note).
    def write(&) = @write_lock.synchronize(&)

    def key(prefix) = @lock.synchronize { "#{prefix}-#{(@seq += 1).to_s(36)}" }

    def seed
      { "ada" => "Ada Lovelace", "alan" => "Alan Turing", "grace" => "Grace Hopper" }.each do |id, name|
        @people[id] = { "id" => id, "name" => name }
      end
      kitchen = create_shelf("name" => "Kitchen", "labels" => { "en" => "Kitchen", "es-es" => "Cocina" })
      create_shelf("name" => "Garage", "labels" => {})
      create_shelf("name" => "Attic", "labels" => { "en" => "Attic" })
      [["Buy flour", 2, "ada", "2026-12-01", "1.5"], ["Fix the tap", 5, "alan", nil, nil], ["Call Grace", 4, "grace", "2026-11-30", "9.0"],
       ["Defrost", 1, nil, nil, "0.5"], ["Bake bread", 3, "ada", "2026-12-02", nil]].each do |title, prio, author, due, score|
        create_note({ "title" => title, "body" => nil, "priority" => prio, "author_id" => author,
                      "due_on" => due && Date.iso8601(due), "score" => score && BigDecimal(score), "pinned" => false,
                      "summary" => { "Buy flour" => { "en" => "Flour", "es-es" => "Harina" }, "Bake bread" => { "es-es" => "Pan" } }.fetch(title, {}),
                      "tags" => title == "Buy flour" ? %w[shop] : [],
                      "meta" => title == "Buy flour" ? { "store" => { "name" => "Corner shop", "open" => true }, "qty" => 1.5 } : nil },
                    kitchen["id"])
      end
      first = @notes.values.first
      kitchen["featured_id"] = first["id"]
      create_comment({ "text" => "Wholemeal?", "in_reply_to" => nil }, first["id"])
    end

    def create_shelf(attrs)
      id = key("shelf")
      @settings[id] = { "color" => "white", "public" => false }
      @shelves[id] = attrs.merge("id" => id, "created_at" => now)
    end

    def delete_shelf(rec)
      @notes.values.select { |n| n["shelf_id"] == rec["id"] }.each { |n| delete_note(n) }
      @settings.delete(rec["id"])
      @shelves.delete(rec["id"])
    end

    def create_note(attrs, shelf_id)
      t = now
      id = key("note")
      @notes[id] = attrs.merge("id" => id, "shelf_id" => shelf_id, "created_at" => t, "updated_at" => t)
    end

    def update(rec, changes)
      rec.merge!(changes)
      rec["updated_at"] = now if rec.key?("updated_at")
      rec
    end

    def delete_note(rec)
      @comments.delete_if { |_, c| c["note_id"] == rec["id"] }
      @notes.delete(rec["id"])
    end

    def create_comment(attrs, note_id) = (id = key("c")) && @comments[id] = attrs.merge("id" => id, "note_id" => note_id, "created_at" => now)
  end

  def self.store = @store ||= Store.new
  def self.reset! = @store = Store.new

  F = Restep::Fields

  PEOPLE = Restep::Collection.new(
    name: "people", path: "/people", description: "People who write notes. Read only.",
    max_limit: 10,
    source: Restep::Sources::Computed.new(all: ->(_) { Workspace.store.people.values }, locate: ->(id) { Workspace.store.people[id] }),
    fields: [F.f(name: "id", type: "id", read_only: true), F.f(name: "name", type: "string", read_only: true)],
    sort: { "name" => {} }
  )

  SHELVES = Restep::Collection.new(
    name: "shelves", path: "/shelves", description: "Shelves, each with its notes.",
    max_limit: 10,
    source: Restep::Sources::Computed.new(
      all: ->(_) { Workspace.store.shelves.values },
      locate: ->(id) { Workspace.store.shelves[id] },
      create: ->(attrs, _) { Workspace.store.create_shelf(attrs) },
      update: ->(rec, changes) { Workspace.store.update(rec, changes) },
      delete: ->(rec) { Workspace.store.delete_shelf(rec) }
    ),
    fields: [
      F.f(name: "id", type: "id", read_only: true),
      F.f(name: "name", type: "string", required: true, max_length: 60, description: "Name of the shelf."),
      F.f(name: "labels", type: "language_map", description: "The shelf's name in other languages."),
      # A relationship to an item of a subcollection: its object carries href (§3).
      F.f(name: "featured", type: "relation", column: "featured_id", relation: "notes", nullable: true,
          description: "The note shown first, one of its own."),
      F.f(name: "created_at", type: "datetime", read_only: true)
    ],
    filters: { "name" => { "type" => "string", "ops" => %w[eq prefix] }, "labels.es-es" => { "type" => "string", "ops" => %w[eq] } },
    sort: { "name" => {}, "labels.es-es" => {} },
    # §9: the relationship that leads to the subcollection, declared only in discovery.
    relations: { "notes" => { "to" => "notes", "many" => true, "path" => "/shelves/{shelf}/notes" } }
  )

  NOTE_IN_SHELF = ->(id, parents) { (n = Workspace.store.notes[id]) && n["shelf_id"] == parents["shelf"] ? n : nil }

  NOTES = Restep::Collection.new(
    name: "notes", path: "/shelves/{shelf}/notes", parent: "shelves",
    description: "Notes on a shelf.",
    max_limit: 3, default_limit: 2,
    source: Restep::Sources::Computed.new(
      all: ->(parents) { Workspace.store.notes.values.select { |n| n["shelf_id"] == parents["shelf"] } },
      find: NOTE_IN_SHELF,
      locate: ->(id) { Workspace.store.notes[id] },
      parent_ids: ->(n) { [n["shelf_id"]] },
      create: ->(attrs, parents) { Workspace.store.create_note(attrs, parents["shelf"]) },
      update: ->(rec, changes) { Workspace.store.update(rec, changes) },
      delete: ->(rec) { Workspace.store.delete_note(rec) },
      transaction: ->(&write) { Workspace.store.write(&write) } # If-Match and the write, atomic (7.2)
    ),
    fields: [
      F.f(name: "id", type: "id", read_only: true),
      F.f(name: "title", type: "string", required: true, max_length: 80, description: "What to do."),
      F.f(name: "body", type: "string", nullable: true, max_length: 2000),
      F.f(name: "priority", type: "integer", range: 1..5, default: 3),
      F.f(name: "due_on", type: "date", nullable: true),
      F.f(name: "score", type: "decimal", scale: 1, range: BigDecimal("0")..BigDecimal("10"), nullable: true),
      F.f(name: "pinned", type: "boolean", default: false),
      F.f(name: "author", type: "relation", column: "author_id", relation: "people", nullable: true, include: true,
          description: "Who wrote it."),
      F.f(name: "summary", type: "language_map", languages: %w[en es-es]),
      # Documents the note carries: any JSON array or object, described by its schema (4.3) and
      # checked by validate:. A PATCH merges meta member by member (RFC 7396) and replaces tags.
      F.f(name: "tags", type: "array", default: [], schema: { "items" => { "type" => "string" }, "maxItems" => 10 },
          validate: ->(v, ptr) { v.each_with_index.reject { |t, _| t.is_a?(String) }.map { |_, i| { "pointer" => "#{ptr}/#{i}", "code" => "type", "detail" => "A tag is a string." } } },
          description: "Free labels."),
      F.f(name: "meta", type: "object", nullable: true, schema: { "properties" => { "qty" => { "type" => "number" } } },
          description: "Whatever else the note needs to keep."),
      F.f(name: "created_at", type: "datetime", read_only: true),
      F.f(name: "updated_at", type: "datetime", read_only: true)
    ],
    filters: {
      "id" => { "type" => "string", "ops" => %w[eq in] },
      "title" => { "type" => "string", "ops" => %w[eq ne lt le gt ge in nin prefix contains] },
      "priority" => { "type" => "integer", "ops" => %w[eq ne lt le gt ge in] },
      "due_on" => { "type" => "date", "ops" => %w[lt ge null] },
      "score" => { "type" => "decimal", "ops" => %w[eq lt ge null] },
      "pinned" => { "type" => "boolean", "ops" => %w[eq] },
      "author.id" => { "type" => "string", "ops" => %w[eq in null] },
      "summary.en" => { "type" => "string", "ops" => %w[eq prefix] },
      "updated_at" => { "type" => "datetime", "ops" => %w[lt ge] }
    },
    named_filters: {
      "urgent" => { "description" => "Notes of priority 4 or 5.", match: ->(r, _) { r["priority"] >= 4 } },
      "search" => { "type" => "string", "description" => "Title contains the text, ignoring case.",
                    match: ->(r, v) { r["title"].downcase.include?(v.downcase) } }
    },
    sort: { "title" => {}, "priority" => {}, "due_on" => {}, "score" => {}, "updated_at" => {} },
    actions: [
      F.action("pin", on: "item", effects: [], description: "Pin the note.", available: ->(r) { !r["pinned"] },
                      run: ->(r, _) { Workspace.store.update(r, "pinned" => true) }),
      # A safe action with POST (11.1): a result computed from its input, which is not the note.
      F.action("compare", on: "item", safe: true, idempotent: true, description: "Which fields differ from the ones sent.",
                          input: [F.f(name: "with", type: "object", required: true)],
                          output: { "type" => "object", "properties" => { "differs" => { "type" => "array", "items" => { "type" => "string" } } } },
                          run: ->(r, input) { [200, { "differs" => input["with"].keys.select { |k| r[k] != input["with"][k] }.sort }] }),
      # An unsafe item action that creates another item: 201 with its Location (11.1).
      F.action("copy", on: "item", effects: [], description: "Copy the note into the same shelf.",
                       run: lambda { |r, _|
                         copy = Workspace.store.create_note(r.slice("title", "body", "priority", "due_on", "score", "author_id", "summary", "tags", "meta").merge("pinned" => false), r["shelf_id"])
                         Restep::Created.new(NOTES.item_url(copy["id"], [r["shelf_id"]]))
                       }),
      # An unsafe item action that answers nothing (204).
      F.action("touch", on: "item", idempotent: true, effects: [], description: "Mark the note as seen now.",
                        run: ->(r, _) { Workspace.store.update(r, {}) && Restep::NO_CONTENT }),
      F.action("stats", on: "collection", method: "GET", safe: true, idempotent: true, description: "How many notes the shelf has.",
                        output: { "type" => "object", "properties" => { "count" => { "type" => "integer" } } },
                        run: ->(parents, _) { [200, { "count" => Workspace.store.notes.values.count { |n| n["shelf_id"] == parents["shelf"] } }] })
    ]
  )

  COMMENTS = Restep::Collection.new(
    name: "comments", path: "/shelves/{shelf}/notes/{note}/comments", parent: "notes",
    description: "Comments on a note.",
    max_limit: 20,
    source: Restep::Sources::Computed.new(
      all: ->(parents) { Workspace.store.comments.values.select { |c| c["note_id"] == parents["note"] } },
      locate: ->(id) { Workspace.store.comments[id] },
      parent_ids: ->(c) { n = Workspace.store.notes[c["note_id"]]; [n["shelf_id"], n["id"]] },
      create: ->(attrs, parents) { Workspace.store.create_comment(attrs, parents["note"]) },
      delete: ->(rec) { Workspace.store.comments.delete(rec["id"]) }
    ),
    fields: [
      F.f(name: "id", type: "id", read_only: true),
      F.f(name: "text", type: "string", required: true, max_length: 500),
      F.f(name: "in_reply_to", type: "relation", relation: "comments", nullable: true, description: "The comment it answers."),
      F.f(name: "created_at", type: "datetime", read_only: true)
    ],
    sort: { "created_at" => {} }
  )

  SETTINGS = Restep::Collection.new(
    name: "settings", path: "/shelves/{shelf}/settings", parent: "shelves", singleton: true,
    description: "How a shelf is shown.",
    source: Restep::Sources::Computed.new(get: ->(parents) { Workspace.store.settings[parents["shelf"]] },
                                          update: ->(rec, changes) { rec.merge!(changes) }),
    method_effects: { "PATCH" => [] },
    fields: [
      F.f(name: "color", type: "enum", values: %w[white red green], required: true),
      F.f(name: "public", type: "boolean", required: true)
    ]
  )

  def self.configure(c)
    c.collections = { "people" => PEOPLE, "shelves" => SHELVES, "notes" => NOTES, "comments" => COMMENTS }
    c.singletons = { "settings" => SETTINGS }
    c.idempotency_store = Restep::Idempotency::MemoryStore.new
    c.cursor_secret = "workspace-test-cursor-secret"
    # §2: who the request acts for comes from the application; here, a header.
    c.principal = ->(request) { request.header("X-User") }
    c.max_body_bytes = 5 * 1024 * 1024
    c.docs_path = File.expand_path("../README.md", __dir__)
    c.docs_language = "en"
  end

  # Makes this API the one Restep serves, and returns the configuration it replaced.
  def self.install!
    saved = Restep.config
    reset! # seeded now, not lazily on the first request: a server's threads would race to seed it
    Restep.reset!
    configure(Restep.config)
    saved
  end
end
