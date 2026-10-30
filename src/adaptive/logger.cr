require "json"

module Adaptive
  class EventLog
    @queue = Channel(String).new(1024)
    @done = Channel(Exception?).new(1)
    @closed = false

    def initialize(path : String)
      fd = LibC.open(path, LibC::O_WRONLY | LibC::O_CREAT | LibC::O_EXCL | LibC::O_CLOEXEC, 0o600)
      raise IO::Error.from_errno("Cannot create audit log #{path}") if fd < 0
      file = IO::FileDescriptor.new(fd)
      IO::FileDescriptor.set_blocking(fd, true)
      context = Fiber::ExecutionContext::Parallel.new("audit", 1)
      context.spawn do
        error = nil
        begin
          while line = @queue.receive?
            file.puts(line)
            file.flush
          end
        rescue ex
          error = ex
          @queue.close
        ensure
          begin
            file.close
          rescue ex
            error ||= ex
          end
          @done.send(error)
        end
      end
    end

    def emit(event : String, **fields) : Nil
      line = {time: Time.utc.to_rfc3339, event: event}.merge(fields).to_json
      select
      when @queue.send(line)
      else
        raise "audit log cannot keep up"
      end
    end

    def close : Nil
      return if @closed
      @closed = true
      @queue.close
      if error = @done.receive
        raise error
      end
    end
  end
end
