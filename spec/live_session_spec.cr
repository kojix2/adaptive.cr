require "spec"
require "../src/adaptive/live_session"

private class SessionPool
  getter results = Channel(Adaptive::Result).new(128)
  getter jobs = [] of Adaptive::Job
  property on_submit : (Adaptive::Job -> Nil)?

  def submit(job : Adaptive::Job) : Bool
    @jobs << job
    @on_submit.try &.call(job)
    true
  end
end

private class SessionPeer
  getter responses = Channel(Minknow::DataService::LiveResponse | Exception).new(128)
  getter sent = [] of Minknow::DataService::LiveRequest
  getter attempts = 0
  getter final_status : GRPC::Status? = nil
  property on_send : (Minknow::DataService::LiveRequest -> Nil)?

  def initialize(@status : GRPC::Status)
  end

  def call
    GRPC::BidiCall(Minknow::DataService::LiveRequest, Minknow::DataService::LiveResponse).new(
      ->(request : Minknow::DataService::LiveRequest) { send(request) }, -> { nil }, @responses,
      status_proc: -> { @status }, final_status_proc: -> { @final_status })
  end

  def send(request : Minknow::DataService::LiveRequest) : Nil
    @attempts += 1
    @on_send.try &.call(request)
    if status = @final_status
      raise GRPC::SendClosedError.new(status)
    end
    @sent << request
  end

  def finish(status = @status) : Nil
    @status = status
    @final_status = status
    @responses.close
  end
end

private class SessionPolicy < Adaptive::Policy
  def decide(read : Adaptive::Evidence, experiment : Adaptive::Experiment, memory : Hash(String, String)) : Adaptive::Decision
    Adaptive::Decision.new(Adaptive::Choice::Accept, "target", "virus", 1)
  end
end

private def session_signal(channels = [1])
  response = Minknow::DataService::LiveResponse.new
  channels.each do |channel|
    read = Minknow::DataService::ReadData.new
    read.id = "read-#{channel}"
    read.chunk_length = 100_u64
    read.raw_data = Bytes.new(200)
    response.channels[channel.to_u32] = read
  end
  response
end

private def session_answer(job)
  Adaptive::Result.new(job, Adaptive::Evidence.new(job.channel, job.read_id, 100, ["ACGT"], [] of Adaptive::Hit))
end

private def session_harness(status = GRPC::Status.ok, deadline_ms = 2000, &)
  config = Adaptive::Config.from_json(%({"reference":"examples/reference.fa","last_channel":2,"min_samples":100,"step_samples":100,"max_samples":400,"observe":false}))
  config.deadline_ms = deadline_ms
  file = File.tempfile("adaptive-session-spec")
  path = file.path
  file.close
  File.delete(path)
  log = Adaptive::EventLog.new(path)
  peer = SessionPeer.new(status)
  pool = SessionPool.new
  session = Adaptive::LiveSession.new(config, SessionPolicy.new, log, pool, peer.call, [0.0, 0.0], [1.0, 1.0], 5000.0)
  begin
    yield session, peer, pool, log, path
  ensure
    peer.responses.close
    log.close
    File.delete(path)
  end
end

describe Adaptive::LiveSession do
  it "reports a successful RPC completion" do
    session_harness do |session, peer, _, _, _|
      peer.finish
      session.run(Channel(Nil).new).should eq("stream_end")
      session.engine.pending_actions.should eq(0)
    end
  end

  it "propagates a non-OK RPC completion" do
    session_harness(GRPC::Status.unavailable("peer unavailable")) do |session, peer, _, _, _|
      peer.finish
      expect_raises(Exception, /peer unavailable/) { session.run(Channel(Nil).new) }
    end
  end

  it "propagates receive errors" do
    session_harness do |session, peer, _, _, _|
      peer.responses.send(IO::Error.new("receive failed"))
      peer.finish
      expect_raises(IO::Error, "receive failed") { session.run(Channel(Nil).new) }
    end
  end

  it "honors a stop request while the RPC remains open" do
    session_harness do |session, peer, _, _, _|
      stop = Channel(Nil).new(1)
      stop.send(nil)
      session.run(stop).should eq("signal")
      peer.finish
    end
  end

  it "ignores worker results and queued signal after observed RPC completion" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal)
      pool.on_submit = ->(job : Adaptive::Job) {
        peer.responses.send(session_signal([999]))
        peer.finish
        pool.results.send(session_answer(job))
        nil
      }
      session.run(Channel(Nil).new).should eq("stream_end")
      peer.attempts.should eq(0)
      session.engine.pending_actions.should eq(0)
      session.engine.experiment.confirmed["virus"].should eq(0)
    end
  end

  it "rolls back an unsent accept when completion races with sending" do
    session_harness do |session, peer, pool, log, path|
      peer.responses.send(session_signal)
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) { peer.finish }
      session.run(Channel(Nil).new).should eq("stream_end")
      peer.attempts.should eq(1)
      peer.sent.should be_empty
      session.engine.unsent_actions.should eq(1)
      session.engine.pending_actions.should eq(0)
      session.engine.experiment.reserved["virus"].should eq(0)
      session.engine.experiment.confirmed["virus"].should eq(0)
      log.close
      events = File.read(path).lines.map { |line| JSON.parse(line) }
      events.count { |row| row["event"] == "decision" }.should eq(1)
      events.count { |row| row["event"] == "action_unsent" }.should eq(1)
      events.any? { |row| row["event"] == "ack" }.should be_false
    end
  end

  it "stops sends originating in signal ingestion when completion races with them" do
    session_harness do |session, peer, _, _, _|
      response = session_signal([1, 2])
      response.channels[1_u32].chunk_start_sample = 1_u64
      response.channels[2_u32].chunk_start_sample = 1_u64
      peer.responses.send(response)
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) { peer.finish }
      session.run(Channel(Nil).new).should eq("stream_end")
      peer.attempts.should eq(1)
      session.engine.unsent_actions.should eq(1)
      session.engine.pending_actions.should eq(0)
    end
  end

  it "stops a deadline fallback batch when completion races with the first send" do
    session_harness(deadline_ms: 1) do |session, peer, pool, _, _|
      session_signal([1, 2]).channels.each do |channel, read|
        session.engine.ingest(channel.to_i, read.id, read.start_sample, read.chunk_start_sample, read.chunk_length, read.raw_data)
      end
      # No responses or worker results are ready: the coordinator's 10 ms timer
      # reaches both deadlines, without a sleep or a race in the test setup.
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) { peer.finish }
      session.run(Channel(Nil).new).should eq("stream_end")
      peer.attempts.should eq(1)
      pool.jobs.should be_empty
      session.engine.unsent_actions.should eq(1)
      session.engine.pending_actions.should eq(0)
    end
  end

  it "drains queued ACKs after a competing send discovers RPC completion" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal([1, 2]))
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) {
        if peer.attempts == 2
          ack = Minknow::DataService::ActionResponse.new
          actions = peer.sent.first.actions || raise "missing actions"
          ack.action_id = actions.actions.first.action_id
          response = session_signal([999])
          response.action_responses << ack
          peer.responses.send(response)
          peer.finish
        end
      }
      session.run(Channel(Nil).new).should eq("stream_end")
      peer.attempts.should eq(2)
      peer.sent.size.should eq(1)
      session.engine.unsent_actions.should eq(1)
      session.engine.pending_actions.should eq(0)
      session.engine.experiment.confirmed["virus"].should eq(1)
      session.engine.experiment.reserved["virus"].should eq(0)
    end
  end

  it "retains reservations for queued actions without an ACK at completion" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal([1, 2]))
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) {
        peer.finish if peer.attempts == 2
      }
      session.run(Channel(Nil).new).should eq("stream_end")
      session.engine.pending_actions.should eq(1)
      session.engine.unsent_actions.should eq(1)
      session.engine.experiment.confirmed["virus"].should eq(0)
      session.engine.experiment.reserved["virus"].should eq(1)
    end
  end

  it "reports a non-OK completion that races with sending" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal)
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) {
        peer.finish(GRPC::Status.unavailable("device disconnected"))
      }
      expect_raises(Exception, /device disconnected/) { session.run(Channel(Nil).new) }
      session.engine.unsent_actions.should eq(1)
      session.engine.pending_actions.should eq(0)
      session.engine.experiment.reserved["virus"].should eq(0)
    end
  end

  it "does not suppress unrelated CANCELLED send errors even with an OK final status" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal)
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = ->(_request : Minknow::DataService::LiveRequest) {
        peer.finish
        raise GRPC::StatusError.new(GRPC::StatusCode::CANCELLED, "other send failure")
      }
      expect_raises(GRPC::StatusError, "other send failure") { session.run(Channel(Nil).new) }
      session.engine.unsent_actions.should eq(0)
      session.engine.pending_actions.should eq(1)
      session.engine.experiment.reserved["virus"].should eq(1)
    end
  end

  it "does not suppress a local request half-close" do
    session_harness do |session, peer, pool, _, _|
      peer.responses.send(session_signal)
      pool.on_submit = ->(job : Adaptive::Job) { pool.results.send(session_answer(job)); nil }
      peer.on_send = Proc(Minknow::DataService::LiveRequest, Nil).new { |_request| raise GRPC::SendClosedError.new }
      expect_raises(GRPC::SendClosedError) { session.run(Channel(Nil).new) }
    end
  end
end
