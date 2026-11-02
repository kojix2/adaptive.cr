require "minknow"
require "./engine"

module Adaptive
  # Coordinates an established RPC and worker pool. Resource acquisition and
  # cleanup belong to Live; keeping the loop here also permits controlled peers.
  class LiveSession(P, C)
    getter engine : Engine

    def initialize(config : Config, policy : Policy, log : EventLog, @pool : P, @call : C,
                   offsets : Array(Float64), scales : Array(Float64), rate : Float64)
      sender = ->(number : Int32, id : String, decision : Decision, action_id : String) do
        action = if decision.choice.reject?
                   Minknow::DataService.unblock_action(action_id, number.to_u32, id, 0.1)
                 else
                   Minknow::DataService.stop_action(action_id, number.to_u32, id)
                 end
        @call.send(Minknow::DataService.actions_request([action]))
      end
      @engine = Engine.new(config, policy, log, ->(job : Job) { @pool.submit(job) }, sender, offsets, scales, rate)
    end

    def run(stop : Channel(Nil)) : String
      incoming = Channel(MinknowApi::Data::GetLiveReadsResponse | Exception?).new(8)
      spawn do
        @call.each { |response| incoming.send(response) }
        status = @call.status
        raise "live stream failed: #{status}" unless status.ok?
        incoming.send(nil)
      rescue ex
        begin
          incoming.send(ex)
        rescue Channel::ClosedError
        end
      end
      loop do
        select
        when stop.receive
          return "signal"
        when event = incoming.receive
          case event
          when Exception
            raise event
          when MinknowApi::Data::GetLiveReadsResponse
            event.action_responses.each { |ack| @engine.acknowledge(ack.action_id, ack.response.raw) }
            event.channels.each do |number, read|
              @engine.ingest(number.to_i, read.id, read.start_sample, read.chunk_start_sample, read.chunk_length, read.raw_data)
            end
          else
            return "stream_end"
          end
        when result = @pool.results.receive
          @engine.complete(result)
        when timeout(10.milliseconds)
        end
        @engine.advance
      end
    ensure
      incoming.try &.close
    end
  end
end
