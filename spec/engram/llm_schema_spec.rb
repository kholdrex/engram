# frozen_string_literal: true

# Guards the LLM JSON schemas against OpenAI's strict structured-outputs rules: every object
# must set `additionalProperties: false` and list every property in `required` (optional
# fields are modelled as nullable unions). The unit suite uses FakeCompletion, which never
# validates the schema, so without this guard a non-conforming schema only fails against a
# real provider.

RSpec.describe "LLM JSON schemas (OpenAI strict structured outputs)" do
  # Yields [path, object] for every object node in a JSON schema.
  def each_object(node, path = "root", &block)
    if node.is_a?(Hash)
      block.call(path, node) if node[:type] == "object"
      node.each { |key, value| each_object(value, "#{path}.#{key}", &block) }
    elsif node.is_a?(Array)
      node.each_with_index { |value, i| each_object(value, "#{path}[#{i}]", &block) }
    end
  end

  def assert_strict(schema, label)
    each_object(schema) do |path, object|
      expect(object[:additionalProperties]).to eq(false),
        "#{label} #{path}: object is missing `additionalProperties: false`"

      properties = (object[:properties] || {}).keys.map(&:to_s).sort
      required = (object[:required] || []).map(&:to_s).sort
      expect(required).to eq(properties),
        "#{label} #{path}: `required` #{required.inspect} must list every property #{properties.inspect}"
    end
  end

  it "LLMExtractor::SCHEMA conforms" do
    assert_strict(Engram::Extractors::LLMExtractor::SCHEMA, "LLMExtractor")
  end

  it "LLMConsolidator::SCHEMA conforms" do
    assert_strict(Engram::Consolidators::LLMConsolidator::SCHEMA, "LLMConsolidator")
  end
end
