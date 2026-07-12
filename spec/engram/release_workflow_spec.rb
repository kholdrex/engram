# frozen_string_literal: true

RSpec.describe "release workflow" do
  subject(:workflow) { File.read(File.expand_path("../../.github/workflows/release.yml", __dir__)) }

  it "uses RubyGems trusted publishing with restricted permissions and immutable actions" do
    expect(workflow).to include("contents: write", "id-token: write", "environment: release")
    expect(workflow).to include("persist-credentials: false")
    expect(workflow.scan(/^\s*- uses: ([^\s#]+)/).flatten).to all(match(%r{\A[^@]+@[0-9a-f]{40}\z}))
    expect(workflow).to include(
      "actions/checkout@93cb6efe18208431cddfb8368fd83d5badbf9bfd # v5.0.1",
      "ruby/setup-ruby@d45b1a4e94b71acab930e56e79c6aa188764e7f9 # v1.316.0",
      "rubygems/release-gem@052cc82692552de3ef2b81fd670e41d13cba8092 # v1.4.0"
    )
    expect(workflow).not_to match(/api[_-]?key|GEM_HOST_API_KEY/i)
  end

  it "installs release dependencies for a pinned supported Ruby without integration gems" do
    expect(workflow).to include("BUNDLE_WITHOUT: integration")
    expect(workflow).to include('ruby-version: "3.3"', "bundler-cache: true")
  end

  it "only triggers for version tags and validates the tag before release" do
    expect(workflow).to include('      - "v*"', "Verify tag matches gem version")
    expect(workflow.index("Verify tag matches gem version")).to be < workflow.index("rubygems/release-gem@")
    expect(workflow).to include('expected="v${version}"', "GITHUB_REF_NAME")
  end

  it "rejects commits outside origin/main before executing repository-controlled code" do
    expect(workflow).to include("fetch-depth: 0", "Verify tagged commit is on main")
    expect(workflow).to include("git fetch --no-tags origin main:refs/remotes/origin/main")
    expect(workflow).to include('git merge-base --is-ancestor "$GITHUB_SHA" origin/main')
    expect(workflow).to include("Refusing to release: tagged commit $GITHUB_SHA is not contained in origin/main")
    steps = workflow.scan(/^      - (?:uses:|name:) (.+)$/).flatten
    checkout_step = steps.index { |step| step.start_with?("actions/checkout@") }
    provenance_guard_step = steps.index("Verify tagged commit is on main")
    checkout = workflow.index("actions/checkout@")
    provenance_guard = workflow.index("Verify tagged commit is on main")

    expect(provenance_guard_step).to eq(checkout_step + 1)
    expect(checkout).to be < provenance_guard
    expect(provenance_guard).to be < workflow.index("ruby/setup-ruby@")
    expect(provenance_guard).to be < workflow.index("Verify tag matches gem version")
    expect(provenance_guard).to be < workflow.index("rubygems/release-gem@")
  end
end
