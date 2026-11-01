require "../adaptive/config"
require "./model"

module NanoporeGUI
  module Profile
    def self.title : String
      "Adaptive Sampling"
    end

    def self.command : String
      "adaptive"
    end

    def self.version : String
      Adaptive::VERSION
    end

    def self.modes : Array(String)
      ["Live (observe/actions as configured)", "Sequence replay (offline)"]
    end

    def self.replay? : Bool
      true
    end

    def self.fields : Array(Field)
      [
        Field.new("reference", "Reference FASTA / minimap2 index", picker: :open),
        Field.new("targets", "Target contigs (comma separated)", :list),
        Field.new("host", "MinKNOW host"),
        Field.new("port", "Position port", :integer),
        Field.new("python", "Python executable"),
        Field.new("dorado_address", "Dorado server address"),
        Field.new("dorado_model", "Dorado model"),
        Field.new("log", "Decision log (new path)", picker: :save),
        Field.new("observe", "Observe only (do not send actions)", :bool),
      ]
    end

    def self.initial : Document
      parse(%({"reference":"examples/reference.fa","targets":["virus"],"log":"decisions-#{Time.utc.to_s("%Y%m%d-%H%M%S")}.jsonl"}))
    end

    def self.parse(text : String) : Document
      config = Adaptive::Config.from_json(text)
      defaults = JSON.parse(config.to_json).as_h
      defaults.merge!(JSON.parse(text).as_h)
      Document.new(defaults.to_json)
    end

    def self.arguments(action : Symbol, mode : Int32, replay : String) : Array(String)
      return ["--validate"] if action == :validate
      return ["--check-backend"] if action == :backend
      return [] of String if mode == 0
      raise "Choose a replay JSONL file" if replay.strip.empty?
      ["--replay=#{replay}"]
    end
  end
end
