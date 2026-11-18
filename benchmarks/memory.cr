# Run from the repository root: crystal run --release benchmarks/memory.cr
# GC.stats measures Crystal allocations, not RSS or native/Python allocations.
require "../src/adaptive/engine"
require "../src/adaptive/bridge"

private def measure(name : String, iterations : Int32, &block : -> Int32)
  5.times { block.call }
  GC.collect
  before = GC.stats.total_bytes
  started = Time.instant
  checksum = 0_i64
  iterations.times { checksum += block.call }
  elapsed = (Time.instant - started).total_milliseconds
  allocated = GC.stats.total_bytes - before
  puts({benchmark: name, iterations: iterations, allocated_bytes: allocated,
        bytes_per_iteration: allocated / iterations, elapsed_ms: elapsed, checksum: checksum}.to_json)
end

segment = Adaptive::BasecallSegment.new("A" * 100_000, "I" * 100_000)
measure("quality_validation_100kb", 100) { segment.validate!; segment.sequence.bytesize }

calls = Adaptive::BasecallResult.new("parent", [segment])
canonical = Adaptive::Evidence.new(1, "parent", 0, [] of Adaptive::Hit,
  source: Adaptive::EvidenceSource::Basecall, basecalls: calls)
measure("canonical_evidence_base_count", 10_000) { canonical.base_count }

hits = Array.new(64) { |i| Adaptive::Hit.new(0, Adaptive::Mapping.new("target", mapq: (i % 61).to_u32)) }
evidence = Adaptive::Evidence.new(1, "read", 0, ["ACGT"], hits)
measure("representative_hit_64", 10_000) { evidence.representative_hit.try(&.mapping.mapq.to_i) || 0 }

payload = {id: "request", sequences: [segment.sequence], segments: [segment]}.to_json
frame = IO::Memory.new
frame.write_bytes(payload.bytesize.to_u32, IO::ByteFormat::LittleEndian)
frame << payload
measure("bridge_response_300kb", 100) do
  frame.rewind
  result = Adaptive::Bridge.read_response(frame, 2_097_152, Adaptive::BasecallResponse)
  Adaptive::BasecallResult.from_bridge_response(result, "read", "request").segments.first.sequence.bytesize
end

compact = {id: "request", segments: [segment]}.to_json
compact_frame = IO::Memory.new
compact_frame.write_bytes(compact.bytesize.to_u32, IO::ByteFormat::LittleEndian)
compact_frame << compact
measure("bridge_response_segments_only_200kb", 100) do
  compact_frame.rewind
  result = Adaptive::Bridge.read_response(compact_frame, 2_097_152, Adaptive::BasecallResponse)
  Adaptive::BasecallResult.from_bridge_response(result, "read", "request").segments.first.sequence.bytesize
end

# Keep the old contiguous implementation here as a local reference. Input
# allocations are outside the measurement, as with decoded MinKNOW responses.
chunks = Array.new(10) { Bytes.new(4000, 7_u8) }
measure("legacy_signal_prefix_10x4kb", 1000) do
  buffer = IO::Memory.new
  total = 0
  chunks.each do |chunk|
    buffer.write(chunk)
    total += buffer.to_slice.dup.size
  end
  total
end
measure("shared_signal_prefix_10x4kb", 1000) do
  prefix = Adaptive::SignalPrefix.new
  total = 0
  chunks.each do |chunk|
    prefix = prefix.append(chunk, take_ownership: true)
    total += prefix.size
  end
  total
end

file = File.tempfile("adaptive-memory-benchmark")
path = file.path
file.close
File.delete(path)
log = Adaptive::EventLog.new(path)
begin
  config = Adaptive::Config.from_json({reference: "examples/reference.fa", targets: ["host"],
                                       first_channel: 1, last_channel: 1, min_samples: 100,
                                       max_samples: 20_000, deadline_ms: 600_000}.to_json)
  engine = Adaptive::Engine.new(config, Adaptive::BuiltinPolicy.new(config), log,
    ->(_job : Adaptive::Job) { false },
    ->(_channel : Int32, _id : String, _decision : Adaptive::Decision, _action_id : String) { true },
    [0.0], [0.1], 5000.0)
  engine.ingest(1, "read", 0_u64, 0_u64, 20_000_u64, Bytes.new(40_000))
  measure("rejected_submit_40kb", 1000) { engine.advance; engine.buffered_bytes.to_i }
ensure
  log.close
  File.delete(path)
end
