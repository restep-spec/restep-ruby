require "json"
require "bigdecimal"
require "date"
require "digest"
require "openssl"
require "base64"
require "securerandom"
require "rack"

# Restep 1 (draft 7) for Ruby: the protocol part, with no domain and no framework. The data comes
# from sources (Restep::Source): Active Record is one of them (Restep::Sources::ActiveRecord,
# loaded only when used), and Restep::Sources::Computed serves resources computed by the domain.
# Two servers use it over the same domain: tools/restep-rack (plain Rack, a single entry point,
# Restep::RackApp) and tools/restep-rails (idiomatic Rails, one controller per resource with
# Restep::Rails::Controller). Both call Restep::Operations with a Restep::Context.
#
# The gem owns the top-level constant Restep and every constant under it: an application must not
# define its own Restep::* constants (see "Namespace" in the README).
module Restep
  PROFILE_URI = "https://w3id.org/restep/1/".freeze # identifier: profile link and error types
  PROFILE_LINK = %(<#{PROFILE_URI}>; rel="profile").freeze
  DRAFT = "1.0-draft.7".freeze
  # §2 and §7.1: requests without an authenticated principal all count as one anonymous principal.
  # It is stored apart from every principal an application can return (those are prefixed).
  ANONYMOUS = "anonymous".freeze

  # A configuration error found when the application boots (Restep.check!): the catalog, the
  # discovery document or a secret. It is raised, never answered as a problem.
  class ConfigurationError < StandardError; end

  # What the application supplies: its catalog, where it keeps its data and its secrets.
  class Config
    attr_accessor :collections,       # { "stations" => Collection, ... }
                  :singletons,        # { "network" => Collection (singleton), ... }
                  :reasons,           # catalog of domain reasons (§5.4)
                  :idempotency_model, # Active Record model for the keys (§7.1), or
                  :idempotency_store, # any store (Restep::Idempotency::MemoryStore, ...)
                  :idempotency_anonymous, # false: refuse Idempotency-Key without a principal (§7.1)
                  :cursor_secret,     # secret the cursor keys derive from (§6.4); required
                  :principal,         # ->(request) { "user-7" or nil }: who the request acts for (§2)
                  :discovery,         # hand-written discovery document: a path or a Hash (§4.2)
                  :max_body_bytes,    # largest request body, in bytes (413 above it)
                  :docs_path,         # human-readable documentation, served at /docs (§4.2)
                  :docs_language,     # hreflang of that documentation
                  :root_path,         # path of the API root, no trailing slash: "" or "/v1" (§2)
                  :logger

    def initialize
      @collections, @singletons, @reasons = {}, {}, {}
      @root_path = ""
      @max_body_bytes = Body::MAX_BYTES
      @idempotency_anonymous = true
      @docs_language = "es"
    end
  end

  class << self
    def config = @config ||= Config.new

    def configure
      yield(config)
      @checked = false
      @catalog = nil
    end

    # Replaces the whole configuration (tests that serve more than one catalog).
    def reset!(new_config = Config.new)
      @config = new_config
      @checked = false
      @catalog = nil
    end

    def collections = config.collections
    def singletons = config.singletons
    # §2: the discovery paths are relative to the API root; the links in bodies and headers
    # (href, next, Location, Link) are absolute paths that include it.
    def url(path) = "#{config.root_path}#{path}"

    # Every resource of the catalog, collections and singletons, for the resolver.
    def catalog = @catalog ||= collections.values + singletons.values

    def collection_by_path(path) = collections.values.find { |c| c.path == path }
    def singleton_by_path(path) = singletons.values.find { |c| c.path == path }

    # §2: who the request acts for, as a string, or nil for the anonymous principal. It comes from
    # the application (config.principal), never from the credential itself.
    def principal_for(request)
      fn = config.principal
      return nil if fn.nil?
      p = fn.call(request)
      return nil if p.nil?
      raise ConfigurationError, "config.principal must return a non-empty String or nil, not #{p.inspect}" unless p.is_a?(String) && !p.empty?
      p
    end

    # The principal as the idempotency store and the cursor keep it: the anonymous one apart from
    # any the application returns.
    def principal_key(principal) = principal.nil? ? ANONYMOUS : "p:#{principal}"

    # Whether responses depend on credentials (§5.1): then reads are private.
    def private_responses? = !config.principal.nil?

    # Checks the configuration and fails loudly (ConfigurationError) on what would break later:
    # the cursor secret, the idempotency store, the catalog against the rules of draft 7 and, if
    # there is one, the hand-written discovery document. Restep::RackApp.new and the Rails
    # railtie call it at boot; it runs once per configuration.
    def check!
      return true if @checked
      Check.run!
      @checked = true
    end

    def checked? = @checked
  end
end

require_relative "restep/version"

%w[problem query_string types merge_patch language template parents source collection envelope conditional cursor
   query body idempotency discovery rules check request resolver context relations operations
   sources/computed rack_app].each do |f|
  require_relative "restep/#{f}"
end

# Active Record is loaded only when the application uses it: Restep::Sources::ActiveRecord (or
# a collection declared with model:) and Restep::Idempotency::ActiveRecordStore.
module Restep
  module Sources
    autoload :ActiveRecord, "restep/sources/active_record"
  end
end
