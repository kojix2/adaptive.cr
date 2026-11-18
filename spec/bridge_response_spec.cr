require "spec"
require "../src/adaptive/bridge"

private def bridge_frame(value)
  io = IO::Memory.new
  json = value.to_json
  io.write_bytes(json.bytesize.to_u32, IO::ByteFormat::LittleEndian)
  io << json
  io.rewind
  io
end

describe Adaptive::Bridge do
  it "reads exactly one bounded response and preserves subsequent frames" do
    io = IO::Memory.new
    io.write(bridge_frame({id: "one"}).to_slice)
    io.write(bridge_frame({id: "two"}).to_slice)
    io.rewind
    Adaptive::Bridge.read_response(io, 1024)["id"].as_s.should eq("one")
    Adaptive::Bridge.read_response(io, 1024)["id"].as_s.should eq("two")
  end

  it "rejects oversized and truncated frames before parsing" do
    oversized = IO::Memory.new
    oversized.write_bytes(1025_u32, IO::ByteFormat::LittleEndian)
    oversized.rewind
    expect_raises(Exception, /too large/) { Adaptive::Bridge.read_response(oversized, 1024) }
    truncated = IO::Memory.new
    truncated.write_bytes(10_u32, IO::ByteFormat::LittleEndian)
    truncated << "{}"
    truncated.rewind
    expect_raises(IO::EOFError) { Adaptive::Bridge.read_response(truncated, 1024) }
  end

  it "preserves the complete UInt64 timing domain through the production frame decoder" do
    json = %({"id":"request","segments":[{"sequence":"ACGT","native_timing":{"start_time":#{UInt64::MAX},"duration":0}}]})
    io = IO::Memory.new
    io.write_bytes(json.bytesize.to_u32, IO::ByteFormat::LittleEndian)
    io << json
    io.rewind
    response = Adaptive::Bridge.read_response(io, 1024, Adaptive::BasecallResponse)
    calls = Adaptive::BasecallResult.from_bridge_response(response, "parent", "request")
    timing = calls.segments.first.native_timing.should_not be_nil
    timing.start_time.should eq(UInt64::MAX)
    Adaptive::BasecallResult.from_json(calls.to_json).should eq(calls)
  end

  it "rejects multiple JSON values within one frame" do
    json = %({"id":"request","sequences":["ACGT"]}{"id":"extra"})
    io = IO::Memory.new
    io.write_bytes(json.bytesize.to_u32, IO::ByteFormat::LittleEndian)
    io << json
    io.rewind
    expect_raises(JSON::ParseException) { Adaptive::Bridge.read_response(io, 1024, Adaptive::BasecallResponse) }
  end

  it "basecalls successive chunked and flat jobs through the persistent pipe" do
    config = Adaptive::Config.from_json({reference: "examples/reference.fa", targets: ["virus"],
                                         fixture_sequence: "ACGT", allow_test_bridge: true}.to_json)
    bridge = Adaptive::Bridge.new(config)
    begin
      signal = Adaptive::SignalPrefix.new.append(Bytes[1, 2]).append(Bytes[3, 4, 5, 6])
      chunked = Adaptive::Job.new(1, "chunked", 0_u64, signal, 0.0, 1.0, 5000.0, 0_u64)
      flat = chunked.copy_with(read_id: "flat", signal: Bytes[7, 8])
      [chunked, flat, chunked].each do |job|
        result = bridge.basecall(job)
        result.read_id.should eq(job.read_id)
        result.sequences.should eq(["ACGT"])
      end
    ensure
      bridge.close
    end
  end
end

describe Adaptive::BasecallResult do
  it "shares parsed strings and preserves split and empty segment positions" do
    response = Adaptive::BasecallResponse.from_json(%({"id":"request","segments":[{"sequence":"ACGT","quality":"IIII","read_id":"child"},{"sequence":""}]}))
    result = Adaptive::BasecallResult.from_bridge_response(response, "parent", "request")
    result.sequences.should eq(["ACGT", ""])
    result.segments.first.sequence.same?(response.segments.as(Array(Adaptive::BasecallSegment))[0].sequence).should be_true
    quality = result.segments.first.quality.should_not be_nil
    quality.same?(response.segments.as(Array(Adaptive::BasecallSegment))[0].quality.as(String)).should be_true
    result.segments.first.read_id.should eq("child")
    result.segments.last.quality.should be_nil
  end

  it "accepts legacy responses and checks compatibility fields when present" do
    legacy = Adaptive::BasecallResponse.from_json(%({"id":"request","sequences":["ACGT",""]}))
    Adaptive::BasecallResult.from_bridge_response(legacy, "parent", "request").sequences.should eq(["ACGT", ""])
    matching = Adaptive::BasecallResponse.from_json(%({"id":"request","sequences":["ACGT"],"segments":[{"sequence":"ACGT","quality":null,"read_id":null}]}))
    Adaptive::BasecallResult.from_bridge_response(matching, "parent", "request").segments.first.quality.should be_nil
    ["[]", "[\"TTTT\"]", "[\"ACGT\",\"\"]"].each do |sequences|
      mismatch = Adaptive::BasecallResponse.from_json(%({"id":"request","sequences":#{sequences},"segments":[{"sequence":"ACGT"}]}))
      expect_raises(Exception, /segment mismatch/) do
        Adaptive::BasecallResult.from_bridge_response(mismatch, "parent", "request")
      end
    end
  end

  it "rejects malformed optional fields, invalid bases, correlation and backend errors" do
    ["{\"sequence\":\"ACGT\",\"quality\":42}", "{\"sequence\":\"ACGT\",\"read_id\":false}",
     "{\"sequence\":\"ACGT\",\"quality\":\"III\"}", "{\"sequence\":\"BAD\"}", "{}"].each do |segment|
      expect_raises(Exception) do
        response = Adaptive::BasecallResponse.from_json(%({"id":"request","segments":[#{segment}]}))
        Adaptive::BasecallResult.from_bridge_response(response, "parent", "request")
      end
    end
    expect_raises(Exception, /correlation/) do
      Adaptive::BasecallResult.from_bridge_response(Adaptive::BasecallResponse.from_json(%({"id":"other","sequences":[]})), "parent", "request")
    end
    expect_raises(Exception, /queue full/) do
      Adaptive::BasecallResult.from_bridge_response(Adaptive::BasecallResponse.from_json(%({"id":"request","error":"queue full"})), "parent", "request")
    end
  end
end
