module Restep
  # Request headers and body, in the order of §5.4: 400 (headers), 415, 406, 413, 400 (body),
  # with the shortcuts it allows ("need not parse a body whose media type it rejects, read past
  # its size limit").
  module Body
    MAX_BYTES = 64 * 1024 # the default of Restep.config.max_body_bytes

    # A body with an unpaired surrogate (§3): JSON, but not an I-JSON message. Its 422 waits for
    # object!, as that of a body that is not an object does. It hashes as its own marker for the
    # Idempotency-Key fingerprint.
    Unpaired = Struct.new(:problem) do
      def to_json(*) = JSON.generate("$unpaired-surrogate")
    end

    module_function

    def media_type(content_type)
      return nil if content_type.nil? || content_type.strip.empty?
      type, *params = content_type.split(";")
      charset = params.map { |x| x.strip.split("=", 2) }.find { |k, _| k&.downcase == "charset" }&.last
      [type.strip.downcase, charset&.delete('"')&.downcase]
    end

    # Accepts the JSON response if Accept admits application/json (or there is no Accept, or it
    # is malformed: RFC 9110 allows ignoring it).
    def accepts_json?(accept)
      return true if accept.nil? || accept.strip.empty?
      ranges = accept.split(",").map do |r|
        type, *params = r.split(";").map(&:strip)
        q = params.map { |x| x.split("=", 2) }.find { |k, _| k&.downcase == "q" }&.last
        qv = q.nil? ? 1.0 : (q.match?(/\A(0(\.[0-9]{0,3})?|1(\.0{0,3})?)\z/) ? q.to_f : nil)
        return true if qv.nil? # malformed range: the whole header is ignored
        [type.to_s.downcase, qv]
      end
      best = ->(t) { ranges.select { |rt, _| rt == t }.map(&:last).max }
      q = best.("application/json") || best.("application/*") || best.("*/*")
      !q.nil? && q.positive?
    end

    # Returns the body's JSON value (an object or not: see object!) or raises 415, 413 or 400, in
    # that order. Before the 413, the 406 has to be checked, as it comes first in §5.4: the caller
    # does it by passing accept_ok.
    # empty_is_object: §11.1, a POST action takes an empty body, with or without Content-Type,
    # as "{}" sent as application/json.
    # max_bytes: the largest body (Restep.config.max_body_bytes, or the collection's own).
    def read(request, allowed_types, accept_ok:, empty_is_object: false, max_bytes: MAX_BYTES)
      raw = request.raw_body
      if empty_is_object && raw.empty?
        raise not_acceptable unless accept_ok
        return {}
      end
      mt = media_type(request.content_type)
      # §3 (draft 6): an empty body is also a body; without Content-Type it gives 415, and empty
      # with application/json, 400 (JSON.parse rejects it further down).
      if mt.nil? || !allowed_types.include?(mt[0]) || (mt[1] && mt[1] != "utf-8")
        raise Problem.new(415, "unsupported_media_type",
                          detail: "Send the body as #{allowed_types.join(" or ")} (UTF-8).",
                          headers: allowed_types.include?("application/merge-patch+json") ? { "accept-patch" => "application/merge-patch+json, application/json" } : {})
      end
      if raw.bytesize > max_bytes
        raise not_acceptable unless accept_ok
        raise Problem.new(413, "content_too_large", detail: "The body takes at most #{max_bytes} bytes.")
      end
      raise Problem.new(400, "bad_request", detail: "The request needs a JSON object as its body.") if raw.empty?
      raw = raw.dup.force_encoding(Encoding::UTF_8)
      raise Problem.new(400, "bad_request", detail: "The body is not valid UTF-8.") unless raw.valid_encoding?
      # §3 (draft 7): a body is an I-JSON message. Duplicate member names give 400 bad_request,
      # because the meaning would depend on the parser; an unpaired surrogate, which the parser
      # refuses, gives the 422 invalid with a format entry that §3 allows.
      doc = begin
        JSON.parse(raw, decimal_class: BigDecimal, allow_nan: false, allow_duplicate_key: false)
      rescue JSON::ParserError => e
        unpaired = nil
        message = e.message.lines.first.to_s.strip
        if message.include?("duplicate key")
          raise Problem.new(400, "bad_request", detail: "The body repeats a member name in an object: #{message[0, 120]}")
        end
        # Deferred like a body that is not an object: object! raises it after the preconditions
        # (§5.4: no 422 from the content while 412 applies).
        if message.include?("surrogate")
          # §3 and §5.4 (draft 7): a body that also has a JSON syntax error (or a duplicate member
          # name) gets 400 bad_request. The parser stops at the first surrogate, so the rest is
          # checked again with the unpaired ones replaced.
          syntax_error!(raw)
          unpaired = Unpaired.new(Problem.invalid([{ "pointer" => "", "code" => "format", "detail" => "The body has an unpaired surrogate." }],
                                            detail: "The body is not an I-JSON message: it has an unpaired surrogate."))
        end
        unpaired or raise Problem.new(400, "bad_request", detail: "The body is not valid JSON: #{message[0, 120]}")
      end
      # §5.1 and §4.3: a JSON value that is not an object is kept as is; it gives 422 through
      # object!, which the operation calls after the preconditions (§5.4: the 412 comes before the
      # content's 422).
      raise not_acceptable unless accept_ok
      doc
    end

    # A \u escape of a surrogate pair, of a lone surrogate, or any other escape (so that "\\ud800",
    # an escaped backslash followed by text, is not taken for one).
    ESCAPE = /\\u[dD][89abAB][0-9a-fA-F]{2}\\u[dD][c-fC-F][0-9a-fA-F]{2}|\\u[dD][89a-fA-F][0-9a-fA-F]{2}|\\./m

    # Parses the body again with every unpaired surrogate escape replaced by U+FFFD and raises
    # 400 bad_request if it is still not valid JSON. The pointer of the 422 stays "": §3 allows
    # it when the server cannot locate the string, and the parser does not say where it is.
    def syntax_error!(raw)
      patched = raw.gsub(ESCAPE) { |e| e.length == 6 && e[1] == "u" ? "\\ufffd" : e }
      JSON.parse(patched, decimal_class: BigDecimal, allow_nan: false, allow_duplicate_key: false)
    rescue JSON::ParserError => e
      message = e.message.lines.first.to_s.strip
      what = message.include?("duplicate key") ? "repeats a member name in an object" : "is not valid JSON"
      raise Problem.new(400, "bad_request", detail: "The body #{what}: #{message[0, 120]}")
    end

    # §5.1 and §4.3: a body that is a JSON value but not an object gives 422 invalid, with a
    # type entry at "".
    def object!(doc)
      return doc if doc.is_a?(Hash)
      raise doc.problem if doc.is_a?(Unpaired)
      raise Problem.new(422, "invalid", detail: "The body must be a JSON object.",
                                        errors: [{ "pointer" => "", "code" => "type", "detail" => "Not a JSON object." }])
    end

    def not_acceptable
      Problem.new(406, "not_acceptable", detail: "This API only produces application/json (and application/problem+json for errors).")
    end

    # Idempotency-Key: a Structured Fields string (RFC 9651 §3.3.3), without parameters.
    SF_STRING = /\A[ ]*"((?:[\x20\x21\x23-\x5b\x5d-\x7e]|\\["\\])*)"[ ]*\z/n

    def idempotency_key(value)
      return nil if value.nil?
      m = SF_STRING.match(value.b)
      unless m && !m[1].empty?
        raise Problem.new(400, "bad_request", detail: "Idempotency-Key must be a Structured Fields string, such as \"8e03978e-40d5\".",
                                              errors: [{ "header" => "Idempotency-Key", "code" => "format", "detail" => "Not a quoted string." }])
      end
      m[1].gsub(/\\(["\\])/, '\1')
    end

    def prefers_minimal?(prefer_headers)
      prefer_headers.to_s.split(",").any? { |p| p.split(";").first.to_s.strip.downcase.gsub(/\s/, "") == "return=minimal" }
    end
  end
end
