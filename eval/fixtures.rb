# frozen_string_literal: true

module Engram
  # Tiny labelled set for the recall quality harness. Grow this over time; it is the
  # honest measure of whether memory retrieval actually works.
  EVAL_FIXTURES = {
    memories: [
      "User's subscription tier is Pro",
      "User prefers concise, short answers",
      "User is vegetarian",
      "User works at Acme Corp",
      "User already tried clearing the cache"
    ],
    queries: [
      {query: "what plan is the user on?", relevant: ["User's subscription tier is Pro"]},
      {query: "how should I format my reply?", relevant: ["User prefers concise, short answers"]},
      {query: "where does the user work?", relevant: ["User works at Acme Corp"]},
      {query: "any dietary restrictions?", relevant: ["User is vegetarian"]}
    ]
  }.freeze
end
