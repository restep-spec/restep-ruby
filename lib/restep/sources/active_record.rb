require "active_record"

module Restep
  module Sources
    # A collection backed by an Active Record model, with SQL for filters, sorting and keyset
    # pagination. It targets PostgreSQL (casts such as ::bigint and ::timestamptz, COLLATE "C",
    # FOR UPDATE); the plain cases also run on SQLite.
    #
    #   Restep::Sources::ActiveRecord.new("Station")
    #   Restep::Sources::ActiveRecord.new("Draft", parent_column: "policy_id")   # a subcollection
    #
    # Each filter, named filter and sort key of the collection says its SQL with sql:
    #   filters: { "code" => { "type" => "string", "ops" => %w[eq in], sql: "code" } }
    #   named_filters: { "wet" => { "description" => "...", sql: ->(value) { ["rainfall_mm > 0"] } } }
    #   sort: { "taken_at" => { sql: "taken_at", type: "datetime" } }
    # A filter or sort key without sql: uses the column of the field of the same name (for
    # relation.id, the relation's column).
    class ActiveRecord < Source
      SQL_OPS = { "eq" => "=", "ne" => "<>", "lt" => "<", "le" => "<=", "gt" => ">", "ge" => ">=" }.freeze

      attr_reader :parent_column

      # model: the class or its name (resolved late: the gem loads before a Rails app's models).
      # parent_column: in a subcollection, the column with the parent item's id.
      # timestamps: sets created_at and updated_at, where the table has them.
      def initialize(model, parent_column: nil, timestamps: true)
        @model, @parent_column, @timestamps = model, parent_column, timestamps
      end

      def model = @model.is_a?(String) ? Object.const_get(@model) : @model

      def supports?(_op) = true

      # The rows under the parent item, as an Active Record relation: what a collection action
      # receives.
      def scope(parents)
        return model.all if parent_column.nil? || parents.empty?
        model.where(parent_column => parents.record.id)
      end

      def value(record, column)
        record.has_attribute?(column) ? record[column] : record.public_send(column)
      end

      def id(record) = record.id.to_s

      # §3: only the canonical strings of an integer key name an item ("07" is not "7").
      def integer_id?
        return @integer_id unless @integer_id.nil?
        @integer_id = %i[integer bigint].include?(model.columns_hash[model.primary_key]&.type)
      end

      def key(id_text)
        return id_text unless integer_id?
        id_text.match?(/\A[1-9][0-9]{0,17}\z/) && Types::BIGINT.cover?(id_text.to_i) ? id_text.to_i : nil
      end

      def find(id_text, parents)
        k = key(id_text) or return nil
        scope(parents).find_by(id: k)
      end

      def find_singleton(parents) = scope(parents).order(:id).first

      def locate(id_text)
        k = key(id_text) or return nil
        model.find_by(id: k)
      end

      def parent_ids(record)
        return [] if parent_column.nil?
        parent = collection.parent_resource
        pid = record[parent_column].to_s
        prec = parent.source.locate(pid)
        (prec ? parent.source.parent_ids(prec) : []) + [pid]
      end

      def healthy?
        model.connection.select_value("SELECT 1") == 1
      rescue StandardError
        false
      end

      # ---- Writes -------------------------------------------------------------------------------

      def transaction(&) = model.transaction(requires_new: true, &)

      def lock(record, parents) = scope(parents).lock("FOR UPDATE").find_by(id: record.id)

      def reload(record, _parents)
        record.reload
      rescue ::ActiveRecord::RecordNotFound
        nil
      end

      def create(attrs, parents)
        rec = model.new(attrs)
        rec[parent_column] = parents.record.id if parent_column && !parents.empty?
        now = Time.now.utc.floor(6)
        %w[created_at updated_at].each { |c| rec[c] = now if @timestamps && rec.has_attribute?(c) }
        save_or_conflict(rec)
        rec.reload
      end

      def update(record, changes)
        return record if changes.empty?
        record.assign_attributes(changes)
        record["updated_at"] = Time.now.utc if @timestamps && record.has_attribute?("updated_at")
        save_or_conflict(record)
        record.reload
      end

      def delete(record)
        model.transaction(requires_new: true) { record.delete }
      rescue ::ActiveRecord::InvalidForeignKey
        raise collection.conflict(:foreign_key, record)
      end

      def save_or_conflict(rec)
        model.transaction(requires_new: true) { rec.save! }
      rescue ::ActiveRecord::RecordNotUnique
        raise collection.conflict(:unique, rec)
      end

      # ---- Lists --------------------------------------------------------------------------------

      # Runs the query and returns [records, next position or nil, total or nil]. The position is
      # the keyset of the last row: its sort values and its id.
      def list(query, parents)
        rel = scope(parents)
        where_clauses(query).each { |c| rel = rel.where(Arel.sql(c)) }
        total = query.count ? rel.count : nil
        if (pos = query.position)
          rel = rel.where(Arel.sql(keyset_sql(query, pos[0], pos[1])))
        end
        limit = query.limit
        rows = rel.order(Arel.sql(order_sql(query))).limit(limit + 1).to_a
        position = nil
        if rows.size > limit
          rows = rows.first(limit)
          last = rows.last
          position = [query.sort.map { |k, _| sort_value(last, k) }, last.id]
        end
        [rows, position, total]
      end

      # The SQL of a filter or a sort key: its sql:, or the column of the field it names. Raises
      # a ConfigurationError if there is none (Restep.check! finds it at boot).
      def sql_for(name, decl)
        return decl[:sql] if decl && decl[:sql]
        fields = collection.fields
        if (f = fields[name]) && f.type != "language_map" then return quote_column(f.column)
        end
        base, rest = name.split(".", 2)
        f = fields[base]
        return quote_column(f.column) if f&.type == "relation" && rest == "id"
        return json_key_sql(quote_column(f.column), rest) if f&.type == "language_map"
        raise ConfigurationError, "#{collection.name}: #{name} needs sql: (no field of that name)"
      end

      # Checks at boot that every filter, named filter and sort key has its SQL.
      def check!
        collection.filters.each { |n, d| sql_for(n, d) }
        collection.sort.each { |n, d| sql_for(n, d) }
        collection.named_filters.each do |n, d|
          raise ConfigurationError, "#{collection.name}: named filter #{n} needs sql: ->(value) { [...] }" unless d[:sql].respond_to?(:call)
        end
      end

      def quote_column(c) = c.to_s.match?(/\A[a-z_][a-z0-9_]*\z/) ? c.to_s : model.connection.quote_column_name(c)

      def json_key_sql(col, key)
        postgres? ? "(#{col} ->> #{q(key)})" : "json_extract(#{col}, #{q("$.\"#{key}\"")})"
      end

      def postgres? = model.connection.adapter_name.match?(/postg/i)

      def where_clauses(query)
        clauses = query.filters.map { |f| filter_sql(f.field, collection.filters[f.field], f.op, f.value) }
        clauses + query.named.map { |n| sanitize(collection.named_filters[n.name][:sql].call(n.value)) }
      end

      def sanitize(arr) = model.sanitize_sql_array(arr)

      def q(v) = model.connection.quote(v)

      def literal(type, v)
        case type
        when "integer" then Types::BIGINT.cover?(v) ? "#{v}::bigint" : "#{q(v.to_s)}::numeric"
        when "decimal" then "#{q(v.to_s("F"))}::numeric"
        when "date" then "#{q(v.iso8601)}::date"
        when "boolean" then v ? "TRUE" : "FALSE"
        else q(v)
        end
      end

      def filter_sql(name, decl, op, value)
        col = sql_for(name, decl)
        return value ? "#{col} IS NULL" : "#{col} IS NOT NULL" if op == "null"
        return id_filter_sql(col, op, value) if collection.id_filter?(name, decl) && integer_key_filter?(name)
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

      # Whether an id filter compares integer keys: the collection's own id, or a relation to a
      # collection whose source has integer keys.
      def integer_key_filter?(name)
        return integer_id? if name == "id"
        base = name.delete_suffix(".id")
        f = collection.fields[base]
        target = f&.type == "relation" && Restep.collections[f.relation]
        target ? !target.source.is_a?(ActiveRecord) || target.source.integer_id? : true
      end

      # §6.1 (draft 7): prefix and contains by code points, which is what the declared collation
      # says for these columns (COLLATE "C" on PostgreSQL; SQLite compares bytes).
      def text_match_sql(col, op, value)
        lit = q(value)
        if op == "prefix"
          postgres? ? "starts_with(#{col}, #{lit})" : "substr(#{col}, 1, length(#{lit})) = #{lit}"
        else
          postgres? ? "strpos(#{col}, #{lit}) > 0" : "instr(#{col}, #{lit}) > 0"
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

      def sort_decl(key) = collection.sort[key] || {}
      def sort_sql(key) = sql_for(key, sort_decl(key))

      def sort_type(key)
        sort_decl(key)[:type] || collection.fields[key]&.type || "string"
      end

      def order_sql(query)
        parts = query.sort.map { |k, desc| "#{sort_sql(k)} #{desc ? "DESC" : "ASC"} NULLS LAST" }
        (parts + ["id ASC"]).join(", ")
      end

      # "After the last row" condition with nulls last in both directions. SQL's row comparison,
      # (a, id) > (x, y), does not work with nulls.
      def keyset_sql(query, keys, last_id)
        ors = []
        eqs = []
        query.sort.each_with_index do |(k, desc), idx|
          col = sort_sql(k)
          v = keys[idx]
          lit = v.nil? ? nil : sort_literal(sort_type(k), v)
          unless v.nil?
            ors << (eqs + ["(#{col} #{desc ? "<" : ">"} #{lit} OR #{col} IS NULL)"]).join(" AND ")
          end
          eqs << (v.nil? ? "#{col} IS NULL" : "#{col} = #{lit}")
        end
        ors << (eqs + ["id > #{integer_id? ? Integer(last_id) : q(last_id.to_s)}"]).join(" AND ")
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
        d = sort_decl(key)
        v = d[:sql] && rec.has_attribute?(d[:sql]) ? rec[d[:sql]] : sort_raw(rec, key)
        case v
        when nil then nil
        when Time, ActiveSupport::TimeWithZone then v.utc.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
        when BigDecimal then v.to_s("F")
        when Date then v.iso8601
        else v
        end
      end

      def sort_raw(rec, key)
        f = collection.fields[key]
        return rec[f.column] if f && f.type != "language_map"
        base, tag = key.split(".", 2)
        f = collection.fields[base]
        return Language.render(rec[f.column])[tag] if f&.type == "language_map"
        rec[sort_decl(key)[:sql]]
      end
    end
  end
end
