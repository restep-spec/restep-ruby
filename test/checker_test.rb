# restep-check --writes against the in-memory test API of test/workspace.rb (a subcollection and a
# singleton under an item, served by Restep::Sources::Computed, with no Active Record), on Puma
# in this process and a free local port. It runs inside the site's repository, where the checker
# is (tools/restep-check), and with Node.js; elsewhere it is skipped.
require "minitest/autorun"
require "open3"
require "puma"
require "puma/server"

require_relative "library" # the books API: restored afterwards
require_relative "workspace"

class CheckerTest < Minitest::Test
  CHECKER = File.join(__dir__, "..", "..", "restep-check", "restep-check.mjs")

  def test_the_workspace_api_passes_restep_check
    skip "restep-check is not here (it is in the site's repository)" unless File.exist?(CHECKER)
    skip "Node.js is not installed" unless system("node", "--version", out: File::NULL, err: File::NULL)
    saved = Workspace.install!
    app = Rack::Builder.new do
      use Restep::Envelope
      run Restep::RackApp.new
    end.to_app
    server = Puma::Server.new(app, nil, min_threads: 1, max_threads: 4, supported_http_methods: :any, log_writer: Puma::LogWriter.null)
    server.add_tcp_listener("127.0.0.1", 0)
    port = server.connected_ports.first
    thread = server.run
    out, status = Open3.capture2e("node", CHECKER, "http://127.0.0.1:#{port}/", "--writes")
    summary = out.lines.last.to_s
    failures = out.lines.grep(/^\s+(FAIL|WARN)\s/)
    assert status.success? || failures.empty?, out
    assert_match(/\A0 failed · 0 warnings · \d+ passed/, summary, failures.join)
  ensure
    server&.stop(true)
    thread&.join(5)
    Restep.reset!(saved) if saved
  end
end
