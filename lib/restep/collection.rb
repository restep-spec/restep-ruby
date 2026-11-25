module Restep
  # A collection (or a singleton) of the application's catalog: the fields, filters and order it
  # declares, and its representation, validation and ETag. The domain creates it with Fields.f.
  class Collection
    Field = Struct.new(:name, :type, :column, :values, :nullable, :required, :default, :read_only,
                       :max_length, :pattern, :range, :scale, :relation, :description, keyword_init: true)

    # An action (§11.1). on: "item" or "collection"; method: "POST" or "GET" (only safe ones);
    # input: body fields (Fields.f), or nil. available: whether the item's state allows it
    # (what _actions lists); unavailable: the 409 it gives if not. run: the effect, which gets
    # the item (or the model, in a collection action) and the validated input. In an item
    # action, the response is the re-read item; in a collection one, run returns
    # [status, JSON object or nil].
    # effects: what a person may want to approve first (§11.1, draft 7), a list out of destroys,
    # external and charges, or nil to leave it undeclared. output: the JSON Schema of a safe
    # action's result, which is not a representation; a safe action without output answers its
    # item's representation or nothing (204).
    Action = Struct.new(:name, :on, :method, :safe, :idempotent, :description, :input, :available,
                        :unavailable, :run, :effects, :output, keyword_init: true) do
      def item? = on == "item"
      def allowed_methods = method == "GET" ? %w[GET HEAD] : [method]
      def available?(rec) = available.nil? || available.call(rec)
    end

    attr_reader :name, :path, :fields, :filters, :named_filters, :sort, :max_limit,
                :default_limit, :description, :actions, :method_effects

    # conflicts: which 409 to give when the database rejects a write, by kind of error:
    #   { unique: ->(rec) { Problem }, foreign_key: ->(rec) { Problem } }
    # method_effects: only for a singleton (§5.9, draft 7), the effects of its PATCH, as
    # { "PATCH" => [...] } out of destroys, external and charges; nil leaves it undeclared, which
    # a client counts as all three.
    def initialize(name:, path:, model:, description:, fields:, filters: {}, named_filters: {}, sort: {},
                   max_limit: nil, default_limit: nil, conflicts: {}, singleton: false, actions: [],
                   method_effects: nil)
      @name, @path, @model, @description = name, path, model, description
      @actions = actions.to_h { |a| [a.name, a] }
      @conflicts, @singleton = conflicts, singleton
      @fields = fields.to_h { |f| [f.name, f] }
      @filters, @named_filters, @sort = filters, named_filters, sort
      @max_limit, @default_limit = max_limit, default_limit
      @method_effects = method_effects
      check_filters!
      check_method_effects!
    end

    # §4.3 and §5.9 (draft 7): a singleton may declare method_effects with PATCH as its only key.
    # This gem declares it on singletons only.
    def check_method_effects!
      return if method_effects.nil?
      bad = ->(why) { raise ArgumentError, "#{name}: method_effects #{why} (4.3, 5.9)" }
      bad.("is declared here only on a singleton") unless singleton?
      bad.("takes PATCH as its only key") unless method_effects.is_a?(Hash) && method_effects.keys == ["PATCH"]
      e = method_effects["PATCH"]
      bad.("takes #{Fields::EFFECTS.join(", ")}") unless e.is_a?(Array) && (e - Fields::EFFECTS).empty? && e.uniq == e
    end

    OPS = %w[eq ne lt le gt ge in nin null prefix contains].freeze

    # §6.1 (draft 7): what a collection may declare in filter and named_filters. A declaration that
    # breaks it is a programming error, raised when the domain is loaded.
    def check_filters!
      bad = ->(name, why) { raise ArgumentError, "#{self.name}: filter #{name}: #{why} (6.1)" }
      filters.each do |name, d|
        ops = d["ops"]
        bad.(name, "operators come from #{OPS.join(", ")}") unless (ops - OPS).empty?
        bad.(name, "a boolean filter declares only eq, ne and null") if d["type"] == "boolean" && !(ops - %w[eq ne null]).empty?
        bad.(name, "the id filter declares no order operators") if d[:id_like] && !(ops & %w[lt le gt ge]).empty?
        if !(ops & %w[prefix contains]).empty? && (d["type"] != "string" || d[:id_like])
          bad.(name, "prefix and contains only on string fields, never on an id")
        end
        bad.(name, "shares its name with a named filter") if named_filters.key?(name)
      end
      named_filters.each do |name, d|
        bad.(name, "only a switch, a named filter without type, can be a default filter") if d["default"] && d["type"]
      end
    end

    # Paths relative to the API root (discovery) and absolute ones (links and headers).
    def item_path(id) = singleton? ? path : "#{path}/#{id}"
    def url = Restep.url(path)
    def item_url(id) = Restep.url(item_path(id))

    def singleton? = @singleton

    def find_singleton = model.order(:id).first

    # The 409 that matches a database error on write (§5.4).
    def conflict(kind, rec)
      hook = @conflicts[kind]
      hook ? hook.call(rec) : Problem.new(409, "conflict", detail: "The write conflicts with the current state of #{name}.")
    end

    # The model is resolved late: this file loads before the app/models autoload.
    def model = Object.const_get(@model)

    def find(id_text)
      return nil unless id_text.match?(/\A[1-9][0-9]{0,17}\z/) && Types::BIGINT.cover?(id_text.to_i)
      model.find_by(id: id_text.to_i)
    end

    # ---- Reading ---------------------------------------------------------------------------

    def represent(rec)
      rep = fields.values.to_h do |f|
        v = rec[f.column]
        out =
          case f.type
          when "id" then v.to_s
          when "relation" then v.nil? ? nil : { "id" => v.to_s, "href" => Restep.collections.fetch(f.relation).item_url(v) }
          when "decimal" then Types.render_decimal(v, f.scale)
          when "datetime" then Types.render_datetime(v)
          when "date" then v&.iso8601
          else v
          end
        [f.name, out]
      end
      item_actions = actions.values.select(&:item?)
      return rep if item_actions.empty?
      # §11.1: the actions its current state allows, so the client need not repeat the rules.
      rep.merge("_actions" => item_actions.select { |a| a.available?(rec) }.to_h { |a|
        [a.name, { "method" => a.method, "href" => "#{item_url(rec.id)}:#{a.name}" }]
      })
    end

    # Validates an action's body against its input. Returns { name => value } or raises 422.
    def validate_input(action, body)
      fields = (action.input || []).to_h { |f| [f.name, f] }
      errors = []
      out = {}
      body.each_key do |k|
        next if k.start_with?("_") || fields.key?(k)
        errors << unknown_member(k, "a member of the #{action.name} input")
      end
      fields.each_value do |f|
        ptr = "/#{esc(f.name)}"
        if !body.key?(f.name)
          errors << err(ptr, "required", "#{f.name} is required.") if f.required
        elsif body[f.name].nil?
          f.nullable ? out[f.name] = nil : errors << err(ptr, "required", "#{f.name} cannot be null.")
        else
          val = coerce(f, body[f.name], ptr, errors)
          out[f.name] = val unless val == :error
        end
      end
      raise Problem.invalid(errors) unless errors.empty?
      out
    end

    # §7.2 (draft 6): strong ETag of the full representation, computed as if "_etag" were not
    # there; the other "_" members count.
    def etag(rep)
      %("#{Digest::SHA256.hexdigest(JSON.generate(rep.except("_etag")))[0, 32]}")
    end

    # Every response whose body is an item carries "_etag" (§7.2, draft 6).
    def with_etag(rep) = rep.merge("_etag" => etag(rep))

    # ---- Writing -------------------------------------------------------------------------

    # Validates a POST body. Returns the column attributes or raises 422.
    # §5.1 (draft 7): in a POST, a field that only the server sets is ignored whatever its value.
    # Such a field is one no client can set directly, in a POST or a PATCH. In this gem that is
    # what read_only: true means for a field other than id: a POST ignores it and a PATCH accepts
    # only its current value, so no request sets it (created_at, updated_at). The gem has no
    # effective or localized fields, and the readOnly it writes in the item schema follows from
    # that behaviour; it does not define it.
    def attributes_for_create(body)
      errors = []
      attrs = {}
      body.each_key do |k|
        next if k.start_with?("_") # §5.1: ignored
        f = fields[k]
        if f.nil?
          errors << unknown_member(k, "a field of #{name}")
        elsif f.type == "id"
          errors << err("/id", "read_only", "id is assigned by the server.")
        end
      end
      fields.each_value do |f|
        next if f.read_only
        ptr = "/#{f.name}"
        if !body.key?(f.name)
          if f.required then errors << err(ptr, "required", "#{f.name} is required.")
          elsif !f.default.nil? then attrs[f.column] = f.default
          else attrs[f.column] = nil
          end
        elsif body[f.name].nil?
          if f.nullable then attrs[f.column] = nil
          else errors << err(ptr, "required", "#{f.name} cannot be null.")
          end
        else
          val = coerce(f, body[f.name], ptr, errors)
          attrs[f.column] = val unless val == :error
        end
      end
      raise Problem.invalid(errors) unless errors.empty?
      attrs
    end

    # Validates a merge patch against the current item. Returns only the columns that change.
    def changes_for_patch(rec, body)
      errors = []
      changes = {}
      current = represent(rec)
      body.each do |k, v|
        next if k.start_with?("_")
        f = fields[k]
        ptr = "/#{esc(k)}"
        if f.nil?
          errors << unknown_member(k, "a field of #{name}")
        elsif f.read_only && f.type == "datetime" && Types.leap_second?(v)
          # §3 (draft 7): a leap second in a request body is rejected with a format entry, even
          # in a read-only field, instead of being taken as the next minute.
          errors << err(ptr, "format", leap_second_detail(f))
        elsif f.read_only
          errors << err(ptr, "read_only", "#{k} cannot be changed.") unless same_read_only?(f, v, current[k])
        elsif f.type == "relation" && v.is_a?(Hash) && current[k].is_a?(Hash) && v["id"] == current[k]["id"]
          # Relation with its current value: ignored without checking that the target exists
          # (§5.1); only href, if present, is checked to be that item's path.
          check_href(f, v, ptr, errors)
        elsif v.nil?
          if f.nullable
            changes[f.column] = nil unless rec[f.column].nil?
          else
            errors << err(ptr, "required", "#{k} cannot be null.")
          end
        else
          val = coerce(f, v, ptr, errors)
          next if val == :error
          changes[f.column] = val unless same_value?(rec[f.column], val)
        end
      end
      raise Problem.invalid(errors) unless errors.empty?
      changes
    end

    private

    def err(pointer, code, detail) = { "pointer" => pointer, "code" => code, "detail" => detail }

    # An unknown member. §3 (council round 3, decision 10): a member name with a noncharacter gets
    # a format entry with pointer "", because a pointer to it (or a detail that quotes it) would
    # carry the same code point, and the response must be an I-JSON message. An unpaired
    # surrogate never gets here: Body rejects it first, also with pointer "".
    def unknown_member(k, what)
      if !k.valid_encoding? || Types.noncharacter?(k)
        return err("", "format", "A member name has a noncharacter, which a request body cannot carry.")
      end
      err("/#{esc(k)}", "unknown", "#{k} is not #{what}.")
    end

    def esc(k) = k.gsub("~", "~0").gsub("/", "~1")

    # §5.1: an href that is not the path of an item of the target collection, or whose last
    # segment is not the id sent, gives 422 (see the journal, B6-4: the text is worded for
    # subcollections).
    def check_href(f, v, ptr, errors)
      return true unless v.key?("href")
      target = Restep.collections.fetch(f.relation)
      href = v["href"]
      decoded = href.is_a?(String) ? (QueryString.decode(href) rescue nil) : nil
      return true if decoded && v["id"].is_a?(String) && decoded == target.item_url(v["id"])
      errors << err("#{ptr}/href", "format", "#{f.name}.href must be the path of the item, #{target.url}/{id}, with the id sent.")
      false
    end

    def leap_second_detail(f) = "#{f.name} has a leap second (:60), which this API does not accept; use :59 or the next minute."

    def same_value?(old, new)
      return old.nil? && new.nil? if old.nil? || new.nil?
      old == new
    end

    # §5.1: a read-only field with its current value is ignored. It is compared by type: the
    # same instant written another way is also the current value (see the journal, L14).
    def same_read_only?(f, v, current)
      return v == current unless f.type == "datetime" && v.is_a?(String) && current.is_a?(String)
      a = Types.parse_datetime(v)
      a && a == Types.parse_datetime(current)
    end

    def coerce(f, v, ptr, errors)
      fail_with = ->(code, detail) { errors << err(ptr, code, detail); :error }
      case f.type
      when "string", "enum"
        return fail_with.("type", "#{f.name} must be a string.") unless v.is_a?(String)
        # §3 (draft 7): no unpaired surrogates or noncharacters (I-JSON), nor U+0000.
        return fail_with.("format", "#{f.name} contains characters that cannot be stored (NUL, an unpaired surrogate or a noncharacter).") if !v.valid_encoding? || v.include?("\u0000") || Types.noncharacter?(v)
        if f.type == "enum"
          return fail_with.("format", "#{f.name} must be one of: #{f.values.join(", ")}.") unless f.values.include?(v)
        else
          return fail_with.("format", "#{f.name} cannot be empty.") if v.empty?
          return fail_with.("too_long", "#{f.name} takes at most #{f.max_length} characters.") if f.max_length && v.length > f.max_length
          return fail_with.("format", "#{f.name} must match #{f.pattern.source}.") if f.pattern && !f.pattern.match?(v)
        end
        v
      when "integer"
        int =
          if v.is_a?(Integer) then v
          elsif (v.is_a?(BigDecimal) || v.is_a?(Float)) && v.finite? && v.to_r.denominator == 1 then v.to_i
          end
        return fail_with.("type", "#{f.name} must be an integer.") if int.nil? || v == true || v == false
        return fail_with.("range", "#{f.name} must be between #{f.range.min} and #{f.range.max}.") unless f.range.cover?(int)
        int
      when "decimal"
        return fail_with.("type", "#{f.name} must be a decimal number written as a string, such as \"12.5\".") unless v.is_a?(String)
        return fail_with.("format", "#{f.name} must match -?[0-9]+(\\.[0-9]+)?.") unless Types::DECIMAL_RE.match?(v)
        return fail_with.("format", "#{f.name} takes at most #{f.scale} decimal places.") if v[/\.([0-9]+)\z/, 1].to_s.length > f.scale
        bd = BigDecimal(v)
        return fail_with.("range", "#{f.name} must be between #{f.range.min.to_s("F")} and #{f.range.max.to_s("F")}.") unless f.range.cover?(bd)
        bd
      when "boolean"
        return fail_with.("type", "#{f.name} must be true or false.") unless v == true || v == false
        v
      when "date"
        return fail_with.("type", "#{f.name} must be a date string (YYYY-MM-DD).") unless v.is_a?(String)
        d = Types.parse_date(v)
        return fail_with.("format", "#{f.name} must be an RFC 3339 full-date (YYYY-MM-DD).") unless d
        d
      when "datetime"
        return fail_with.("type", "#{f.name} must be an RFC 3339 date-time string.") unless v.is_a?(String)
        return fail_with.("format", leap_second_detail(f)) if Types.leap_second?(v)
        r = Types.parse_datetime(v)
        return fail_with.("format", "#{f.name} must be an RFC 3339 date-time with an offset.") unless r
        return fail_with.("format", "#{f.name} takes at most microsecond precision.") unless Types.micro_exact?(r)
        Time.at(r).utc
      when "relation"
        return fail_with.("type", "#{f.name} must be an object with an id, such as {\"id\": \"3\"}.") unless v.is_a?(Hash)
        unless v.key?("id")
          errors << err("#{ptr}/id", "required", "#{f.name}.id is required.")
          return :error
        end
        id = v["id"]
        unless id.is_a?(String)
          errors << err("#{ptr}/id", "type", "#{f.name}.id must be a string.")
          return :error
        end
        return :error unless check_href(f, v, ptr, errors)
        target = Restep.collections.fetch(f.relation).find(id)
        unless target
          errors << err("#{ptr}/id", "unknown", "There is no #{f.relation} item with id #{id.inspect}.")
          return :error
        end
        target.id
      end
    end
  end

  module Fields
    module_function

    def f(**kw) = Collection::Field.new(**{ column: kw[:name] }.merge(kw))

    EFFECTS = %w[destroys external charges].freeze

    # Checks the declaration against §11.1 (draft 7); a declaration that breaks it is a
    # programming error, raised when the domain is loaded.
    def action(name, on:, method: "POST", safe: false, idempotent: false, **kw)
      bad = ->(why) { raise ArgumentError, "action #{name}: #{why} (11.1)" }
      bad.("on must be item or collection") unless %w[item collection].include?(on)
      bad.("method must be POST or GET") unless %w[POST GET].include?(method)
      bad.("only a safe action may use GET") if method == "GET" && !safe
      bad.("a safe action declares idempotent: true") if safe && !idempotent
      bad.("a GET action has no body, so no input") if method == "GET" && kw[:input]
      bad.("output is only for a safe action") if kw[:output] && !safe
      bad.("changes is reserved for sync") if name == "changes"
      if name == "new" && !(on == "collection" && safe && method == "GET")
        bad.("new is the safe GET action of a collection that gives the starting values of a new item")
      end
      if (effects = kw[:effects])
        bad.("effects takes #{EFFECTS.join(", ")}") unless effects.is_a?(Array) && (effects - EFFECTS).empty? && effects.uniq == effects
        bad.("a safe action declares only charges") if safe && !(effects - ["charges"]).empty?
      end
      Collection::Action.new(name: name, on: on, method: method, safe: safe, idempotent: idempotent, **kw)
    end
  end
end
