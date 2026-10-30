require "minknow"
require "./engine"
require "./pool"

module Adaptive
  class Live
    def initialize(@config : Config, @policy : Policy)
    end

    def run : Nil
      log = EventLog.new(@config.log)
      incoming = Channel(MinknowApi::Data::GetLiveReadsResponse | Exception?).new(8)
      stop = Channel(Nil).new(1)
      outcome = "error"
      [Signal::INT, Signal::TERM].each do |signal|
        signal.trap do
          select
          when stop.send(nil)
          else
          end
        end
      end
      begin
        pool = Pool.new(@config)
        connection = Minknow::ConnectionConfig.new(host: @config.host, port: @config.port,
          tls: @config.tls, ca_certificate_path: @config.ca_file, auto_local_auth: false)
        channel = connection.channel
        offsets, scales, rate = calibration(connection, channel)
        ctx = connection.client_context
        call = Minknow::DataService.new(channel, ctx).live_reads
        call.send(Minknow::DataService.setup_request(first_channel: @config.first_channel,
          last_channel: @config.last_channel, raw_data_type: Minknow::DataService::RawDataType::UNCALIBRATED,
          sample_minimum_chunk_size: @config.min_samples.to_u64))
        log.emit("start", version: VERSION, observe: @config.observe, workers: @config.workers,
          backend: @config.fixture_sequence ? "fixture" : "dorado", model: @config.dorado_model,
          backend_info: pool.backend_info, reference: @config.reference, policy: @config.policy,
          sample_rate: rate, deadline_ms: @config.deadline_ms)
        active_pool = pool
        active_call = call
        sender = ->(number : Int32, id : String, decision : Decision, action_id : String) do
          action = if decision.choice.reject?
                     Minknow::DataService.unblock_action(action_id, number.to_u32, id, 0.1)
                   else
                     Minknow::DataService.stop_action(action_id, number.to_u32, id)
                   end
          active_call.send(Minknow::DataService.actions_request([action]))
        end
        engine = Engine.new(@config, @policy, log, ->(job : Job) { active_pool.submit(job) }, sender, offsets, scales, rate)
        spawn do
          active_call.each { |response| incoming.send(response) }
          status = active_call.status
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
            outcome = "signal"
            break
          when event = incoming.receive
            case event
            when Exception
              raise event
            when MinknowApi::Data::GetLiveReadsResponse
              event.action_responses.each { |ack| engine.acknowledge(ack.action_id, ack.response.raw) }
              event.channels.each do |number, read|
                engine.ingest(number.to_i, read.id, read.start_sample, read.chunk_start_sample, read.chunk_length, read.raw_data)
              end
            else
              outcome = "stream_end"
              break
            end
          when result = active_pool.results.receive
            engine.complete(result)
          when timeout(10.milliseconds)
          end
          engine.advance
        end
      rescue ex
        log.emit("error", error: ex.message || ex.class.to_s) rescue nil
        raise ex
      ensure
        begin
          log.emit("end", outcome: outcome, confirmed: engine.try(&.experiment.confirmed),
            pending: engine.try(&.experiment.reserved), unacknowledged_actions: engine.try(&.pending_actions) || 0)
        ensure
          incoming.close
          begin
            call.try &.cancel
          ensure
            begin
              channel.try &.close
            ensure
              begin
                pool.try &.close
              ensure
                log.close
              end
            end
          end
        end
      end
    end

    private def calibration(connection, channel)
      ctx = connection.client_context
      ctx.deadline = Time.utc + 10.seconds
      device = MinknowApi::Device::DeviceService::Client.new(channel)
      request = MinknowApi::Device::GetCalibrationRequest.new
      request.first_channel = @config.first_channel.to_u32
      request.last_channel = @config.last_channel.to_u32
      calibration = device.get_calibration(request, ctx)
      rate = device.get_sample_rate(MinknowApi::Device::GetSampleRateRequest.new, ctx).sample_rate.to_f64
      count = @config.last_channel - @config.first_channel + 1
      raise "invalid calibration lengths" unless calibration.offsets.size == count && calibration.pa_ranges.size == count
      raise "missing calibration" unless calibration.has_calibration && calibration.digitisation > 0 && rate.finite? && rate > 0
      offsets = calibration.offsets.map(&.to_f64)
      scales = calibration.pa_ranges.map { |range| range.to_f64 / calibration.digitisation }
      raise "invalid calibration values" unless offsets.all?(&.finite?) && scales.all? { |scale| scale.finite? && scale > 0 }
      {offsets, scales, rate}
    end
  end
end
