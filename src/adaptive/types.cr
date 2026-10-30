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
  record Decision, choice : Choice, reason : String, group : String? = nil, limit : Int32 = 0
  record Hit, segment : Int32, mapping : Minimap2::Mapping
  record Evidence, channel : Int32, read_id : String, samples : Int32, sequences : Array(String), hits : Array(Hit)
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
      @reserved[group] -= 1
      @confirmed[group] += 1 if success
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
