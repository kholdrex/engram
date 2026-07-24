# frozen_string_literal: true

RSpec.describe Engram::Adapters::PgvectorStore do
  it "lets the database allocate IDs on add instead of forwarding a caller-supplied ID" do
    model = double
    row = double(
      id: 42, content: "new", scope: "u:1", kind: "fact", importance: 1.0,
      metadata: {}, embedding: [0.0], created_at: Time.at(0)
    )
    allow(row).to receive(:try).with(:last_accessed_at).and_return(nil)
    expect(model).to receive(:create!).with(
      content: "new", scope: "u:1", kind: "fact", importance: 1.0,
      metadata: {}, embedding: [0.0]
    ).and_return(row)
    supplied = Engram::Record.new(id: 7, content: "new", scope: "u:1", embedding: [0.0])

    expect(described_class.new(model: model).add(supplied).id).to eq(42)
  end

  it "checks requested ids with a scoped pluck query" do
    relation = double
    model = double
    id_type = double
    expect(model).to receive(:where).with(scope: "u:1", id: [3, "7", 7]).and_return(relation)
    expect(relation).to receive(:pluck).with(:id).and_return([7])
    expect(model).to receive(:type_for_attribute).with("id").and_return(id_type)
    allow(id_type).to receive(:cast) { |id| id.to_i }

    expect(described_class.new(model: model).existing_ids(scope: "u:1", ids: [3, "7", 7])).to eq(["7"])
  end
end
