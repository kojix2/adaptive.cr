require "json"

module NanoporeGUI
  record Field, key : String, label : String, kind : Symbol = :string, picker : Symbol? = nil

  # Keep the complete document, including settings not exposed by the form.
  class Document
    getter value : JSON::Any

    def initialize(text : String)
      @value = JSON.parse(text)
      @value.as_h
    end

    def get(key : String) : JSON::Any
      key.split('.').reduce(@value) do |node, part|
        node.as_a? ? node[part.to_i] : (node[part]? || JSON::Any.new(nil))
      end
    end

    def set(key : String, value : JSON::Any)
      parts = key.split('.')
      leaf = parts.pop
      node = parts.reduce(@value) { |item, part| item.as_a? ? item[part.to_i] : item[part] }
      if array = node.as_a?
        array[leaf.to_i] = value
      else
        node.as_h[leaf] = value
      end
    end

    def text : String
      @value.to_pretty_json
    end

    def set_text(field : Field, text : String)
      value = case field.kind
              when :integer then JSON::Any.new(text.to_i64)
              when :number  then JSON::Any.new(text.to_f64)
              when :list    then JSON::Any.new(text.split(',').map(&.strip).reject(&.empty?).map { |s| JSON::Any.new(s) })
              when :optional
                JSON::Any.new(text.empty? ? nil : text)
              else JSON::Any.new(text)
              end
      set(field.key, value)
    rescue error
      raise ArgumentError.new("#{field.label}: #{error.message}")
    end
  end
end
