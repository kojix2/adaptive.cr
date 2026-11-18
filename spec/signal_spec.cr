require "spec"
require "../src/adaptive/types"

describe Adaptive::SignalPrefix do
  it "copies borrowed input and keeps earlier prefixes unchanged" do
    bytes = Bytes[1, 2]
    prefix = Adaptive::SignalPrefix.new.append(bytes)
    bytes[0] = 9
    extended = prefix.append(Bytes[3, 4])
    prefix.to_slice.should eq(Bytes[1, 2])
    extended.to_slice.should eq(Bytes[1, 2, 3, 4])
    prefix.chunk_count.should eq(1)
    extended.chunk_count.should eq(2)
  end

  it "transfers owned allocations and exposes only read-only chunks" do
    bytes = Bytes[1, 2]
    signal = Adaptive::SignalPrefix.new.append(bytes, take_ownership: true)
    signal.each_chunk do |chunk|
      chunk.to_unsafe.should eq(bytes.to_unsafe)
      chunk.read_only?.should be_true
    end
    signal.to_slice.read_only?.should be_true
  end

  it "writes many small chunks in order without recursion or empty links" do
    signal = Adaptive::SignalPrefix.new.append(Bytes.empty)
    signal.chunk_count.should eq(0)
    4096.times { |i| signal = signal.append(Bytes[(i % 256).to_u8, (i % 256).to_u8]) }
    io = IO::Memory.new
    signal.write_to(io)
    io.to_slice.should eq(Bytes.new(8192) { |i| (i // 2 % 256).to_u8 })
    signal.size.should eq(8192)
    signal.samples.should eq(4096)
  end

  it "shares stable prefixes with a concurrent writer of later chunks" do
    signal = Adaptive::SignalPrefix.new.append(Bytes.new(200, 7_u8))
    prefix = signal
    context = Fiber::ExecutionContext::Parallel.new("signal-spec", 1)
    done = Channel(Bool | Exception).new(1)
    context.spawn do
      100.times do
        GC.collect
        io = IO::Memory.new
        prefix.write_to(io)
        raise "changed prefix" unless io.to_slice == Bytes.new(200, 7_u8)
      end
      done.send(true)
    rescue ex
      done.send(ex)
    end
    1000.times { signal = signal.append(Bytes[8, 9]) }
    result = done.receive
    raise result if result.is_a?(Exception)
    result.should be_true
    signal.size.should eq(2200)
    prefix.size.should eq(200)
  end

  it "sends both flat and chunked jobs as identical ADC bytes" do
    flat = Adaptive::Job.new(1, "read", 0_u64, Bytes[1, 2, 3, 4], 0.0, 1.0, 5000.0, 0_u64)
    signal = Adaptive::SignalPrefix.new.append(Bytes[1, 2]).append(Bytes[3, 4])
    chunked = flat.copy_with(signal: signal)
    [flat, chunked].each do |job|
      io = IO::Memory.new
      job.write_signal(io)
      io.to_slice.should eq(Bytes[1, 2, 3, 4])
    end
  end
end
