module Restep
  # Parses QUERY_STRING by hand. Rack::QueryParser loses repeated parameters (it keeps the last
  # one) and turns brackets into nested hashes, so neither §5.3 (repeated names, name "exactly as
  # received after percent-decoding") nor §6.1 (filter[x] versus filter[x][eq]) can be met.
  module QueryString
    Pair = Struct.new(:name, :value, :raw, keyword_init: true) # value is nil when there is no "="

    # A "%" that does not start an escape of two hex digits: RFC 3986 (section 2.1) has no such
    # query, and RFC 9112 (section 3) asks for 400 to an invalid request target.
    MALFORMED_ESCAPE = /%(?![0-9A-Fa-f]{2})/

    module_function

    # Whether every "%" in s starts an escape of two hex digits (RFC 3986, section 2.1).
    def well_formed?(s) = !MALFORMED_ESCAPE.match?(s.to_s.b)

    # The pairs of a query string, in the order received. A malformed escape ("%zz", a trailing
    # "%") gives 400 bad_request, as text that is not UTF-8 after percent-decoding does.
    def parse(qs)
      return [] if qs.nil? || qs.empty?
      unless well_formed?(qs)
        raise Problem.new(400, "bad_request",
                          detail: "The query string has a % that does not start a percent-encoded octet (%XX); send a literal % as %25.")
      end
      qs.split("&").reject(&:empty?).map do |seg|
        name, value = seg.split("=", 2)
        Pair.new(name: decode(name), value: value.nil? ? nil : decode(value), raw: seg)
      end
    end

    # "+" is decoded as a space, as forms and URLSearchParams do (see the journal). A "%" that
    # starts no escape is kept as is: parse refuses it in a query first, and in a path segment it
    # names no item, since "%" is not in an id.
    def decode(s)
      out = s.tr("+", " ").gsub(/%([0-9A-Fa-f]{2})/) { $1.hex.chr }.force_encoding(Encoding::UTF_8)
      raise Problem.new(400, "bad_request", detail: "The query string is not valid UTF-8 after percent-decoding.") unless out.valid_encoding?
      out
    end

    # §5.2 (draft 7): a parameter as received, ready for a link the server builds. Whatever RFC 3986
    # (section 3.4) does not allow unencoded in a query, [ and ] among them, is percent-encoded; a
    # % that starts no escape becomes %25 (parse refuses one in a request, so that only guards a
    # caller that builds a link from other text). The rest stays as received, + (a space) included, since
    # encoding again does not change a parameter.
    def link_form(raw)
      raw.b.gsub(/%(?![0-9A-Fa-f]{2})|[^A-Za-z0-9\-._~!$&'()*+,;=:@\/?%]/n) { |c| format("%%%02X", c.ord) }
    end

    def encode_component(s)
      s.b.gsub(/[^A-Za-z0-9\-._~]/) { |c| format("%%%02X", c.ord) }
    end
  end
end
