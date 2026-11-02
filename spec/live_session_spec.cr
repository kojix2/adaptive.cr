require "spec"
require "../src/adaptive/live_session"

private class SessionPool
  getter results = Channel(Adaptive::Result).new(128)
  getter jobs = [] of Adaptive::Job

  def submit(job : Adaptive::Job) : Bool
    @jobs << job
    true
  end
end

private def session_harness(status = GRPC::Status.ok, &)
  config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","last_channel":1,"observe":false}))
  file = File.tempfile("adaptive-session-spec")
  path = file.path
  file.close
  File.delete(path)
  log = Adaptive::EventLog.new(path)
  responses = Channel(Minknow::DataService::LiveResponse | Exception).new(128)
  call = GRPC::BidiCall(Minknow::DataService::LiveRequest, Minknow::DataService::LiveResponse).new(
    ->(_request : Minknow::DataService::LiveRequest) { nil }, -> { nil }, responses,
    status_proc: -> { status })
  pool = SessionPool.new
  session = Adaptive::LiveSession.new(config, Adaptive::BuiltinPolicy.new(config), log, pool, call, [0.0], [1.0], 5000.0)
  begin
    yield session, responses, pool
  ensure
    log.close
    File.delete(path)
  end
end

describe Adaptive::LiveSession do
  it "reports a successful RPC completion" do
    session_harness do |session, responses, _|
      responses.close
      session.run(Channel(Nil).new).should eq("stream_end")
      session.engine.pending_actions.should eq(0)
    end
  end

  it "propagates a non-OK RPC completion" do
    session_harness(GRPC::Status.unavailable("peer unavailable")) do |session, responses, _|
      responses.close
      expect_raises(Exception, /peer unavailable/) { session.run(Channel(Nil).new) }
    end
  end

  it "propagates receive errors" do
    session_harness do |session, responses, _|
      responses.send(IO::Error.new("receive failed"))
      responses.close
      expect_raises(IO::Error, "receive failed") { session.run(Channel(Nil).new) }
    end
  end

  it "honors a stop request while the RPC remains open" do
    session_harness do |session, responses, _|
      stop = Channel(Nil).new(1)
      stop.send(nil)
      session.run(stop).should eq("signal")
      responses.close
    end
  end
end
