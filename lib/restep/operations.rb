module Restep
  # What each operation does once steps 1 to 4 of §5.4 are done (Resolver and Context):
  # preconditions (412), validation (422) and conflicts (409), and the response. Each method
  # returns [status, headers, body] with the body as a string or nil; whoever writes it
  # (Restep::RackApp or a Rails controller) drops the body on a HEAD.
  module Operations
    module_function

    # ---- Reads --------------------------------------------------------------------------

    # §4.2 (draft 6): the same for everyone, no credentials, so it can be public with max-age.
    def discovery(ctx)
      status, headers, body = read_response(ctx, JSON.generate(Discovery.document), groups: [],
                                                                                     cache_control: "public, max-age=60")
      headers["link"] = %(<#{Restep.url("/docs")}>; rel="service-doc"; hreflang="es") if Restep.config.docs_path
      [status, headers, body]
    end

    def list(ctx)
      coll, q = ctx.collection, ctx.query
      rows, token, total = q.run
      items = rows.map { |r| q.project(coll.with_etag(coll.represent(r))) }
      doc = { "items" => items, "next" => token ? q.next_link(ctx.path, token) : nil }
      doc["total"] = total if q.count
      read_response(ctx, JSON.generate(doc), groups: [coll.url] + rows.map { |r| coll.item_url(r.id) })
    end

    def show(ctx)
      coll, rec = ctx.collection, ctx.record
      rep = coll.with_etag(coll.represent(rec))
      groups = [coll.item_url(rec.id)]
      if ctx.query.fields
        read_response(ctx, JSON.generate(ctx.query.project(rep)), groups: groups)
      else
        read_response(ctx, JSON.generate(rep), groups: groups, etag: rep["_etag"])
      end
    end

    # §4.2: human-readable documentation, linked with rel="service-doc" (RFC 8631) from the
    # discovery document.
    def docs
      @docs ||= File.read(Restep.config.docs_path).freeze
      [200, { "content-type" => "text/markdown; charset=utf-8", "content-language" => "es",
              "cache-control" => "public, max-age=3600" }, @docs]
    end

    def status
      ok = begin
        ActiveRecord::Base.connection.select_value("SELECT 1") == 1
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
        ActiveRecord::Base.transaction(requires_new: true) do
          precheck.call
          now = Time.now.utc.floor(6)
          attrs = coll.attributes_for_create(Body.object!(ctx.body))
          rec = coll.model.new(attrs.merge("created_at" => now, "updated_at" => now))
          save_or_conflict(coll, rec)
          rec.reload
          write_result(ctx, 201, rec, coll.represent(rec), location: true)
        end
      end
      return effect.call unless ctx.idempotency_key
      # §7.1 (draft 6): the path is compared after decoding and the query counts toward "the same
      # request".
      Idempotency.run(path: QueryString.decode(ctx.path), key: ctx.idempotency_key, body: ctx.body,
                      query: idempotency_query(ctx), precheck: precheck, current: stored_item_current(coll), &effect)
    end

    def update(ctx)
      coll = ctx.collection
      ActiveRecord::Base.transaction do
        # If-Match and write, atomic against other writes to the same item (§7.2).
        rec = lock!(coll, ctx.record)
        rep = coll.represent(rec)
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(rep), safe: false)
        changes = coll.changes_for_patch(rec, Body.object!(ctx.body))
        unless changes.empty?
          rec.assign_attributes(changes.merge("updated_at" => Time.now.utc))
          save_or_conflict(coll, rec)
          rec.reload
          rep = coll.represent(rec)
        end
        write_result(ctx, 200, rec, rep, invalidate: !changes.empty?)
      end
    end

    def destroy(ctx)
      coll = ctx.collection
      ActiveRecord::Base.transaction do
        rec = lock!(coll, ctx.record)
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec)), safe: false)
        begin
          ActiveRecord::Base.transaction(requires_new: true) { rec.delete }
        rescue ActiveRecord::InvalidForeignKey
          raise coll.conflict(:foreign_key, rec)
        end
        [204, { "cache-group-invalidation" => sf_list([coll.url, coll.item_url(rec.id)]) }, nil]
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
        rec = current!(coll, ctx.record)
        unless a.available?(rec)
          raise(a.unavailable&.call(rec) ||
                Problem.new(409, "conflict", detail: "The #{a.name} action is not available in the item's current state."))
        end
        next unless ctx.if_match || ctx.if_none_match
        Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec)), safe: false)
      end
      effect = lambda do
        ActiveRecord::Base.transaction(requires_new: true) do
          rec = lock!(coll, ctx.record)
          unless a.available?(rec)
            raise(a.unavailable&.call(rec) ||
                  Problem.new(409, "conflict", detail: "The #{a.name} action is not available in the item's current state."))
          end
          Conditional.evaluate(ctx.if_match, ctx.if_none_match, coll.etag(coll.represent(rec)), safe: false)
          input = coll.validate_input(a, Body.object!(ctx.body))
          before = coll.represent(rec)
          a.run.call(rec, input)
          rec.reload
          after = coll.represent(rec)
          write_result(ctx, 200, rec, after, invalidate: after != before, action: true)
        end
      end
      # §11.1: an idempotent action may ignore Idempotency-Key, because repeating it is already safe.
      return effect.call if a.idempotent || ctx.idempotency_key.nil?
      Idempotency.run(path: QueryString.decode(ctx.path), key: ctx.idempotency_key, body: ctx.body,
                      query: idempotency_query(ctx), precheck: precheck, current: stored_item_current(coll, ctx.record.id), &effect)
    end

    # §7.1: the item of a stored response as it is now (another request may have changed or
    # deleted it): the one in its body or, with return=minimal and no body, the one its Location
    # names, or else the action's target (a 204 without Location). Its representation with
    # _etag, nil if it no longer exists, :unknown if the response names no item.
    def stored_item_current(coll, target_id = nil)
      lambda do |body, headers|
        id = (JSON.parse(body)["id"] rescue nil) if body
        id ||= headers["location"]&.split("/")&.last
        id ||= target_id if body.nil?
        next :unknown if id.nil?
        rec = coll.find(id.to_s)
        rec && coll.with_etag(coll.represent(rec))
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
      target = a.item? ? ctx.record : ctx.collection.model
      status, doc = a.run.call(target, {})
      if !doc.nil? && a.output.nil? && !a.item?
        raise ArgumentError, "the safe action #{a.name} on a collection answers 200 only with a declared output (11.1)"
      end
      return [status, { "cache-control" => "no-cache" }, nil] if doc.nil?
      read_response(ctx, JSON.generate(doc), groups: [ctx.collection.url])
    end

    def collection_action(ctx, a)
      coll = ctx.collection
      ActiveRecord::Base.transaction(requires_new: true) do
        precheck_collection(ctx).call
        input = coll.validate_input(a, Body.object!(ctx.body))
        status, doc = a.run.call(coll.model, input)
        # §11.1 (draft 7): an unsafe action on a collection has no representation of its own, so
        # it answers 201 with the Location of what it creates, or 204; never 200.
        unless [201, 204].include?(status)
          raise ArgumentError, "the unsafe action #{a.name} on a collection answers 201 or 204, not #{status} (11.1)"
        end
        headers = { "cache-control" => "no-store", "cache-group-invalidation" => sf_list([coll.url]) }
        next [status, headers, nil] if doc.nil?
        [status, headers.merge("content-type" => "application/json"), JSON.generate(doc)]
      end
    end

    # ---- Support -----------------------------------------------------------------------------

    # Strong ETag of the body for what is not the full representation of an item (discovery,
    # pages, items with fields): different if anything changes.
    def body_etag(body) = %("#{Digest::SHA256.hexdigest(body)[0, 32]}")

    def read_response(ctx, body, groups:, etag: nil, cache_control: "no-cache")
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
          q = Query.new(coll, :collection, "GET", [])
          rows, token, = q.run
          items = rows.map { |r| coll.with_etag(coll.represent(r)) }
          body_etag(JSON.generate({ "items" => items, "next" => token ? q.next_link(coll.url, token) : nil }))
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
    # "07"): it gives 404 without querying, because find_by would turn it into another id ("7").
    def lock!(coll, rec)
      raise gone if rec.is_a?(Resolver::Missing)
      coll.model.lock("FOR UPDATE").find_by(id: rec.id) or raise gone
    end

    # The item as it is now, without locking it: the same 404 as lock! if it no longer exists
    # (another request deleted it, or the Resolver gave a Resolver::Missing).
    def current!(coll, rec)
      raise gone if rec.is_a?(Resolver::Missing)
      coll.model.find_by(id: rec.id) or raise gone
    end

    def gone = Problem.new(404, "not_found", detail: "The item no longer exists.")

    def save_or_conflict(coll, rec)
      ActiveRecord::Base.transaction(requires_new: true) { rec.save! }
    rescue ActiveRecord::RecordNotUnique
      raise coll.conflict(:unique, rec)
    end

    # action: §7.2 and §11.1 (draft 7). A 200 to an action carries the item's representation with
    # Content-Location (the item's path) and the new item ETag, so it is the client's new copy;
    # the 204 of an action carries no ETag, unlike the minimal response of a POST or a PATCH (7.3).
    def write_result(ctx, status, rec, rep, location: false, invalidate: true, action: false)
      coll = ctx.collection
      rep = coll.with_etag(rep)
      headers = { "etag" => rep["_etag"], "cache-control" => "no-store" }
      headers["location"] = coll.item_url(rec.id) if location
      headers["cache-group-invalidation"] = sf_list([coll.url, coll.item_url(rec.id)]) if invalidate
      if ctx.minimal?
        headers["preference-applied"] = "return=minimal"
        headers.delete("etag") if action
        [status == 201 ? 201 : 204, headers, nil]
      else
        headers["content-location"] = coll.item_url(rec.id) if action
        [status, headers.merge("content-type" => "application/json"), JSON.generate(rep)]
      end
    end

    def sf_list(items) = items.first(32).map { |g| %("#{g}") }.join(", ")

    def problem_response(e) = [e.status, e.response_headers, JSON.generate(e.body)]
  end
end
