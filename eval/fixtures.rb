# frozen_string_literal: true

module Engram
  # Labelled fixtures for the local quality harness. The recall set intentionally
  # includes near distractors, contradiction pairs, and negative queries so future
  # memory-policy changes can be judged against a stable baseline instead of vibes.
  EVAL_FIXTURES = {
    memories: [
      "User's subscription tier is Pro",
      "User previously used the Free subscription tier",
      "User's company account has an Enterprise contract",
      "User prefers concise, short answers",
      "User dislikes long preambles",
      "User likes detailed architecture notes for design reviews",
      "User is vegetarian",
      "User is allergic to peanuts",
      "User enjoys spicy Thai food",
      "User works at Acme Corp",
      "User used to work at Globex",
      "User's manager is Priya",
      "User is based in Berlin",
      "User's timezone is Europe/Berlin",
      "User travels to London every quarter",
      "User already tried clearing the cache",
      "User already restarted the Rails server",
      "User has not tried rotating the API key yet",
      "User's production database is Postgres",
      "User's staging database is SQLite",
      "User stores embeddings with pgvector",
      "User's preferred Ruby version is 3.3",
      "User's Rails app is named Atlas",
      "User uses Sidekiq for background jobs",
      "User deploys with Fly.io",
      "User deploys a separate analytics service on Render",
      "User prefers pull requests without emoji",
      "User wants CI to be green before review",
      "User's GitHub username is octocat",
      "User's billing email is billing@example.test",
      "User's preferred test command is bundle exec rspec",
      "User prefers StandardRB for Ruby linting",
      "User is evaluating Engram for AI agent memory",
      "User wants memories stored in their own Postgres database",
      "User previously rejected a managed memory SaaS",
      "User's support ticket number is EXAMPLE-0001",
      "User's current project milestone is beta launch",
      "User wants unsafe secrets excluded from memory",
      "User shared that API keys must never be persisted",
      "User prefers XML-style memory injection blocks",
      "User's notification preference is email",
      "User's notification preference is Slack"
    ],
    recall_queries: [
      {
        query: "what plan is the user on?",
        relevant: ["User's subscription tier is Pro"],
        distractors: ["User previously used the Free subscription tier"]
      },
      {
        query: "how brief should the answer be?",
        relevant: ["User prefers concise, short answers", "User dislikes long preambles"]
      },
      {
        query: "what dietary restrictions matter?",
        relevant: ["User is vegetarian", "User is allergic to peanuts"]
      },
      {
        query: "where does the user work now?",
        relevant: ["User works at Acme Corp"],
        distractors: ["User used to work at Globex"]
      },
      {
        query: "what database should persistence examples use?",
        relevant: ["User's production database is Postgres"]
      },
      {
        query: "which vector extension stores embeddings?",
        relevant: ["User stores embeddings with pgvector"]
      },
      {
        query: "how should Ruby code be linted?",
        relevant: ["User prefers StandardRB for Ruby linting"]
      },
      {
        query: "what should happen before asking for review?",
        relevant: ["User wants CI to be green before review"]
      },
      {
        query: "what memory product is being evaluated?",
        relevant: ["User is evaluating Engram for AI agent memory"]
      },
      {
        query: "where should memories live?",
        relevant: ["User wants memories stored in their own Postgres database"]
      },
      {
        query: "what should never be persisted?",
        relevant: [
          "User wants unsafe secrets excluded from memory",
          "User shared that API keys must never be persisted"
        ]
      },
      {
        query: "how should recalled memories be formatted in prompts?",
        relevant: ["User prefers XML-style memory injection blocks"]
      },
      {
        query: "what notification preference is recorded?",
        relevant: [
          "User's notification preference is email",
          "User's notification preference is Slack"
        ],
        contradiction: true
      },
      {query: "what is the user's favorite football club?", relevant: []},
      {query: "what is the user's passport number?", relevant: []},
      {query: "which Kubernetes namespace hosts production?", relevant: []},
      {query: "what is the user's spouse named?", relevant: []}
    ],
    extraction_cases: [
      {
        name: "stable preferences and attributes",
        messages: [
          {role: "user", content: "I'm vegetarian and I prefer concise replies."},
          {role: "assistant", content: "Got it."}
        ],
        response: {
          facts: [
            {
              content: "User is vegetarian",
              kind: "preference",
              importance: 0.8,
              confidence: 0.95
            },
            {
              content: "User prefers concise replies",
              kind: "preference",
              importance: 0.7,
              confidence: 0.95
            }
          ]
        },
        expected: ["User is vegetarian", "User prefers concise replies"]
      },
      {
        name: "ephemeral chatter ignored",
        messages: [{role: "user", content: "Thanks, that fixed today's issue."}],
        response: {facts: []},
        expected: []
      },
      {
        name: "low confidence fact filtered",
        messages: [{role: "user", content: "Maybe I work at Acme? I'm not sure."}],
        response: {
          facts: [
            {
              content: "User works at Acme",
              kind: "semantic",
              importance: 0.5,
              confidence: 0.2
            }
          ]
        },
        expected: []
      }
    ],
    consolidation_cases: [
      {
        name: "new fact is added",
        existing: [],
        candidate: "User uses Sidekiq for background jobs",
        response: {decisions: [{index: 0, action: "add", target_id: nil, reason: "new fact"}]},
        expected_action: :add
      },
      {
        name: "duplicate fact is ignored",
        existing: ["User is vegetarian"],
        candidate: "User is vegetarian",
        response: {decisions: [{index: 0, action: "noop", target_id: 1, reason: "already known"}]},
        expected_action: :noop
      },
      {
        name: "changed preference updates old memory",
        existing: ["User prefers verbose answers"],
        candidate: "User prefers concise answers",
        response: {decisions: [{index: 0, action: "update", target_id: 1, reason: "preference changed"}]},
        expected_action: :update
      },
      {
        name: "obsolete fact can be forgotten",
        existing: ["User works at Globex"],
        candidate: "User no longer works at Globex",
        response: {decisions: [{index: 0, action: "forget", target_id: 1, reason: "obsolete"}]},
        expected_action: :forget
      }
    ]
  }.freeze
end
