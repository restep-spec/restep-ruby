module Restep
  module Sources
    # A collection, or a singleton, whose items the domain computes: no table behind it, ids that
    # may be document keys, writes that go through the domain. The domain gives lambdas; the gem
    # filters, sorts and pages the items in memory with the rules of §6 (types, null and absent
    # values, code points, nulls last), so it suits collections that fit in memory under one
    # parent. For a larger one, subclass Restep::Source and implement list.
    #
    #   Restep::Sources::Computed.new(
    #     all: ->(parents) { Policy.find(parents["policy"]).drafts },  # every item under the parents
    #     find: ->(id, parents) { ... },             # optional: by default, looked up in all
    #     create: ->(attrs, parents) { ... },        # optional, each one: the methods follow
    #     update: ->(record, changes) { ... },
    #     delete: ->(record) { ... })
    #
    # A record is a Hash (string or symbol keys) or any object with readers. Filters compare the
    # value of the field of the same name (for relation.id, the relation's column; for
    # map.tag, that translation), or what value: ->(record) gives; a named filter says
    # match: ->(record, value) { true or false }. For a singleton, get: ->(parents) { record }.
    # transaction: ->(&write) { ... } wraps each write, so that evaluating If-Match and applying
    # the write are atomic (§7.2): a mutex, or the domain's own transaction.
    class Computed < Source
      OPTIONS = %i[all find get create update delete id scope locate parent_ids lock transaction].freeze

      def initialize(**fns)
        unknown = fns.keys - OPTIONS
        raise ArgumentError, "Restep::Sources::Computed takes #{OPTIONS.join(", ")}, not #{unknown.join(", ")}" unless unknown.empty?
        @fns = fns
      end

      def supports?(op)
        case op
        when :list then @fns.key?(:all)
        when :find then @fns.key?(:all) || @fns.key?(:find)
        else @fns.key?(op)
        end
      end

      def all(parents) = @fns.fetch(:all) { raise NotImplementedError, "#{collection.name}: all: is needed to list" }.call(parents).to_a

      def id(record) = @fns[:id] ? @fns[:id].call(record).to_s : super

      def find(id_text, parents)
        return @fns[:find].call(id_text, parents) if @fns[:find]
        all(parents).find { |r| id(r) == id_text }
      end

      def find_singleton(parents) = @fns.fetch(:get).call(parents)
      def create(attrs, parents) = @fns.fetch(:create).call(attrs, parents)
      def update(record, changes) = changes.empty? ? record : @fns.fetch(:update).call(record, changes)
      def delete(record) = @fns.fetch(:delete).call(record)
      def scope(parents) = @fns[:scope] ? @fns[:scope].call(parents) : parents
      def locate(id_text) = @fns[:locate]&.call(id_text)
      def parent_ids(record) = @fns[:parent_ids] ? @fns[:parent_ids].call(record).map(&:to_s) : super

      def lock(record, parents)
        return @fns[:lock].call(record, parents) if @fns[:lock]
        collection.singleton? ? find_singleton(parents) : find(id(record), parents)
      end

      def reload(record, parents) = lock(record, parents)

      def transaction(&write) = @fns[:transaction] ? @fns[:transaction].call(&write) : yield

      def list(query, parents) = InMemory.page(self, all(parents), query)
    end

    # Filtering, sorting and paging of records in memory, by the rules of §6. A custom source may
    # use it on records it already holds: Restep::Sources::InMemory.page(source, records, query).
    module InMemory
      module_function

      # Returns [records, next position or nil, total or nil]. The position is the keyset of the
      # last record of the page: its sort values and its id.
      def page(source, records, query)
        coll = source.collection
        rows = records.select { |r| match?(source, coll, r, query) }
        total = query.count ? rows.size : nil
        keyed = rows.map { |r| [key(source, coll, r, query), r] }
        keyed.sort! { |(a, _), (b, _)| compare_keys(a, b, query.sort) }
        if (pos = query.position)
          after = [pos[0].each_with_index.map { |v, i| decode(sort_type(coll, query.sort[i][0]), v) }, pos[1]]
          keyed = keyed.drop_while { |k, _| compare_keys(k, after, query.sort) <= 0 }
        end
        limit = query.limit
        page = keyed.first(limit)
        position = nil
        if keyed.size > limit
          last_key = page.last[0]
          position = [last_key[0].each_with_index.map { |v, i| encode(v, sort_type(coll, query.sort[i][0])) }, last_key[1]]
        end
        [page.map(&:last), position, total]
      end

      def match?(source, coll, r, query)
        query.filters.all? { |f| filter?(field_value(source, coll, r, f.field, coll.filters[f.field]), coll.filters[f.field]["type"], f.op, f.value) } &&
          query.named.all? do |n|
            fn = coll.named_filters[n.name][:match] or raise ConfigurationError, "#{coll.name}: named filter #{n.name} needs match: ->(record, value) { ... }"
            fn.call(r, n.value)
          end
      end

      # The value a filter or a sort key compares, in the declared type, or nil when absent.
      def field_value(source, coll, r, name, decl)
        decl ||= {}
        return normalize(decl[:value].call(r), decl["type"] || decl[:type]) if decl[:value]
        type = decl["type"] || decl[:type]
        if (f = coll.fields[name]) && f.type != "language_map"
          v = source.value(r, f.column)
          v = v.is_a?(Hash) ? v["id"] || v[:id] : v if f.type == "relation"
          return v&.to_s if %w[id relation].include?(f.type)
          return normalize(v, type || f.type)
        end
        base, rest = name.split(".", 2)
        f = coll.fields[base]
        if f&.type == "relation" && rest == "id"
          v = source.value(r, f.column)
          v = v["id"] || v[:id] if v.is_a?(Hash)
          return v&.to_s
        end
        return Language.render(source.value(r, f.column))[rest] if f&.type == "language_map"
        raise ConfigurationError, "#{coll.name}: #{name} needs value: ->(record) { ... } (no field of that name)"
      end

      # A stored value in the type it is compared by: Rational instants, BigDecimal decimals,
      # Date dates, strings.
      def normalize(v, type)
        return nil if v.nil?
        case type
        when "datetime"
          case v
          when String then Types.parse_datetime(v)
          when Time then v.to_r
          when DateTime then v.to_time.to_r
          else v.respond_to?(:to_time) ? v.to_time.to_r : v
          end
        when "decimal" then v.is_a?(String) ? BigDecimal(v) : BigDecimal(v.to_s)
        when "integer" then v.is_a?(String) ? Integer(v, 10) : v
        when "date" then v.is_a?(String) ? Types.parse_date(v) : v
        when "id" then v.to_s
        else v
        end
      end

      def filter?(v, type, op, operand)
        return operand ? v.nil? : !v.nil? if op == "null"
        return false if v.nil? # §6.1: every other operator never matches an absent or null value
        case op
        when "eq" then v == operand
        when "ne" then v != operand
        when "lt" then (v <=> operand) == -1
        when "le" then [-1, 0].include?(v <=> operand)
        when "gt" then (v <=> operand) == 1
        when "ge" then [1, 0].include?(v <=> operand)
        when "in" then operand.include?(v)
        when "nin" then !operand.include?(v)
        when "prefix" then v.is_a?(String) && v.start_with?(operand)
        when "contains" then v.is_a?(String) && v.include?(operand)
        else false
        end
      end

      def sort_type(coll, key)
        d = coll.sort[key] || {}
        d[:type] || coll.filters.dig(key, "type") || coll.fields[key]&.type || "string"
      end

      def key(source, coll, r, query)
        values = query.sort.map do |k, _|
          d = coll.sort[k] || {}
          field_value(source, coll, r, k, { "type" => sort_type(coll, k) }.merge(d.slice(:value)))
        end
        [values, source.id(r)]
      end

      # Nulls go last in both directions (§6.2); ties break by id, in the server's order: here,
      # code points.
      def compare_keys(a, b, sort)
        sort.each_with_index do |(_, desc), i|
          x, y = a[0][i], b[0][i]
          next if x == y
          return 1 if x.nil?
          return -1 if y.nil?
          c = x <=> y
          next if c.nil? || c.zero?
          return desc ? -c : c
        end
        a[1] <=> b[1]
      end

      # Sort values as the cursor carries them (JSON), and back.
      def encode(v, type)
        case v
        when nil then nil
        when Rational then type == "datetime" ? "#{v.numerator}/#{v.denominator}" : v.to_s
        when BigDecimal then v.to_s("F")
        when Date then v.iso8601
        else v
        end
      end

      def decode(type, v)
        return nil if v.nil?
        case type
        when "datetime" then v.is_a?(String) && v.include?("/") ? Rational(v) : normalize(v, type)
        when "decimal" then BigDecimal(v)
        when "date" then Date.iso8601(v)
        else v
        end
      end
    end
  end
end
