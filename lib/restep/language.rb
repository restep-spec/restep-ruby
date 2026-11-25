module Restep
  # Language maps (§3): the same text in several languages, as an object whose keys are lowercase
  # language tags (BCP 47, RFC 5646) and whose values are strings.
  #
  #   Restep::Fields.f(name: "name", type: "language_map", languages: %w[en es-es])
  #
  # languages: the tags the API accepts; nil accepts any well-formed one.
  module Language
    alnum = "[a-z0-9]"
    language = "(?:[a-z]{2,3}(?:-[a-z]{3}){0,3}|[a-z]{4}|[a-z]{5,8})"
    variant = "(?:#{alnum}{5,8}|[0-9]#{alnum}{3})"
    extension = "(?:[0-9a-wy-z](?:-#{alnum}{2,8})+)"
    privateuse = "(?:x(?:-#{alnum}{1,8})+)"
    langtag = "#{language}(?:-[a-z]{4})?(?:-(?:[a-z]{2}|[0-9]{3}))?(?:-#{variant})*(?:-#{extension})*(?:-#{privateuse})?"
    grandfathered = %w[en-gb-oed i-ami i-bnn i-default i-enochian i-hak i-klingon i-lux i-mingo i-navajo i-pwn
                       i-tao i-tay i-tsu sgn-be-fr sgn-be-nl sgn-ch-de art-lojban cel-gaulish no-bok no-nyn
                       zh-guoyu zh-hakka zh-min zh-min-nan zh-xiang].map { |t| Regexp.escape(t) }.join("|")
    # RFC 5646, section 2.1, in lowercase: a well-formed tag, which need not be in the registry.
    TAG = /\A(?:#{langtag}|#{privateuse}|#{grandfathered})\z/

    module_function

    def tag?(s) = s.is_a?(String) && TAG.match?(s)

    # A language map is never null or absent in a representation: one with no translations is {}.
    def render(v)
      case v
      when nil then {}
      when String then JSON.parse(v)
      else v.to_h { |k, x| [k.to_s, x] }
      end
    end

    def esc(k) = k.gsub("~", "~0").gsub("/", "~1")

    def entry(pointer, code, detail) = { "pointer" => pointer, "code" => code, "detail" => detail }

    # Validates a language map in a POST (patch: false: an object of strings) or the value of a
    # PATCH (patch: true: null is valid for the field and for each key). Returns the map's
    # entries or :error; appends one errors entry per failure (§3).
    def validate(f, v, ptr, errors, patch:, current: {})
      unless v.is_a?(Hash)
        errors << entry(ptr, "type", "#{f.name} must be an object of translations by language tag#{patch ? ", or null" : ""}.")
        return :error
      end
      ok = true
      v.each do |k, text|
        kp = "#{ptr}/#{esc(k)}"
        unless k.valid_encoding? && !Types.noncharacter?(k)
          errors << entry(ptr, "format", "#{f.name} has a key with characters a request body cannot carry.")
          ok = false
          next
        end
        unless tag?(k)
          errors << entry(kp, "format", "#{k} is not a well-formed lowercase language tag (BCP 47), such as es-es.")
          ok = false
          next
        end
        if text.nil? && patch
          next # deletes the translation: any well-formed key, accepted or not
        end
        unless text.is_a?(String)
          errors << entry(kp, "type", "The #{k} translation of #{f.name} must be a string#{patch ? ", or null to delete it" : ""}.")
          ok = false
          next
        end
        if !text.valid_encoding? || text.include?("\u0000") || Types.noncharacter?(text)
          errors << entry(kp, "format", "The #{k} translation of #{f.name} contains characters that cannot be stored.")
          ok = false
          next
        end
        # §3: unknown if a translation is added, or changed, under a tag the API does not accept.
        if f.languages && !f.languages.include?(k) && current[k] != text
          errors << entry(kp, "unknown", "#{f.name} takes no #{k} translation; it takes: #{f.languages.join(", ")}.")
          ok = false
        end
      end
      ok ? v : :error
    end

    # §3: a PATCH merges a language map by key: a string adds or changes it, null deletes it, and
    # null for the whole field empties it. Returns the merged map or :error.
    def merge(f, current, v, ptr, errors)
      return {} if v.nil?
      valid = validate(f, v, ptr, errors, patch: true, current: current)
      return :error if valid == :error
      out = current.dup
      valid.each { |k, text| text.nil? ? out.delete(k) : out[k] = text }
      out
    end
  end
end
