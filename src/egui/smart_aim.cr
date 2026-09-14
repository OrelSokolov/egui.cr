# Port of egui_upstream/crates/emath/src/smart_aim.rs.
#
# Find the "simplest" number in a closed range — the one with the fewest
# decimal digits. Used when dragging sliders to land on round values.

module Egui
  module SmartAim
    NUM_DECIMALS = 16

    def self.best_in_range_f64(min : Float64, max : Float64) : Float64
      # Avoid NaN if we can:
      return max if min.nan?
      return min if max.nan?

      return best_in_range_f64(max, min) if max < min
      return min if min == max
      return 0.0 if min <= 0.0 && 0.0 <= max # always prefer zero
      return -best_in_range_f64(-max, -min) if min < 0.0

      # 0.0 < min < max here

      # Prefer finite numbers:
      return min unless max.finite?

      min_exponent = Math.log10(min)
      max_exponent = Math.log10(max)

      if min_exponent.floor != max_exponent.floor
        # Different orders of magnitude.
        # Pick the geometric center of the two:
        exponent = (min_exponent + max_exponent) / 2.0
        return 10.0 ** exponent.round.to_i64
      end

      return 10.0 ** min_exponent if integer?(min_exponent)
      return 10.0 ** max_exponent if integer?(max_exponent)

      # Find the proper scale, and then convert to integers:

      scale = NUM_DECIMALS - max_exponent.floor.to_i64 - 1
      scale_factor = 10.0 ** scale

      min_str = to_decimal_string((min * scale_factor).round.to_u64)
      max_str = to_decimal_string((max * scale_factor).round.to_u64)

      # We now have two positive integers of the same length.
      # Find the first non-matching digit (the "deciding digit"):
      # everything before it stays, everything after is zero, and the
      # deciding digit itself is picked as a "smart average".
      #   min:    12345
      #   max:    12780
      #   output: 12500

      ret = StaticArray(UInt8, NUM_DECIMALS).new(0_u8)

      NUM_DECIMALS.times do |i|
        if min_str[i] == max_str[i]
          ret[i] = min_str[i]
        else
          deciding_digit_min = min_str[i]
          deciding_digit_max = max_str[i]

          rest_of_min_is_zeroes = (i + 1...NUM_DECIMALS).all? do |j|
            min_str[j] == 0
          end

          unless rest_of_min_is_zeroes
            # More digits follow `deciding_digit_min`, so we cannot pick
            # it; the true min of what we can pick is one greater:
            deciding_digit_min += 1
          end

          deciding_digit = if deciding_digit_min == 0
            0_u8
          elsif deciding_digit_min <= 5 && 5 <= deciding_digit_max
            5_u8 # 5 is the roundest number in the range
          else
            ((deciding_digit_min + deciding_digit_max) // 2).to_u8
          end

          ret[i] = deciding_digit
          return from_decimal_string(ret).to_f64 / scale_factor
        end
      end

      min # all digits are the same
    end

    def self.integer?(f : Float64) : Bool
      f.round == f
    end

    def self.to_decimal_string(v : UInt64) : StaticArray(UInt8, NUM_DECIMALS)
      ret = StaticArray(UInt8, NUM_DECIMALS).new(0_u8)
      value = v
      (NUM_DECIMALS - 1).step(to: 0, by: -1) do |i|
        ret[i] = (value % 10).to_u8
        value //= 10
      end
      ret
    end

    def self.from_decimal_string(s : StaticArray(UInt8, NUM_DECIMALS)) : UInt64
      value = 0_u64
      NUM_DECIMALS.times do |i|
        value = value * 10 + s[i].to_u64
      end
      value
    end
  end
end
