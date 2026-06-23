require "date"
require "time"

module CDX
  module Timestamp
    LOW = "19780101000000"
    HIGH = "29991231235959"
    FORMAT = "%Y%m%d%H%M%S"

    module_function

    def normalize(value, high: false)
      return nil if value.nil?

      string = value.to_s
      unless string.match?(/\A\d{1,14}\z/)
        raise ArgumentError, "invalid CDX timestamp: #{value.inspect}"
      end

      high ? pad_up(string) : pad_down(string)
    end

    def pad_down(value)
      value + LOW[value.length..]
    end

    def pad_up(value)
      padded = value + HIGH[value.length..]
      return padded if value.length > 6

      year = padded[0, 4].to_i
      month = padded[4, 2].to_i
      day = Date.new(year, month, -1).day.to_s.rjust(2, "0")
      "#{padded[0, 6]}#{day}#{padded[8..]}"
    end

    def to_time(value, high: false)
      normalized = normalize(value, high: high)
      Time.strptime(normalized, FORMAT).utc
    end

    def in_range?(timestamp, from: nil, to: nil)
      normalized = normalize(timestamp)
      lower = normalize(from) if from
      upper = normalize(to, high: true) if to

      (!lower || normalized >= lower) && (!upper || normalized <= upper)
    end
  end
end
