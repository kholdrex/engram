# frozen_string_literal: true

RSpec.describe Engram::Extractors::LLMExtractor do
  subject(:extractor) { described_class.new(completion: completion, embedder: embedder, min_confidence: 0.5) }

  let(:embedder) { Engram::Adapters::NullEmbedder.new }
  let(:completion) do
    Engram::Adapters::FakeCompletion.new(responses: [
      {"facts" => [
        {"content" => "User is on the Pro plan", "kind" => "preference", "importance" => 0.8, "confidence" => 0.9},
        {"content" => "barely confident", "confidence" => 0.1}
      ]}
    ])
  end

  it "builds records from facts above the confidence threshold" do
    records = extractor.extract(messages: [{role: "user", content: "I upgraded to Pro"}], scope: "u:1")

    expect(records.map(&:content)).to eq(["User is on the Pro plan"])
    expect(records.first.kind).to eq(:preference)
    expect(records.first.scope).to eq("u:1")
  end

  it "embeds each extracted fact" do
    record = extractor.extract(messages: ["hi"], scope: "u:1").first
    expect(record.embedding).to eq(embedder.embed("User is on the Pro plan"))
  end

  it "sends a role-tagged transcript to the LLM" do
    extractor.extract(messages: [{role: "user", content: "hello"}], scope: "u:1")
    expect(completion.calls.first[:user]).to include("user: hello")
  end

  it "supports instruction as an explicit memory kind" do
    completion = Engram::Adapters::FakeCompletion.new(responses: [
      {"facts" => [
        {"content" => "User wants direct answers", "kind" => "instruction", "importance" => 0.8, "confidence" => 0.9}
      ]}
    ])
    extractor = described_class.new(completion: completion, embedder: embedder)

    record = extractor.extract(messages: ["Be direct"], scope: "u:1").first

    expect(record.kind).to eq(:instruction)
  end
end
