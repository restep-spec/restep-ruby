module Restep
  # §7.1: Idempotency-Key. A key belongs to one principal (Restep.config.principal) and one
  # target (method and path); the request it was first used with is kept as a hash of its query
  # and body. Where the keys live is a store:
  #
  #   c.idempotency_model = "IdempotencyKey"                    # ActiveRecordStore on that model
  #   c.idempotency_store = Restep::Idempotency::MemoryStore.new # one process only: tests, development
  #
  # Any object with run(scope, request_hash, ttl:, precheck:, replay:) { effect } is a store; see
  # ActiveRecordStore for what it must guarantee.
  module Idempotency
    TTL = 86_400
    REPLAY_HEADERS = %w[content-type location content-location etag preference-applied cache-group-invalidation].freeze

    # What a store keeps for a key.
    Entry = Struct.new(:request_hash, :completed, :status, :headers, :body, :expires_at, keyword_init: true)

    module_function

    def store
      s = Restep.config.idempotency_store
      return s if s
      m = Restep.config.idempotency_model
      @ar_store = nil if @ar_store && @ar_store.model_ref != m
      @ar_store ||= m && ActiveRecordStore.new(m)
    end

    # The keys' lifetime: the one a hand-written discovery document declares, or a day.
    def ttl = Restep::Discovery.handwritten&.dig("idempotency", "ttl") || TTL

    # precheck: the 409 of the stored state and If-Match/If-None-Match (412), which come before
    # the 422 idempotency_mismatch.
    # Returns [status, headers, body]; the block does the effect.
    # current: the item of the stored response (the one in its body or, without a body, the one
    # in its Location) as a read would give it now: its representation with _etag, nil if it can
    # no longer be read, or :unknown if the response names no item. See replay.
    def run(path:, key:, body:, query:, precheck:, principal: nil, current: ->(_body, _headers) { :unknown }, &effect)
      s = store or raise ConfigurationError, "Restep.config.idempotency_store (or idempotency_model) is not set"
      scope = { principal: Restep.principal_key(principal), http_method: "POST", path: path, key: key }
      request_hash = Digest::SHA256.hexdigest(Types.canonical_json({ "query" => query, "body" => body }))
      s.run(scope, request_hash, ttl: ttl, precheck: precheck, replay: ->(entry) { replay(entry, current) }, &effect)
    end

    def mismatch = Problem.new(422, "idempotency_mismatch",
                               detail: "This Idempotency-Key was already used with a different request body; use a new key.")

    def in_progress(detail = "A request with this Idempotency-Key is still running; retry it after Retry-After.")
      Problem.new(409, "request_in_progress", detail: detail, headers: { "retry-after" => "1" })
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

    # Keys in memory, for one process (tests, development, a single-process server). The effect
    # and the stored response are not atomic against a crash: a key whose effect ran is lost with
    # the process. Use a durable store where that matters.
    class MemoryStore
      def initialize
        @entries = {}
        @lock = Mutex.new
      end

      def run(scope, request_hash, ttl:, precheck:, replay:)
        k = scope.values_at(:principal, :http_method, :path, :key)
        entry = @lock.synchronize do
          e = @entries[k]
          @entries.delete(k) if e && e.expires_at < Time.now
          @entries[k] ||= Entry.new(request_hash: request_hash, completed: false, expires_at: Time.now + ttl, status: :new)
        end
        if entry.request_hash != request_hash
          precheck.call
          raise Idempotency.mismatch
        end
        return replay.call(entry) if entry.completed
        claimed = @lock.synchronize do
          next false unless entry.status == :new
          entry.status = :running
          true
        end
        raise Idempotency.in_progress unless claimed
        begin
          status, headers, body = yield
        rescue StandardError
          @lock.synchronize { @entries.delete(k) }
          raise
        end
        @lock.synchronize do
          entry.status, entry.headers, entry.body, entry.completed = status, headers.slice(*REPLAY_HEADERS), body, true
        end
        [status, headers, body]
      end

      def clear = @lock.synchronize { @entries.clear }
    end

    # Keys in a table, with PostgreSQL, valid with several processes. The table needs principal,
    # http_method, path, key, request_hash, completed, status, headers (json), body, expires_at,
    # and a unique index named index_idempotency_keys_unique on (principal, http_method, path, key).
    #
    # 1. The key's record (with the request hash) is inserted and committed right away, outside
    #    the effect's transaction, so another request with the same key sees it.
    # 2. The effect runs in a transaction that first takes the key's row with
    #    FOR UPDATE NOWAIT. If another transaction holds it, the request is in progress: 409.
    # 3. The effect and the stored response are committed in the same transaction (atomically),
    #    when the source writes to the same database. If the process dies halfway, the transaction
    #    rolls back and the row stays uncompleted and unlocked: the next retry takes it and runs
    #    the effect exactly once.
    # 4. A rejected request (4xx) deletes the row: it does not spend the key.
    class ActiveRecordStore
      attr_reader :model_ref

      # By name or by class: with Rails autoloading, the model does not exist yet at configuration time.
      def initialize(model) = @model_ref = model

      def model = @model_ref.is_a?(String) ? Object.const_get(@model_ref) : @model_ref

      def run(scope, request_hash, ttl:, precheck:, replay:)
        3.times do
          model.where(scope).where("expires_at < ?", Time.now.utc).delete_all
          model.insert_all([scope.merge(request_hash: request_hash, expires_at: Time.now.utc + ttl)],
                           unique_by: :index_idempotency_keys_unique)
          row = model.find_by(scope)
          next if row.nil? # a rejected request deleted it in between: try again

          if row.request_hash != request_hash
            precheck.call
            raise Idempotency.mismatch
          end

          outcome = begin
            model.transaction do
              locked = model.lock("FOR UPDATE NOWAIT").find_by(id: row.id)
              next :retry if locked.nil?
              next replay.call(locked) if locked.completed
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
          rescue ::ActiveRecord::LockWaitTimeout
            raise Idempotency.in_progress
          end
          next if outcome == :retry
          raise outcome if outcome.is_a?(Problem)
          return outcome
        end
        raise Idempotency.in_progress("The Idempotency-Key is busy; retry.")
      end
    end
  end
end
