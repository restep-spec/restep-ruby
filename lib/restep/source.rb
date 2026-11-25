module Restep
  # Where a collection (or a singleton) gets its data: the seam between the protocol and the
  # domain. The gem parses and checks every request (§5.3, §5.4, §6) and hands a source only what
  # is left: list a page, find an item, create, change or delete one. A source never sees HTTP.
  #
  # Restep::Sources::ActiveRecord reads a table with SQL; Restep::Sources::Computed takes lambdas
  # for resources the domain computes and filters, sorts and pages them in memory. For anything
  # else, subclass Restep::Source and implement what the collection offers:
  #
  #   list(query, parents)       # [records, next position or nil, total or nil]   GET /drafts
  #   find(id, parents)          # the record or nil                               GET /drafts/7
  #   find_singleton(parents)    # the singleton's record or nil                   GET /settings
  #   create(attrs, parents)     # the new record                                  POST
  #   update(record, changes)    # the changed record                              PATCH
  #   delete(record)                                                               DELETE
  #
  # query is a Restep::Query: filters, named, sort, limit, count and position (the value the
  # source returned as next position for the previous page, any JSON value: an offset or a
  # keyset). The gem wraps the position in the encrypted, bound cursor of §6.4. attrs and changes
  # are { column => value } after validation (§5.1); id is the path segment, a string. A write
  # that clashes with the stored state raises a Restep::Problem (409), usually through
  # collection.conflict(kind, record).
  class Source
    attr_reader :collection

    # Called once by the collection that uses the source.
    def bind(collection)
      raise ArgumentError, "a source serves one collection; #{@collection.name} already uses this one" if @collection && !@collection.equal?(collection)
      @collection = collection
      self
    end

    # ---- Reading ------------------------------------------------------------------------------

    def list(_query, _parents) = raise(NotImplementedError, "#{self.class}#list")
    def find(_id, _parents) = raise(NotImplementedError, "#{self.class}#find")
    def find_singleton(_parents) = raise(NotImplementedError, "#{self.class}#find_singleton")

    # The item's id as a string (§3).
    def id(record) = value(record, "id").to_s

    # A column of a record: a Hash (string or symbol keys) or an object with readers.
    def value(record, column)
      case record
      when Hash then record.key?(column) ? record[column] : record[column.to_sym]
      else record.respond_to?(column) ? record.public_send(column) : record[column]
      end
    end

    # ---- Writing ------------------------------------------------------------------------------

    def create(_attrs, _parents) = raise(NotImplementedError, "#{self.class}#create")
    def update(_record, _changes) = raise(NotImplementedError, "#{self.class}#update")
    def delete(_record) = raise(NotImplementedError, "#{self.class}#delete")

    # Which operations the source implements: :list, :find, :create, :update, :delete. The
    # collection's methods follow from them unless it declares its own.
    def supports?(op) = self.class.instance_method(op).owner != Restep::Source

    # ---- Consistency ----------------------------------------------------------------------------

    # Runs a write: evaluating If-Match and applying the write must be atomic against other writes
    # to the same item (§7.2). A source with transactions wraps the block in one.
    def transaction = yield

    # The record as it is now, locked against other writes until the transaction ends where the
    # source can; nil if it no longer exists.
    def lock(record, parents) = find(id(record), parents)

    # The record as it is now, after an action changed it; nil if it no longer exists.
    def reload(record, parents) = find(id(record), parents)

    # What a collection action receives (§11.1): by default, the parents.
    def scope(parents) = parents

    # Whether the source can serve requests (§4.4).
    def healthy? = true

    # ---- Relationships to a subcollection's items (§3, §9) --------------------------------------

    # A record by its id alone, for a relationship that points to this collection; nil if none.
    def locate(_id) = nil

    # The ids of the parent items of a record, outermost first: the variables of its item path.
    def parent_ids(_record)
      return [] if collection.nil? || collection.template.vars.empty?
      raise NotImplementedError, "#{self.class}#parent_ids: #{collection.name} is a subcollection, so an href to its items needs its parents' ids"
    end
  end
end
