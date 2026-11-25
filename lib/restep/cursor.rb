module Restep
  # Opaque cursor (§6.4): bound to the collection, the filters, the order and the principal,
  # never to limit, fields, include or count. It carries the keyset position, encrypted and
  # authenticated (AES-256-GCM), so the sort values stay unreadable in the logs where the
  # next URLs end up (§6.4 and §13.9, draft 6).
  module Cursor
    module_function

    MIN_SECRET_BYTES = 16

    # The secret every replica shares: Restep.config.cursor_secret (in Rails, the railtie derives
    # one from secret_key_base with the application's key_generator) or RESTEP_CURSOR_SECRET. It
    # is never generated here: one per process would make each replica reject the others'
    # cursors. Without one, Restep.check! fails at boot.
    def secret
      s = Restep.config.cursor_secret || ENV["RESTEP_CURSOR_SECRET"]
      if s.nil? || s.to_s.empty?
        raise ConfigurationError, "Restep.config.cursor_secret is not set (nor RESTEP_CURSOR_SECRET): every replica must share " \
                                  "it, so it is never generated. In Rails, require \"restep/rails\" to derive it from secret_key_base."
      end
      raise ConfigurationError, "the cursor secret must have at least #{MIN_SECRET_BYTES} bytes" if s.to_s.bytesize < MIN_SECRET_BYTES
      s.to_s
    end

    # Deterministic encryption: the nonce comes from an HMAC of the content (SIV style). With a
    # random nonce, every response would carry a different next and the page would change body
    # and ETag on every read, so If-None-Match would never give 304 on a collection (see the
    # journal, B6-6). The keys are derived again when the secret changes.
    def keys
      s = secret
      return @keys if @keys && @keys_for == s
      material = OpenSSL::KDF.pbkdf2_hmac(s, salt: "restep-cursor", iterations: 1000, length: 64, hash: "SHA256")
      @keys_for = s
      @keys = [material[0, 32], material[32, 32]]
    end

    def issue(payload)
      enc_key, mac_key = keys
      plain = JSON.generate(payload)
      nonce = OpenSSL::HMAC.digest("SHA256", mac_key, plain)[0, 12]
      c = OpenSSL::Cipher.new("aes-256-gcm").encrypt
      c.key = enc_key
      c.iv = nonce
      c.auth_data = "restep-cursor-v1"
      ct = c.update(plain) + c.final
      Base64.urlsafe_encode64(nonce + c.auth_tag + ct, padding: false)
    end

    def read(token)
      raw = Base64.urlsafe_decode64(token.to_s)
      return nil if raw.bytesize < 29
      enc_key, = keys
      c = OpenSSL::Cipher.new("aes-256-gcm").decrypt
      c.key = enc_key
      c.iv = raw[0, 12]
      c.auth_tag = raw[12, 16]
      c.auth_data = "restep-cursor-v1"
      v = JSON.parse(c.update(raw[28..]) + c.final)
      v.is_a?(Hash) ? v : nil
    rescue ArgumentError, JSON::ParserError, OpenSSL::Cipher::CipherError
      nil
    end
  end
end
