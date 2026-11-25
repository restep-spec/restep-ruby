# Serves the in-memory test API of test/workspace.rb (no database), for example to run
# restep-check on it:
#   bundle exec puma -p 9292 test/workspace.ru
require "logger"
require_relative "workspace"

Workspace.install!
use Restep::Envelope
run Restep::RackApp.new(logger: Logger.new($stderr))
