require "./signal_format"

module Adaptive
  # An immutable prefix of owned ADC chunks. Appending creates one new link;
  # earlier snapshots remain valid while the coordinator receives more data.
  # GC keeps shared chunks alive across read replacement and late results.
  struct SignalPrefix
    private class Chunk
      getter bytes : Bytes
      getter previous : Chunk?

      def initialize(bytes : Bytes, @previous : Chunk?)
        @bytes = Slice.new(bytes.to_unsafe, bytes.size, read_only: true)
      end
    end

    @tail : Chunk?
    getter size : Int32
    getter chunk_count : Int32

    def initialize
      @tail = nil
      @size = 0
      @chunk_count = 0
    end

    def initialize(@tail : Chunk, @size : Int32, @chunk_count : Int32)
    end

    # The default isolates callers that may reuse or mutate their input buffer.
    # take_ownership requires an exact owned allocation that will never be
    # modified again; do not pass a view into a reusable transport buffer.
    def append(bytes : Bytes, *, take_ownership : Bool = false) : self
      format.samples(bytes.size)
      return self if bytes.empty?
      owned = take_ownership ? bytes : bytes.dup
      self.class.new(Chunk.new(owned, @tail), @size + bytes.size, @chunk_count + 1)
    end

    def format : SignalFormat
      SignalFormat::AdcInt16LE
    end

    def samples : Int32
      format.samples(size)
    end

    def each_chunk(& : Bytes ->) : Nil
      return unless tail = @tail
      unless tail.previous
        yield tail.bytes
        return
      end
      chunks = Array(Bytes).new(@chunk_count)
      cursor = tail.as(Chunk?)
      while chunk = cursor
        chunks << chunk.bytes
        cursor = chunk.previous
      end
      chunks.reverse_each { |bytes| yield bytes }
    end

    # Send scatter/gather data without materializing a contiguous signal copy.
    def write_to(io : IO) : Nil
      each_chunk { |bytes| io.write(bytes) }
    end

    # Explicit compatibility conversion for consumers that require contiguous
    # bytes. The live bridge uses write_to instead.
    def to_slice : Bytes
      bytes = Bytes.new(@size)
      offset = 0
      each_chunk do |chunk|
        bytes[offset, chunk.size].copy_from(chunk)
        offset += chunk.size
      end
      Slice.new(bytes.to_unsafe, bytes.size, read_only: true)
    end
  end
end
