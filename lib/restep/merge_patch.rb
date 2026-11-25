module Restep
  # JSON Merge Patch (RFC 7396, section 2): what a PATCH does to a field of type object, member by
  # member and recursively. A member set to null is removed; an array, a scalar or null in the
  # patch replaces the target's value whole.
  #
  #   Restep::MergePatch.apply({ "a" => 1, "b" => { "c" => 2 } }, { "b" => { "c" => nil, "d" => 3 } })
  #   # => { "a" => 1, "b" => { "d" => 3 } }
  module MergePatch
    module_function

    def apply(target, patch)
      return patch unless patch.is_a?(Hash)
      out = target.is_a?(Hash) ? target.dup : {}
      patch.each do |k, v|
        if v.nil? then out.delete(k)
        else out[k] = apply(out[k], v)
        end
      end
      out
    end
  end
end
