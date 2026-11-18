require "json"
require "./signal_format"

module Adaptive
  # Zero-based half-open sample interval relative to the submitted parent
  # signal. This is neither an acquisition timestamp nor a base coordinate.
  class SampleInterval
    include JSON::Serializable
    getter start_sample : UInt64
    getter end_sample : UInt64

    def initialize(@start_sample, @end_sample)
      validate!
    end

    def validate! : Nil
      raise ArgumentError.new("reversed signal interval") if end_sample < start_sample
    end

    def after_initialize : Nil
      validate!
    end

    def_equals_and_hash @start_sample, @end_sample
  end

  # Original sample-valued fields from the pinned native client. Preserve them
  # without assuming how splitting/trimming transforms their coordinate frame.
  # They do not by themselves establish a parent-relative signal_span.
  class NativeSignalTiming
    include JSON::Serializable
    getter start_time : UInt64? = nil
    getter duration : UInt64? = nil
    getter trimmed_samples : UInt64? = nil
    getter trimmed_duration : UInt64? = nil

    def initialize(@start_time = nil, @duration = nil, @trimmed_samples = nil, @trimmed_duration = nil)
    end

    def_equals_and_hash @start_time, @duration, @trimmed_samples, @trimmed_duration
  end

  # Segment positions match Hit#segment. Missing quality remains nil; sequence
  # fixtures and older adapters must never acquire invented quality values.
  record BasecallSegment, sequence : String, quality : String? = nil, read_id : String? = nil,
    signal_span : SampleInterval? = nil, native_timing : NativeSignalTiming? = nil do
    include JSON::Serializable

    def validate! : Nil
      raise ArgumentError.new("invalid basecall sequence") unless sequence.matches?(/\A[ACGTNacgtn]*\z/)
      if value = quality
        raise ArgumentError.new("basecall quality length mismatch") unless value.bytesize == sequence.bytesize
        raise ArgumentError.new("invalid basecall quality") unless value.to_slice.all? { |byte| (33..126).includes?(byte) }
      end
      signal_span.try &.validate!
      if (span = signal_span) && span.start_sample == span.end_sample && !sequence.empty?
        raise ArgumentError.new("nonempty sequence requires a nonempty signal interval")
      end
    end

    def after_initialize : Nil
      validate!
    end
  end

  # Decode sample positions directly as UInt64. JSON::Any restricts integers
  # to Int64 and cannot represent the complete signal-coordinate domain.
  class BasecallResponse
    include JSON::Serializable
    getter id : String
    getter error : String? = nil
    getter segments : Array(BasecallSegment)? = nil
    getter sequences : Array(String)? = nil
  end

  record BasecallResult, read_id : String, segments : Array(BasecallSegment),
    input_samples : Int32? = nil, signal_context : SignalContext? = nil do
    include JSON::Serializable

    def initialize(@read_id : String, segments : Array(BasecallSegment), @input_samples : Int32? = nil,
                   @signal_context : SignalContext? = nil)
      @segments = segments.dup
      validate!
    end

    # Callers cannot reorder/replace the canonical segments through this view.
    def segments : Slice(BasecallSegment)
      Slice.new(@segments.to_unsafe, @segments.size, read_only: true)
    end

    def self.from_bridge_response(result : BasecallResponse, read_id : String, request_id : String, *,
                                  input_samples : Int32? = nil, signal_context : SignalContext? = nil) : self
      raise "basecaller correlation mismatch" unless result.id == request_id
      raise error if error = result.error
      segments = result.segments || result.sequences.try(&.map { |sequence| BasecallSegment.new(sequence) })
      raise "basecaller omitted segments and sequences" unless segments
      basecalls = new(read_id, segments, input_samples, signal_context)
      if sequences = result.sequences
        raise "basecaller segment mismatch" unless basecalls.matches_sequences?(sequences)
      end
      basecalls
    end

    def sequences : Array(String)
      @segments.map(&.sequence)
    end

    def each_sequence(& : String ->) : Nil
      @segments.each { |segment| yield segment.sequence }
    end

    def matches_sequences?(sequences : Array(String)) : Bool
      @segments.size == sequences.size && @segments.each_with_index.all? { |segment, i| segment.sequence == sequences[i] }
    end

    def validate! : Nil
      raise ArgumentError.new("empty basecall read identifier") if read_id.empty?
      raise ArgumentError.new("negative input sample count") if input_samples.try { |count| count < 0 }
      signal_context.try &.validate!
      @segments.each do |segment|
        segment.validate!
        if (span = segment.signal_span) && (count = input_samples)
          raise ArgumentError.new("segment signal interval exceeds input prefix") if span.end_sample > count.to_u64
        end
      end
    end

    def after_initialize : Nil
      validate!
    end
  end
end
