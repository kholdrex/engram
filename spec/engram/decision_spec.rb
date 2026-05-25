# frozen_string_literal: true

RSpec.describe Engram::Decision do
  it "accepts known actions" do
    expect(described_class.new(action: :add, candidate: nil).action).to eq(:add)
  end

  it "coerces string actions to symbols" do
    expect(described_class.new(action: "update", candidate: nil, target_id: 1).action).to eq(:update)
  end

  it "rejects unknown actions" do
    expect { described_class.new(action: :frobnicate, candidate: nil) }.to raise_error(ArgumentError)
  end
end
