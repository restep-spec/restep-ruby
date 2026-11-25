# Serves the test API, with a Rack server such as puma, on a fresh SQLite file:
#   RESTEP_TEST_DATABASE=/tmp/restep-test.sqlite3 puma test/config.ru
require_relative "library"

use Restep::Envelope
run Restep::RackApp.new
