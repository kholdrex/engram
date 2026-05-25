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

  it "declares no hard runtime dependencies" do
    expect(spec.runtime_dependencies).to be_empty
  end
end
