module Restep
  # If-Match / If-None-Match (RFC 9110 §13.1.1 and §13.1.2).
  module Conditional
    # entity-tag = [ "W/" ] DQUOTE *etagc DQUOTE; etagc = %x21 / %x23-7E / obs-text
    TAG = %r{\G(W/)?"([\x21\x23-\x7e\x80-\xff]*)"}n
    SEPARATORS = /\G[ \t,]*/n

    module_function

    # Returns :any, a list of [weak, opaque] or raises 400 if the header is malformed.
    # The field is "*" / #entity-tag (RFC 9110, sections 13.1.1 and 5.6.1): a list may be empty
    # and may have empty elements, so an empty If-Match is a list with no entity tag, which no
    # ETag matches (412), and an empty If-None-Match matches none (the request goes on).
    def parse(name, value)
      return nil if value.nil?
      v = value.b.strip
      return :any if v == "*"
      tags = []
      pos = SEPARATORS.match(v, 0).end(0)
      while pos < v.length
        m = TAG.match(v, pos)
        sep = m && SEPARATORS.match(v, m.end(0))
        # After a tag: optional whitespace, then a comma or the end.
        unless m && m.begin(0) == pos && (sep.end(0) == v.length || v.byteslice(m.end(0), sep.end(0) - m.end(0)).include?(","))
          raise Problem.new(400, "bad_request", detail: "The #{name} header is malformed: expected * or a list of entity tags.",
                                                errors: [{ "header" => name, "code" => "format", "detail" => "Not a valid list of entity tags." }])
        end
        tags << [!m[1].nil?, m[2]]
        pos = sep.end(0)
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
