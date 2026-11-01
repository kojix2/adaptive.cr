require "./policy"
require "./logger"

module Adaptive
  record Pending, group : String?, sent : Time::Instant, channel : Int32, read_id : String

  class Engine
    getter experiment = Experiment.new
    getter states = {} of Int32 => ReadState
    getter buffered_bytes = 0_i64
    getter inflight_bytes = 0_i64
    @generation = 0_u64
    @counter = 0_u64
    @pending = {} of String => Pending
    @active_jobs = Set(Tuple(Int32, UInt64)).new

    def initialize(@config : Config, @policy : Policy, @log : EventLog,
                   @submit : Job -> Bool, @send : Int32, String, Decision, String -> Nil,
                   @offsets : Array(Float64), @scales : Array(Float64), @sample_rate : Float64)
    end

    def ingest(channel : Int32, id : String, start : UInt64, chunk_start : UInt64, count : UInt64, data : Bytes) : Nil
      raise "unexpected channel" unless (@config.first_channel..@config.last_channel).includes?(channel)
      raise "invalid signal payload" unless count <= 250000 && data.size.to_u64 == count * 2
      state = @states[channel]?
      unless state && state.id == id
        @buffered_bytes -= state.signal.size if state
        @generation += 1
        state = ReadState.new(id, @generation, start)
        @states[channel] = state
      end
      return if state.terminal
      unless start == state.start_sample && chunk_start == state.end_sample
        finish_read(channel, state, Decision.new(Choice::Accept, "signal_gap_or_overlap"))
        return
      end
      if state.samples.to_u64 + count > @config.max_samples || @buffered_bytes + @inflight_bytes + data.size > @config.max_buffer_bytes
        finish_read(channel, state, Decision.new(Choice::Accept, "signal_budget"))
        return
      end
      state.signal.write(data)
      state.end_sample += count
      @buffered_bytes += data.size
    end

    def advance : Nil
      check_ack_deadline
      now = Time.instant
      @states.each do |channel, state|
        next if state.terminal
        if (now - state.created).total_milliseconds >= @config.deadline_ms
          finish_read(channel, state, Decision.new(Choice::Accept, "decision_deadline"))
          next
        end
        next if state.busy || state.samples < @config.min_samples
        next if state.evaluated > 0 && state.samples - state.evaluated < @config.step_samples
        next if @buffered_bytes + @inflight_bytes + state.signal.size > @config.max_buffer_bytes
        next if @active_jobs.size >= @config.workers * 2
        index = channel - @config.first_channel
        job = Job.new(channel, state.id, state.generation, state.signal.to_slice.dup,
          @offsets[index], @scales[index], @sample_rate, state.start_sample, state.created + @config.deadline_ms.milliseconds)
        if @submit.call(job)
          state.busy = true
          @inflight_bytes += job.signal.size
          @active_jobs.add({channel, state.generation})
        end
      end
    end

    def complete(result : Result) : Nil
      check_ack_deadline
      job = result.job
      return unless @active_jobs.delete({job.channel, job.generation})
      @inflight_bytes -= job.signal.size
      state = @states[job.channel]?
      if !state || state.generation != job.generation || state.id != job.read_id || state.terminal
        @log.emit("stale_result", channel: job.channel, read_id: job.read_id)
        return
      end
      state.busy = false
      # A late result must not reject a molecule merely because advance has not
      # yet run its next timer iteration.
      if (Time.instant - state.created).total_milliseconds >= @config.deadline_ms
        finish_read(job.channel, state, Decision.new(Choice::Accept, "decision_deadline"))
        return
      end
      if error = result.error
        @log.emit("worker_error", read_id: job.read_id, error: error)
        finish_read(job.channel, state, Decision.new(Choice::Accept, "worker_error"))
        return
      end
      evidence = result.evidence || raise "worker omitted evidence"
      state.evaluated = evidence.samples
      started = Time.instant
      decision = @policy.decide(evidence, @experiment, state.memory)
      if (Time.instant - state.created).total_milliseconds >= @config.deadline_ms
        decision = Decision.new(Choice::Accept, "decision_deadline")
      end
      @log.emit("evaluation", read_id: job.read_id, channel: job.channel, samples: evidence.samples,
        bases: evidence.sequences.sum(&.size), hits: evidence.hits.size, worker_ms: result.elapsed_ms,
        policy_ms: (Time.instant - started).total_milliseconds, choice: decision.choice.to_s, reason: decision.reason)
      if decision.choice.continue?
        if state.samples >= @config.max_samples
          finish_read(job.channel, state, Decision.new(Choice::Accept, "sample_limit"))
        end
      else
        finish_read(job.channel, state, decision)
      end
    end

    def pending_actions : Int32
      @pending.size
    end

    def acknowledge(id : String, status : Int32) : Nil
      check_ack_deadline
      if pending = @pending.delete(id)
        if group = pending.group
          @experiment.acknowledge(group, status == 0)
        end
        @log.emit("ack", action_id: id, status: status, read_id: pending.read_id,
          channel: pending.channel, latency_ms: (Time.instant - pending.sent).total_milliseconds)
      end
    end

    private def finish_read(channel : Int32, state : ReadState, decision : Decision) : Nil
      return if state.terminal
      # A slow policy or a long ingest/advance iteration can cross an ACK
      # deadline after the public entry point checked it. Check before sending.
      check_ack_deadline
      group = decision.choice.accept? ? decision.group : nil
      if group && !@experiment.reserve(group, decision.limit)
        decision = Decision.new(Choice::Reject, "quota_full")
        group = nil
      end
      state.terminal = true
      samples = state.samples
      @buffered_bytes -= state.signal.size
      state.signal = IO::Memory.new
      @counter += 1
      action_id = "adaptive-#{@counter}"
      @log.emit("decision", action_id: action_id, read_id: state.id, channel: channel,
        choice: decision.choice.to_s, reason: decision.reason, group: group, samples: samples,
        elapsed_ms: (Time.instant - state.created).total_milliseconds, observe: @config.observe)
      if @config.observe
        @experiment.acknowledge(group, true) if group
      else
        raise "too many unacknowledged actions" if @pending.size >= 4096
        @pending[action_id] = Pending.new(group, Time.instant, channel, state.id)
        @send.call(channel, state.id, decision, action_id)
      end
    end

    private def check_ack_deadline : Nil
      # Hash iteration follows insertion order; sends use a monotonic clock.
      # Checking the oldest outstanding action is sufficient and avoids scans
      # on every result or ACK at high channel counts.
      return unless oldest = @pending.first?
      id, pending = oldest
      return if (Time.instant - pending.sent).total_milliseconds < @config.ack_timeout_ms
      # It may already have been applied. Retain its reservation and stop;
      # neither a late ACK nor a subsequent action can hide this timeout.
      raise "action acknowledgment timeout: #{id}"
    end
  end
end
