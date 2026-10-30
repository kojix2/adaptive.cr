require "./bridge"

module Adaptive
  class Pool
    getter results = Channel(Result).new(128)
    getter backend_info = [] of JSON::Any
    @jobs : Channel(Job)
    @done : Channel(Nil)
    @context : Fiber::ExecutionContext::Parallel
    @closed = false

    def initialize(@config : Config)
      @jobs = Channel(Job).new(config.workers)
      @done = Channel(Nil).new(config.workers)
      # Aligner.map allocates its own mm_tbuf per call; index/options remain
      # immutable during mapping. Do not use its finalize method manually.
      aligner = Minimap2::Aligner.new(config.reference, preset: "map-ont", cigar: true, threads: config.workers).validate_targets!(config)
      @context = Fiber::ExecutionContext::Parallel.new("mapping", config.workers)
      ready = Channel(JSON::Any | Exception).new(config.workers)
      config.workers.times do
        @context.spawn do
          begin
            bridge = Bridge.new(config)
            ready.send(bridge.info)
          rescue ex
            ready.send(ex)
            @done.send(nil)
            next
          end
          begin
            while job = @jobs.receive?
              break if @jobs.closed?
              started = Time.instant
              begin
                check_deadline(job)
                bridge ||= Bridge.new(config)
                sequences = bridge.call(job)
                check_deadline(job)
                hits = [] of Hit
                sequences.each_with_index do |sequence, index|
                  next if sequence.empty?
                  aligner.map(sequence).each { |mapping| hits << Hit.new(index, mapping) }
                end
                evidence = Evidence.new(job.channel, job.read_id, job.signal.size // 2, sequences, hits)
                @results.send(Result.new(job, evidence, elapsed_ms: (Time.instant - started).total_milliseconds))
              rescue ex
                bridge.try &.close
                bridge = nil
                @results.send(Result.new(job, error: ex.message || ex.class.to_s))
              end
            end
          rescue Channel::ClosedError
            # Shutdown closes the result channel before waiting for workers.
          ensure
            bridge.try &.close
            @done.send(nil)
          end
        end
      end
      failures = [] of Exception
      config.workers.times do
        case reply = ready.receive
        when Exception
          failures << reply
        when JSON::Any
          @backend_info << reply
        end
      end
      unless failures.empty?
        close
        raise failures.first
      end
    end

    def submit(job : Job) : Bool
      return false if @closed
      select
      when @jobs.send(job)
        true
      else
        false
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      @jobs.close
      @results.close
      @config.workers.times { @done.receive }
    end

    private def check_deadline(job : Job) : Nil
      if expires = job.expires_at
        raise "job deadline exceeded" if Time.instant >= expires
      end
    end
  end
end
