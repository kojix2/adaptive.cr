require "./config"
require "minimap2"
require "set"
require "./index"
require "./basecall"
require "./signal"

module Adaptive
  enum Choice
    Continue
    Accept
    Reject
  end
  enum Strand
    Forward
    Reverse
  end

  enum AlignmentClass
    Primary
    Secondary
    Supplementary
    Unknown
  end

  record Mapping,
    target_name : String, mapq : UInt32 = 0_u32,
    target_start : Int32 = 0, target_end : Int32 = 0, target_len : Int32 = 0,
    query_start : Int32 = 0, query_end : Int32 = 0, strand : Strand = Strand::Forward,
    match_len : Int32 = 0, block_len : Int32 = 0, is_primary : Bool = true,
    cigar : Array(Tuple(UInt32, UInt8)) = [] of Tuple(UInt32, UInt8),
    cigar_str : String = "", nm : Int32? = nil,
    md : String? = nil, cs : String? = nil, ds : String? = nil,
    secondary : Bool? = nil, inversion : Bool? = nil do
    include JSON::Serializable

    def self.from_minimap2(mapping : Minimap2::Mapping) : self
      new(target_name: mapping.target_name, mapq: mapping.mapq,
        target_start: mapping.target_start, target_end: mapping.target_end, target_len: mapping.target_len,
        query_start: mapping.query_start, query_end: mapping.query_end,
        strand: mapping.strand.forward? ? Strand::Forward : Strand::Reverse,
        match_len: mapping.match_len, block_len: mapping.block_len, is_primary: mapping.is_primary,
        cigar: mapping.cigar.dup, cigar_str: mapping.cigar_str, nm: mapping.nm,
        md: mapping.md, cs: mapping.cs, ds: mapping.ds,
        secondary: mapping.secondary?, inversion: mapping.inversion?)
    end

    # Legacy non-primary records lack the fact needed to distinguish an
    # alternative mapping from another aligned segment of the same query.
    def classification : AlignmentClass
      return AlignmentClass::Primary if is_primary
      case secondary
      when true  then AlignmentClass::Secondary
      when false then AlignmentClass::Supplementary
      else            AlignmentClass::Unknown
      end
    end

    def secondary? : Bool
      classification.secondary?
    end

    def supplementary? : Bool
      classification.supplementary?
    end

    def validate! : Nil
      raise ArgumentError.new("primary alignment cannot be secondary") if is_primary && secondary == true
      unless 0 <= query_start <= query_end && 0 <= target_start <= target_end <= target_len
        raise ArgumentError.new("invalid alignment coordinates")
      end
    end

    def after_initialize : Nil
      validate!
    end
  end

  record Hit, segment : Int32, mapping : Mapping do
    include JSON::Serializable

    def initialize(@segment : Int32, mapping : Minimap2::Mapping)
      @mapping = Mapping.from_minimap2(mapping)
    end
  end

  record Decision, choice : Choice, reason : String, group : String? = nil, limit : Int32 = 0, hit : Hit? = nil do
    include JSON::Serializable
  end

  enum EvidenceSource
    Sequence
    Basecall
  end

  struct Evidence
    getter channel : Int32
    getter read_id : String
    # Number of input ADC samples evaluated, not aligned bases or a segment's
    # trimmed signal length. Known basecall input_samples must agree.
    getter samples : Int32
    getter hits : Array(Hit)
    getter source : EvidenceSource
    getter basecalls : BasecallResult?
    @sequence_only : Array(String)?

    # Accept legacy sequence+basecall JSON, but retain only the canonical
    # representation. The sequences JSON field is a derived compatibility
    # projection, not an independently retained array.
    private class Payload
      include JSON::Serializable
      getter channel : Int32
      getter read_id : String
      getter samples : Int32
      getter sequences : Array(String)? = nil
      getter hits : Array(Hit)
      getter source : EvidenceSource = EvidenceSource::Sequence
      getter basecalls : BasecallResult? = nil
    end

    def initialize(@channel : Int32, @read_id : String, @samples : Int32, sequences : Array(String),
                   @hits : Array(Hit), @source : EvidenceSource = EvidenceSource::Sequence, @basecalls : BasecallResult? = nil)
      if calls = @basecalls
        raise ArgumentError.new("basecalls do not match evidence") unless calls.matches_sequences?(sequences)
        @sequence_only = nil
      else
        @sequence_only = sequences.dup
      end
      validate!
    end

    def initialize(@channel : Int32, @read_id : String, @samples : Int32, @hits : Array(Hit),
                   @source : EvidenceSource, basecalls : BasecallResult)
      @basecalls = basecalls
      @sequence_only = nil
      validate!
    end

    def initialize(pull : JSON::PullParser)
      payload = Payload.new(pull)
      if sequences = payload.sequences
        initialize(payload.channel, payload.read_id, payload.samples, sequences, payload.hits, payload.source, payload.basecalls)
      elsif calls = payload.basecalls
        initialize(payload.channel, payload.read_id, payload.samples, payload.hits, payload.source, calls)
      else
        raise ArgumentError.new("evidence requires sequences or basecalls")
      end
    end

    def sequences : Array(String)
      if calls = basecalls
        calls.sequences
      else
        @sequence_only.as(Array(String)).dup
      end
    end

    def each_sequence(& : String ->) : Nil
      if calls = basecalls
        calls.each_sequence { |sequence| yield sequence }
      else
        @sequence_only.as(Array(String)).each { |sequence| yield sequence }
      end
    end

    def base_count : Int32
      count = 0
      each_sequence { |sequence| count += sequence.bytesize }
      count
    end

    private def validate! : Nil
      raise ArgumentError.new("invalid evidence metadata") if channel < 1 || read_id.empty? || samples < 0
      if calls = basecalls
        calls.validate!
        unless calls.read_id == read_id && (calls.input_samples.nil? || calls.input_samples == samples)
          raise ArgumentError.new("basecalls do not match evidence")
        end
        count = calls.segments.size
      else
        count = @sequence_only.as(Array(String)).size
      end
      hits.each do |hit|
        raise ArgumentError.new("invalid hit segment index") unless 0 <= hit.segment < count
        hit.mapping.validate!
        length = if calls = basecalls
                   calls.segments[hit.segment].sequence.bytesize
                 else
                   @sequence_only.as(Array(String))[hit.segment].bytesize
                 end
        raise ArgumentError.new("alignment exceeds query segment") if hit.mapping.query_end > length
      end
    end

    def to_json(json : JSON::Builder) : Nil
      json.object do
        json.field "channel", channel
        json.field "read_id", read_id
        json.field "samples", samples
        json.field "hits", hits
        json.field "source", source
        json.field "sequences" do
          json.array { each_sequence(&.to_json(json)) }
        end
        if calls = basecalls
          json.field "basecalls", calls
        end
      end
    end

    def representative_hit(minimum_mapq : UInt32 = 0_u32, primary_only = false) : Hit?
      best : Hit? = nil
      hits.each do |hit|
        next if hit.mapping.mapq < minimum_mapq || (primary_only && !hit.mapping.is_primary)
        best = hit if best.nil? || hit.mapping.mapq > best.mapping.mapq
      end
      best
    end
  end

  record Evaluation, evidence : Evidence, decision : Decision, display_hit : Hit?
  record Job, channel : Int32, read_id : String, generation : UInt64, signal : Bytes | SignalPrefix, context : SignalContext, expires_at : Time::Instant? = nil do
    def initialize(@channel : Int32, @read_id : String, @generation : UInt64,
                   @signal : Bytes | SignalPrefix, @context : SignalContext, @expires_at : Time::Instant? = nil)
      context.validate!
      context.format.samples(signal.size)
      raise ArgumentError.new("invalid job identity") if channel < 1 || read_id.empty?
    end

    # Compatibility constructor; all signal interpretation travels as one
    # context internally rather than as unrelated scalar arguments.
    def initialize(channel : Int32, read_id : String, generation : UInt64, signal : Bytes | SignalPrefix,
                   offset : Float64, scale : Float64, sample_rate : Float64, start_sample : UInt64,
                   expires_at : Time::Instant? = nil)
      initialize(channel, read_id, generation, signal, SignalContext.new(offset, scale, sample_rate, start_sample), expires_at)
    end

    delegate offset, scale, sample_rate, start_sample, format, to: context

    def samples : Int32
      format.samples(signal.size)
    end

    def write_signal(io : IO) : Nil
      case value = signal
      when SignalPrefix
        value.write_to(io)
      when Bytes
        io.write(value)
      end
    end
  end
  record Result, job : Job, evidence : Evidence? = nil, error : String? = nil, elapsed_ms : Float64 = 0.0

  # Owned exclusively by the coordinator. Quotas count accepted/reserved reads,
  # not full-read coverage or completed molecules.
  class Experiment
    getter confirmed = Hash(String, Int32).new(0)
    getter reserved = Hash(String, Int32).new(0)

    def reserve(group : String, limit : Int32) : Bool
      return false if limit > 0 && @confirmed[group] + @reserved[group] >= limit
      @reserved[group] += 1
      true
    end

    def acknowledge(group : String, success : Bool) : Nil
      release(group)
      @confirmed[group] += 1 if success
    end

    def release(group : String) : Nil
      @reserved[group] -= 1
    end
  end

  class ReadState
    getter id : String
    getter generation : UInt64
    getter start_sample : UInt64
    property signal = SignalPrefix.new
    getter created = Time.instant
    property end_sample : UInt64
    property busy = false
    property terminal = false
    property evaluated = 0
    property memory = {} of String => String

    def initialize(@id, @generation, @start_sample)
      @end_sample = @start_sample
    end

    def samples : Int32
      @signal.samples
    end
  end
end
