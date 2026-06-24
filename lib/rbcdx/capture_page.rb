module CDX
  class CapturePage
    include Enumerable

    attr_reader :captures, :next_cursor

    def initialize(captures, next_cursor:)
      @captures = Array(captures).freeze
      @next_cursor = next_cursor
      freeze
    end

    def each(&block)
      return captures.each unless block

      captures.each(&block)
      self
    end

    def exhausted?
      next_cursor.nil?
    end

    def empty?
      captures.empty?
    end

    def length
      captures.length
    end
    alias_method :size, :length
  end
end
