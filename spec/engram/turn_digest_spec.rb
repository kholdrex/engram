# frozen_string_literal: true

RSpec.describe Engram::TurnDigest do
  it "is stable for the same scope and messages" do
    a = described_class.digest(scope: "u:1", messages: [{role: "user", content: "hi"}])
    b = described_class.digest(scope: "u:1", messages: [{role: "user", content: "hi"}])
    expect(a).to eq(b)
  end

  it "differs when the scope differs" do
    a = described_class.digest(scope: "u:1", messages: ["hi"])
    b = described_class.digest(scope: "u:2", messages: ["hi"])
    expect(a).not_to eq(b)
  end

  it "differs when the messages differ" do
    a = described_class.digest(scope: "u:1", messages: ["hi"])
    b = described_class.digest(scope: "u:1", messages: ["bye"])
    expect(a).not_to eq(b)
  end

  it "treats a plain string as a user message" do
    a = described_class.digest(scope: "u:1", messages: ["hi"])
    b = described_class.digest(scope: "u:1", messages: [{role: "user", content: "hi"}])
    expect(a).to eq(b)
  end
end
