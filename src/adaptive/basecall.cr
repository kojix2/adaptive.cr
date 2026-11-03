require "json"

module Adaptive
  # Segment positions match Hit#segment. Missing quality remains nil; sequence
  # fixtures and older adapters must never acquire invented quality values.
  record BasecallSegment, sequence : String, quality : String? = nil, read_id : String? = nil do
    include JSON::Serializable

    def validate! : Nil
      raise ArgumentError.new("invalid basecall sequence") unless sequence.matches?(/\A[ACGTNacgtn]*\z/)
      if value = quality
        raise ArgumentError.new("basecall quality length mismatch") unless value.bytesize == sequence.bytesize
        raise ArgumentError.new("invalid basecall quality") unless value.bytes.all? { |byte| (33..126).includes?(byte) }
      end
    end
  end

  record BasecallResult, read_id : String, segments : Array(BasecallSegment) do
    include JSON::Serializable

    def sequences : Array(String)
      segments.map(&.sequence)
    end

    def validate! : Nil
      raise ArgumentError.new("empty basecall read identifier") if read_id.empty?
      segments.each(&.validate!)
    end
  end
end
