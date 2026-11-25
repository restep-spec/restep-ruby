module Restep
  # Discovery document (§4.2) and the JSON Schemas of each collection (§4.3). The gem writes it
  # from the catalog, unless the application gives its own (Restep.config.discovery): then that
  # document is the contract, served as written, and Restep.check! validates it and binds the
  # catalog to it (Restep::Rules).
  module Discovery
    module_function

    # The hand-written document, parsed, or nil.
    def handwritten
      src = Restep.config.discovery
      return nil if src.nil?
      return @handwritten if @handwritten_src.equal?(src)
      @handwritten_src = src
      @handwritten = src.is_a?(Hash) ? JSON.parse(JSON.generate(src)) : JSON.parse(File.read(src.to_s))
    end

    # The body served at the API root.
    def body
      doc = handwritten or return JSON.generate(generate)
      return @body if @body_for.equal?(doc)
      @body_for = doc
      @body = JSON.generate(doc)
    end

    def document
      handwritten || generate
    end

    def generate
      colls = Restep.collections
      profiles = %w[core query writes cache]
      profiles << "relations" if Relations.declared?
      d = {
        "restep" => DRAFT,
        "version" => "1",
        "profiles" => profiles,
        "extensions" => Restep.catalog.any? { |c| c.actions.any? } ? ["actions"] : [],
        "idempotency" => { "ttl" => Idempotency::TTL },
        "status" => Restep.url("/status"), # a link, absolute like those in bodies (§4.2)
        "reasons" => Restep.config.reasons,
        "collections" => colls.transform_values { |c| collection(c) },
        "singletons" => Restep.singletons.transform_values { |c| singleton(c) }
      }
      d["idempotency"]["anonymous"] = false if Restep.config.idempotency_anonymous == false
      d
    end

    def collection(c)
      d = { "path" => c.path }
      d["parent"] = c.parent if c.parent
      d["description"] = c.description if c.description
      d["methods"] = c.methods_list
      d["item_methods"] = c.item_methods_list
      d["schemas"] = { "item" => item_schema(c) }
      d["schemas"]["create"] = create_schema(c) if c.methods_list.include?("POST")
      d["schemas"]["update"] = update_schema(c) if c.item_methods_list.include?("PATCH")
      if c.methods_list.include?("GET")
        d["filter"] = c.filters.transform_values { |x| x.select { |k, _| k.is_a?(String) } }
        d["named_filters"] = c.named_filters.transform_values { |x| x.select { |k, _| k.is_a?(String) } }
        d["sort"] = c.sort.keys
        # Declared even though it is the default value: the columns carry COLLATE "C" (§6.1).
        d["collations"] = collations(c)
        d["max_limit"] = c.max_limit if c.max_limit
        d["count"] = c.count if c.count
      end
      rels = c.relations
      d["relations"] = rels unless rels.empty?
      d["include_depth"] = c.include_depth if c.include_depth && !rels.empty?
      maps = c.language_map_fields
      d["language_maps"] = maps.to_h { |f| [f.name, {}] } unless maps.empty?
      d.merge(c.actions.empty? ? {} : { "actions" => c.actions.transform_values { |a| action(a) } })
    end

    # §11.1: on, safe and idempotent always; method only if it is not POST; input only with POST.
    # Draft 7: effects where the domain declares them, and output for a safe action's result.
    def action(a)
      d = { "on" => a.on, "safe" => a.safe, "idempotent" => a.idempotent }
      d["method"] = a.method unless a.method == "POST"
      d["description"] = a.description if a.description
      d["effects"] = a.effects if a.effects
      d["output"] = a.output if a.output
      if a.input && a.method == "POST"
        d["input"] = { "$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
                       "properties" => a.input.to_h { |f| [f.name, property(f, :create)] },
                       "required" => a.input.select(&:required).map(&:name),
                       "additionalProperties" => false }
      end
      d
    end

    # §6.1: a string filter, a string sort key and a translation compare by code points.
    def collations(c)
      names = c.filters.select { |n, d| d["type"] == "string" && !c.id_filter?(n, d) }.keys
      names |= c.sort.select { |n, d| (d[:type] || c.fields[n]&.type) == "string" || translation?(c, n) }.keys
      names.to_h { |n| [n, "codepoint"] }
    end

    def translation?(c, name)
      base, tag = name.split(".", 2)
      tag && c.fields[base]&.type == "language_map"
    end

    def singleton(c)
      d = { "path" => c.path }
      d["parent"] = c.parent if c.parent
      d["description"] = c.description if c.description
      d["methods"] = c.methods_list
      d["schemas"] = { "item" => item_schema(c) }
      d["schemas"]["update"] = update_schema(c) if c.methods_list.include?("PATCH")
      # §5.9 (draft 7): the effects of its PATCH, where the domain declares them.
      c.method_effects ? d.merge("method_effects" => c.method_effects) : d
    end

    LANGUAGE_KEY = { "pattern" => "^[a-z0-9]+(-[a-z0-9]+)*$" }.freeze

    def property(f, mode)
      s =
        case f.type
        when "id" then { "type" => "string" }
        when "string" then { "type" => "string", "minLength" => 1 }.merge(f.max_length ? { "maxLength" => f.max_length } : {}).merge(f.pattern ? { "pattern" => f.pattern.source.sub(/\A\\A/, "^").sub(/\\z\z/, "$") } : {})
        when "enum" then { "type" => "string", "enum" => f.values }
        when "integer" then { "type" => "integer", "minimum" => f.range.min, "maximum" => f.range.max }
        when "decimal" then { "type" => "string", "pattern" => "^-?[0-9]+(\\.[0-9]{1,#{f.scale}})?$" }
        when "boolean" then { "type" => "boolean" }
        when "date" then { "type" => "string", "format" => "date" }
        when "datetime" then { "type" => "string", "format" => "date-time" }
        when "relation"
          target = Restep.collections[f.relation]
          required = target && !target.template.vars.empty? ? %w[id href] : ["id"]
          { "type" => "object", "required" => required,
            "properties" => { "id" => { "type" => "string" }, "href" => { "type" => "string" } } }
        # §4.3: the shape of a document goes in the schemas. In an update schema an object is a
        # merge patch (RFC 7396), where any member may be null or left out, so only its type is given.
        when "object" then mode == :update ? { "type" => "object" } : { "type" => "object" }.merge(f.schema || {})
        when "array" then { "type" => "array" }.merge(f.schema || {})
        when "language_map"
          # §3 and §4.3: an object of strings by lowercase tag; an update schema accepts null for
          # the field and for any well-formed key.
          if mode == :update
            { "type" => %w[object null], "propertyNames" => LANGUAGE_KEY, "additionalProperties" => { "type" => %w[string null] } }
          else
            { "type" => "object", "propertyNames" => LANGUAGE_KEY, "additionalProperties" => { "type" => "string" } }
          end
        end
      s = { "type" => [s["type"], "null"] }.merge(s.except("type")) if f.nullable && f.type != "language_map" && s["type"].is_a?(String)
      s["description"] = f.description if f.description
      s["default"] = f.default if mode == :create && !f.default.nil?
      s["readOnly"] = true if f.read_only && mode == :item
      s
    end

    def item_schema(c)
      { "$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
        "properties" => c.fields.transform_values { |f| property(f, :item) } }
    end

    def create_schema(c)
      writable = c.fields.values.reject(&:read_only)
      { "$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
        "properties" => writable.to_h { |f| [f.name, property(f, :create)] },
        "required" => writable.select(&:required).map(&:name),
        "additionalProperties" => false }
    end

    def update_schema(c)
      writable = c.fields.values.reject(&:read_only)
      { "$schema" => "https://json-schema.org/draft/2020-12/schema", "type" => "object",
        "properties" => writable.to_h { |f| [f.name, property(f, :update)] },
        "additionalProperties" => false }
    end
  end
end
