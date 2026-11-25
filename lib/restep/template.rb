module Restep
  # The path of a collection or a singleton (§4.2): an absolute path or, for a subcollection, an
  # RFC 6570 URI template of level 1 whose variables take in order the ids of the parent items:
  # /company_groups/{company_group}/policies/{policy}/drafts.
  class Template
    VAR_NAME = /\A[A-Za-z][A-Za-z0-9_]*\z/
    VAR = /\A\{([^{}]*)\}\z/

    Segment = Struct.new(:literal, :var) do
      def var? = !var.nil?
    end

    attr_reader :source, :segments

    def initialize(source)
      @source = source
      raise ArgumentError, "path #{source.inspect} must start with /" unless source.is_a?(String) && source.start_with?("/")
      @segments = source.split("/", -1).drop(1).map do |s|
        if (m = VAR.match(s))
          Segment.new(nil, m[1])
        else
          raise ArgumentError, "path #{source.inspect}: a variable takes a whole segment, {name}" if s.include?("{") || s.include?("}")
          Segment.new(s, nil)
        end
      end
    end

    def vars = segments.select(&:var?).map(&:var)
    def template? = segments.any?(&:var?)
    def size = segments.size
    def literal_count = segments.count { |s| !s.var? }

    # Problems of the template on its own (§4.2): variables of level 1, named ALPHA *( ALPHA /
    # DIGIT / "_" ), distinct, and no empty segment.
    def problems
      out = []
      out << "#{source} has an empty segment" if segments.any? { |s| !s.var? && s.literal.empty? }
      vars.each { |v| out << "#{source}: the variable {#{v}} is not a name of letters, digits and _ (RFC 6570, level 1)" unless VAR_NAME.match?(v) }
      out << "#{source}: its variables must have distinct names" unless vars.uniq.size == vars.size
      out
    end

    # Matches decoded segments: returns the variables' values in order, or nil.
    def match(decoded)
      return nil unless decoded.size == segments.size
      values = []
      segments.each_with_index do |s, i|
        if s.var? then values << decoded[i]
        elsif s.literal != decoded[i] then return nil
        end
      end
      values
    end

    # The path with its variables replaced by ids, in order (§5.1). An id is made of unreserved
    # characters (§3), so it goes into the path as it is.
    def expand(ids)
      raise ArgumentError, "#{source} takes #{vars.size} ids, not #{ids.size}" unless ids.size == vars.size
      it = ids.each
      "/" + segments.map { |s| s.var? ? it.next.to_s : s.literal }.join("/")
    end
  end
end
