require "rails/railtie"
require "restep/rails/cursor_secret"

module Restep
  module Rails
    # §6.4: cursors must open on every replica, so their secret comes from one the application
    # already has: unless config.cursor_secret is set, it is derived from secret_key_base with the
    # application's key_generator. Restep.check! then runs once the application has booted.
    class Railtie < ::Rails::Railtie
      config.after_initialize do |app|
        Restep.config.cursor_secret ||= Restep::Rails.cursor_secret_from(app)
        Restep.check!
      end
    end
  end
end
