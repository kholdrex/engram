# frozen_string_literal: true

require "open3"
require "rbconfig"

RSpec.describe "ActiveJob boot", :integration do
  it "observes a turn before any other job loads ActiveJob::Base" do
    script = <<~RUBY
      require "tmpdir"
      require "rails"
      require "active_job/railtie"
      require "engram"

      class JobBootApp < Rails::Application
        config.eager_load = false
        config.logger = Logger.new(IO::NULL)
        config.active_job.queue_adapter = :inline
        config.secret_key_base = "engram-job-boot-test"
      end

      Dir.mktmpdir("engram-job-boot") do |root|
        JobBootApp.config.root = root
        JobBootApp.initialize!
        raise "test preloaded ActiveJob::Base" unless ActiveJob.autoload?(:Base)

        Engram.config.completion = Engram::Adapters::FakeCompletion.new(responses: [
          {"facts" => [{"content" => "User likes tea", "confidence" => 0.9}]}
        ])
        memory = Engram::Memory.new(scope: "user:1")
        memory.observe_later([{role: "user", content: "I like tea"}])
        raise "observation failed" unless memory.all.map(&:content) == ["User likes tea"]
      end
    RUBY

    stdout, stderr, status = Open3.capture3(RbConfig.ruby,
      "-I", File.expand_path("../../lib", __dir__), "-e", script)

    expect(status.success?).to be(true), "#{stdout}\n#{stderr}"
  end
end
