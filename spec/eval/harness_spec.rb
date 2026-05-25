# frozen_string_literal: true

require "spec_helper"
require "stringio"
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
      :hallucinated
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
end
