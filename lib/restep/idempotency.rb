module Restep
  # §7.1 with PostgreSQL, valid with several processes.
  #
  # 1. The key's record (with the request hash) is inserted and committed right away, outside
  #    the effect's transaction, so another request with the same key sees it.
  # 2. The effect runs in a transaction that first takes the key's row with
  #    FOR UPDATE NOWAIT. If another transaction holds it, the request is in progress: 409.
  # 3. The effect and the stored response are committed in the same transaction (atomically). If
  #    the process dies halfway, the transaction rolls back and the row stays uncompleted and
  #    unlocked: the next retry takes it and runs the effect exactly once.
  # 4. A rejected request (4xx) deletes the row: it does not spend the key.
  module Idempotency
    TTL = 86_400
    REPLAY_HEADERS = %w[content-type location content-location etag preference-applied cache-group-invalidation].freeze

    module_function

    # By name or by class: with Rails autoloading, the model does not exist yet at configuration time.
    def model
      m = Restep.config.idempotency_model
      m.is_a?(String) ? Object.const_get(m) : m
    end

    # precheck: the 409 of the stored state and If-Match/If-None-Match (412), which come before
    # the 422 idempotency_mismatch.
    # Returns [status, headers, body]; the block does the effect inside the transaction.
    # current: the item of the stored response (the one in its body or, without a body, the one
    # in its Location) as a read would give it now: its representation with _etag, nil if it can
    # no longer be read, or :unknown if the response names no item. See replay.
    def run(path:, key:, body:, query:, precheck:, current: ->(_body, _headers) { :unknown })
      scope = { principal: PRINCIPAL, http_method: "POST", path: path, key: key }
      request_hash = Digest::SHA256.hexdigest(Types.canonical_json({ "query" => query, "body" => body }))
      3.times do
        model.where(scope).where("expires_at < now()").delete_all
        model.insert_all([scope.merge(request_hash: request_hash, expires_at: Time.now.utc + TTL)],
                                  unique_by: :index_idempotency_keys_unique)
        row = model.find_by(scope)
        next if row.nil? # a rejected request deleted it in between: try again

        if row.request_hash != request_hash
          precheck.call
          raise Problem.new(422, "idempotency_mismatch",
                            detail: "This Idempotency-Key was already used with a different request body; use a new key.")
        end

        outcome = begin
          model.transaction do
            locked = model.lock("FOR UPDATE NOWAIT").find_by(id: row.id)
            next :retry if locked.nil?
            next replay(locked, current) if locked.completed
            begin
              status, headers, resp_body = yield
              locked.update!(completed: true, status: status, body: resp_body,
                             headers: headers.slice(*REPLAY_HEADERS))
              [status, headers, resp_body]
            rescue Problem => e
              locked.destroy!
              e
            end
          end
        rescue ActiveRecord::LockWaitTimeout
          raise Problem.new(409, "request_in_progress",
                            detail: "A request with this Idempotency-Key is still running; retry it after Retry-After.",
                            headers: { "retry-after" => "1" })
        end
        next if outcome == :retry
        raise outcome if outcome.is_a?(Problem)
        return outcome
      end
      raise Problem.new(409, "request_in_progress", detail: "The Idempotency-Key is busy; retry.", headers: { "retry-after" => "1" })
    end

    # §7.1: the same status and Location, and a body that gives no more than a read would now.
    # An item that can no longer be read gives no body or ETag. Draft 7: a replay whose body is not
    # the item's current representation must not carry Content-Location, ETag or _etag, so when
    # the item changed after the stored response (another write, or an action's 200 replayed
    # later), the replay carries its current representation, whose validators are true. §7.3
    # (council round 3, decision 5): a replay without a body (a 201 with return=minimal) carries
    # no ETag, even when the item still exists: the stored one may no longer be current, and the
    # current one was not produced by this request; a client that needs one reads Location.
    def replay(row, current)
      headers = (row.headers || {}).merge("idempotent-replayed" => "true")
      rep = current.call(row.body, headers)
      return [row.status, headers.except("content-type", "content-location", "etag"), nil] if rep.nil?
      return [row.status, headers.except("etag"), nil] if row.body.nil?
      return [row.status, headers, row.body] if rep == :unknown
      stored_etag = (JSON.parse(row.body)["_etag"] rescue nil)
      return [row.status, headers, row.body] if stored_etag && stored_etag == rep["_etag"]
      [row.status, headers.merge("etag" => rep["_etag"], "content-type" => "application/json"), JSON.generate(rep)]
    end
  end
end
