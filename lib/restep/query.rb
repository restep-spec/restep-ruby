module Restep
  # Reserved parameters (§5.3), the query profile (§6) and include (§9): parsing and errors in
  # order. What is left (filters, named filters, sort, limit, count and the position the cursor
  # carries) goes to the collection's source, which runs it.
  class Query
    RESERVED = %w[filter sort fields include count limit cursor since languages].freeze
    MAX_IN = 500
    DEFAULT_LIMIT = 20

    Filter = Struct.new(:field, :op, :value, :raw, :name, keyword_init: true)
    Named = Struct.new(:name, :value, :raw, keyword_init: true)

    attr_reader :collection, :filters, :named, :sort, :fields, :limit, :count, :cursor_payload, :pairs,
                :includes, :parents, :principal

    # kind: :root, :collection, :item, :singleton, :item_action or :collection_action; method:
    # the request's. parents: those of the request (the cursor is bound to them); principal: who
    # the request acts for (and the cursor too, §6.4).
    def initialize(collection, kind, method, pairs, parents: Parents::NONE, principal: nil)
      @collection, @kind, @method, @pairs = collection, kind, method, pairs
      @parents, @principal = parents, principal
      @filters, @named, @sort, @fields, @includes = [], [], [], nil, []
      @switched_off = [] # default switches the request turns off with filter[name]=false (§6.1)
      # §5.2: the server picks the page size when the request does not.
      @limit = collection && (collection.default_limit || [collection.max_limit, DEFAULT_LIMIT].compact.min)
      @count = false
      @issues = [] # [category (0 unsupported, 1 invalid), position, name, detail]
      analyze
    end

    # The position the source returned for the previous page (§6.4), or nil on the first one.
    def position = @cursor_payload && @cursor_payload["k"]

    def supported
      safe = %w[GET HEAD].include?(@method)
      return [] unless safe
      case @kind
      when :collection
        list = %w[filter sort fields cursor]
        list << "limit" if collection.max_limit
        list << "count" if collection.count
        list << "include" if include_offered?
        list
      when :item then include_offered? ? %w[fields include] : %w[fields]
      when :singleton then %w[fields]
      else []
      end
    end

    def include_offered? = Relations.declared? && collection.relation_fields.any?(&:include)

    def unsupported(i, name, detail) = @issues << [0, i, name, detail]
    def invalid(i, name, detail) = @issues << [1, i, name, detail]

    def analyze
      sup = supported
      seen = {}
      raw_cursor = nil
      raw_fields = nil
      @pairs.each_with_index do |p, i|
        name = p.name
        base = name[/\A[^\[]*/]
        # §5.3 and §11.1 (draft 7): a GET action without params is one with "params": {}, so it
        # answers any query parameter, reserved or not, with unsupported_parameter. This gem does
        # not declare params, so that is every GET action.
        if get_action?
          unsupported(i, name, "The #{name} parameter is not declared: this action takes no query parameters.")
          next
        end
        next unless RESERVED.include?(base) || name.start_with?("$")
        if name.start_with?("$") || !sup.include?(base)
          unsupported(i, name, unsupported_detail(base))
          next
        end
        if base == "filter"
          analyze_filter(p, i, seen)
          next
        end
        if name != base
          unsupported(i, name, "The #{name} form is not supported; use #{base}=… without brackets.")
          next
        end
        if seen[base]
          invalid(i, name, "#{name} is repeated; give it once.")
          next
        end
        seen[base] = true
        case base
        when "sort" then analyze_sort(p, i)
        when "fields" then raw_fields = [p, i]
        when "include" then analyze_include(p, i)
        when "limit" then analyze_limit(p, i)
        when "count" then analyze_count(p, i)
        when "cursor"
          if p.value.nil? || p.value.empty? then invalid(i, name, "cursor cannot be empty.")
          else raw_cursor = [p.value, i]
          end
        end
      end
      # fields after include: a dotted path is valid only with its relationship included (§9).
      analyze_fields(*raw_fields) if raw_fields
      apply_defaults_and_required if list?
      raise_first!
      check_cursor(*raw_cursor) if raw_cursor
      raise_first!
    end

    def list? = @kind == :collection && %w[GET HEAD].include?(@method)

    # A POST action answers a GET with 405 before the query is read, so here it is a GET action.
    def get_action? = %i[item_action collection_action].include?(@kind) && %w[GET HEAD].include?(@method)

    # §6.1 (draft 7): a default switch applies to every list request that does not turn it off,
    # and a list request without a required filter gives invalid_parameter naming it. Neither
    # applies to reading an item.
    def apply_defaults_and_required
      collection.named_filters.each do |name, nf|
        next unless nf["default"] && !@switched_off.include?(name) && @named.none? { |n| n.name == name }
        @named << Named.new(name: name, value: nil, raw: "")
      end
      given = @pairs.filter_map { |p| p.name[/\Afilter\[([^\[\]]+)\]/, 1] }
      missing = collection.filters.select { |_, d| d["required"] }.keys +
                collection.named_filters.select { |_, d| d["required"] }.keys
      missing.reject { |f| given.include?(f) }.each do |f|
        invalid(@pairs.size, "filter[#{f}]", "filter[#{f}] is required on this collection.")
      end
    end

    def unsupported_detail(base)
      case @kind
      when :root then "The API root takes no reserved parameters."
      when :item, :singleton then @method == "GET" || @method == "HEAD" ? "Here only #{supported.join(" and ")} #{supported.size > 1 ? "are" : "is"} supported." : "#{@method} takes no reserved parameters."
      else
        if %w[GET HEAD].include?(@method)
          "#{base} is not supported here; this collection supports #{supported.join(", ")}."
        else
          "#{@method} takes no reserved parameters."
        end
      end
    end

    def raise_first!
      return if @issues.empty?
      cat, _i, name, detail = @issues.min_by { |c, i, *| [c, i] }
      raise Problem.param(cat.zero? ? "unsupported_parameter" : "invalid_parameter", name, detail)
    end

    # ---- filter -----------------------------------------------------------------------------

    def analyze_filter(p, i, seen)
      m = /\Afilter\[([^\[\]]+)\](?:\[([^\[\]]+)\])?\z/.match(p.name)
      unless m
        return unsupported(i, p.name, "Only filter[field]=value and filter[field][op]=value are supported (no filter-expr).")
      end
      field, op = m[1], m[2]
      if (decl = collection.filters[field])
        op_eff = op || "eq"
        unless decl["ops"].include?(op_eff)
          return unsupported(i, p.name, "Operator #{op_eff} is not declared for #{field}; it takes: #{decl["ops"].join(", ")}.")
        end
        key = [:f, field, op_eff]
        return invalid(i, p.name, "The filter #{field} #{op_eff} is given twice.") if seen[key]
        seen[key] = true
        value = parse_filter_operand(decl, op_eff, p, i)
        # §6.1 (draft 7): operands equal under the field's type are the same filter, also for the
        # cursor, so the cursor is bound to their canonical form, not to the text received.
        unless value == :error
          raw = op_eff == "null" || !value.is_a?(Array) ? Query.canonical(decl["type"], value) : value.map { |v| Query.canonical(decl["type"], v) }
          @filters << Filter.new(field: field, op: op_eff, value: value, raw: raw, name: p.name)
        end
      elsif (nf = collection.named_filters[field])
        return unsupported(i, p.name, "#{field} is a named filter and takes no operators.") if op
        key = [:n, field]
        return invalid(i, p.name, "The named filter #{field} is given twice.") if seen[key]
        seen[key] = true
        if nf["type"].nil? && nf["default"] && p.value == "false"
          # §6.1: false turns a default switch off; it does not negate it.
          @switched_off << field
        elsif nf["type"].nil?
          unless p.value.nil? || p.value.empty?
            hint = nf["default"] ? " or filter[#{field}]=false to turn it off" : " without a value"
            return invalid(i, p.name, "#{field} is a switch: use filter[#{field}]#{hint}.")
          end
          @named << Named.new(name: field, value: nil, raw: "")
        else
          return invalid(i, p.name, "#{field} needs a value of type #{nf["type"]}.") if p.value.nil? || p.value.empty?
          return invalid(i, p.name, over_limit_detail) if nf["type"] == "integer" && Types.integer_over_limit?(p.value)
          parsed = Types.parse_filter_value(nf["type"], p.value, nf["values"])
          return invalid(i, p.name, "#{field} needs a value of type #{nf["type"]}.") unless parsed
          @named << Named.new(name: field, value: parsed[1], raw: Query.canonical(nf["type"], parsed[1]))
        end
      else
        named = collection.named_filters.empty? ? "" : "; named filters: #{collection.named_filters.keys.join(", ")}"
        unsupported(i, p.name, "#{field} cannot be filtered here. Filters: #{collection.filters.keys.join(", ")}#{named}.")
      end
    end

    def parse_filter_operand(decl, op, p, i)
      type = decl["type"]
      if op == "null"
        return p.value == "true" if %w[true false].include?(p.value)
        invalid(i, p.name, "The null operator takes true or false.")
        return :error
      end
      if %w[prefix contains].include?(op) && (p.value.nil? || p.value.empty?)
        invalid(i, p.name, "The #{op} operand cannot be empty.")
        return :error
      end
      if %w[in nin].include?(op)
        if p.value.nil? || p.value.empty?
          invalid(i, p.name, "The #{op} list cannot be empty.")
          return :error
        end
        raw_vals = p.value.split(",", -1)
        if raw_vals.size > MAX_IN
          # §5.3 (draft 6): an undeclared limit gives invalid_parameter, never part of the result.
          invalid(i, p.name, "An #{op} list takes at most #{MAX_IN} values.")
          return :error
        end
        if type == "integer" && raw_vals.any? { |x| Types.integer_over_limit?(x) }
          invalid(i, p.name, over_limit_detail)
          return :error
        end
        vals = raw_vals.map { |x| Types.parse_filter_value(type, x, decl["values"]) }
        if vals.any?(&:nil?)
          invalid(i, p.name, "Every value of the #{op} list must be of type #{type}#{enum_hint(decl)}#{leap_hint(type)}.")
          return :error
        end
        return vals.map(&:last)
      end
      if type == "integer" && Types.integer_over_limit?(p.value)
        invalid(i, p.name, over_limit_detail)
        return :error
      end
      parsed = Types.parse_filter_value(type, p.value, decl["values"])
      unless parsed
        invalid(i, p.name, "#{p.value.inspect} is not a valid #{type}#{enum_hint(decl)}#{leap_hint(type)}.")
        return :error
      end
      parsed[1]
    end

    # §5.3 and §6.1 (council round 4, decision 6): an operand over the limit names it in detail.
    def over_limit_detail = "An integer operand may have at most #{Types::MAX_INTEGER_DIGITS} digits, this server's limit; it is compared exactly, never replaced by another value."

    def enum_hint(decl) = decl["values"] ? " (one of: #{decl["values"].join(", ")})" : ""

    def leap_hint(type)
      case type
      when "datetime" then "; a leap second (:60) is not accepted"
      when "integer" then "; write it as a JSON number with a whole value (20, 20.0 and 2e1 are the same; +20, 020 and .5 are not JSON numbers), of at most #{Types::MAX_INTEGER_DIGITS} digits"
      else ""
      end
    end

    # A filter operand in a canonical text form: the same for operands equal under the field's
    # type (20 and 20.0, 007 and 7, two offsets of one instant), as §6.1 and §6.4 require of the
    # cursor.
    def self.canonical(type, v)
      case v
      when BigDecimal then v.zero? ? "0" : v.to_s("F").sub(/\.0\z/, "")
      when Rational then "#{v.numerator}/#{v.denominator}"
      when Date then v.iso8601
      else v.to_s
      end
    end

    # ---- sort, fields, include, limit, count ------------------------------------------------

    def analyze_sort(p, i)
      return invalid(i, p.name, "sort cannot be empty.") if p.value.nil? || p.value.empty?
      keys = []
      p.value.split(",", -1).each do |tok|
        desc = tok.start_with?("-")
        key = desc ? tok[1..] : tok
        return invalid(i, p.name, "sort has an empty key.") if key.empty?
        unless collection.sort.key?(key)
          return unsupported(i, p.name, "#{key} is not a sort key here; keys: #{collection.sort.keys.join(", ")}.")
        end
        return invalid(i, p.name, "#{key} appears twice in sort.") if keys.any? { |k, _| k == key }
        keys << [key, desc]
      end
      @sort = keys
    end

    # §6.3 and §9: names of fields, or dotted paths into an included relationship
    # (author.name). A path into a language map (name.es) is a field that does not exist.
    def analyze_fields(p, i)
      return invalid(i, p.name, "fields cannot be empty.") if p.value.nil? || p.value.empty?
      list = p.value.split(",", -1)
      return invalid(i, p.name, "fields has an empty name.") if list.any?(&:empty?)
      list.each do |f|
        problem = field_path_problem(f)
        return invalid(i, p.name, problem) if problem
      end
      @fields = list
    end

    def field_path_problem(path)
      segs = path.split(".", -1)
      coll = collection
      segs.each_with_index do |seg, n|
        f = coll.fields[seg]
        return "Unknown field #{path}. Fields: #{coll.fields.keys.join(", ")}." if f.nil?
        return nil if n == segs.size - 1
        return "#{path}: #{seg} is a language map, which fields takes whole." if f.type == "language_map"
        return "Unknown field #{path}: #{seg} is not a relationship." unless f.type == "relation" && Relations.declared?
        prefix = segs[0..n].join(".")
        return "#{path} needs include=#{prefix}: a dotted path in fields goes into an included relationship." unless @includes.include?(prefix)
        coll = Restep.collections.fetch(f.relation)
      end
      nil
    end

    # §9: include=author,author.publisher: declared, expandable relationships, up to the
    # collection's include_depth (1 if not declared).
    def analyze_include(p, i)
      return invalid(i, p.name, "include cannot be empty.") if p.value.nil? || p.value.empty?
      list = p.value.split(",", -1)
      return invalid(i, p.name, "include has an empty name.") if list.any?(&:empty?)
      depth = collection.include_depth || 1
      list.each do |path|
        segs = path.split(".", -1)
        return unsupported(i, p.name, "include goes at most #{depth} relationship#{"s" if depth > 1} deep here (include_depth).") if segs.size > depth
        coll = collection
        segs.each do |seg|
          unless coll.includable?(seg)
            names = coll.relation_fields.select(&:include).map(&:name)
            return unsupported(i, p.name, "#{seg} is not a relationship that #{coll.name} can include#{names.empty? ? "" : "; it can include: #{names.join(", ")}"}.")
          end
          coll = Restep.collections.fetch(coll.fields[seg].relation)
        end
        return invalid(i, p.name, "#{path} appears twice in include.") if @includes.include?(path)
        @includes << path
      end
      # A dotted path includes the relationships it goes through.
      @includes = @includes.flat_map { |x| s = x.split("."); (1..s.size).map { |n| s.first(n).join(".") } }.uniq
    end

    def analyze_limit(p, i)
      v = p.value.to_s
      unless v.match?(/\A[0-9]{1,9}\z/) && (1..collection.max_limit).cover?(v.to_i)
        return invalid(i, p.name, "limit must be an integer between 1 and #{collection.max_limit}.")
      end
      @limit = v.to_i
    end

    def analyze_count(p, i)
      return invalid(i, p.name, "count takes true or false.") unless %w[true false].include?(p.value)
      @count = p.value == "true"
    end

    # ---- cursor -------------------------------------------------------------------------------

    # §6.4: a cursor is bound to the collection (with its parents' ids: the same subcollection
    # under another parent is another collection), the filters, the sort and the principal.
    def binding_payload
      f = @filters.map { |x| ["f", x.field, x.op, x.raw] } + @named.map { |x| ["n", x.name, x.raw] }
      { "c" => collection.name, "a" => parents.ids, "f" => Digest::SHA256.hexdigest(JSON.generate(f.sort))[0, 22],
        "s" => @sort.map { |k, d| d ? "-#{k}" : k }.join(","), "p" => Restep.principal_key(principal) }
    end

    def check_cursor(token, i)
      payload = Cursor.read(token)
      b = binding_payload
      if payload.nil?
        invalid(i, "cursor", "The cursor was not issued by this server or has been altered.")
      elsif b.any? { |k, v| payload[k] != v }
        invalid(i, "cursor", "The cursor belongs to another collection, other filters or another sort; start again without it.")
      else
        @cursor_payload = payload
      end
    end

    # The cursor of the next page, from the position the source returned.
    def issue_cursor(position) = Cursor.issue(binding_payload.merge("k" => position))

    # §6.4: next carries the cursor and leaves the other parameters as they arrived.
    def next_link(path, token)
      kept = @pairs.reject { |p| p.name == "cursor" }.map { |p| QueryString.link_form(p.raw) }
      "#{path}?#{(kept + ["cursor=#{QueryString.encode_component(token)}"]).join("&")}"
    end

    # §6.3 and §9: only the fields asked for, plus id and the _ members; a dotted path projects the
    # included item it goes into.
    def project(rep, paths = @fields, nested: false)
      return rep unless paths
      top = paths.map { |p| p.split(".", 2) }
      rep.each_with_object({}) do |(k, v), out|
        # In an included item, href stays too: a relationship object to a subcollection needs it (§3).
        next out[k] = v if k == "id" || k.start_with?("_") || (nested && %w[href type].include?(k))
        sub = top.select { |a, _| a == k }
        next if sub.empty?
        out[k] = if sub.any? { |_, rest| rest.nil? } || !v.is_a?(Hash) then v
                 else project(v, sub.map(&:last), nested: true)
                 end
      end
    end
  end
end
