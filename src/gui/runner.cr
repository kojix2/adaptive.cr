require "file/tempfile"

module NanoporeGUI
  # Process output can be unbounded during sequencing; retain only a small tail.
  class LogBuffer < IO
    LIMIT = 65_536
    getter generation = 0_u64
    getter text = ""

    def read(slice : Bytes) : Int32
      raise IO::Error.new("write-only log")
    end

    def write(slice : Bytes) : Nil
      combined = @text + String.new(slice).scrub
      @text = combined.bytesize > LIMIT ? combined.byte_slice(combined.bytesize - LIMIT, LIMIT).scrub : combined
      @generation += 1
    end
  end

  class Runner
    getter log = LogBuffer.new
    getter status = "Ready"
    getter exit_code : Int32?
    getter snapshot_path : String?
    @process : Process?
    @busy = false

    def busy? : Bool
      @busy
    end

    def start(executable : String, args : Array(String), config : String, directory : String)
      raise "A process is already running" if busy?
      raise "Working directory does not exist: #{directory}" unless Dir.exists?(directory)
      @exit_code = nil
      @log = LogBuffer.new
      snapshot = File.tempfile("nanopore-gui-", ".json")
      @snapshot_path = snapshot.path
      begin
        snapshot << config
        snapshot.close
        process = Process.new(executable, ["-c", snapshot.path] + args,
          chdir: directory, input: Process::Redirect::Close, output: @log, error: @log,
          env: {"PYTHONUNBUFFERED" => "1"})
        @process = process
        @busy = true
        @status = "Running"
        spawn do
          result = process.wait
          @exit_code = result.exit_code
          @status = "Finished (#{result})"
        rescue error
          @status = "Process error: #{error.message}"
        ensure
          File.delete?(snapshot.path)
          @snapshot_path = nil
          @process = nil
          @busy = false
        end
      rescue error
        snapshot.close
        File.delete?(snapshot.path)
        @snapshot_path = nil
        @status = "Could not start: #{error.message}"
        raise error
      end
    end

    def stop
      if process = @process
        process.terminate
        @status = "Stopping…"
      end
    rescue IO::Error
      # A child may exit between the click and signal delivery; wait still reaps it.
    end
  end
end
