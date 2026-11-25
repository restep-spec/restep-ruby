require "restep"
require "active_support/concern"

module Restep
  module Rails
    # Concern for a Rails controller that serves Restep resources. The Rails router does step 1
    # of §5.4 (which resource) and each resource's controller looks up the item in a
    # before_action (404). What has no route goes to a fallback controller that tells 404 from
    # 405 with Restep::Resolver. Steps 3 and 4 (400, 415, 413, 406) are done by restep_context;
    # the rest, by Restep::Operations.
    #
    # Parameters do not come from `params`: Restep::Envelope empties Rails' caches so it does not
    # parse the query or the body (§5.3 asks to see them raw). Only the route's remain.
    module Controller
      extend ActiveSupport::Concern

      # For config.exceptions_app: what fails before reaching a controller. A path with an
      # invalid encoding (/stations/%FF) makes the router fail; it names no resource, so it is a
      # 404, as in Restep::RackApp. Anything else, 500.
      def self.exceptions_app
        lambda do |env|
          e = env["action_dispatch.exception"]
          if e.is_a?(ActionController::BadRequest) && e.message.start_with?("Invalid path parameters")
            Restep::Problem.rack(404, "not_found", detail: "Nothing here. The API root (/) lists the collections.")
          else
            Restep::Problem.rack(500, "internal", detail: "Unexpected server failure.")
          end
        end
      end

      included do
        # rescue_from checks the last one declared first: Problem before StandardError.
        rescue_from StandardError, with: :restep_internal_error
        rescue_from Restep::Problem, with: :restep_problem
        before_action :restep_check_uri_length
        before_action :restep_check_exact_path
      end

      private

      def restep_request = @restep_request ||= Restep::Request.new(request.env)

      def restep_check_uri_length = Restep::Context.check_uri_length!(restep_request)

      # The Rails router normalizes the path before looking it up (it drops the trailing slash and
      # merges doubled ones), so "/stations/7/" and "//stations" would reach the action of
      # "/stations/7" and "/stations". §3 compares the path segment by segment: neither exists.
      def restep_check_exact_path
        path = restep_request.path
        return if path == "/" || path == "#{Restep.config.root_path}/"
        return unless path.end_with?("/") || path.include?("//")
        raise Restep::Problem.new(404, "not_found", detail: "Nothing here. The API root lists the collections.")
      end

      def restep_context(kind:, collection: nil, record: nil, action: nil, parents: Restep::Parents::NONE)
        Restep::Context.new(restep_request, kind: kind, collection: collection, record: record, action: action, parents: parents)
      end

      # The resource the raw path names, resolved by the gem whatever the route looks like (a
      # subcollection's parents included, each found under the one before): a
      # Restep::Resolver::Target, or 404. Then 405 if the method is not allowed there.
      #
      #   before_action { @restep = restep_context_for(restep_target) }
      def restep_target
        t = Restep::Resolver.resolve(restep_request.path, method: request.method,
                                                          idempotency_key: request.headers["Idempotency-Key"])
        unless Restep::Resolver.allowed(t.kind, t.action, t.collection).include?(request.method)
          raise Restep::Resolver.method_not_allowed(t.kind, restep_request.path, t.action, t.collection)
        end
        t
      end

      def restep_context_for(t)
        restep_context(kind: t.kind, collection: t.collection, record: t.record, action: t.action, parents: t.parents)
      end

      # Writes [status, headers, body] as is: Restep sets its own validators, content types and
      # caches, so neither render nor fresh_when is used.
      def render_restep(result)
        status, headers, body = result
        self.status = status
        headers.each { |k, v| response.headers[k] = v }
        if body.nil?
          response.headers.delete("content-type")
          self.response_body = ""
        else
          response.headers["content-type"] = headers["content-type"] || "application/json"
          response.headers["content-length"] = body.bytesize.to_s
          self.response_body = request.head? ? "" : body
        end
      end

      def restep_problem(e) = render_restep(Restep::Operations.problem_response(e))

      def restep_internal_error(e)
        logger&.error("#{e.class}: #{e.message}\n#{e.backtrace&.first(12)&.join("\n")}")
        restep_problem(Restep::Problem.new(500, "internal", detail: "Unexpected server failure."))
      end
    end
  end
end
