module Restep
  # Steps 3 and 4 of §5.4 for a request whose resource is already resolved (404) and whose method
  # is allowed (405): reserved parameters (400), malformed headers (400), and body (415, 413,
  # 400) and Accept (406). What remains (412, 422, 409) is decided by the operation.
  class Context
    MAX_QUERY_BYTES = 8 * 1024

    attr_reader :request, :collection, :kind, :record, :action, :query, :if_match, :if_none_match,
                :idempotency_key, :body, :parents, :principal

    # 414 outside the order of §5.4. Puma cuts off any query over 10 KB earlier, with a plain-text
    # 400 (a limit fixed at compile time); here the 414 is given as problem+json below that.
    def self.check_uri_length!(request)
      return if request.query_string.bytesize <= MAX_QUERY_BYTES
      raise Problem.new(414, "uri_too_long", detail: "The query string takes at most #{MAX_QUERY_BYTES} bytes.")
    end

    # kind: :root, :collection, :item, :singleton, :item_action o :collection_action.
    # parents: the parent items the resolver found (Restep::Resolver::Target#parents).
    def initialize(request, kind:, collection: nil, record: nil, action: nil, parents: Parents::NONE)
      @request, @kind, @collection, @record, @action, @parents = request, kind, collection, record, action, parents
      @principal = Restep.principal_for(request)
      m = request.method
      @query = Query.new(collection, kind, request.head? ? "GET" : m, QueryString.parse(request.query_string),
                         parents: parents, principal: @principal)
      @if_match = Conditional.parse("If-Match", request.header("If-Match"))
      @if_none_match = Conditional.parse("If-None-Match", request.header("If-None-Match"))
      # §7.1: only a POST reads the key. §11.1 (draft 7): an action declared idempotent ignores
      # keys here, so it ignores a malformed one too instead of answering 400.
      @idempotency_key = m == "POST" && !action&.idempotent ? Body.idempotency_key(request.header("Idempotency-Key")) : nil
      refuse_anonymous_key! if @idempotency_key && @principal.nil? && Restep.config.idempotency_anonymous == false
      accept_ok = Body.accepts_json?(request.header("Accept"))
      limit = collection&.max_body_bytes || Restep.config.max_body_bytes
      @body =
        case m
        when "POST" then Body.read(request, %w[application/json], accept_ok: accept_ok, empty_is_object: !action.nil?, max_bytes: limit)
        when "PATCH" then Body.read(request, %w[application/merge-patch+json application/json], accept_ok: accept_ok, max_bytes: limit)
        else
          raise Body.not_acceptable if request.safe? && !accept_ok
          nil
        end
    end

    # §7.1: with "anonymous": false, a POST without credentials that carries Idempotency-Key gets
    # 400 before any effect.
    def refuse_anonymous_key!
      raise Problem.new(400, "bad_request", detail: "This API takes Idempotency-Key only from authenticated requests.",
                                            errors: [{ "header" => "Idempotency-Key", "code" => "unknown",
                                                       "detail" => "Not accepted without credentials." }])
    end

    def path = request.path
    def minimal? = Body.prefers_minimal?(request.header("Prefer"))
  end
end
