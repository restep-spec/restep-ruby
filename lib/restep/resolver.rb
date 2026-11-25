module Restep
  # Step 1 of §5.4: which resource the path names, before looking at the method (a PUT to an
  # item that does not exist is 404, not 405). Returns [kind, collection, item, action] or raises 404.
  # An action (§11.1) goes after a colon, which may also arrive as %3A:
  # /stations/7:deactivate on an item, /readings:summary on the collection.
  module Resolver
    ALLOW = { root: %w[GET HEAD], collection: %w[GET HEAD POST], item: %w[GET HEAD PATCH DELETE],
              singleton: %w[GET HEAD PATCH], status: %w[GET HEAD], docs: %w[GET HEAD] }.freeze
    NOT_FOUND = "Nothing here. The API root lists the collections.".freeze

    module_function

    # path: the whole request path; outside the API root (config.root_path) it is 404.
    # method and idempotency_key (the header as it arrives) only matter on an item action
    # (action_target!).
    def resolve(path, method: nil, idempotency_key: nil)
      root = Restep.config.root_path
      unless root.empty?
        raise Problem.new(404, "not_found", detail: NOT_FOUND) unless path == root || path.start_with?("#{root}/")
        path = path.delete_prefix(root)
        path = "/" if path.empty?
      end
      return [:root, nil, nil, nil] if path == "/"
      return [:status, nil, nil, nil] if path == "/status"
      return [:docs, nil, nil, nil] if path == "/docs"
      if (single = Restep.singleton_by_path(path))
        return [:singleton, single, find_singleton!(single), nil]
      end
      segs = path.split("/", -1)
      raise Problem.new(404, "not_found", detail: NOT_FOUND) unless segs.size.between?(2, 3) && segs[0].empty?
      last = (QueryString.decode(segs[-1]) rescue nil) or raise Problem.new(404, "not_found", detail: NOT_FOUND)
      head, colon, name = last.rpartition(":")
      if segs.size == 2
        coll = Restep.collection_by_path("/#{colon.empty? ? last : head}")
        raise Problem.new(404, "not_found", detail: NOT_FOUND) unless coll
        return [:collection, coll, nil, nil] if colon.empty?
        return [:collection_action, coll, nil, declared!(coll, name, "collection")]
      end
      coll = Restep.collection_by_path("/#{segs[1]}")
      raise Problem.new(404, "not_found", detail: NOT_FOUND) unless coll
      return [:item, coll, find!(coll, last), nil] if colon.empty?
      action = declared!(coll, name, "item")
      [:item_action, coll, action_target!(coll, head, action, method, idempotency_key), action]
    end

    # The item of an action. §5.4, rule 3, and §7.1: in a POST action that is not idempotent and
    # carries Idempotency-Key, the item no longer existing does not give 404 yet, because a replay
    # takes its place (whether the first request or another one deleted it). It then returns a
    # Missing with its id; Operations.action looks for the stored response first and, if there is
    # none, gives the 404 when it goes to read the item (current! and lock!).
    Missing = Struct.new(:id)

    def action_target!(coll, id, action, method, idempotency_key)
      rec = id && coll.find(id)
      return rec if rec
      return Missing.new(id) if id && method == "POST" && action.method == "POST" && !action.idempotent && !idempotency_key.nil?
      find!(coll, id)
    end

    # §11.1: an action that is not declared, or declared on the other kind of resource, gives 404.
    def declared!(coll, name, on)
      action = coll.actions[name]
      return action if action && action.on == on
      raise Problem.new(404, "not_found", detail: "#{coll.name} has no #{on} action named #{name.inspect}.")
    end

    def find!(coll, id)
      rec = id && coll.find(id)
      rec or raise Problem.new(404, "not_found", detail: "There is no #{coll.name} item with id #{id.inspect}.")
    end

    def find_singleton!(single)
      single.find_singleton or raise Problem.new(404, "not_found", detail: "The #{single.name} singleton is not set up.")
    end

    def allowed(kind, action = nil) = action ? action.allowed_methods : ALLOW.fetch(kind)

    # Step 2 of §5.4.
    def method_not_allowed(kind, path, action = nil)
      allow = allowed(kind, action).join(", ")
      Problem.new(405, "method_not_allowed", detail: "#{path} supports #{allow}.", headers: { "allow" => allow })
    end
  end
end
