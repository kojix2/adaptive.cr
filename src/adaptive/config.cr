require "json"

module Adaptive
  VERSION = "0.3.0"

  class Config
    include JSON::Serializable
    include JSON::Serializable::Strict
    property host : String = "127.0.0.1"
    property port : Int32 = 10001
    property tls : Bool = true
    property ca_file : String? = nil
    property first_channel : Int32 = 1
    property last_channel : Int32 = 512
    property reference : String
    property workers : Int32 = 4
    property min_samples : Int32 = 2500
    property step_samples : Int32 = 2000
    property max_samples : Int32 = 20000
    property max_buffer_bytes : Int64 = 268435456_i64
    property deadline_ms : Int32 = 2000
    property bridge_timeout_ms : Int32 = 3000
    property bridge_startup_timeout_ms : Int32 = 60000
    property ack_timeout_ms : Int32 = 3000
    property bridge_script : String = "scripts/dorado_bridge.py"
    property python : String = "python3"
    property dorado_address : String = "ipc:///tmp/.guppy/5555"
    property dorado_model : String = "dna_r10.4.1_e8.2_400bps_5khz_fast"
    property observe : Bool = true
    property log : String = "decisions.jsonl"
    property policy : String = "contig"
    property targets : Array(String) = [] of String
    property motif : String = ""
    property mapq : UInt32 = 20_u32
    property min_bases : Int32 = 300
    property quota : Int32 = 0
    property background_fraction : Float64 = 0.0
    property seed : UInt64 = 42_u64
    property allow_test_bridge : Bool = false
    property fixture_sequence : String? = nil

    def validate! : Nil
      validate_connection!
      validate_policy!
      raise "invalid worker count" unless (1..64).includes?(workers)
      raise "invalid sample limits" unless 100 <= min_samples <= max_samples <= 250000 && step_samples > 0
      raise "invalid timeouts" unless deadline_ms > 0 && (100..60000).includes?(bridge_timeout_ms) && ack_timeout_ms > 0
      raise "invalid bridge startup timeout" unless (100..600000).includes?(bridge_startup_timeout_ms)
      raise "invalid memory limit" unless max_buffer_bytes >= max_samples.to_i64 * 4 && max_buffer_bytes <= 16_i64 * 1024**3
    end

    private def validate_connection! : Nil
      raise "invalid port" unless (1..65535).includes?(port)
      raise "empty connection setting" if {host, python, bridge_script, dorado_address, dorado_model, log}.any?(&.strip.empty?)
      raise "missing bridge script" unless File.file?(bridge_script)
      raise "missing reference" unless File.file?(reference)
      if path = ca_file
        raise "missing CA certificate" unless File.file?(path)
      end
      raise "invalid channel range" unless 1 <= first_channel <= last_channel <= 65535
    end

    private def validate_policy! : Nil
      raise "invalid selection settings" unless min_bases > 0 && quota >= 0 && (0.0..1.0).includes?(background_fraction)
      raise "unknown policy" unless {"contig", "motif", "all", "custom"}.includes?(policy)
      raise "motif requires A/C/G/T sequence" if policy == "motif" && !motif.matches?(/\A[ACGT]+\z/)
      raise "contig policy requires targets" if policy == "contig" && targets.empty?
      raise "empty target name" if targets.any?(&.empty?)
      raise "MAPQ must be between 0 and 60" unless mapq <= 60
      raise "fixture mode requires allow_test_bridge=true" if fixture_sequence && !allow_test_bridge
    end
  end
end
