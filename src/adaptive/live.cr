require "minknow"
require "./engine"
require "./pool"
require "./live_session"

module Adaptive
  class Live
    def initialize(@config : Config, @policy : Policy)
    end

    def run : Nil
      log = EventLog.new(@config.log)
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
        session = LiveSession.new(@config, @policy, log, pool, call, offsets, scales, rate)
        engine = session.engine
        outcome = session.run(stop)
      rescue ex
        log.emit("error", error: ex.message || ex.class.to_s) rescue nil
        raise ex
      ensure
        begin
          log.emit("end", outcome: outcome, confirmed: engine.try(&.experiment.confirmed),
            pending: engine.try(&.experiment.reserved), unacknowledged_actions: engine.try(&.pending_actions) || 0,
            unsent_actions: engine.try(&.unsent_actions) || 0)
        ensure
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
