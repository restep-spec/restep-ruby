module Restep
  # If-Match / If-None-Match (RFC 9110 §13.1.1 and §13.1.2).
  module Conditional
    # entity-tag = [ "W/" ] DQUOTE *etagc DQUOTE; etagc = %x21 / %x23-7E / obs-text
    TAG = %r{\G[ \t]*(W/)?"([\x21\x23-\x7e\x80-\xff]*)"[ \t]*(?:,|\z)}n

    module_function

    # Returns :any, a list of [weak, opaque] or raises 400 if the header is malformed.
    def parse(name, value)
      return nil if value.nil?
      v = value.b.strip
      return :any if v == "*"
      tags = []
      pos = 0
      v = v.gsub(/,[ \t]*(?=,)/, ",") # empty list elements
      until pos >= v.length
        m = TAG.match(v, pos)
        unless m && m.begin(0) == pos
          raise Problem.new(400, "bad_request", detail: "The #{name} header is malformed: expected * or a list of entity tags.",
                                                errors: [{ "header" => name, "code" => "format", "detail" => "Not a valid list of entity tags." }])
        end
        tags << [!m[1].nil?, m[2]]
        pos = m.end(0)
      end
      tags
    end

    def opaque(etag) = etag.delete_prefix("W/").delete_prefix('"').delete_suffix('"')

    def strong_match?(list, etag)
      return !etag.nil? if list == :any
      return false if etag.nil? || etag.start_with?("W/")
      list.any? { |weak, op| !weak && op == opaque(etag) }
    end

    def weak_match?(list, etag)
      return !etag.nil? if list == :any
      return false if etag.nil?
      list.any? { |_weak, op| op == opaque(etag) }
    end

    # Order of RFC 9110 §13.2.2 (If-Match before If-None-Match). Returns nil, :not_modified or
    # raises 412.
    def evaluate(if_match, if_none_match, etag, safe:)
      if if_match && !strong_match?(if_match, etag)
        raise Problem.new(412, "precondition_failed", detail: "If-Match does not match the current ETag: the resource has changed.")
      end
      if if_none_match && weak_match?(if_none_match, etag)
        return :not_modified if safe
        raise Problem.new(412, "precondition_failed", detail: "If-None-Match matches the current representation.")
      end
      nil
    end
  end
end
