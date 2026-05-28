# frozen_string_literal: true

require "spec_helper"
require "stringio"
require "tempfile"
require_relative "../../eval/harness"

RSpec.describe "eval harness" do
  let(:embedder) { Engram::Adapters::NullEmbedder.new }

  def silence_stdout
    original_stdout = $stdout
    $stdout = StringIO.new
    yield
  ensure
    $stdout = original_stdout
  end

  def silence_stderr
    original_stderr = $stderr
    $stderr = StringIO.new
    yield($stderr)
  ensure
    $stderr = original_stderr
  end

  it "keeps a baseline-sized recall fixture set with negative queries" do
    fixtures = Engram::EVAL_FIXTURES

    expect(fixtures[:memories].size).to be >= 30
    expect(fixtures[:recall_queries].count { |query| query[:relevant].any? }).to be >= 10
    expect(fixtures[:recall_queries].count { |query| query[:relevant].empty? }).to be >= 3
    expect(fixtures[:recall_queries].count { |query| query[:distractors]&.any? }).to be >= 2
    expect(fixtures[:recall_queries]).to include(include(contradiction: true))
  end

  it "returns recall metrics without treating NullEmbedder quality as CI-gating" do
    metrics = silence_stdout { Engram::Eval.run_recall(embedder) }

    expect(metrics[:positive_count]).to be >= 10
    expect(metrics[:negative_count]).to be >= 3
    expect(metrics).to include(
      :relevant_retrieved,
      :relevant_total,
      :positive_retrieved,
      :distractor_retrieved,
      :distractor_total,
      :contradiction_hits,
      :contradiction_count
    )
  end

  it "runs the scripted extraction smoke cases" do
    result = silence_stdout { Engram::Eval.run_extraction(embedder) }

    expect(result).to eq(true)
  end

  it "runs the scripted consolidation smoke cases" do
    result = silence_stdout { Engram::Eval.run_consolidation(embedder) }

    expect(result).to eq(true)
  end

  it "keeps the heuristic duplicate baseline green" do
    result = silence_stdout { Engram::Eval.run_heuristic_consolidation(embedder) }

    expect(result).to eq(true)
  end

  it "does nothing when no RubyLLM setup file is configured" do
    [nil, ""].each do |setup_path|
      with_env("ENGRAM_RUBY_LLM_SETUP" => setup_path) do
        expect { Engram::Eval.load_ruby_llm_setup! }.not_to raise_error
      end
    end
  end

  it "forces UTF-8 before loading RubyLLM under ASCII locales" do
    original_external = Encoding.default_external
    Encoding.default_external = Encoding::US_ASCII

    Engram::Eval.ensure_utf8_external_encoding!

    expect(Encoding.default_external).to eq(Encoding::UTF_8)
  ensure
    Encoding.default_external = original_external
  end

  it "explains missing RubyLLM provider configuration without a raw stack trace" do
    stub_const("RubyLLM::ConfigurationError", Class.new(StandardError))
    allow(Engram::Eval).to receive(:configure_embedder)
    allow(Engram::Eval).to receive(:run_recall).and_raise(
      RubyLLM::ConfigurationError,
      "Missing configuration for OpenAI: openai_api_key"
    )

    silence_stdout do
      silence_stderr do |stderr|
        expect { Engram::Eval.run }.to raise_error(SystemExit)
        expect(stderr.string).to include("RubyLLM provider configuration is missing or invalid")
        expect(stderr.string).to include("ENGRAM_RUBY_LLM_SETUP=/path/to/setup.rb")
      end
    end
  end

  it "loads an optional RubyLLM setup file without assuming provider credential names" do
    marker_file = Tempfile.new("engram-ruby-llm-setup-marker")
    marker_path = marker_file.path
    marker_file.close
    setup_file = Tempfile.new(["engram-ruby-llm-setup", ".rb"])
    setup_file.write("File.write(ENV.fetch('ENGRAM_EVAL_SETUP_MARKER'), 'loaded')\n")
    setup_file.close

    with_env("ENGRAM_RUBY_LLM_SETUP" => setup_file.path, "ENGRAM_EVAL_SETUP_MARKER" => marker_path) do
      Engram::Eval.load_ruby_llm_setup!
    end

    expect(File.read(marker_path)).to eq("loaded")
  ensure
    marker_file&.unlink
    setup_file&.unlink
  end

  def with_env(values)
    previous = values.to_h { |key, _value| [key, ENV.fetch(key, :__missing__)] }
    values.each do |key, value|
      if value.nil?
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
    yield
  ensure
    previous.each do |key, value|
      if value == :__missing__
        ENV.delete(key)
      else
        ENV[key] = value
      end
    end
  end
end
