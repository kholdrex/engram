# frozen_string_literal: true

RSpec.describe "gem packaging" do
  subject(:spec) do
    root = File.expand_path("../..", __dir__)
    Dir.chdir(root) { Gem::Specification.load(File.join(root, "engram.gemspec")) }
  end

  it "ships the Rails generator templates the install generator copies" do
    templates = spec.files.grep(%r{\Alib/generators/engram/templates/.+\.tt\z})
    expect(templates).to contain_exactly(
      "lib/generators/engram/templates/create_engram_memories.rb.tt",
      "lib/generators/engram/templates/initializer.rb.tt",
      "lib/generators/engram/templates/memory_record.rb.tt"
    )
  end

  it "ships the install generator itself" do
    expect(spec.files).to include("lib/generators/engram/install_generator.rb")
  end

  it "ships the rake tasks the Railtie loads into host apps" do
    expect(spec.files).to include("lib/engram/rails/tasks.rake")
  end

  it "declares BigDecimal as its only hard runtime dependency" do
    expect(spec.runtime_dependencies.map(&:name)).to contain_exactly("bigdecimal")
  end

  it "ships only the documented top-level files alongside Ruby sources" do
    top_level_files = spec.files.reject { |path| path.start_with?("lib/") }
    expect(top_level_files).to contain_exactly("README.md", "LICENSE.txt", "CHANGELOG.md")
    expect(spec.files).to all(satisfy { |path| File.file?(File.expand_path("../../#{path}", __dir__)) })
  end

  it "declares useful gem metadata" do
    expect(spec.metadata).to include(
      "homepage_uri" => "https://github.com/kholdrex/engram",
      "source_code_uri" => "https://github.com/kholdrex/engram/tree/main",
      "changelog_uri" => "https://github.com/kholdrex/engram/blob/main/CHANGELOG.md",
      "bug_tracker_uri" => "https://github.com/kholdrex/engram/issues",
      "rubygems_mfa_required" => "true"
    )
  end
end
