require "action_dispatch"

module Restep
  module Rails
    # Action routes (§11.1) for config/routes.rb. Restep puts the action name after a colon, in
    # the same segment (/stations/7:deactivate, /readings:summary), and also accepts %3A. The
    # Rails router does not work for that as is: ":" marks a parameter and cannot be escaped
    # ("readings:summary" is "readings" and the parameter :summary). So each action is a route
    # with the whole segment as a parameter and a constraint that requires the name after ":" or
    # "%3A". The constraints look at the undecoded path; the parameter arrives decoded.
    #
    #   restep_action :stations, :deactivate                         # POST /stations/:id:deactivate
    #   restep_action :readings, :summary, on: :collection, via: :get
    module Routes
      COLON = "(?::|%3[Aa])".freeze
      # An id with no colon, encoded or not: for show, update and destroy, so that
      # /stations/7:deactivate does not reach show with the id "7:deactivate".
      ID = /(?:(?!%3[Aa])[^\/:])+/

      def restep_action(resource, name, on: :member, via: :post)
        if on == :member
          match "#{resource}/:id", to: "#{resource}##{name}", via: via, as: nil, format: false,
                                   constraints: { id: /(?:(?!%3[Aa])[^\/:])+#{COLON}#{name}/ }
        else
          match ":restep_target", to: "#{resource}##{name}", via: via, as: nil, format: false,
                                  constraints: { restep_target: /#{resource}#{COLON}#{name}/ }
        end
      end
    end
  end
end

ActionDispatch::Routing::Mapper.include(Restep::Rails::Routes)
