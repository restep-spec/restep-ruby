require_relative "lib/restep/version"

Gem::Specification.new do |s|
  s.name = "restep"
  s.version = Restep::VERSION
  s.summary = "Restep 1 for Ruby: the protocol on Rack, over Active Record or any data source"
  s.description = "Query parsing, filters, cursors, ETags and conditional requests, idempotency, discovery " \
                  "(generated or hand-written and validated), subcollections, relations and language maps of " \
                  "Restep 1, with a Rack application and a Rails concern. Data comes from sources: Active Record " \
                  "(optional) or lambdas for resources computed by the domain."
  s.authors = ["wubytes"]
  s.license = "MIT"
  s.homepage = "https://w3id.org/restep/tools/restep-ruby/"
  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => "https://github.com/restep-spec/restep-ruby",
    "bug_tracker_uri" => "https://github.com/restep-spec/restep-ruby/issues",
    "documentation_uri" => "https://w3id.org/restep/1/",
    "rubygems_mfa_required" => "true"
  }
  s.required_ruby_version = ">= 3.4"
  s.files = Dir["lib/**/*.rb"] + Dir["lib/restep/schema/*.json"] + ["README.md"] + Dir["LICENSE"]
  s.add_dependency "rack", ">= 3.0"
end
