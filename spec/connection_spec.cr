require "spec"
require "minknow"
require "../src/adaptive/bridge"
require "../src/adaptive/logger"

describe Minknow::ConnectionConfig do
  it "honors explicitly disabled local authentication on localhost" do
    config = Minknow::ConnectionConfig.new(auto_local_auth: false, authentication_token: nil, protocol_token: nil)
    config.local_auth_enabled?.should be_false
    config.effective_metadata.should be_empty
  end

  it "disables automatic lookup even with an environment override while preserving explicit tokens" do
    previous = ENV["MINKNOW_API_USE_LOCAL_TOKEN"]?
    begin
      ENV["MINKNOW_API_USE_LOCAL_TOKEN"] = "true"
      config = Minknow::ConnectionConfig.new(auto_local_auth: false, authentication_token: "explicit", protocol_token: "protocol")
      config.local_auth_enabled?.should be_false
      config.effective_metadata.should eq({"local-auth" => "explicit", "protocol-auth" => "protocol"})
    ensure
      if previous
        ENV["MINKNOW_API_USE_LOCAL_TOKEN"] = previous
      else
        ENV.delete("MINKNOW_API_USE_LOCAL_TOKEN")
      end
    end
  end

  it "serializes a multi-chunk raw signal setup" do
    request = Minknow::DataService.setup_request(first_channel: 3, last_channel: 8,
      raw_data_type: Minknow::DataService::RawDataType::UNCALIBRATED, sample_minimum_chunk_size: 500_u64)
    copy = Minknow::DataService::LiveRequest.decode(request.encode)
    setup = copy.setup.should_not be_nil
    setup.first_channel.should eq(3)
    setup.last_channel.should eq(8)
    setup.sample_minimum_chunk_size.should eq(500)
    setup.raw_data_type.raw.should eq(Minknow::DataService::RawDataType::UNCALIBRATED.value)
    setup.accepted_first_chunk_classifications.should be_empty
  end
end

describe Adaptive::Bridge do
  it "requires opt-in for the synthetic backend" do
    config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","policy":"all","fixture_sequence":"ACGT"}))
    expect_raises(Exception, /fixture mode/) { config.validate! }
    expect_raises(Exception, /test basecaller prohibited/) { Adaptive::Bridge.new(config) }
  end

  it "rejects log replacement rather than truncate existing data" do
    file = File.tempfile("adaptive-existing")
    file.print("retained")
    file.close
    begin
      expect_raises(IO::Error) { Adaptive::EventLog.new(file.path) }
      File.read(file.path).should eq("retained")
    ensure
      File.delete(file.path)
    end
  end
end
