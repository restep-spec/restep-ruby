module Restep
  # Reserved parameters (§5.3) and the query profile (§6): parsing, errors in order, and SQL.
  class Query
    RESERVED = %w[filter sort fields include count limit cursor since languages].freeze
    MAX_IN = 500
    SQL_OPS = { "eq" => "=", "ne" => "<>", "lt" => "<", "le" => "<=", "gt" => ">", "ge" => ">=" }.freeze

    Filter = Struct.new(:field, :op, :value, :raw, :name, keyword_init: true)
    Named = Struct.new(:name, :value, :raw, keyword_init: true)

    attr_reader :collection, :filters, :named, :sort, :fields, :limit, :count, :cursor_payload, :pairs

    # kind: :root, :collection or :item; method: the request's.
    def initialize(collection, kind, method, pairs)
      @collection, @kind, @method, @pairs = collection, kind, method, pairs
      @filters, @named, @sort, @fields = [], [], [], nil
      @switched_off = [] # default switches the request turns off with filter[name]=false (§6.1)
      @limit = collection&.default_limit
      @count = false
      @issues = [] # [category (0 unsupported, 1 invalid), position, name, detail]
      analyze
    end

    def supported
      safe = %w[GET HEAD].include?(@method)
      return [] unless safe
      case @kind
      when :collection then %w[filter sort fields limit cursor count]
      when :item, :singleton then %w[fields]
      else []
      end
    end

    def unsupported(i, name, detail) = @issues << [0, i, name, detail]
    def invalid(i, name, detail) = @issues << [1, i, name, detail]

    def analyze
      sup = supported
      seen = {}
      raw_cursor = nil
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
        when "fields" then analyze_fields(p, i)
        when "limit" then analyze_limit(p, i)
        when "count" then analyze_count(p, i)
        when "cursor"
          if p.value.nil? || p.value.empty? then invalid(i, name, "cursor cannot be empty.")
          else raw_cursor = [p.value, i]
          end
        end
      end
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
      when :item, :singleton then @method == "GET" || @method == "HEAD" ? "Here only fields is supported." : "#{@method} takes no reserved parameters."
      else
        if %w[GET HEAD].include?(@method)
          "#{base} is not supported here; this collection supports filter, sort, fields, limit, cursor and count."
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

    # ---- sort, fields, limit, count ---------------------------------------------------------

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

    def analyze_fields(p, i)
      return invalid(i, p.name, "fields cannot be empty.") if p.value.nil? || p.value.empty?
      list = p.value.split(",", -1)
      return invalid(i, p.name, "fields has an empty name.") if list.any?(&:empty?)
      unknown = list.reject { |f| collection.fields.key?(f) }
      return invalid(i, p.name, "Unknown field#{"s" if unknown.size > 1}: #{unknown.join(", ")}. Fields: #{collection.fields.keys.join(", ")}.") unless unknown.empty?
      @fields = list
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

    def binding_payload
      f = @filters.map { |x| ["f", x.field, x.op, x.raw] } + @named.map { |x| ["n", x.name, x.raw] }
      { "c" => collection.name, "f" => Digest::SHA256.hexdigest(JSON.generate(f.sort))[0, 22],
        "s" => @sort.map { |k, d| d ? "-#{k}" : k }.join(","), "p" => PRINCIPAL }
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

    # ---- SQL ----------------------------------------------------------------------------------

    def where_clauses
      clauses = @filters.map { |f| filter_sql(collection.filters[f.field], f.op, f.value) }
      clauses += @named.map { |n| sanitize(collection.named_filters[n.name][:sql].call(n.value)) }
      clauses
    end

    def sanitize(arr) = ActiveRecord::Base.sanitize_sql_array(arr)

    def q(v) = ActiveRecord::Base.connection.quote(v)

    def literal(type, v)
      case type
      when "integer" then Types::BIGINT.cover?(v) ? "#{v}::bigint" : "#{q(v.to_s)}::numeric"
      when "decimal" then "#{q(v.to_s("F"))}::numeric"
      when "date" then "#{q(v.iso8601)}::date"
      when "boolean" then v ? "TRUE" : "FALSE"
      else q(v)
      end
    end

    def filter_sql(decl, op, value)
      col = decl[:sql]
      return value ? "#{col} IS NULL" : "#{col} IS NOT NULL" if op == "null"
      return id_filter_sql(col, op, value) if decl[:id_like]
      return datetime_filter_sql(col, op, value) if decl["type"] == "datetime"
      return text_match_sql(col, op, value) if %w[prefix contains].include?(op)
      if op == "in"
        "#{col} IN (#{value.map { |v| literal(decl["type"], v) }.join(", ")})"
      elsif op == "nin"
        # §6.1: nin, like every operator but null, never matches an absent or null value.
        "#{col} IS NOT NULL AND #{col} NOT IN (#{value.map { |v| literal(decl["type"], v) }.join(", ")})"
      else
        "#{col} #{SQL_OPS.fetch(op)} #{literal(decl["type"], value)}"
      end
    end

    # §6.1 (draft 7): prefix and contains by code points, which is what the declared collation
    # says for these columns (COLLATE "C" on PostgreSQL; SQLite compares bytes).
    def text_match_sql(col, op, value)
      lit = q(value)
      postgres = ActiveRecord::Base.connection.adapter_name.match?(/postg/i)
      if op == "prefix"
        postgres ? "starts_with(#{col}, #{lit})" : "substr(#{col}, 1, length(#{lit})) = #{lit}"
      else
        postgres ? "strpos(#{col}, #{lit}) > 0" : "instr(#{col}, #{lit}) > 0"
      end
    end

    # The id is a string (§3): only the canonical strings of a bigint can match.
    def id_filter_sql(col, op, value)
      canon = ->(s) { s.match?(/\A[1-9][0-9]{0,17}\z/) ? s.to_i : nil }
      case op
      when "eq" then (n = canon.(value)) ? "#{col} = #{n}" : "FALSE"
      when "ne" then (n = canon.(value)) ? "#{col} <> #{n}" : "#{col} IS NOT NULL"
      when "in"
        ns = value.filter_map { |v| canon.(v) }
        ns.empty? ? "FALSE" : "#{col} IN (#{ns.join(", ")})"
      when "nin"
        ns = value.filter_map { |v| canon.(v) }
        ns.empty? ? "#{col} IS NOT NULL" : "#{col} NOT IN (#{ns.join(", ")})"
      end
    end

    # Exact comparison of instants even if the value has more precision than the microseconds
    # PostgreSQL stores (which would round): see the journal.
    def datetime_filter_sql(col, op, r)
      if %w[in nin].include?(op)
        exact = r.select { |x| Types.micro_exact?(x) }
        return op == "in" ? "FALSE" : "#{col} IS NOT NULL" if exact.empty?
        list = exact.map { |x| "#{q(Types.sql_instant(x))}::timestamptz" }.join(", ")
        return op == "in" ? "#{col} IN (#{list})" : "#{col} IS NOT NULL AND #{col} NOT IN (#{list})"
      end
      lit = ->(mode) { "#{q(Types.sql_instant(r, mode))}::timestamptz" }
      if Types.micro_exact?(r)
        "#{col} #{SQL_OPS.fetch(op)} #{lit.(:floor)}"
      else
        case op
        when "eq" then "FALSE"
        when "ne" then "#{col} IS NOT NULL"
        when "lt", "le" then "#{col} <= #{lit.(:floor)}"
        when "gt", "ge" then "#{col} >= #{lit.(:ceil)}"
        end
      end
    end

    def order_sql
      parts = @sort.map { |k, desc| "#{collection.sort[k][:sql]} #{desc ? "DESC" : "ASC"} NULLS LAST" }
      (parts + ["id ASC"]).join(", ")
    end

    # "After the last row" condition with nulls last in both directions. SQL's row comparison,
    # (a, id) > (x, y), does not work with nulls.
    def keyset_sql(keys, last_id)
      ors = []
      eqs = []
      @sort.each_with_index do |(k, desc), idx|
        d = collection.sort[k]
        v = keys[idx]
        lit = v.nil? ? nil : sort_literal(d[:type], v)
        unless v.nil?
          ors << (eqs + ["(#{d[:sql]} #{desc ? "<" : ">"} #{lit} OR #{d[:sql]} IS NULL)"]).join(" AND ")
        end
        eqs << (v.nil? ? "#{d[:sql]} IS NULL" : "#{d[:sql]} = #{lit}")
      end
      ors << (eqs + ["id > #{Integer(last_id)}"]).join(" AND ")
      "(" + ors.map { |o| "(#{o})" }.join(" OR ") + ")"
    end

    def sort_literal(type, v)
      case type
      when "datetime" then "#{q(v)}::timestamptz"
      when "decimal" then "#{q(v)}::numeric"
      when "date" then "#{q(v)}::date"
      when "integer" then "#{Integer(v)}::bigint"
      else q(v)
      end
    end

    def sort_value(rec, key)
      d = collection.sort[key]
      v = rec[d[:sql]]
      case v
      when nil then nil
      when Time, ActiveSupport::TimeWithZone then v.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
      when BigDecimal then v.to_s("F")
      when Date then v.iso8601
      else v
      end
    end

    # Runs the query and returns [records, next cursor or nil, total or nil].
    def run
      model = collection.model
      scope = model.all
      where_clauses.each { |c| scope = scope.where(Arel.sql(c)) }
      total = @count ? scope.count : nil
      if @cursor_payload
        scope = scope.where(Arel.sql(keyset_sql(@cursor_payload["k"], @cursor_payload["i"])))
      end
      rows = scope.order(Arel.sql(order_sql)).limit(@limit + 1).to_a
      next_token = nil
      if rows.size > @limit
        rows = rows.first(@limit)
        last = rows.last
        next_token = Cursor.issue(binding_payload.merge("k" => @sort.map { |k, _| sort_value(last, k) }, "i" => last.id))
      end
      [rows, next_token, total]
    end

    # §6.4: next carries the cursor and leaves the other parameters as they arrived.
    def next_link(path, token)
      kept = @pairs.reject { |p| p.name == "cursor" }.map { |p| QueryString.link_form(p.raw) }
      "#{path}?#{(kept + ["cursor=#{QueryString.encode_component(token)}"]).join("&")}"
    end

    def project(rep)
      return rep unless @fields
      rep.select { |k, _| k == "id" || k.start_with?("_") || @fields.include?(k) }
    end
  end

end
