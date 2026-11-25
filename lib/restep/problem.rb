module Restep
  # A Restep error (§5.4) that the controller turns into application/problem+json.
  class Problem < StandardError
    # §5.4 (draft 7): the closed table of codes, in the order of public/1/schema/problem.json, with
    # the status each one goes with and its title. A status the table does not list takes
    # http_ and its three digits as code, never a name derived from the IANA registry.
    CODES = {
      "bad_request" => [400, "Bad request"],
      "invalid_parameter" => [400, "Invalid parameter"],
      "unsupported_parameter" => [400, "Unsupported parameter"],
      "idempotency_key_required" => [400, "Idempotency key required"],
      "unauthenticated" => [401, "Unauthenticated"],
      "forbidden" => [403, "Forbidden"],
      "not_found" => [404, "Not found"],
      "method_not_allowed" => [405, "Method not allowed"],
      "not_acceptable" => [406, "Not acceptable"],
      "request_timeout" => [408, "Request timeout"],
      "conflict" => [409, "Conflict"],
      "request_in_progress" => [409, "Request in progress"],
      "state_expired" => [410, "State expired"],
      "retired" => [410, "Retired"],
      "precondition_failed" => [412, "Precondition failed"],
      "content_too_large" => [413, "Content too large"],
      "uri_too_long" => [414, "URI too long"],
      "unsupported_media_type" => [415, "Unsupported media type"],
      "misdirected_request" => [421, "Misdirected request"],
      "invalid" => [422, "Invalid data"],
      "idempotency_mismatch" => [422, "Idempotency key reused with a different request"],
      "not_executed" => [424, "Not executed"],
      "too_early" => [425, "Too early"],
      "precondition_required" => [428, "Precondition required"],
      "rate_limited" => [429, "Too many requests"],
      "internal" => [500, "Internal server error"],
      "not_implemented" => [501, "Not implemented"],
      "bad_gateway" => [502, "Bad gateway"],
      "unavailable" => [503, "Service unavailable"],
      "gateway_timeout" => [504, "Gateway timeout"]
    }.freeze
    TITLES = CODES.transform_values(&:last).freeze
    # Statuses the table lists: any other takes http_NNN.
    LISTED = CODES.values.map(&:first).uniq.freeze
    # §5.1 and §5.4: fields aimed at shared caches (RFC 9213), which a problem never carries.
    SHARED_CACHE_FIELD = /\A(cdn-cache-control|surrogate-control|[a-z0-9-]+-cdn-cache-control)\z/i

    # §5.4: the code a status carries. With code nil, the only one the table gives that status,
    # or http_NNN for a status it does not list. A code that does not go with its status is a
    # programming error.
    def self.code_for(status, code = nil)
      raise ArgumentError, "#{status.inspect} is not an error status" unless status.is_a?(Integer) && status.between?(400, 599)
      unless LISTED.include?(status)
        raise ArgumentError, "status #{status} is not in the table of 5.4, so its code is http_#{status}, not #{code}" unless code.nil? || code == "http_#{status}"
        return "http_#{status}"
      end
      listed = CODES.select { |_, (st, _)| st == status }.keys
      return listed.first if code.nil? && listed.size == 1
      raise ArgumentError, "code #{code.inspect} does not go with status #{status}; use one of #{listed.join(", ")} (5.4)" unless listed.include?(code)
      code
    end

    # Title of a problem: the table's, or the reason phrase of a status the table does not list.
    def self.title_for(status, code)
      TITLES[code] || Rack::Utils::HTTP_STATUS_CODES.fetch(status, "Error")
    end

    attr_reader :status, :code, :detail, :extra, :headers

    def initialize(status, code, detail: nil, headers: {}, **extra)
      @status = status
      @code = Problem.code_for(status, code)
      @detail = detail
      @headers = headers
      @extra = extra.compact
      super("#{status} #{code}: #{detail}")
    end

    def body
      h = { "type" => "#{PROFILE_URI}errors##{code}", "title" => Problem.title_for(status, code),
            "status" => status, "code" => code }
      h["detail"] = detail if detail
      extra.each { |k, v| h[k.to_s] = v }
      h
    end

    def self.rack(status, code, detail: nil, headers: {}, **extra)
      pr = new(status, code, detail: detail, headers: headers, **extra)
      [status, pr.response_headers, [JSON.generate(pr.body)]]
    end

    # §5.4: every problem is no-store (428, 429, 431 and 511 must be), whatever its own headers
    # say, and never carries a field aimed at shared caches such as CDN-Cache-Control.
    def response_headers
      own = headers.reject { |k, _| k.to_s.downcase == "cache-control" || SHARED_CACHE_FIELD.match?(k.to_s) }
      { "content-type" => "application/problem+json", "cache-control" => "no-store" }.merge(own)
    end

    # Shortcuts
    def self.param(code, name, detail)
      new(400, code, detail: detail, parameter: name)
    end

    def self.invalid(errors, detail: "The request body is not valid.")
      new(422, "invalid", detail: detail, errors: errors)
    end
  end
end
