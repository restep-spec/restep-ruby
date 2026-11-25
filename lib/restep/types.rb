module Restep
  # Types of §4.2: parsing of filter values (text) and body values (JSON), and rendering.
  module Types
    DECIMAL_RE = /\A-?[0-9]+(\.[0-9]+)?\z/
    # number of RFC 8259 §6: no "+", no leading zeros, digits on both sides of ".", optional exponent.
    NUMBER_RE = /\A(-?)(0|[1-9][0-9]*)(?:\.([0-9]+))?(?:[eE]([+-]?[0-9]+))?\z/
    MAX_INTEGER_DIGITS = 8 * 1024
    DATE_RE = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})\z/
    # RFC 3339 date-time with a mandatory offset. T and Z may be lowercase (RFC 3339 §5.6).
    DATETIME_RE = /\A([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt]([0-9]{2}):([0-9]{2}):([0-9]{2})(\.[0-9]+)?([Zz]|[+-][0-9]{2}:[0-9]{2})\z/
    BIGINT = (-(2**63))..(2**63 - 1)
    # Unicode noncharacters: U+FDD0..U+FDEF and the last two code points of every plane (§3, I-JSON).
    NONCHARACTER = /[\u{FDD0}-\u{FDEF}\u{FFFE}\u{FFFF}\u{1FFFE}\u{1FFFF}\u{2FFFE}\u{2FFFF}\u{3FFFE}\u{3FFFF}\u{4FFFE}\u{4FFFF}\u{5FFFE}\u{5FFFF}\u{6FFFE}\u{6FFFF}\u{7FFFE}\u{7FFFF}\u{8FFFE}\u{8FFFF}\u{9FFFE}\u{9FFFF}\u{AFFFE}\u{AFFFF}\u{BFFFE}\u{BFFFF}\u{CFFFE}\u{CFFFF}\u{DFFFE}\u{DFFFF}\u{EFFFE}\u{EFFFF}\u{FFFFE}\u{FFFFF}\u{10FFFE}\u{10FFFF}]/

    module_function

    def noncharacter?(s) = s.valid_encoding? && NONCHARACTER.match?(s)

    def parse_date(s)
      m = DATE_RE.match(s) or return nil
      y, mo, d = m[1].to_i, m[2].to_i, m[3].to_i
      Date.valid_date?(y, mo, d) ? Date.new(y, mo, d) : nil
    end

    # Returns the instant as seconds since the epoch, as an exact Rational (without going through
    # floating point or PostgreSQL's microsecond precision).
    # leap: whether a leap second (:60) is accepted, only to recognize one (leap_second?). Draft
    # 7: a filter operand with one gives invalid_parameter (6.1), and a request body with one,
    # 422 with a format entry (3).
    def parse_datetime(s, leap: false)
      m = DATETIME_RE.match(s) or return nil
      y, mo, d, h, mi, se = (1..6).map { |i| m[i].to_i }
      return nil unless Date.valid_date?(y, mo, d) && h <= 23 && mi <= 59 && se <= (leap ? 60 : 59)
      frac = m[7] ? Rational(m[7][1..].to_i, 10**(m[7].length - 1)) : 0
      off = 0
      if m[8] =~ /\A([+-])([0-9]{2}):([0-9]{2})\z/
        oh, om = $2.to_i, $3.to_i
        return nil if oh > 23 || om > 59
        off = ($1 == "-" ? -1 : 1) * (oh * 3600 + om * 60)
      end
      # With leap: true, a leap second (:60) is the first instant of the next minute.
      Rational(Time.utc(y, mo, d, h, mi, 0).to_i) + se + frac - off
    end

    # Whether s is an RFC 3339 date-time that is valid only as a leap second (:60). §3 (draft 7):
    # a server never writes one and rejects it in a request body with a format entry; §6.1: a
    # filter operand with one gives invalid_parameter.
    def leap_second?(s)
      s.is_a?(String) && (m = DATETIME_RE.match(s)) && m[6] == "60" && !parse_datetime(s, leap: true).nil?
    end

    def micro_exact?(r)
      (r * 1_000_000).denominator == 1
    end

    # Instant (Rational) to text that PostgreSQL understands, rounded to microseconds down or up.
    def sql_instant(r, mode = :floor)
      us = mode == :ceil ? (r * 1_000_000).ceil : (r * 1_000_000).floor
      t = Time.at(us.div(1_000_000), us % 1_000_000, :usec, in: "UTC")
      t.strftime("%Y-%m-%dT%H:%M:%S.%6NZ")
    end

    # Filter value (URL text) according to the declared type. Returns [:ok, value] or nil.
    def parse_filter_value(type, raw, values = nil)
      raw = "" if raw.nil?
      case type
      when "string" then [:ok, raw]
      when "enum" then values.include?(raw) ? [:ok, raw] : nil
      when "integer" then parse_integer_operand(raw)
      when "decimal" then DECIMAL_RE.match?(raw) ? [:ok, BigDecimal(raw)] : nil
      when "boolean" then %w[true false].include?(raw) ? [:ok, raw == "true"] : nil
      when "date" then (d = parse_date(raw)) ? [:ok, d] : nil
      when "datetime" then (t = parse_datetime(raw)) ? [:ok, t] : nil
      end
    end

    # §6.1 (draft 7, council round 3, decision 7): an integer operand is written with the number
    # grammar of RFC 8259 §6, exponent included, and matches its type when its exact value has no
    # fractional part: 20.0 and 2e1 are the operand 20 (and bind the cursor as 20); 20.5, 2e-1,
    # +20, .5, 020 and 0x14 are invalid. The value is computed from the digits and the exponent
    # as integers, never through BigDecimal, which turns 1e-99999999999999999999 into 0.
    # An operand of more than MAX_INTEGER_DIGITS digits is outside this server's undeclared limit
    # (§5.3: invalid_parameter): in plain digits the query string (8 KiB) could not hold it either.
    def parse_integer_operand(raw)
      parts = integer_parts(raw) or return nil
      sign, stripped, shift = parts
      return [:ok, 0] if stripped.empty?
      return nil if shift.negative?
      return nil if stripped.length + shift > MAX_INTEGER_DIGITS
      value = Integer(stripped, 10) * (10**shift)
      [:ok, sign == "-" ? -value : value]
    end

    # §6.1 (draft 7, council round 4, decision 6): whether raw is a whole JSON number whose value
    # has more than MAX_INTEGER_DIGITS digits. It is over this server's §5.3 limit, so it gives
    # invalid_parameter with the limit in detail; it is never replaced by another value.
    def integer_over_limit?(raw)
      parts = integer_parts(raw.to_s) or return false
      _, stripped, shift = parts
      !stripped.empty? && !shift.negative? && stripped.length + shift > MAX_INTEGER_DIGITS
    end

    # The sign, the significant digits without trailing zeros and the power of ten of a JSON
    # number, computed as integers (never through BigDecimal or a float), or nil.
    def integer_parts(raw)
      m = NUMBER_RE.match(raw) or return nil
      sign, int, frac, exp = m[1], m[2], m[3].to_s, m[4].to_s
      digits = (int + frac).sub(/\A0+/, "")
      return [sign, "", 0] if digits.empty?
      stripped = digits.sub(/0+\z/, "")
      [sign, stripped, Integer(exp.empty? ? "0" : exp, 10) - frac.length + (digits.length - stripped.length)]
    end

    def render_decimal(bd, scale)
      return nil if bd.nil?
      s = bd.round(scale).to_s("F") # "12.5", "-0.5", "12.0"
      neg = s.start_with?("-")
      int, frac = s.delete_prefix("-").split(".")
      frac = (frac || "").ljust(scale, "0")[0, scale]
      out = scale.zero? ? int : "#{int}.#{frac}"
      out = "-#{out}" if neg && out =~ /[1-9]/
      out
    end

    def render_datetime(t)
      return nil if t.nil?
      t = t.utc
      s = t.strftime("%Y-%m-%dT%H:%M:%S")
      s << format(".%06d", t.usec).sub(/0+\z/, "") if t.usec.positive?
      s << "Z"
    end

    # §3: a JSON value of a field of type object or array, as a request body carries it, checked
    # as an I-JSON message and made ready to store and render. Strings (member names too) must be
    # valid UTF-8 without U+0000 or noncharacters; a number with a fraction or an exponent becomes
    # a Float, and one a double cannot hold without losing digits (I-JSON, RFC 7493 section 2.2)
    # is refused rather than rounded. Integers stay exact. Each fault is a 422 entry: at the
    # string that holds it, or at "" for a member name (§3: a pointer to it would carry it too).
    # Returns the value, or :error with the entries added to errors.
    def json_value(v, pointer, errors)
      before = errors.size
      out = normalize_json(v, pointer, errors)
      errors.size == before ? out : :error
    end

    def normalize_json(v, pointer, errors)
      case v
      when Hash
        v.to_h do |k, x|
          k = k.to_s
          unless storable_string?(k)
            errors << { "pointer" => "", "code" => "format", "detail" => "A member name has a character that cannot be stored (NUL or a noncharacter)." }
            next [k, nil]
          end
          [k, normalize_json(x, "#{pointer}/#{k.gsub("~", "~0").gsub("/", "~1")}", errors)]
        end
      when Array then v.each_with_index.map { |x, i| normalize_json(x, "#{pointer}/#{i}", errors) }
      when String
        unless storable_string?(v)
          errors << { "pointer" => pointer, "code" => "format", "detail" => "The string has a character that cannot be stored (NUL, an unpaired surrogate or a noncharacter)." }
        end
        v
      when BigDecimal, Float then json_float(v, pointer, errors)
      when Integer, true, false, nil then v
      else
        errors << { "pointer" => pointer, "code" => "type", "detail" => "Not a JSON value." }
        nil
      end
    end

    def storable_string?(s) = s.valid_encoding? && !s.include?("\u0000") && !noncharacter?(s)

    def json_float(v, pointer, errors)
      f = v.to_f
      exact = f.finite? && (v.is_a?(Float) || BigDecimal(f.to_s) == v)
      return f if exact
      errors << { "pointer" => pointer, "code" => "range",
                  "detail" => "The number has more digits or magnitude than a double holds (I-JSON); send it as a string." }
      nil
    end

    # Canonical form to compare bodies "equal as JSON values" (§7.1): sorted keys and normalized
    # exact numbers (1, 1.0 and 1e0 are the same number).
    def canonical_json(v)
      case v
      when Hash then "{" + v.keys.sort.map { |k| "#{JSON.generate(k)}:#{canonical_json(v[k])}" }.join(",") + "}"
      when Array then "[" + v.map { |x| canonical_json(x) }.join(",") + "]"
      when Integer then v.to_s
      when BigDecimal, Float
        bd = BigDecimal(v.to_s)
        bd.frac.zero? ? bd.to_i.to_s : bd.to_s("F")
      else JSON.generate(v)
      end
    end
  end
end
