# frozen_string_literal: true

RSpec.describe "release workflow" do
  subject(:workflow) { File.read(File.expand_path("../../.github/workflows/release.yml", __dir__)) }

  it "uses RubyGems trusted publishing with the required restricted checkout and permissions" do
    expect(workflow).to include("contents: write", "id-token: write", "environment: release")
    expect(workflow).to include("actions/checkout@v5", "persist-credentials: false")
    expect(workflow).to include("ruby/setup-ruby@v1", "rubygems/release-gem@v1")
    expect(workflow).not_to match(/api[_-]?key|GEM_HOST_API_KEY/i)
  end

  it "installs release dependencies for a pinned supported Ruby without integration gems" do
    expect(workflow).to include("BUNDLE_WITHOUT: integration")
    expect(workflow).to include('ruby-version: "3.3"', "bundler-cache: true")
  end

  it "only triggers for version tags and checks the tag before release" do
    expect(workflow).to include('      - "v*"', "Verify tag matches gem version")
    expect(workflow.index("Verify tag matches gem version")).to be < workflow.index("rubygems/release-gem@v1")
    expect(workflow).to include('expected="v${version}"', "GITHUB_REF_NAME")
  end
end
