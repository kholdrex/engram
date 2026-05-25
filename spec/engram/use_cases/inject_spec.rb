# frozen_string_literal: true

RSpec.describe Engram::UseCases::Inject do
  subject(:inject) { described_class.new }

  def mem(content)
    Engram::Record.new(content: content, scope: "u:1")
  end

  it "appends a memory block to the prompt" do
    out = inject.call(prompt: "Answer the user.", memories: [mem("plan is Pro"), mem("vegetarian")])

    expect(out).to include("Answer the user.")
    expect(out).to include("# What you remember about the user:")
    expect(out).to include("- plan is Pro")
    expect(out).to include("- vegetarian")
  end

  it "returns the prompt unchanged when there are no memories" do
    expect(inject.call(prompt: "Hi", memories: [])).to eq("Hi")
    expect(inject.call(prompt: "Hi", memories: nil)).to eq("Hi")
  end

  it "supports a custom header" do
    out = described_class.new(header: "# Context").call(prompt: "P", memories: [mem("x")])
    expect(out).to include("# Context:")
  end
end
