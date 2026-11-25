module Restep
  # What each operation does once steps 1 to 4 of §5.4 are done (Resolver and Context):
  # preconditions (412), validation (422) and conflicts (409), and the response. Each method
  # returns [status, headers, body] with the body as a string or nil; whoever writes it
  # (Restep::RackApp or a Rails controller) drops the body on a HEAD. The data goes through the
  # collection's source (Restep::Source).
  module Operations
    module_function

    # ---- Reads --------------------------------------------------------------------------

    # §4.2 (draft 6): the same for everyone, no credentials, so it can be public with max-age.
    def discovery(ctx)
      status, headers, body = read_response(ctx, Discovery.body, groups: [], cache_control: "public, max-age=60")
      if Restep.config.docs_path
        headers["link"] = %(<#{Restep.url("/docs")}>; rel="service-doc"; hreflang="#{Restep.config.docs_language}")
      end
      [status, headers, body]
    end

    # The first page of a collection, or the one a cursor names, as a JSON object (§5.2), with the
    # paths of the items it represents.
    def page(coll, q, parents, link_path)
      rows, position, total = coll.source.list(q, parents)
      groups = []
      items = rows.map do |r|
        rep, inc = Relations.expand(coll, coll.with_etag(coll.represent(r, parents)), q.includes)
        groups << coll.item_url(coll.id_of(r), parents)
        groups.concat(inc)
        q.project(rep)
      end
      doc = { "items" => items, "next" => position.nil? ? nil : q.next_link(link_path, q.issue_cursor(position)) }
      doc["total"] = total if q.count
      [doc, groups]
    end

    def list(ctx)
      coll = ctx.collection
      doc, groups = page(coll, ctx.query, ctx.parents, ctx.path)
      read_response(ctx, JSON.generate(doc), groups: [coll.url(ctx.parents)] + groups)
    end

    def show(ctx)
      coll, rec = ctx.collection, ctx.record
      rep = coll.with_etag(coll.represent(rec, ctx.parents))
      groups = [coll.item_url(coll.id_of(rec), ctx.parents)]
      if ctx.query.fields || !ctx.query.includes.empty?
        # §7.2: another representation, whose ETag changes with anything in it, included items too.
        rep, inc = Relations.expand(coll, rep, ctx.query.includes)
        read_response(ctx, JSON.generate(ctx.query.project(rep)), groups: groups + inc)
      else
        read_response(ctx, JSON.generate(rep), groups: groups, etag: rep["_etag"])
      end
    end

    # §4.2: human-readable documentation, linked with rel="service-doc" (RFC 8631) from the
    # discovery document.
    def docs
      @docs ||= File.read(Restep.config.docs_path).freeze
      [200, { "content-type" => "text/markdown; charset=utf-8", "content-language" => Restep.config.docs_language,
              "cache-control" => "public, max-age=3600" }, @docs]
    end

    # §4.4: whether every source (and the idempotency store) can serve.
    def status
      sources = Restep.catalog.map(&:source).uniq
      ok = sources.all? do |s|
        s.healthy?
      rescue StandardError
        false
      end
      [ok ? 200 : 503, { "content-type" => "application/health+json", "cache-control" => "no-store" },
       JSON.generate({ "status" => ok ? "pass" : "fail" })]
    end

    # ---- Writes ------------------------------------------------------------------------

    def create(ctx)
      coll = ctx.collection
      precheck = precheck_collection(ctx)
      effect = lambda do
        coll.source.transaction do
          precheck.call
          attrs = coll.attributes_for_create(Body.object!(ctx.body))
          rec = coll.source.create(attrs, ctx.parents)
          write_result(ctx, 201, rec, coll.represent(rec, ctx.parents), location: true)
        end
      end
      return effect.call unless ctx.idempotency_key
      # §7.1 (draft 6): the path is compared after decoding and the query counts toward "the same
      # request".
      Idempotency.run(path: QueryString.decode(ctx.path), key: ctx.idempotency_key, body: ctx.body, principal: ctx.principal,
                      query: idempotency_query(ctx), precheck: precheck, current: stored_item_current(coll, ctx.parents), &effect)
    end

    def update(ctx)
      coll = ctx.collection
      coll.source.transaction do
        # If-Match and write, atomic against other writes to the same item (§7.2).
        rec = lock!(coll, ctx.record, ctx.parents)
        rep = coll.represent(rec, ctx.parents)
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(rep), safe: false)
        changes = coll.changes_for_patch(rec, Body.object!(ctx.body))
        unless changes.empty?
          rec = coll.source.update(rec, changes)
          rep = coll.represent(rec, ctx.parents)
        end
        write_result(ctx, 200, rec, rep, invalidate: !changes.empty?)
      end
    end

    def destroy(ctx)
      coll = ctx.collection
      coll.source.transaction do
        rec = lock!(coll, ctx.record, ctx.parents)
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec, ctx.parents)), safe: false)
        coll.source.delete(rec)
        [204, { "cache-group-invalidation" => sf_list([coll.url(ctx.parents), coll.item_url(coll.id_of(rec), ctx.parents)]) }, nil]
      end
    end

    # ---- Actions (§11.1) ------------------------------------------------------------------

    # Order of §5.4 within the action: 409 if the stored state does not allow it (it does not
    # depend on the content, so it comes before the preconditions, RFC 9110 §13.2.1), 412 (against
    # the item's ETag, §7.2), 422 on the input, and then the effect.
    def action(ctx)
      a = ctx.action
      return safe_action(ctx, a) if a.method == "GET"
      return collection_action(ctx, a) unless a.item?
      coll = ctx.collection
      precheck = lambda do
        rec = current!(coll, ctx.record, ctx.parents)
        unless a.available?(rec)
          raise(a.unavailable&.call(rec) ||
                Problem.new(409, "conflict", detail: "The #{a.name} action is not available in the item's current state."))
        end
        next unless ctx.if_match || ctx.if_none_match
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec, ctx.parents)), safe: false)
      end
      effect = lambda do
        coll.source.transaction do
          rec = lock!(coll, ctx.record, ctx.parents)
          unless a.available?(rec)
            raise(a.unavailable&.call(rec) ||
                  Problem.new(409, "conflict", detail: "The #{a.name} action is not available in the item's current state."))
          end
          Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec, ctx.parents)), safe: false)
          input = coll.validate_input(a, Body.object!(ctx.body))
          before = coll.represent(rec, ctx.parents)
          a.run.call(rec, input)
          rec = coll.source.reload(rec, ctx.parents) or raise gone
          after = coll.represent(rec, ctx.parents)
          write_result(ctx, 200, rec, after, invalidate: after != before, action: true)
        end
      end
      # §11.1: an idempotent action may ignore Idempotency-Key, because repeating it is already safe.
      return effect.call if a.idempotent || ctx.idempotency_key.nil?
      Idempotency.run(path: QueryString.decode(ctx.path), key: ctx.idempotency_key, body: ctx.body, principal: ctx.principal,
                      query: idempotency_query(ctx), precheck: precheck,
                      current: stored_item_current(coll, ctx.parents, target_id(coll, ctx.record)), &effect)
    end

    def target_id(coll, rec) = rec.is_a?(Resolver::Missing) ? rec.id : coll.id_of(rec)

    # §7.1: the item of a stored response as it is now (another request may have changed or
    # deleted it): the one in its body or, with return=minimal and no body, the one its Location
    # names, or else the action's target (a 204 without Location). Its representation with
    # _etag, nil if it no longer exists, :unknown if the response names no item.
    def stored_item_current(coll, parents, target_id = nil)
      lambda do |body, headers|
        id = (JSON.parse(body)["id"] rescue nil) if body
        id ||= headers["location"]&.split("/")&.last
        id ||= target_id if body.nil?
        next :unknown if id.nil?
        rec = coll.find(id.to_s, parents)
        rec && coll.with_etag(coll.represent(rec, parents))
      end
    end

    # §7.1: the query of the fingerprint as [name, [values]], sorted by name (the order of
    # different names does not count) and with each name's values in the order received (that
    # one does).
    def idempotency_query(ctx)
      ctx.query.pairs.group_by(&:name).sort_by(&:first).map { |name, pairs| [name, pairs.map(&:value)] }
    end

    # A safe action with GET: no effects, with ETag and 304 like any read.
    # §11.1 (draft 7): its 200 is the result that output declares; without output, a collection's
    # safe action answers 204, never 200.
    def safe_action(ctx, a)
      coll = ctx.collection
      target = a.item? ? ctx.record : coll.source.scope(ctx.parents)
      status, doc = a.run.call(target, {})
      if !doc.nil? && a.output.nil? && !a.item?
        raise ArgumentError, "the safe action #{a.name} on a collection answers 200 only with a declared output (11.1)"
      end
      return [status, { "cache-control" => read_cache_control }, nil] if doc.nil?
      read_response(ctx, JSON.generate(doc), groups: [coll.url(ctx.parents)])
    end

    def collection_action(ctx, a)
      coll = ctx.collection
      coll.source.transaction do
        precheck_collection(ctx).call
        input = coll.validate_input(a, Body.object!(ctx.body))
        status, doc = a.run.call(coll.source.scope(ctx.parents), input)
        # §11.1 (draft 7): an unsafe action on a collection has no representation of its own, so
        # it answers 201 with the Location of what it creates, or 204; never 200.
        unless [201, 204].include?(status)
          raise ArgumentError, "the unsafe action #{a.name} on a collection answers 201 or 204, not #{status} (11.1)"
        end
        headers = { "cache-control" => "no-store", "cache-group-invalidation" => sf_list([coll.url(ctx.parents)]) }
        next [status, headers, nil] if doc.nil?
        [status, headers.merge("content-type" => "application/json"), JSON.generate(doc)]
      end
    end

    # ---- Support -----------------------------------------------------------------------------

    # Strong ETag of the body for what is not the full representation of an item (discovery,
    # pages, items with fields): different if anything changes.
    def body_etag(body) = %("#{Digest::SHA256.hexdigest(body)[0, 32]}")

    # §5.1: a response that depends on credentials is private; one that does not may be stored by
    # a shared cache once revalidated.
    def read_cache_control = Restep.private_responses? ? "private, no-cache" : "no-cache"

    def read_response(ctx, body, groups:, etag: nil, cache_control: read_cache_control)
      etag ||= body_etag(body)
      headers = { "etag" => etag, "cache-control" => cache_control, "content-type" => "application/json" }
      headers["cache-groups"] = sf_list(groups) unless groups.empty?
      if Conditional.evaluate(ctx.if_match, ctx.if_none_match, etag, safe: true) == :not_modified
        return [304, headers.except("content-type"), nil]
      end
      [200, headers, body]
    end

    # §7.2: a POST to the collection evaluates the conditions against the ETag of the GET without parameters.
    def precheck_collection(ctx)
      coll = ctx.collection
      lambda do
        next unless ctx.if_match || ctx.if_none_match
        # §7.2 (draft 7): * depends on whether the principal can read the collection, which every
        # principal here can, whether or not its GET carries an ETag; a list compares with the ETag
        # of a GET without parameters, and there is none where a filter is required (6.1).
        etag = begin
          q = Query.new(coll, :collection, "GET", [], parents: ctx.parents, principal: ctx.principal)
          doc, = page(coll, q, ctx.parents, coll.url(ctx.parents))
          body_etag(JSON.generate(doc))
        rescue Problem
          nil
        end
        if ctx.if_none_match == :any
          raise Problem.new(412, "precondition_failed", detail: "If-None-Match: * matches: the collection has a current representation.")
        end
        Conditional.evaluate(ctx.if_match == :any ? nil : ctx.if_match, ctx.if_none_match, etag, safe: false)
      end
    end

    # A Resolver::Missing is an id that names no item (it may not even be a valid id, such as
    # "07"): it gives 404 without querying, because a lookup could turn it into another id ("7").
    def lock!(coll, rec, parents = Parents::NONE)
      raise gone if rec.is_a?(Resolver::Missing)
      coll.source.lock(rec, parents) or raise gone
    end

    # The item as it is now, without locking it: the same 404 as lock! if it no longer exists
    # (another request deleted it, or the Resolver gave a Resolver::Missing).
    def current!(coll, rec, parents = Parents::NONE)
      raise gone if rec.is_a?(Resolver::Missing)
      coll.source.reload(rec, parents) or raise gone
    end

    def gone = Problem.new(404, "not_found", detail: "The item no longer exists.")

    # action: §7.2 and §11.1 (draft 7). A 200 to an action carries the item's representation with
    # Content-Location (the item's path) and the new item ETag, so it is the client's new copy;
    # the 204 of an action carries no ETag, unlike the minimal response of a POST or a PATCH (7.3).
    def write_result(ctx, status, rec, rep, location: false, invalidate: true, action: false)
      coll = ctx.collection
      rep = coll.with_etag(rep)
      item_url = coll.item_url(coll.id_of(rec), ctx.parents)
      headers = { "etag" => rep["_etag"], "cache-control" => "no-store" }
      headers["location"] = item_url if location
      headers["cache-group-invalidation"] = sf_list([coll.url(ctx.parents), item_url].uniq) if invalidate
      if ctx.minimal?
        headers["preference-applied"] = "return=minimal"
        headers.delete("etag") if action
        [status == 201 ? 201 : 204, headers, nil]
      else
        headers["content-location"] = item_url if action
        [status, headers.merge("content-type" => "application/json"), JSON.generate(rep)]
      end
    end

    def sf_list(items) = items.first(32).map { |g| %("#{g}") }.join(", ")

    def problem_response(e) = [e.status, e.response_headers, JSON.generate(e.body)]
  end
end
