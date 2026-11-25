module Restep
  # Step 1 of §5.4: which resource the path names, before looking at the method (a PUT to an
  # item that does not exist is 404, not 405). Returns a Target or raises 404. It matches the
  # path against every path of the catalog, templates of subcollections included, and finds each
  # parent item under the one before (§4.2): a subcollection under a parent item that does not
  # exist gives 404.
  # An action (§11.1) goes after a colon, which may also arrive as %3A:
  # /stations/7:deactivate on an item, /readings:summary on the collection.
  module Resolver
    ALLOW = { root: %w[GET HEAD], status: %w[GET HEAD], docs: %w[GET HEAD] }.freeze
    # What a collection, an item and a singleton allow when the caller does not say which one.
    DEFAULT_ALLOW = { collection: %w[GET HEAD POST], item: %w[GET HEAD PATCH DELETE], singleton: %w[GET HEAD PATCH] }.freeze
    NOT_FOUND = "Nothing here. The API root lists the collections.".freeze

    # What the path names. Destructures as [kind, collection, record, action] for callers of
    # the 0.1 API.
    Target = Struct.new(:kind, :collection, :record, :action, :parents) do
      def to_ary = [kind, collection, record, action]
    end

    module_function

    def not_found(detail = NOT_FOUND) = Problem.new(404, "not_found", detail: detail)

    # path: the whole request path; outside the API root (config.root_path) it is 404.
    # method and idempotency_key (the header as it arrives) only matter on an item action
    # (action_target!).
    def resolve(path, method: nil, idempotency_key: nil)
      root = Restep.config.root_path
      unless root.empty?
        raise not_found unless path == root || path.start_with?("#{root}/")
        path = path.delete_prefix(root)
        path = "/" if path.empty?
      end
      return Target.new(:root, nil, nil, nil, Parents::NONE) if path == "/"
      return Target.new(:status, nil, nil, nil, Parents::NONE) if path == "/status"
      return Target.new(:docs, nil, nil, nil, Parents::NONE) if path == "/docs"
      segs = path.split("/", -1)
      raise not_found unless segs.size >= 2 && segs[0].empty? && segs[1..].none?(&:empty?)
      decoded = segs[1..].map { |s| (QueryString.decode(s) rescue nil) or raise not_found }
      found = match(decoded) or raise not_found
      kind, res, ids, last = found
      parents = load_parents!(res, ids)
      case kind
      when :singleton
        Target.new(:singleton, res, find_singleton!(res, parents), nil, parents)
      when :collection then Target.new(:collection, res, nil, nil, parents)
      when :collection_action then Target.new(:collection_action, res, nil, declared!(res, last, "collection"), parents)
      when :item
        head, colon, name = last.rpartition(":")
        return Target.new(:item, res, find!(res, last, parents), nil, parents) if colon.empty?
        action = declared!(res, name, "item")
        Target.new(:item_action, res, action_target!(res, head, action, method, idempotency_key, parents), action, parents)
      end
    end

    # The resource of the catalog the decoded segments name: [kind, resource, parent ids, last
    # segment or action name]. Where two paths could match (a literal and a variable), the one
    # with more literal segments wins; §5.9 forbids the clashes that would remain.
    def match(decoded)
      best = nil
      consider = ->(cand, literals) { best = [cand, literals] if best.nil? || literals > best[1] }
      Restep.catalog.each do |res|
        t = res.template or next
        n = t.size
        if decoded.size == n
          if res.singleton?
            (ids = t.match(decoded)) and consider.([:singleton, res, ids, nil], t.literal_count)
          else
            last = decoded[-1]
            if (ids = t.match(decoded))
              consider.([:collection, res, ids, nil], t.literal_count)
            elsif (i = last.index(":")) && (ids = t.match(decoded[0..-2] + [last[0...i]]))
              consider.([:collection_action, res, ids, last[(i + 1)..]], t.literal_count)
            end
          end
        elsif decoded.size == n + 1 && !res.singleton? && (ids = t.match(decoded[0..-2]))
          consider.([:item, res, ids, decoded[-1]], t.literal_count)
        end
      end
      best&.first
    end

    # Finds each parent item under the one before. Returns the Parents, or nil if one of them
    # does not exist (or its id is not one: §3).
    def load_parents(res, ids)
      vars = res.template.vars
      parents = Parents::NONE
      res.ancestors.each_with_index do |coll, i|
        rec = coll.find(ids[i], parents) or return nil
        parents = parents.push(vars[i], coll, rec)
      end
      parents
    end

    # load_parents, or the 404 that names the first parent item that does not exist.
    def load_parents!(res, ids)
      vars = res.template.vars
      parents = Parents::NONE
      res.ancestors.each_with_index do |coll, i|
        rec = coll.find(ids[i], parents) or raise not_found("There is no #{coll.name} item with id #{ids[i].inspect}#{" here" if i.positive?}.")
        parents = parents.push(vars[i], coll, rec)
      end
      parents
    end

    # The parent ids of an item path of a collection (decoded, without the API root), if it is
    # one and its last segment is id; nil otherwise. For an href (§5.1).
    def item_path_ids(coll, path, id)
      root = Restep.config.root_path
      return nil unless root.empty? || path.start_with?("#{root}/")
      segs = path.delete_prefix(root).split("/", -1)
      return nil unless segs.size >= 2 && segs[0].empty? && segs[-1] == id
      coll.template.match(segs[1..-2])
    end

    # The item with that id under the parents those ids name, or nil.
    def find_under(coll, id, parent_ids)
      parents = load_parents(coll, parent_ids) or return nil
      coll.find(id, parents)
    end

    # The item of an action. §5.4, rule 3, and §7.1: in a POST action that is not idempotent and
    # carries Idempotency-Key, the item no longer existing does not give 404 yet, because a replay
    # takes its place (whether the first request or another one deleted it). It then returns a
    # Missing with its id; Operations.action looks for the stored response first and, if there is
    # none, gives the 404 when it goes to read the item (current! and lock!).
    Missing = Struct.new(:id)

    def action_target!(coll, id, action, method, idempotency_key, parents = Parents::NONE)
      rec = id && coll.find(id, parents)
      return rec if rec
      return Missing.new(id) if id && method == "POST" && action.method == "POST" && !action.idempotent && !idempotency_key.nil?
      find!(coll, id, parents)
    end

    # §11.1: an action that is not declared, or declared on the other kind of resource, gives 404.
    def declared!(coll, name, on)
      action = coll.actions[name]
      return action if action && action.on == on
      raise not_found("#{coll.name} has no #{on} action named #{name.inspect}.")
    end

    def find!(coll, id, parents = Parents::NONE)
      rec = id && coll.find(id, parents)
      rec or raise not_found("There is no #{coll.name} item with id #{id.inspect}.")
    end

    def find_singleton!(single, parents = Parents::NONE)
      single.find_singleton(parents) or raise not_found("The #{single.name} singleton is not set up.")
    end

    # The methods a resource allows (§4.3): GET goes with HEAD.
    def allowed(kind, action = nil, collection = nil)
      return action.allowed_methods if action
      return DEFAULT_ALLOW.fetch(kind) if collection.nil? && DEFAULT_ALLOW.key?(kind)
      case kind
      when :collection, :singleton then Collection.allow(collection.methods_list)
      when :item then Collection.allow(collection.item_methods_list)
      else ALLOW.fetch(kind)
      end
    end

    # Step 2 of §5.4.
    def method_not_allowed(kind, path, action = nil, collection = nil)
      allow = allowed(kind, action, collection).join(", ")
      Problem.new(405, "method_not_allowed", detail: "#{path} supports #{allow}.", headers: { "allow" => allow })
    end
  end
end
