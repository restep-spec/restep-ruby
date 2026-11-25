require "json"
require "bigdecimal"
require "date"
require "digest"
require "openssl"
require "base64"
require "securerandom"
require "rack"
require "active_record"

# Restep 1 (draft 7) for Ruby: the protocol part, with no domain and no framework. Two servers
# use it over the same domain: tools/restep-rack (plain Rack, a single entry point,
# Restep::RackApp) and tools/restep-rails (idiomatic Rails, one controller per resource with
# Restep::Rails::Controller). Both call Restep::Operations with a Restep::Context.
module Restep
  PROFILE_URI = "https://w3id.org/restep/1/".freeze # identifier: profile link and error types
  PROFILE_LINK = %(<#{PROFILE_URI}>; rel="profile").freeze
  PRINCIPAL = "anonymous".freeze # no authentication: a single principal

  # What the application supplies: its catalog and where it keeps its data.
  class Config
    attr_accessor :collections,       # { "stations" => Collection, ... }
                  :singletons,        # { "network" => Collection (singleton), ... }
                  :reasons,           # catalog of domain reasons (§5.4)
                  :idempotency_model, # Active Record model for the keys (§7.1)
                  :cursor_key_path,   # file holding the cursor secret (§6.4)
                  :docs_path,         # human-readable documentation, served at /docs (§4.2)
                  :root_path,         # path of the API root, no trailing slash: "" or "/v1" (§2)
                  :logger

    def initialize
      @collections, @singletons, @reasons = {}, {}, {}
      @root_path = ""
    end
  end

  class << self
    def config = @config ||= Config.new
    def configure = yield(config)

    def collections = config.collections
    def singletons = config.singletons
    # §2: the discovery paths are relative to the API root; the links in bodies and headers
    # (href, next, Location, Link) are absolute paths that include it.
    def url(path) = "#{config.root_path}#{path}"

    def collection_by_path(path) = collections.values.find { |c| c.path == path }
    def singleton_by_path(path) = singletons.values.find { |c| c.path == path }
  end
end

require_relative "restep/version"

%w[problem query_string types collection envelope conditional cursor query body idempotency
   discovery request resolver context operations rack_app].each do |f|
  require_relative "restep/#{f}"
end
