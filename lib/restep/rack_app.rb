module Restep
  # Restep server as a Rack application with a single entry point: it resolves the resource
  # itself and applies the error order of §5.4 from start to finish. It is mounted behind
  # Restep::Envelope (501, profile and CORS):
  #
  #   use Restep::Envelope
  #   run Restep::RackApp.new
  class RackApp
    def initialize(logger: nil) = @logger = logger

    def call(env)
      request = Request.new(env)
      status, headers, body = handle(request)
      finish(request, status, headers, body)
    rescue Problem => e
      finish(request, *Operations.problem_response(e))
    rescue StandardError => e
      @logger&.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(12)&.join("\n")}")
      finish(request, *Operations.problem_response(Problem.new(500, "internal", detail: "Unexpected server failure.")))
    end

    private

    def handle(request)
      path = request.path
      Context.check_uri_length!(request) unless [Restep.url("/status"), Restep.url("/docs")].include?(path)
      kind, coll, rec, action = Resolver.resolve(path, method: request.method,     # 1. 404
                                                       idempotency_key: request.header("Idempotency-Key"))
      unless Resolver.allowed(kind, action).include?(request.method)              # 2. 405
        raise Resolver.method_not_allowed(kind, path, action)
      end
      return Operations.status if kind == :status
      return Operations.docs if kind == :docs

      ctx = Context.new(request, kind: kind, collection: coll, record: rec, action: action) # 3 and 4
      case [kind, request.method]
      in [:item_action | :collection_action, _] then Operations.action(ctx)
      in [:root, _] then Operations.discovery(ctx)
      in [:collection, "GET" | "HEAD"] then Operations.list(ctx)
      in [:collection, "POST"] then Operations.create(ctx)
      in [:item | :singleton, "GET" | "HEAD"] then Operations.show(ctx)
      in [:item | :singleton, "PATCH"] then Operations.update(ctx)
      in [:item, "DELETE"] then Operations.destroy(ctx)
      end
    end

    def finish(request, status, headers, body)
      headers = headers.dup
      if body.nil?
        headers.delete("content-type")
        [status, headers, []]
      else
        headers["content-type"] ||= "application/json"
        headers["content-length"] = body.bytesize.to_s
        [status, headers, request&.head? ? [] : [body]]
      end
    end
  end
end
