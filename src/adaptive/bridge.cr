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
      request_id = UUID.random.to_s
      header = {id: request_id, bytes: job.signal.size, offset: job.offset, scale: job.scale,
                sample_rate: job.sample_rate, start_sample: job.start_sample}.to_json
      @input.puts(header)
      @input.write(job.signal)
      @input.flush
      result = receive
      raise "basecaller correlation mismatch" unless result["id"].as_s == request_id
      raise result["error"].as_s if result["error"]?
      result["sequences"].as_a.map(&.as_s)
    end

    private def receive : JSON::Any
      size = @output.read_bytes(UInt32, IO::ByteFormat::LittleEndian)
      raise "bridge response too large" if size > 2 * 1024 * 1024
      bytes = Bytes.new(size)
      @output.read_fully(bytes)
      JSON.parse(String.new(bytes))
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
