module Restep
  module Rails
    # §6.4: a secret for the cursors derived from the application's secret_key_base, through its
    # key_generator, so every replica derives the same one.
    def self.cursor_secret_from(app) = app.key_generator.generate_key("restep cursor", 32).unpack1("H*")
  end
end
