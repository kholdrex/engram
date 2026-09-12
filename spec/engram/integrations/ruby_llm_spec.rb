# frozen_string_literal: true

RSpec.describe Engram::Integrations::RubyLLM::MemoryChat do
  let(:memory) { Engram::Memory.new(scope: "u:1") }
  let(:chat) do
    Class.new do
      attr_reader :requests

      def initialize
        @requests = []
      end

      def ask(message, **options)
        @requests << [message, options]
        yield "first" if block_given?
        yield "second" if block_given?
        :complete_response
      end

      def with_instructions(instructions)
        @instructions = instructions
        self
      end

      def model
        :model
      end
    end.new
  end

  it "forwards streaming chunks, request options, and the final response" do
    memory.add("User likes tea")
    wrapped = Engram.with_memory(chat, memory: memory)
    chunks = []

    result = wrapped.ask("User likes tea", with: ["image.png"]) { |chunk| chunks << chunk }

    expect(chunks).to eq(%w[first second])
    expect(result).to eq(:complete_response)
    expect(chat.requests.size).to eq(1)
    expect(chat.requests.first.first).to include("<engram-memories>")
    expect(chat.requests.first.last).to eq(with: ["image.png"])
  end

  it "keeps memory active when chaining fluent chat configuration" do
    memory.add("User likes tea")
    wrapped = Engram.with_memory(chat, memory: memory)

    expect(wrapped.with_instructions("Be concise")).to equal(wrapped)
    wrapped.with_instructions("Be concise").ask("User likes tea")

    expect(chat.requests.first.first).to include("<engram-memories>")
    expect(wrapped.model).to eq(:model)
    expect(wrapped).to respond_to(:with_instructions)
    expect(wrapped).not_to respond_to(:nonexistent)
    expect { wrapped.nonexistent }.to raise_error(NoMethodError)
  end

  it "passes memory controls through without sending them as provider options" do
    memory.add("User likes tea", kind: :preference)
    memory.add("User likes tea", kind: :fact)
    wrapped = Engram.with_memory(chat, memory: memory, limit: 2,
      kinds: [:preference], min_similarity: 0.9, max_bytes: 200)

    wrapped.ask("User likes tea")

    prompt, options = chat.requests.first
    expect(prompt).to include('kind="preference"')
    expect(prompt).not_to include('kind="fact"')
    expect(prompt.bytesize - "User likes tea".bytesize).to be <= 200
    expect(options).to eq({})
  end

  it "uses configured defaults and lets callers disable them" do
    memory.add("User likes tea")
    Engram.config.injection_max_bytes = 0
    Engram.with_memory(chat, memory: memory).ask("User likes tea")
    Engram.with_memory(chat, memory: memory, max_bytes: nil).ask("User likes tea")

    expect(chat.requests.first.first).to eq("User likes tea")
    expect(chat.requests.last.first).to include("<engram-memories>")
  end

  it "propagates streaming errors without retrying the provider request" do
    wrapped = Engram.with_memory(chat, memory: memory)

    expect { wrapped.ask("q") { raise "consumer disconnected" } }
      .to raise_error(RuntimeError, "consumer disconnected")
    expect(chat.requests.size).to eq(1)
  end
end
