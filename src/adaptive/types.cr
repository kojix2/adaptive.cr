require "./config"
require "minimap2"
require "set"
require "./index"

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

  # A value snapshot; callers never need minimap2's types or native pointers.
  # Non-primary includes both secondary and supplementary alignments: the
  # binding does not expose enough information to distinguish those two.
  record Mapping,
    target_name : String, mapq : UInt32 = 0_u32,
    target_start : Int32 = 0, target_end : Int32 = 0, target_len : Int32 = 0,
    query_start : Int32 = 0, query_end : Int32 = 0, strand : Strand = Strand::Forward,
    match_len : Int32 = 0, block_len : Int32 = 0, is_primary : Bool = true,
    cigar : Array(Tuple(UInt32, UInt8)) = [] of Tuple(UInt32, UInt8),
    cigar_str : String = "", nm : Int32 = 0,
    md : String? = nil, cs : String? = nil, ds : String? = nil do
    def self.from_minimap2(mapping : Minimap2::Mapping) : self
      new(target_name: mapping.target_name, mapq: mapping.mapq,
        target_start: mapping.target_start, target_end: mapping.target_end, target_len: mapping.target_len,
        query_start: mapping.query_start, query_end: mapping.query_end,
        strand: mapping.strand.forward? ? Strand::Forward : Strand::Reverse,
        match_len: mapping.match_len, block_len: mapping.block_len, is_primary: mapping.is_primary,
        cigar: mapping.cigar.dup, cigar_str: mapping.cigar_str, nm: mapping.nm,
        md: mapping.md, cs: mapping.cs, ds: mapping.ds)
    end
  end

  record Hit, segment : Int32, mapping : Mapping do
    # Compatibility for existing custom policies that construct evidence.
    def initialize(@segment : Int32, mapping : Minimap2::Mapping)
      @mapping = Mapping.from_minimap2(mapping)
    end
  end

  record Decision, choice : Choice, reason : String, group : String? = nil, limit : Int32 = 0, hit : Hit? = nil

  enum EvidenceSource
    Sequence
    Basecall
  end

  record Evidence, channel : Int32, read_id : String, samples : Int32, sequences : Array(String), hits : Array(Hit), source : EvidenceSource = EvidenceSource::Sequence do
    def representative_hit(minimum_mapq : UInt32 = 0_u32, primary_only = false) : Hit?
      hits.select { |hit| hit.mapping.mapq >= minimum_mapq && (!primary_only || hit.mapping.is_primary) }
        .max_by?(&.mapping.mapq)
    end
  end

  record Evaluation, evidence : Evidence, decision : Decision, display_hit : Hit?
  record Job, channel : Int32, read_id : String, generation : UInt64, signal : Bytes, offset : Float64, scale : Float64, sample_rate : Float64, start_sample : UInt64, expires_at : Time::Instant? = nil
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
    property signal = IO::Memory.new
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
      @signal.size // 2
    end
  end
end
