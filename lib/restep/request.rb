module Restep
  # The request as it arrives in the Rack environment, without going through any framework's
  # parameter parsing: §5.3 asks to read the query string raw (repeated names, bracket forms)
  # and §5.4 fixes which error comes first.
  class Request
    attr_reader :env

    def initialize(env) = @env = env

    def method = env["REQUEST_METHOD"].to_s
    def safe? = %w[GET HEAD].include?(method)
    def head? = method == "HEAD"
    # The path as it arrived. The Rails router rewrites PATH_INFO already normalized (no trailing
    # slash, doubled slashes merged); Rails keeps the original in ORIGINAL_FULLPATH.
    def path
      original = env["ORIGINAL_FULLPATH"]
      original ? original.split("?", 2).first : "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
    end
    def query_string = env["QUERY_STRING"].to_s
    def content_type = env["CONTENT_TYPE"]

    # Header by its HTTP name ("If-Match").
    def header(name)
      key = name.upcase.tr("-", "_")
      env[%w[CONTENT_TYPE CONTENT_LENGTH].include?(key) ? key : "HTTP_#{key}"]
    end

    def raw_body
      @raw_body ||= begin
        io = env["rack.input"]
        if io
          io.rewind if io.respond_to?(:rewind)
          data = io.read.to_s
          io.rewind if io.respond_to?(:rewind)
          data
        else
          ""
        end
      end
    end
  end
end
