module Restep
  # Outer middleware: runs before the whole stack (Rails', or Restep::RackApp directly).
  # - A method the server does not know gives 501 not_implemented (§5.4). Without this, Rails
  #   raises ActionController::UnknownHttpMethod and answers 405 without problem+json.
  # - Profile header (§4.1) on every response, errors included.
  # - CORS (§5.8), as the application chooses:
  #     use Restep::Envelope                                   # cors: "*" (the default): any origin
  #     use Restep::Envelope, cors: false                      # none: a same-origin API
  #     use Restep::Envelope, cors: ["https://app.example"]    # those origins, named back with Vary: Origin
  #   With CORS on, OPTIONS serves the preflight, with no Restep rules; with it off, OPTIONS goes on
  #   to the application like any other method.
  # - credentials: true says that the API accepts credentials a browser attaches on its own
  #   (cookies, HTTP authentication). §5.8 then requires refusing with 403 every unsafe request
  #   that a browser sent from an origin the API does not allow: the API's own origin and the
  #   origins of cors are allowed; "*" allows none. Allowed origins also get
  #   Access-Control-Allow-Credentials: true.
  # - exempt: with credentials: true, ->(env) { true or false } says which requests the
  #   application authenticates only with a token a browser never attaches on its own (a bearer
  #   token in Authorization, an API key header). §5.8 does not cover them, so they skip the
  #   origin check. The application must not also authenticate them with a cookie:
  #     use Restep::Envelope, credentials: true, exempt: Restep::Envelope.method(:token_authorization?)
  # - path: the API's root path ("/v1"), or a list of them. Only requests under it go through the
  #   envelope; the rest (the HTML pages of the same application) go straight to the application,
  #   untouched. Without it, every request is the API's.
  class Envelope
    KNOWN = %w[GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT].freeze
    SAFE = %w[GET HEAD OPTIONS TRACE].freeze
    # §5.8 (draft 7): Content-Location joins the list, for the 200 of an action (7.2), and
    # Accept-Post, for the 415 of a collection that only takes uploads (5.1).
    EXPOSE = "ETag, Location, Content-Location, Link, Allow, Accept-Patch, Accept-Post, Retry-After, Deprecation, Sunset, " \
             "Idempotent-Replayed, Preference-Applied, Accept-Query, WWW-Authenticate"
    ALLOW_HEADERS = "Content-Type, Content-Disposition, If-Match, If-None-Match, Idempotency-Key, Prefer, Authorization, DPoP"
    ALLOW_METHODS = "GET, HEAD, POST, PATCH, DELETE, QUERY"

    def initialize(app, cors: "*", credentials: false, exempt: nil, path: nil)
      @app = app
      raise ArgumentError, "exempt takes a callable, ->(env) { true or false }" unless exempt.nil? || exempt.respond_to?(:call)
      raise ArgumentError, "exempt goes with credentials: true" if exempt && !credentials
      @exempt = exempt
      @paths = path.nil? ? nil : Array(path).map { |p| normalize_path(p) }
      @cors =
        case cors
        when "*", false, nil then cors || false
        when Array then cors.map { |o| normalize_origin(o) or raise ArgumentError, "cors: #{o.inspect} is not an origin (scheme://host[:port])" }
        else raise ArgumentError, "cors takes \"*\", false or a list of origins"
        end
      @credentials = credentials
    end

    # Whether Authorization carries a token a browser never attaches on its own: any scheme but
    # Basic, Digest, Negotiate and NTLM, which a browser repeats by itself once the user has given
    # them (§5.8 counts them as HTTP authentication).
    def self.token_authorization?(env)
      scheme = env["HTTP_AUTHORIZATION"].to_s.strip.split(/[ \t]/, 2).first.to_s.downcase
      !scheme.empty? && !%w[basic digest negotiate ntlm].include?(scheme)
    end

    # Whether the request is under one of the envelope's paths (all are, without path:).
    def covers?(env)
      return true if @paths.nil?
      full = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
      @paths.any? { |p| p == "" || full == p || full.start_with?("#{p}/") }
    end

    def call(env)
      return @app.call(env) unless covers?(env)
      method = env["REQUEST_METHOD"].to_s
      # Rails parses the query and the body as soon as anyone asks for `params`, and its own
      # instrumentation (the "Parameters: ..." log line) asks for it before entering the action:
      # with "filter[a]=1&filter[a][b]=2" it raises BadRequest before the application can give
      # the 404 or the 405 that come first in §5.4. Its caches are filled with empty hashes so
      # that it parses nothing; the application reads QUERY_STRING and the raw body.
      env["action_dispatch.request.query_parameters"] = {}
      env["action_dispatch.request.request_parameters"] = {}
      origin = env["HTTP_ORIGIN"]
      status, headers, body =
        if method == "OPTIONS" && @cors
          preflight(origin)
        elsif !KNOWN.include?(method)
          Problem.rack(501, "not_implemented", detail: "This server does not implement the #{method} method.")
        elsif @credentials && !SAFE.include?(method) && cross_origin?(env, origin) && !@exempt&.call(env)
          Problem.rack(403, "forbidden", detail: "This API does not accept writes sent by a browser from #{origin || "another site"} (5.8).")
        else
          @app.call(env)
        end
      headers = headers.dup
      headers["link"] = [headers["link"], PROFILE_LINK].compact.reject(&:empty?).join(", ")
      cors_headers(headers, origin)
      [status, headers, body]
    end

    private

    def preflight(origin)
      headers = {}
      if allowed_origin(origin)
        headers.merge!("access-control-allow-methods" => ALLOW_METHODS, "access-control-allow-headers" => ALLOW_HEADERS,
                       "access-control-max-age" => "600")
      end
      [204, headers, []]
    end

    def allowed_origin(origin)
      return "*" if @cors == "*"
      return nil unless @cors.is_a?(Array) && origin
      o = normalize_origin(origin)
      o && @cors.include?(o) ? origin : nil
    end

    # §5.8: Access-Control-Allow-Origin on every response, errors included; when it depends on
    # Origin, Vary: Origin on every response, also those that do not carry it.
    def cors_headers(headers, origin)
      return unless @cors
      if @cors.is_a?(Array)
        headers["vary"] = [headers["vary"], "Origin"].compact.join(", ") unless headers["vary"].to_s.split(/,\s*/).include?("Origin")
      end
      allow = allowed_origin(origin) or return
      headers["access-control-allow-origin"] = allow
      headers["access-control-allow-credentials"] = "true" if @credentials && allow != "*"
      headers["access-control-expose-headers"] = EXPOSE
    end

    # §5.8: a request a browser sent from an origin that is neither the API's nor one it names.
    # Origin: null counts as the API's own with Sec-Fetch-Site: same-origin; without Origin, the
    # request is cross-origin when Sec-Fetch-Site says it is.
    def cross_origin?(env, origin)
      site = env["HTTP_SEC_FETCH_SITE"]
      if origin.nil? || origin.empty?
        return %w[cross-site same-site].include?(site)
      end
      return site != "same-origin" if origin == "null"
      o = normalize_origin(origin)
      return true if o.nil?
      return false if o == own_origin(env)
      !(@cors.is_a?(Array) && @cors.include?(o))
    end

    # The API's origin as Rack sees it (behind a proxy, from the forwarded headers Rack trusts).
    def own_origin(env) = normalize_origin(Rack::Request.new(env).base_url)

    def normalize_path(p)
      raise ArgumentError, "path: #{p.inspect} must be an absolute path such as \"/v1\"" unless p.is_a?(String) && p.start_with?("/")
      p.delete_suffix("/")
    end

    # scheme://host[:port] in lowercase, without the default port.
    def normalize_origin(o)
      m = %r{\A([a-z][a-z0-9+.-]*)://([^/?#:]+|\[[0-9a-f:.]+\])(?::([0-9]+))?/?\z}i.match(o.to_s) or return nil
      scheme, host, port = m[1].downcase, m[2].downcase, m[3]
      port = nil if (scheme == "http" && port == "80") || (scheme == "https" && port == "443")
      port ? "#{scheme}://#{host}:#{port}" : "#{scheme}://#{host}"
    end
  end
end
