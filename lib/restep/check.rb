module Restep
  # What Restep.check! verifies at boot, so that a misconfiguration fails loudly once instead of
  # answering requests wrongly: the cursor secret (§6.4), the idempotency store (§7.1), the
  # catalog (paths, parents, the SQL or lambdas each filter needs) and the discovery document,
  # generated or hand-written, against the rules of draft 7 and, for a hand-written one, its JSON
  # Schema.
  module Check
    module_function

    def run!
      problems = []
      doc = Discovery.handwritten
      if doc
        # The contract first: its JSON Schema and the rules of the text, then the code against it.
        problems.concat(Rules.schema_problems(doc).map { |p| "discovery schema: #{p}" })
        problems.concat(Rules.problems(doc).map { |p| "discovery: #{p}" })
        problems.concat(Rules.bind(doc))
      end
      problems.concat(catalog_problems)
      begin
        Cursor.keys
      rescue ConfigurationError => e
        problems << e.message
      end
      problems << "a collection takes POST or a non-idempotent action, so §7.1 needs config.idempotency_store or idempotency_model" if needs_store? && Idempotency.store.nil?
      if problems.empty? && doc.nil?
        # The generated document follows the same rules: a failure here is the catalog's.
        d = Discovery.generate
        problems.concat(Rules.problems(d).map { |p| "discovery: #{p}" })
        problems.concat(Rules.schema_problems(d).map { |p| "discovery schema: #{p}" }) if schemer?
      end
      return if problems.empty?
      raise ConfigurationError, "Restep configuration:\n  - #{problems.join("\n  - ")}"
    end

    def schemer?
      require "json_schemer"
      true
    rescue LoadError
      false
    end

    def needs_store?
      Restep.catalog.any? do |c|
        c.methods_list.include?("POST") || c.actions.values.any? { |a| a.method == "POST" && !a.idempotent }
      end
    end

    def catalog_problems
      out = []
      (Restep.collections.keys & Restep.singletons.keys).each { |k| out << "#{k} is both a collection and a singleton" }
      Restep.collections.each { |k, c| out << "collections[#{k.inspect}] holds the collection named #{c.name}" unless c.name == k }
      Restep.singletons.each { |k, c| out << "singletons[#{k.inspect}] holds #{c.name}, which is not a singleton" unless c.name == k && c.singleton? }
      Restep.catalog.each do |c|
        if c.template.nil?
          out << "#{c.name} has no path (give path:, or declare it in a hand-written discovery document)"
          next
        end
        begin
          ancestors = c.ancestors
          out << "#{c.name}: its path has #{c.template.vars.size} variables for #{ancestors.size} parent collections" unless ancestors.size == c.template.vars.size
        rescue ConfigurationError => e
          out << e.message
        end
        c.relation_fields.each { |f| out << "#{c.name}: relation #{f.name} points to #{f.relation}, which is not a collection" unless Restep.collections.key?(f.relation) }
        begin
          c.source.check! if c.source.respond_to?(:check!)
        rescue ConfigurationError => e
          out << e.message
        end
        next unless c.source.is_a?(Sources::Computed)
        c.named_filters.each { |n, d| out << "#{c.name}: named filter #{n} needs match: ->(record, value) { ... }" unless d[:match].respond_to?(:call) }
      end
      out
    end
  end
end
