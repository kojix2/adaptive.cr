require "json"

module Adaptive
  enum SignalFormat
    AdcInt16LE

    def wire_name : String
      "adc_int16_le"
    end

    def samples(bytesize : Int32) : Int32
      raise ArgumentError.new("signal must contain whole int16 ADC samples") unless bytesize >= 0 && bytesize.even?
      bytesize // 2
    end

    def self.from_description(*, signed : Bool, bytes : UInt32, big_endian : Bool) : self
      if !signed || bytes != 2 || big_endian
        raise ArgumentError.new("unsupported signal format: expected signed little-endian int16 ADC")
      end
      AdcInt16LE
    end
  end

  # start_sample is absolute in acquisition samples. Calibration converts ADC
  # to pA as (adc + offset) * scale; sample_rate is samples per second.
  record SignalContext, offset : Float64, scale : Float64, sample_rate : Float64, start_sample : UInt64 do
    include JSON::Serializable

    def format : SignalFormat
      SignalFormat::AdcInt16LE
    end

    def validate! : Nil
      unless offset.finite? && scale.finite? && scale > 0 && sample_rate.finite? && sample_rate > 0
        raise ArgumentError.new("invalid signal calibration or sample rate")
      end
    end

    def after_initialize : Nil
      validate!
    end
  end
end
