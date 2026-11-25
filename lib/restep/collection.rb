module Restep
  # A collection (or a singleton) of the application's catalog: the fields, filters and order it
  # declares, where its data comes from (a Restep::Source), and its representation, validation
  # and ETag. The domain creates it with Fields.f and Fields.action.
  #
  # A subcollection declares a path template and its parent collection (§4.2):
  #
  #   Restep::Collection.new(name: "drafts", parent: "policies",
  #                          path: "/company_groups/{company_group}/policies/{policy}/drafts", ...)
  #
  # With a hand-written discovery document (Restep.config.discovery), what discovery declares
  # (path, parent, description, filter, sort, max_limit...) may be left out here: the document
  # fills it in, and Restep.check! fails on anything the code contradicts.
  # What an action's run returns to answer other than with its default (§11.1, draft 7):
  #   Restep::Created.new(location)        # 201 with the Location of what it created (absolute path)
  #   Restep::Created.new(location, body)  # the same with a JSON object as its body
  #   Restep::NO_CONTENT                   # 204, on an item or a singleton
  Created = Struct.new(:location, :body)
  NoContent = Class.new
  NO_CONTENT = NoContent.new.freeze

  class Collection
    Field = Struct.new(:name, :type, :column, :values, :nullable, :required, :default, :read_only,
                       :max_length, :pattern, :range, :scale, :relation, :description, :include,
                       :languages, :schema, :validate, keyword_init: true)

    # An action (§11.1). on: "item" or "collection"; method: "POST" or "GET" (only safe ones);
    # input: body fields (Fields.f), or nil. available: whether the item's state allows it
    # (what _actions lists); unavailable: the 409 it gives if not. run: the effect, which gets
    # the item (or, in a collection action, the source's scope for the parents: an Active Record
    # relation for Restep::Sources::ActiveRecord) and the validated input. §11.1 (draft 7) fixes
    # what each kind answers:
    # - unsafe, on an item: the re-read item (200), unless run returns Restep::Created (201 with
    #   Location) or Restep::NO_CONTENT (204);
    # - unsafe, on a collection: run returns Restep::Created (201 with Location) or [204, nil];
    #   never 200, since a collection has no representation of its own;
    # - safe, with GET or POST: run returns [status, result or nil]; a result (200) needs a
    #   declared output on a collection, and nil answers 204. A safe POST action takes an input,
    #   so it is how a client asks for a computed result from data in a body (a diff, a quote).
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

    attr_reader :name, :path, :template, :fields, :filters, :named_filters, :sort, :max_limit,
                :default_limit, :description, :actions, :method_effects, :source, :parent, :count,
                :extra_relations, :include_depth, :max_body_bytes

    # model: an Active Record model (a class or its name), shorthand for
    # source: Restep::Sources::ActiveRecord.new(model). source: any Restep::Source.
    # conflicts: which 409 to give when the store rejects a write, by kind of error:
    #   { unique: ->(rec) { Problem }, foreign_key: ->(rec) { Problem } }
    # methods and item_methods (§4.3): what the collection and its items support; by default, what
    # the source implements. method_effects: only for a singleton (§5.9, draft 7), the effects of
    # its PATCH, as { "PATCH" => [...] } out of destroys, external and charges; nil leaves it
    # undeclared, which a client counts as all three.
    # relations: relationships declared only in discovery (§9), such as the one that leads to a
    # subcollection: { "reviews" => { "to" => "reviews", "many" => true, "path" => "/books/{book_id}/reviews" } }.
    # A relation field (type "relation") with include: true can be expanded with include (§9).
    def initialize(name:, fields:, path: nil, model: nil, source: nil, parent: nil, description: nil, filters: {},
                   named_filters: {}, sort: {}, max_limit: nil, default_limit: nil, conflicts: {}, singleton: false,
                   actions: [], method_effects: nil, methods: nil, item_methods: nil, count: "exact", relations: {},
                   include_depth: nil, max_body_bytes: nil)
      raise ArgumentError, "#{name}: give model: or source:, not both" if model && source
      @name, @description, @parent = name, description, parent
      @actions = actions.to_h { |a| [a.name, a] }
      @conflicts, @singleton = conflicts, singleton
      @fields = fields.to_h { |f| [f.name, f] }
      @filters, @named_filters, @sort = filters, named_filters, sort
      @max_limit, @default_limit = max_limit, default_limit
      @method_effects = method_effects
      @declared_methods, @declared_item_methods = methods, item_methods
      @count = count
      @extra_relations = relations
      @include_depth = include_depth
      @max_body_bytes = max_body_bytes
      @source = source || (model && Sources::ActiveRecord.new(model)) or raise ArgumentError, "#{name}: give model: or source:"
      @source.bind(self)
      self.path = path if path
      check_filters!
      check_method_effects!
      check_fields!
    end

    def path=(value)
      @template = Template.new(value)
      @path = value
    end

    # Fills what a hand-written discovery document declares (Restep::Rules.bind!).
    attr_writer :parent, :description, :filters, :named_filters, :sort, :max_limit, :default_limit, :count,
                :include_depth, :declared_methods, :declared_item_methods, :method_effects, :extra_relations

    def model = source.respond_to?(:model) ? source.model : raise(NoMethodError, "#{name} has no Active Record model")

    # §4.3: the methods of the collection and of its items. GET goes with HEAD in Allow.
    def methods_list
      return @declared_methods if @declared_methods
      singleton? ? (["GET"] + (source.supports?(:update) ? ["PATCH"] : [])) : (["GET"] + (source.supports?(:create) ? ["POST"] : []))
    end

    def item_methods_list
      return @declared_item_methods if @declared_item_methods
      ["GET"] + (source.supports?(:update) ? ["PATCH"] : []) + (source.supports?(:delete) ? ["DELETE"] : [])
    end

    def declared_methods? = !@declared_methods.nil?

    def self.allow(methods) = methods.flat_map { |m| m == "GET" ? %w[GET HEAD] : [m] }

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
        next if ops.nil? # filled in from a hand-written discovery document
        bad.(name, "operators come from #{OPS.join(", ")}") unless (ops - OPS).empty?
        bad.(name, "a boolean filter declares only eq, ne and null") if d["type"] == "boolean" && !(ops - %w[eq ne null]).empty?
        bad.(name, "the id filter declares no order operators") if id_filter?(name, d) && !(ops & %w[lt le gt ge]).empty?
        if !(ops & %w[prefix contains]).empty? && (d["type"] != "string" || id_filter?(name, d))
          bad.(name, "prefix and contains only on string fields, never on an id")
        end
        bad.(name, "shares its name with a named filter") if named_filters.key?(name)
        bad.(name, "a language map is filtered by translation, as #{name}.tag (6.1)") if fields[name]&.type == "language_map"
        base, tag = name.split(".", 2)
        if fields[base]&.type == "language_map"
          bad.(name, "#{tag.inspect} is not a lowercase language tag") unless Language.tag?(tag)
          bad.(name, "a translation is of type string") unless d["type"] == "string"
        end
      end
      named_filters.each do |name, d|
        bad.(name, "only a switch, a named filter without type, can be a default filter") if d["default"] && d["type"]
      end
    end

    def id_filter?(name, d) = d[:id_like] || name == "id" || name.end_with?(".id")

    def check_fields!
      fields.each_value do |f|
        if f.type == "language_map"
          raise ArgumentError, "#{name}: #{f.name}: a singleton has no language maps in this version (5.9)" if singleton?
          if f.languages && !f.languages.all? { |t| Language.tag?(t) }
            raise ArgumentError, "#{name}: #{f.name}: languages must be lowercase language tags (3)"
          end
        end
        raise ArgumentError, "#{name}: #{f.name}: include is for relation fields (9)" if !f.include.nil? && f.type != "relation"
        raise ArgumentError, "#{name}: #{f.name}: schema is for object and array fields (4.3)" if f.schema && !JSON_TYPES.include?(f.type)
        raise ArgumentError, "#{name}: #{f.name}: validate takes ->(value, pointer) { [errors] or nil }" if f.validate && !f.validate.respond_to?(:call)
      end
      # §4.2 and §6.1: an object or array has no type of the discovery list, so it is filtered and
      # sorted by a dotted path to a scalar inside it (address.city), never whole.
      (filters.keys + sort.keys).each do |k|
        if JSON_TYPES.include?(fields[k]&.type)
          raise ArgumentError, "#{name}: #{k} is of type #{fields[k].type}: filter or sort by a member, such as #{k}.name, with its own sql: or value: (6.1)"
        end
      end
    end

    # Fields whose value is any JSON object or array (a document the item carries): their shape
    # goes in the schemas (§4.3), never in the types of discovery (§4.2).
    JSON_TYPES = %w[object array].freeze

    # ---- Paths ----------------------------------------------------------------------------------

    # The collection that holds this one's parent items (a singleton's parent may be a singleton).
    def parent_resource
      return nil unless parent
      Restep.collections[parent] || Restep.singletons[parent] or raise ConfigurationError, "#{name}: parent #{parent} is not in the catalog"
    end

    # The collections whose item ids fill this path's variables, outermost first.
    def ancestors
      out = []
      r = parent_resource
      while r
        out.unshift(r) unless r.singleton?
        r = r.parent_resource
      end
      out
    end

    def ids_of(parents) = parents.is_a?(Parents) ? parents.ids : Array(parents)

    # Paths relative to the API root (discovery) and absolute ones (links and headers). parents:
    # the Parents of the request, or the parent ids in order.
    def path_for(parents = Parents::NONE) = template.expand(ids_of(parents))
    def item_path(id, parents = Parents::NONE) = singleton? ? path_for(parents) : "#{path_for(parents)}/#{id}"
    def url(parents = Parents::NONE) = Restep.url(path_for(parents))
    def item_url(id, parents = Parents::NONE) = Restep.url(item_path(id, parents))

    def singleton? = @singleton

    def find_singleton(parents = Parents::NONE) = source.find_singleton(parents)

    # The 409 that matches a store error on write (§5.4).
    def conflict(kind, rec)
      hook = @conflicts[kind]
      hook ? hook.call(rec) : Problem.new(409, "conflict", detail: "The write conflicts with the current state of #{name}.")
    end

    # §3: an id is a non-empty string of unreserved characters, never "." or "..". Anything else
    # names no item.
    ID = /\A[A-Za-z0-9\-._~]+\z/

    def self.id?(text) = text.is_a?(String) && ID.match?(text) && text != "." && text != ".."

    def find(id_text, parents = Parents::NONE)
      return nil unless Collection.id?(id_text)
      source.find(id_text, parents)
    end

    def id_of(rec) = source.id(rec)

    # ---- Relations (§9) -------------------------------------------------------------------------

    def relation_fields = fields.values.select { |f| f.type == "relation" }

    # The relationships discovery declares: every relation field once the API declares relations
    # (Restep::Relations.declared?), plus those declared only in discovery.
    def relations
      return {} unless Relations.declared?
      out = relation_fields.to_h do |f|
        d = { "to" => f.relation }
        d["include"] = true if f.include
        d["description"] = f.description if f.description
        [f.name, d]
      end
      out.merge(extra_relations)
    end

    def includable?(name) = relation_fields.any? { |f| f.name == name && f.include }

    def language_map_fields = fields.values.select { |f| f.type == "language_map" }

    # The relationship object of a to-one field (§3): id, and href, which a subcollection's item
    # needs, since its path cannot be built from the id alone.
    def relation_object(f, v)
      return nil if v.nil?
      target = Restep.collections.fetch(f.relation)
      { "id" => v.to_s, "href" => target.href_for(v.to_s) }.compact
    end

    # The path of an item of this collection from its id alone; nil if a subcollection's item can
    # no longer be found.
    def href_for(id)
      return item_url(id) if template.vars.empty?
      rec = source.locate(id)
      rec && item_url(id, source.parent_ids(rec))
    end

    # ---- Reading ---------------------------------------------------------------------------

    def represent(rec, parents = Parents::NONE)
      rep = field_values(rec)
      item_actions = actions.values.select(&:item?)
      return rep if item_actions.empty?
      # §11.1: the actions its current state allows, so the client need not repeat the rules.
      href = item_url(source.id(rec), parents)
      rep.merge("_actions" => item_actions.select { |a| a.available?(rec) }.to_h { |a|
        [a.name, { "method" => a.method, "href" => "#{href}:#{a.name}" }]
      })
    end

    # The fields of the representation, without the _ members.
    def field_values(rec)
      fields.values.to_h do |f|
        v = source.value(rec, f.column)
        out =
          case f.type
          when "id" then v.to_s
          when "relation" then relation_object(f, v)
          when "decimal" then Types.render_decimal(v.is_a?(String) ? BigDecimal(v) : v, f.scale)
          when "datetime" then Types.render_datetime(v)
          when "date" then v.is_a?(String) ? v : v&.iso8601
          when "language_map" then Language.render(v)
          else v
          end
        [f.name, out]
      end
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
          elsif f.type == "language_map" then attrs[f.column] = {}
          else attrs[f.column] = nil
          end
        elsif f.type == "language_map"
          # §3: in a POST, a language map is an object of strings; null is not one.
          val = Language.validate(f, body[f.name], ptr, errors, patch: false)
          attrs[f.column] = val unless val == :error
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
      current = field_values(rec)
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
        elsif f.type == "language_map"
          # §3: merged by key, validated first (deleted keys too); left as it was, it changes nothing.
          merged = Language.merge(f, current[k] || {}, v, ptr, errors)
          changes[f.column] = merged unless merged == :error || merged == (current[k] || {})
        elsif f.type == "object" && v.is_a?(Hash)
          # §5.1: a merge patch (RFC 7396) merges an object member by member.
          val = coerce(f, MergePatch.apply(current[k], v), ptr, errors)
          changes[f.column] = val unless val == :error || Types.canonical_json(val) == Types.canonical_json(current[k])
        elsif f.type == "relation" && current_relation?(f, v, current[k])
          # Relation with its current value: ignored without checking that the target exists
          # (§5.1); only href, if present, is checked to be that item's path.
          check_href(f, v, ptr, errors)
        elsif v.nil?
          if f.nullable
            changes[f.column] = nil unless source.value(rec, f.column).nil?
          else
            errors << err(ptr, "required", "#{k} cannot be null.")
          end
        else
          val = coerce(f, v, ptr, errors)
          next if val == :error
          same = JSON_TYPES.include?(f.type) ? Types.canonical_json(val) == Types.canonical_json(current[k]) : same_value?(source.value(rec, f.column), val)
          changes[f.column] = val unless same
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
    # segment is not the id sent, gives 422 format. Returns false on that error, or the item's
    # parent ids when the href is a subcollection item's path.
    def check_href(f, v, ptr, errors)
      target = Restep.collections.fetch(f.relation)
      return [] unless v.key?("href")
      href = v["href"]
      decoded = href.is_a?(String) ? (QueryString.decode(href) rescue nil) : nil
      ids = decoded && v["id"].is_a?(String) && Resolver.item_path_ids(target, decoded, v["id"])
      return ids if ids
      errors << err("#{ptr}/href", "format", "#{f.name}.href must be the path of the item, #{Restep.url(target.path)}/{id}, with the id sent.")
      false
    end

    # §5.1: a relationship object leaves the field as it was when it names the same item: the same
    # id and, for a subcollection's item (whose id is unique only under its parent), the same href.
    def current_relation?(f, v, cur)
      return false unless v.is_a?(Hash) && cur.is_a?(Hash) && v["id"] == cur["id"]
      return true if !v.key?("href") || Restep.collections.fetch(f.relation).template.vars.empty?
      v["href"].is_a?(String) && (QueryString.decode(v["href"]) rescue nil) == cur["href"]
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

    # The value of a field in a request body, checked against its type and then against the
    # field's own validate: hook, or :error with the 422 entries added to errors.
    def coerce(f, v, ptr, errors)
      val = coerce_type(f, v, ptr, errors)
      return val if val == :error || f.validate.nil?
      found = Array(f.validate.call(val, ptr))
      return val if found.empty?
      errors.concat(found)
      :error
    end

    def coerce_type(f, v, ptr, errors)
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
      when "object"
        return fail_with.("type", "#{f.name} must be a JSON object.") unless v.is_a?(Hash)
        Types.json_value(v, ptr, errors)
      when "array"
        return fail_with.("type", "#{f.name} must be a JSON array.") unless v.is_a?(Array)
        Types.json_value(v, ptr, errors)
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
        target = Restep.collections.fetch(f.relation)
        # §5.1: to link an item of a subcollection the client sends its href, as read.
        if !target.template.vars.empty? && !v.key?("href")
          errors << err("#{ptr}/href", "required", "#{f.name}.href is required: #{f.relation} is a subcollection, so its items are linked by their path.")
          return :error
        end
        ids = check_href(f, v, ptr, errors)
        return :error unless ids
        rec = Resolver.find_under(target, id, ids)
        unless rec
          errors << err("#{ptr}/id", "unknown", "There is no #{f.relation} item with id #{id.inspect}.")
          return :error
        end
        target.source.id(rec)
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
