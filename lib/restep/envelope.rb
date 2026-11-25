module Restep
  # Outer middleware: runs before the whole stack (Rails', or Restep::RackApp directly).
  # - A method the server does not know gives 501 not_implemented (§5.4). Without this, Rails
  #   raises ActionController::UnknownHttpMethod and answers 405 without problem+json.
  # - OPTIONS only serves the CORS preflight (§5.8), with no Restep rules.
  # - Profile header (§4.1) and CORS on every response, errors included.
  class Envelope
    KNOWN = %w[GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT].freeze
    # §5.8 (draft 7): Content-Location joins the list, for the 200 of an action (7.2), and
    # Accept-Post, for the 415 of a collection that only takes uploads (5.1).
    EXPOSE = "ETag, Location, Content-Location, Link, Allow, Accept-Patch, Accept-Post, Retry-After, Deprecation, Sunset, " \
             "Idempotent-Replayed, Preference-Applied, Accept-Query, WWW-Authenticate"

    def initialize(app) = @app = app

    def call(env)
      method = env["REQUEST_METHOD"].to_s
      # Rails parses the query and the body as soon as anyone asks for `params`, and its own
      # instrumentation (the "Parameters: ..." log line) asks for it before entering the action:
      # with "filter[a]=1&filter[a][b]=2" it raises BadRequest before the application can give
      # the 404 or the 405 that come first in §5.4. Its caches are filled with empty hashes so
      # that it parses nothing; the application reads QUERY_STRING and the raw body.
      env["action_dispatch.request.query_parameters"] = {}
      env["action_dispatch.request.request_parameters"] = {}
      status, headers, body =
        if method == "OPTIONS"
          [204, { "access-control-allow-methods" => "GET, HEAD, POST, PATCH, DELETE, QUERY",
                  "access-control-allow-headers" => "Content-Type, Content-Disposition, If-Match, If-None-Match, Idempotency-Key, Prefer, Authorization, DPoP",
                  "access-control-max-age" => "600" }, []]
        elsif !KNOWN.include?(method)
          Problem.rack(501, "not_implemented", detail: "This server does not implement the #{method} method.")
        else
          @app.call(env)
        end
      headers["link"] = [headers["link"], PROFILE_LINK].compact.reject(&:empty?).join(", ")
      headers["access-control-allow-origin"] = "*"
      headers["access-control-expose-headers"] = EXPOSE
      [status, headers, body]
    end
  end
end
