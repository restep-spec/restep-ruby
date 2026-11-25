module Restep
  # Opaque cursor (§6.4): bound to the collection, the filters, the order and the principal,
  # never to limit, fields, include or count. It carries the keyset position, encrypted and
  # authenticated (AES-256-GCM), so the sort values stay unreadable in the logs where the
  # next URLs end up (§6.4 and §13.9, draft 6).
  module Cursor
    module_function

    def secret
      @secret ||= ENV["RESTEP_CURSOR_SECRET"] || begin
        path = Restep.config.cursor_key_path or raise "Restep.config.cursor_key_path is not set"
        File.write(path, SecureRandom.hex(32)) unless File.exist?(path)
        File.read(path).strip
      end
    end

    # Deterministic encryption: the nonce comes from an HMAC of the content (SIV style). With a
    # random nonce, every response would carry a different next and the page would change body
    # and ETag on every read, so If-None-Match would never give 304 on a collection (see the
    # journal, B6-6).
    def keys
      @keys ||= begin
        material = OpenSSL::KDF.pbkdf2_hmac(secret, salt: "restep-cursor", iterations: 1000, length: 64, hash: "SHA256")
        [material[0, 32], material[32, 32]]
      end
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
