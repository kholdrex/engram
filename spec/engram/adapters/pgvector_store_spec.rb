# frozen_string_literal: true

RSpec.describe Engram::Adapters::PgvectorStore do
  it "checks requested ids with a scoped pluck query" do
    relation = double
    model = double
    expect(model).to receive(:where).with(scope: "u:1", id: [3, 7]).and_return(relation)
    expect(relation).to receive(:pluck).with(:id).and_return([7])

    expect(described_class.new(model: model).existing_ids(scope: "u:1", ids: [3, 7])).to eq([7])
  end
end
