require "uuid"
require "./types"

module Adaptive
  # A persistent official-client process per worker. Binary ADC bytes follow
  # one JSON header; the response is length-prefixed JSON. No shell execution.
  class Bridge
    @process : Process
    @input : IO::FileDescriptor
    @output : IO::FileDescriptor
    getter info : JSON::Any
    @closed = false

    def initialize(config : Config)
      args = [config.bridge_script, "--address", config.dorado_address, "--model", config.dorado_model,
              "--timeout", (config.bridge_timeout_ms / 1000.0).to_s,
              "--startup-timeout", (config.bridge_startup_timeout_ms / 1000.0).to_s]
      if config.bridge_max_signal_bytes != 500000
        args += ["--max-signal-bytes", config.bridge_max_signal_bytes.to_s]
      end
      if config.bridge_max_response_bytes != 2097152
        args += ["--max-response-bytes", config.bridge_max_response_bytes.to_s]
      end
      @max_signal_bytes = config.bridge_max_signal_bytes
      @max_response_bytes = config.bridge_max_response_bytes
      if fixture = config.fixture_sequence
        args += ["--test-sequence", fixture]
      end
      @process = Process.new(config.python, args, input: Process::Redirect::Pipe,
        output: Process::Redirect::Pipe, error: Process::Redirect::Inherit)
      @input = @process.input.as(IO::FileDescriptor)
      @output = @process.output.as(IO::FileDescriptor)
      @input.write_timeout = config.bridge_timeout_ms.milliseconds
      @output.read_timeout = config.bridge_startup_timeout_ms.milliseconds
      @info = JSON.parse("{}")
      begin
        @info = receive
        raise @info["error"].as_s if @info["error"]?
        raise "unexpected bridge handshake" unless @info["protocol"].as_i == 1
        if format = @info["signal_format"]?
          raise "unsupported bridge signal format" unless format.as_s == SignalFormat::AdcInt16LE.wire_name
        end
        backend = @info["backend"].as_s
        raise "test basecaller prohibited" if backend == "fixture" && !config.allow_test_bridge
        raise "unexpected basecaller backend" unless backend == "dorado" || (backend == "fixture" && config.allow_test_bridge)
        @output.read_timeout = config.bridge_timeout_ms.milliseconds
      rescue ex
        close
        raise ex
      end
    end

    def call(job : Job) : Array(String)
      basecall(job).sequences
    end

    # Full basecall data, including quality and the original molecule identity.
    # call remains a sequence-only compatibility view for existing clients.
    def basecall(job : Job) : BasecallResult
      unless 0 < job.signal.size <= @max_signal_bytes && job.signal.size.even?
        raise ArgumentError.new("signal exceeds configured bridge limit or is not int16 ADC")
      end
      request_id = UUID.random.to_s
      header = {id: request_id, bytes: job.signal.size, offset: job.offset, scale: job.scale,
                sample_rate: job.sample_rate, start_sample: job.start_sample,
                signal_format: job.format.wire_name, segments_only: true}.to_json
      @input.puts(header)
      job.write_signal(@input)
      @input.flush
      response = self.class.read_response(@output, @max_response_bytes, BasecallResponse)
      BasecallResult.from_bridge_response(response, job.read_id, request_id,
        input_samples: job.samples, signal_context: job.context)
    end

    private def receive : JSON::Any
      self.class.read_response(@output, @max_response_bytes)
    end

    def self.read_response(output : IO, max_response_bytes : Int32) : JSON::Any
      read_response(output, max_response_bytes, JSON::Any)
    end

    def self.read_response(output : IO, max_response_bytes : Int32, type : T.class) : T forall T
      size = output.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      raise "bridge response too large" if size > max_response_bytes
      json = String.new(size) do |buffer|
        output.read_fully(Slice.new(buffer, size.to_i))
        {size.to_i, 0}
      end
      pull = JSON::PullParser.new(json)
      response = type.new(pull)
      raise "trailing bridge response data" unless pull.kind.eof?
      response
    end

    def close : Nil
      return if @closed
      @closed = true
      @input.close rescue nil
      done = Channel(Nil).new(1)
      spawn do
        @process.wait
      rescue
      ensure
        done.send(nil)
      end
      select
      when done.receive
      when timeout(250.milliseconds)
        @process.signal(Signal::KILL) rescue nil
        done.receive
      end
    ensure
      @output.close rescue nil
    end
  end
end
