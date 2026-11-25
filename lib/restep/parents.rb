module Restep
  # The parent items of a request to a subcollection or to a singleton with a parent, outermost
  # first, as the resolver found them (§4.2): each one exists, and each one under the one before.
  # A source receives them to scope what it lists, finds and creates.
  #
  #   parents.ids            # => ["cg-1", "p-7"]
  #   parents["policy"]      # => "p-7" (by the variable of the path template)
  #   parents.record         # => the immediate parent's record
  class Parents
    Entry = Struct.new(:var, :collection, :record, :id)

    attr_reader :entries

    def initialize(entries = []) = @entries = entries.freeze

    NONE = new

    def empty? = entries.empty?
    def size = entries.size
    def ids = entries.map(&:id)
    def records = entries.map(&:record)
    def record = entries.last&.record
    def last = entries.last
    def [](var) = entries.find { |e| e.var == var }&.id
    def to_h = entries.to_h { |e| [e.var, e.id] }
    def first(n) = Parents.new(entries.first(n))

    def push(var, collection, record) = Parents.new(entries + [Entry.new(var, collection, record, collection.source.id(record))])

    def ==(other) = other.is_a?(Parents) && other.ids == ids
    alias eql? ==
    def hash = ids.hash
    def inspect = "#<Restep::Parents #{to_h.inspect}>"
  end
end
