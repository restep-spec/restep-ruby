module Restep
  # The rules of draft 7 that a discovery document must follow beyond its JSON Schema (§3, §4.2,
  # §5.9, §6.1, §9, §11.1), and the binding of the catalog to a hand-written document.
  #
  #   Restep::Rules.problems(doc)        # => ["drafts: ...", ...], empty when it follows them
  #   Restep::Rules.schema_problems(doc) # the same against public/1/schema/discovery.json (json_schemer)
  module Rules
    NAME = /\A[A-Za-z][A-Za-z0-9_-]{0,63}\z/
    OPS = Collection::OPS
    ORDER_OPS = %w[lt le gt ge].freeze
    SCHEMA_PATH = File.expand_path("schema/discovery.json", __dir__)

    module_function

    def name?(s) = s.is_a?(String) && NAME.match?(s)

    # A dotted path: names joined by ".", whose last segment may be a language tag (§3).
    def path?(s)
      return false unless s.is_a?(String)
      segs = s.split(".", -1)
      segs[0..-2].all? { |x| name?(x) } && (name?(segs[-1]) || (segs.size > 1 && Language.tag?(segs[-1])))
    end

    def obj(x) = x.is_a?(Hash) ? x : {}

    # ---- The rules ----------------------------------------------------------------------------

    def problems(doc)
      out = []
      colls = obj(doc["collections"])
      singles = obj(doc["singletons"])
      colls.each_key { |k| out << "collection #{k}: not a name (3)" unless name?(k) }
      singles.each_key { |k| out << "singleton #{k}: not a name (3)" unless name?(k) }
      obj(doc["reasons"]).each_key { |k| out << "reason #{k}: not a name (3)" unless name?(k) }
      colls.each { |k, c| out.concat(collection_problems(k, obj(c), colls)) }
      singles.each { |k, s| out.concat(singleton_problems(k, obj(s), colls, singles)) }
      out
    end

    def collection_problems(k, c, colls)
      out = []
      bad = ->(why) { out << "collection #{k}: #{why}" }
      path = c["path"]
      if path.is_a?(String)
        t = (Template.new(path) rescue nil)
        if t.nil? then bad.("path #{path.inspect} is not an absolute path or a level-1 template (4.2)")
        else
          t.problems.each { |p| bad.("#{p} (4.2)") }
          if t.template?
            parent = c["parent"].is_a?(String) ? colls[c["parent"]] : nil
            if parent.nil? then bad.("a path template needs parent, a declared collection (4.2)")
            elsif !subpath?(path, parent["path"], t.vars.last)
              bad.("path #{path} must be its parent's path #{parent["path"]}, /{#{t.vars.last}}/ and literal segments (4.2)")
            end
          elsif c.key?("parent")
            bad.("parent goes only with a path template (4.2)")
          end
        end
      end
      filters = obj(c["filter"])
      named = obj(c["named_filters"])
      rels = obj(c["relations"])
      maps = obj(c["language_maps"])
      filters.each do |name, d|
        d = obj(d)
        ops = Array(d["ops"])
        fb = ->(why) { bad.("filter #{name}: #{why} (6.1)") }
        fb.("not a name or a dotted path") unless path?(name)
        fb.("operators come from #{OPS.join(", ")}") unless (ops - OPS).empty?
        fb.("a boolean filter declares only eq, ne and null") if d["type"] == "boolean" && !(ops - %w[eq ne null]).empty?
        id = name == "id" || name.end_with?(".id")
        fb.("the id filter declares no order operators") if id && !(ops & ORDER_OPS).empty?
        fb.("prefix and contains only on string fields, never on an id") if !(ops & %w[prefix contains]).empty? && (d["type"] != "string" || id)
        fb.("shares its name with a named filter") if named.key?(name)
        fb.("a language map is filtered by translation, as #{name}.tag") if maps.key?(name)
        base = name.split(".").first
        fb.("goes through the language map #{base}, filtered only as #{base}.tag") if maps.key?(base) && name.count(".") > 1
        if name.end_with?(".id") && (r = obj(rels[name.delete_suffix(".id")])) && Array(r["to"]).any? { |t| subcollection?(colls[t]) }
          fb.("ends in the id of a subcollection's item, which identifies it only under its parent")
        end
        fb.("quantifier is not implemented by this server") if d.key?("quantifier")
      end
      named.each do |name, d|
        bad.("named filter #{name}: not a name (3)") unless name?(name)
        bad.("named filter #{name}: only a switch can be a default filter (6.1)") if obj(d)["default"] && obj(d)["type"]
      end
      Array(c["sort"]).each do |s|
        bad.("sort key #{s}: not a name or a dotted path (6.2)") unless path?(s)
        bad.("sort key #{s}: a language map is sorted by translation (6.1)") if maps.key?(s)
      end
      methods = c["methods"]
      if methods.is_a?(Array) && !methods.include?("GET")
        %w[filter named_filters sort count sync].each { |m| bad.("#{m}: a collection without GET cannot be listed (4.3)") if c.key?(m) }
      end
      rels.each do |r, d|
        d = obj(d)
        bad.("relation #{r}: not a name (3)") unless name?(r)
        to = Array(d["to"])
        bad.("relation #{r}: to must name declared collections (9)") if to.empty? || to.any? { |t| !colls.key?(t) }
        if d.key?("path") && to.size == 1 && colls[to[0]] && d["path"] != obj(colls[to[0]])["path"]
          bad.("relation #{r}: its path must be its target's path #{obj(colls[to[0]])["path"]} (9)")
        end
      end
      maps.each_key do |m|
        bad.("language map #{m}: only top-level fields are language maps (3)") unless name?(m)
        bad.("language map #{m}: shares its name with a relation (6.1)") if rels.key?(m)
      end
      obj(c["collations"]).each do |n, v|
        bad.("collation #{n}: id has the server's order (6.1)") if n == "id"
        string_filter = obj(filters[n])["type"] == "string"
        translation = n.include?(".") && maps.key?(n.split(".").first)
        bad.("collation #{n}: not a string filter, a sort key or a translation (6.1)") unless string_filter || Array(c["sort"]).include?(n) || translation
        bad.("collation #{n}: its value is a string (6.1)") unless v.is_a?(String)
      end
      bad.("include_depth must be an integer of at least 1 (9)") if c.key?("include_depth") && !(c["include_depth"].is_a?(Integer) && c["include_depth"] >= 1)
      obj(c["actions"]).each do |a, d|
        d = obj(d)
        ab = ->(why) { bad.("action #{a}: #{why} (11.1)") }
        ab.("not a name") unless name?(a)
        effects = d["effects"]
        ab.("effects come from #{Fields::EFFECTS.join(", ")}") if effects && !(effects.is_a?(Array) && (effects - Fields::EFFECTS).empty?)
        ab.("a safe action declares only charges") if d["safe"] && effects.is_a?(Array) && !(effects - ["charges"]).empty?
        ab.("only a safe action uses GET") if d["method"] == "GET" && !d["safe"]
        ab.("output is only for a safe action") if d.key?("output") && !d["safe"]
      end
      %w[method_effects item_method_effects].each do |m|
        list = m == "method_effects" ? c["methods"] : c["item_methods"]
        obj(c[m]).each do |meth, e|
          bad.("#{m}.#{meth}: not a method it declares (4.3)") if list.is_a?(Array) && !list.include?(meth)
          bad.("#{m}.#{meth}: effects come from #{Fields::EFFECTS.join(", ")} (4.3)") unless e.is_a?(Array) && (e - Fields::EFFECTS).empty?
        end
      end
      out
    end

    def singleton_problems(k, s, colls, singles)
      out = []
      bad = ->(why) { out << "singleton #{k}: #{why}" }
      path = s["path"]
      return out unless path.is_a?(String)
      t = (Template.new(path) rescue nil) or return out << "singleton #{k}: path #{path.inspect} is not an absolute path or a level-1 template (5.9)"
      t.problems.each { |p| bad.("#{p} (5.9)") }
      parent_name = s["parent"]
      if parent_name.nil?
        bad.("a path template needs parent (5.9)") if t.template?
        colls.each do |ck, c|
          cp = obj(c)["path"]
          next unless cp.is_a?(String) && !cp.include?("{")
          if path == cp || (path.start_with?("#{cp}/") && path.delete_prefix("#{cp}/").count("/").zero?)
            bad.("path #{path} is one that #{ck} or its items have or could have (5.9)")
          end
        end
      elsif (pc = colls[parent_name])
        bad.("path #{path} must be its parent's item path #{pc["path"]}/{var} and literal segments (5.9)") unless t.template? && subpath?(path, pc["path"], t.vars.last)
      elsif (ps = singles[parent_name])
        pp = obj(ps)["path"].to_s
        bad.("path #{path} must be its parent's path #{pp} and literal segments (5.9)") unless path.start_with?("#{pp}/") && !path.delete_prefix("#{pp}/").include?("{")
      else
        bad.("parent #{parent_name} names no collection or singleton (5.9)")
      end
      methods = s["methods"]
      bad.("methods come from GET and PATCH (5.9)") if methods.is_a?(Array) && !(methods - %w[GET PATCH]).empty?
      out
    end

    # path is parent_path, /{var}/ and one or more literal segments.
    def subpath?(path, parent_path, var)
      return false unless parent_path.is_a?(String)
      rest = path.delete_prefix("#{parent_path}/{#{var}}/")
      rest != path && !rest.empty? && rest.split("/", -1).none? { |x| x.empty? || x.include?("{") }
    end

    def subcollection?(c) = c.is_a?(Hash) && c["path"].to_s.include?("{")

    # ---- JSON Schema --------------------------------------------------------------------------

    # Validates against the schema of discovery.json. Needs the json_schemer gem.
    def schema_problems(doc)
      begin
        require "json_schemer"
      rescue LoadError
        raise ConfigurationError, "validating a discovery document needs the json_schemer gem: add it to the Gemfile"
      end
      @schemer ||= JSONSchemer.schema(JSON.parse(File.read(SCHEMA_PATH)))
      @schemer.validate(doc).first(20).map { |e| "#{e["data_pointer"].empty? ? "/" : e["data_pointer"]}: #{e["error"]}" }
    end

    # ---- Binding the catalog to a hand-written document ---------------------------------------

    PROFILES = %w[core query writes cache relations].freeze
    EXTENSIONS = %w[actions].freeze
    UNSUPPORTED = %w[id_from reusable_ids upsert upload localized local_times inherit inherit_items sync deprecations].freeze

    # Fills each collection and singleton with what the document declares and returns what the
    # code contradicts or the gem cannot serve.
    def bind(doc)
      out = []
      out << "restep is #{doc["restep"].inspect}: this gem implements #{DRAFT}" unless doc["restep"] == DRAFT
      (Array(doc["profiles"]) - PROFILES).each { |p| out << "profile #{p} is not implemented by this gem" }
      (Array(doc["extensions"]) - EXTENSIONS).each { |e| out << "extension #{e} is not implemented by this gem" }
      %w[batch events].each { |m| out << "#{m} is not implemented by this gem" if doc.key?(m) }
      ttl = doc.dig("idempotency", "ttl")
      out << "idempotency.ttl must be at least #{Idempotency::TTL} seconds (7.1)" if ttl && !(ttl.is_a?(Integer) && ttl >= Idempotency::TTL)
      anonymous = doc.dig("idempotency", "anonymous")
      out << "idempotency.anonymous is #{anonymous.inspect} but config.idempotency_anonymous is #{Restep.config.idempotency_anonymous.inspect}" if
        !anonymous.nil? && anonymous != Restep.config.idempotency_anonymous
      out << "status is #{doc["status"]}, but this gem serves #{Restep.url("/status")}" if doc.key?("status") && doc["status"] != Restep.url("/status")
      if doc.key?("reasons")
        if Restep.config.reasons.empty? then Restep.config.reasons = doc["reasons"]
        elsif Restep.config.reasons != doc["reasons"] then out << "reasons differ from config.reasons"
        end
      end
      %w[collections singletons].each do |kind|
        declared = obj(doc[kind])
        code = kind == "collections" ? Restep.collections : Restep.singletons
        (declared.keys - code.keys).each { |k| out << "#{kind}: #{k} is declared but the catalog has no #{k}" }
        (code.keys - declared.keys).each { |k| out << "#{kind}: #{k} is in the catalog but discovery does not declare it" }
        (declared.keys & code.keys).each { |k| out.concat(bind_resource(code[k], obj(declared[k]), doc)) }
      end
      out
    end

    def bind_resource(c, d, doc)
      out = []
      bad = ->(why) { out << "#{c.name}: #{why}" }
      fill = lambda do |attr, value|
        current = c.public_send(attr)
        if current.nil? then c.public_send("#{attr}=", value)
        elsif current != value then bad.("#{attr} is #{current.inspect} in code and #{value.inspect} in discovery")
        end
      end
      fill.(:path, d["path"]) if d["path"]
      fill.(:parent, d["parent"]) if d["parent"]
      fill.(:description, d["description"]) if d["description"]
      (UNSUPPORTED & d.keys).each { |m| bad.("#{m} is not implemented by this gem") }
      if d["methods"]
        bad.("methods are #{c.methods_list.inspect} in code and #{d["methods"].inspect} in discovery") if c.declared_methods? && c.methods_list != d["methods"]
        c.declared_methods = d["methods"]
      end
      c.declared_item_methods = d["item_methods"] if d["item_methods"]
      { "POST" => :create, "PATCH" => :update, "DELETE" => :delete }.each do |m, op|
        if (c.methods_list + (c.singleton? ? [] : c.item_methods_list)).include?(m) && !c.source.supports?(op)
          bad.("discovery declares #{m}, but its source does not implement #{op}")
        end
      end
      if c.singleton?
        c.method_effects = d["method_effects"] if d["method_effects"]
        return out
      end
      bind_filters(c, d, bad)
      fill.(:max_limit, d["max_limit"]) if d["max_limit"]
      bad.("default_limit #{c.default_limit} is over max_limit #{c.max_limit}") if c.default_limit && c.max_limit && c.default_limit > c.max_limit
      c.count = d["count"]
      c.include_depth = d["include_depth"]
      bind_actions(c, obj(d["actions"]), bad)
      bind_relations(c, obj(d["relations"]), Array(doc["profiles"]).include?("relations"), bad)
      maps = obj(d["language_maps"]).keys.sort
      code_maps = c.language_map_fields.map(&:name).sort
      bad.("language_maps are #{maps.inspect} in discovery and #{code_maps.inspect} in code") unless maps == code_maps
      bind_schemas(c, obj(d["schemas"]), bad)
      out
    end

    # Discovery's declarations of filters, named filters and sort keys, with the code's
    # implementation (the symbol keys: sql:, match:, value:, type:) on top.
    def bind_filters(c, d, bad)
      merge = lambda do |label, declared, code|
        (code.keys - declared.keys).each { |k| bad.("#{label} #{k} is in code but discovery does not declare it") }
        declared.to_h do |k, decl|
          impl = code[k] || {}
          impl.each { |ik, iv| bad.("#{label} #{k}: #{ik} is #{iv.inspect} in code and #{decl[ik].inspect} in discovery") if ik.is_a?(String) && decl[ik] != iv }
          [k, decl.merge(impl.reject { |ik, _| ik.is_a?(String) })]
        end
      end
      c.filters = merge.("filter", obj(d["filter"]).transform_values { |x| obj(x) }, c.filters)
      c.named_filters = merge.("named filter", obj(d["named_filters"]).transform_values { |x| obj(x) }, c.named_filters)
      sort = Array(d["sort"])
      (c.sort.keys - sort).each { |k| bad.("sort key #{k} is in code but discovery does not declare it") }
      c.sort = sort.to_h { |k| [k, c.sort[k] || {}] }
    end

    def bind_actions(c, declared, bad)
      (declared.keys - c.actions.keys).each { |a| bad.("action #{a} is declared but the code does not implement it") }
      (c.actions.keys - declared.keys).each { |a| bad.("action #{a} is in code but discovery does not declare it") }
      (declared.keys & c.actions.keys).each do |name|
        a, d = c.actions[name], obj(declared[name])
        bad.("action #{name}: params are not implemented by this gem") if d.key?("params")
        { "on" => a.on, "safe" => a.safe, "idempotent" => a.idempotent, "method" => a.method }.each do |k, v|
          dv = k == "method" ? d.fetch("method", "POST") : d[k]
          bad.("action #{name}: #{k} is #{v.inspect} in code and #{dv.inspect} in discovery") unless dv == v
        end
        a.effects = d["effects"] if d.key?("effects") && a.effects.nil?
        a.output = d["output"] if d.key?("output") && a.output.nil?
        bad.("action #{name}: effects differ from discovery") if d.key?("effects") && a.effects != d["effects"]
      end
    end

    def bind_relations(c, declared, profile, bad)
      fields = c.relation_fields
      fields.each do |f|
        r = declared[f.name]
        if r.nil?
          bad.("relation field #{f.name} is not declared in relations (9)") if profile
          next
        end
        bad.("relation #{f.name}: to is #{r["to"].inspect} in discovery and #{f.relation.inspect} in code") unless r["to"] == f.relation
        f.include = r["include"] == true
      end
      extra = declared.reject { |k, _| fields.any? { |f| f.name == k } }
      extra.each { |k, r| bad.("relation #{k}: only relationships to a subcollection, with path, can be declared without a field") unless r["path"] }
      c.extra_relations = extra
    end

    # Inline schemas must describe the fields the code validates.
    def bind_schemas(c, schemas, bad)
      fields = c.fields.values
      writable = fields.reject(&:read_only).map(&:name).sort
      { "item" => fields.map(&:name).sort, "create" => writable, "update" => writable }.each do |kind, names|
        s = schemas[kind]
        next unless s.is_a?(Hash) && s["properties"].is_a?(Hash)
        declared = s["properties"].keys.sort
        bad.("schemas.#{kind} has properties #{declared.inspect}, the code's fields are #{names.inspect}") unless declared == names
      end
    end
  end
end
