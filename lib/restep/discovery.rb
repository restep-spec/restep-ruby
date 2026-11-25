module Restep
  # Discovery document (§4.2) and the JSON Schemas of each collection (§4.3).
  module Discovery
    module_function

    def document
      {
        "restep" => "1.0-draft.7",
        "version" => "1",
        "profiles" => %w[core query writes cache],
        "extensions" => Restep.collections.values.any? { |c| c.actions.any? } ? ["actions"] : [],
        "idempotency" => { "ttl" => Idempotency::TTL },
        "status" => Restep.url("/status"), # a link, absolute like those in bodies (§4.2)
        "reasons" => Restep.config.reasons,
        "collections" => Restep.collections.transform_values { |c| collection(c) },
        "singletons" => Restep.singletons.transform_values { |c| singleton(c) }
      }
    end

    def collection(c)
      {
        "path" => c.path,
        "description" => c.description,
        "methods" => %w[GET POST],
        "item_methods" => %w[GET PATCH DELETE],
        "schemas" => { "item" => item_schema(c), "create" => create_schema(c), "update" => update_schema(c) },
        "filter" => c.filters.transform_values { |d| d.select { |k, _| k.is_a?(String) } },
        "named_filters" => c.named_filters.transform_values { |d| d.select { |k, _| k.is_a?(String) } },
        "sort" => c.sort.keys,
        # Declared even though it is the default value: the columns carry COLLATE "C" (§6.1).
        "collations" => collations(c),
        "max_limit" => c.max_limit,
        "count" => "exact"
      }.merge(c.actions.empty? ? {} : { "actions" => c.actions.transform_values { |a| action(a) } })
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

    def collations(c)
      names = c.filters.select { |_, d| d["type"] == "string" && !d[:id_like] }.keys
      names |= c.sort.select { |_, d| d[:type] == "string" }.keys
      names.to_h { |n| [n, "codepoint"] }
    end

    def singleton(c)
      d = { "path" => c.path, "description" => c.description, "methods" => %w[GET PATCH],
            "schemas" => { "item" => item_schema(c), "update" => update_schema(c) } }
      # §5.9 (draft 7): the effects of its PATCH, where the domain declares them.
      c.method_effects ? d.merge("method_effects" => c.method_effects) : d
    end

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
          { "type" => "object", "required" => ["id"],
            "properties" => { "id" => { "type" => "string" }, "href" => { "type" => "string" } } }
        end
      s = { "type" => [s["type"], "null"] }.merge(s.except("type")) if f.nullable
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
