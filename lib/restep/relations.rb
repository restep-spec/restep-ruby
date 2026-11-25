module Restep
  # The relations profile (§9): declarations in discovery and include. A relation field (type
  # "relation") is a to-one relationship whose object carries id and, when its target is a
  # subcollection, href (§3). The API declares its relationships, and announces the profile, once
  # some relation field says whether it can be included (include: true or false) or some
  # collection declares relations: then every relation field is declared.
  module Relations
    module_function

    def declared?
      doc = Discovery.handwritten
      return doc["profiles"].to_a.include?("relations") if doc
      Restep.collections.values.any? { |c| !c.extra_relations.empty? || c.relation_fields.any? { |f| !f.include.nil? } }
    end

    # Fills the included relationships of a representation (include=author,author.publisher):
    # each object becomes the related item's representation, with its _etag; one the principal
    # cannot see (the source does not find it) stays with id and href. Returns the
    # representation and the paths of the included items (for Cache-Groups, §8).
    def expand(coll, rep, includes)
      return [rep, []] if includes.empty?
      groups = []
      [fill(coll, rep, includes, "", groups), groups]
    end

    def fill(coll, rep, includes, prefix, groups)
      out = rep.dup
      coll.relation_fields.each do |f|
        path = "#{prefix}#{f.name}"
        next unless includes.include?(path)
        obj = rep[f.name]
        next unless obj.is_a?(Hash) && obj["id"]
        target = Restep.collections.fetch(f.relation)
        rec, parents = related(target, obj)
        next unless rec
        full = target.with_etag(target.represent(rec, parents))
        groups << target.item_url(obj["id"], parents)
        out[f.name] = obj.merge(fill(target, full, includes, "#{path}.", groups))
      end
      out
    end

    # The related item and its parents, from the object's href where the target is a
    # subcollection.
    def related(target, obj)
      if target.template.vars.empty?
        rec = target.find(obj["id"])
        return [rec, Parents::NONE]
      end
      ids = obj["href"] && Resolver.item_path_ids(target, obj["href"], obj["id"])
      parents = ids && Resolver.load_parents(target, ids)
      parents ? [target.find(obj["id"], parents), parents] : [nil, nil]
    end
  end
end
