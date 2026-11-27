# frozen_string_literal: true

require "spec_helper"
require "tmpdir"

RSpec.describe Ancora::GateRun do
  let(:graph) { Ancora::Graph.from_data(FleetFixture::GATE_NETWORK, FleetFixture::DELTA) }
  let(:chain) { FleetFixture.load_chain(FleetFixture::METANORMA_CHAIN) }
  let(:pins) do
    { "metanorma-iso" => "3.5.1.pre.alpha.1",
      "metanorma-cli" => "1.18.0.pre.alpha.1" }
  end

  def suite_env(dir, gem_dir)
    home = File.join(dir, "gem_home")
    described_class::SCRUBBED_ENV.merge(
      "BUNDLE_GEMFILE" => File.join(gem_dir, "Gemfile.ancora"),
      "GEM_HOME" => home, "GEM_PATH" => home
    )
  end

  def run_gate(shell, dir, **opts)
    described_class.new(chain: chain, graph: graph, workdir: dir, shell: shell,
                        **opts)
      .call(pins)
  end

  it "compiles the full set, then runs the canary in every configured corpus" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new
      verdict = run_gate(shell, dir)

      expect(verdict).to be_green
      expect(verdict.suspects).to be_empty
      lock = File.read(File.join(dir, "lock", "Gemfile"))
      expect(lock).to include('gem "metanorma-cli", "1.18.0.pre.alpha.1"')
      expect(shell.commands.first(2)).to eq ["bundle lock", "bundle install"]
      canaries = shell.calls.select do |c|
        c[:command] == "bundle exec rake site"
      end
      expect(canaries.map { |c| File.basename(c[:chdir]) }).to eq(
        %w[metanorma__mn-samples-iso metanorma__mn-samples-iso-private
           metanorma__mn-samples-jis],
      )
      expect(canaries.map { |c| c[:timeout] }).to eq [300, 600, 240]
      expect(canaries.first[:env]).to include(
        "BUNDLE_GEMFILE" => File.join(dir, "lock", "Gemfile"),
        "ANCORA_CORPUS_DOCUMENTS" => "ISO 10303-2",
      )
    end
  end

  it "runs every gem suite on main against its overlay before canary" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new
      verdict = run_gate(shell, dir, token: "token-123")
      suites = shell.calls.select { |c| c[:command] == "bundle exec rspec" }
      expect(verdict).to be_green
      expect(suites.map { |c| [c[:chdir], c[:env]] }).to eq(
        %w[metanorma-cli metanorma-iso].map do |gem|
          gem_dir = File.join(dir, "suites", gem)
          [gem_dir, suite_env(dir, gem_dir)]
        end,
      )
      expect(shell.commands[2]).to eq(
        "git clone --depth 1 --branch main " \
        "https://github.com/metanorma/metanorma-cli.git " \
        "#{dir}/suites/metanorma-cli",
      )
      expect(verdict.steps.map(&:kind)).to eq(
        %w[compile compile suite suite suite suite corpus corpus corpus],
      )
    end
  end

  it "bundles each suite with the other candidates pinned, not its own gem" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new
      run_gate(shell, dir)
      overlay = File.read(File.join(dir, "suites", "metanorma-cli",
                                    "Gemfile.ancora"))
      installs = shell.calls.select { |c| c[:command] == "bundle install" }

      expect(overlay).to include('"metanorma-iso" => "3.5.1.pre.alpha.1"')
      expect(overlay).not_to include('"metanorma-cli" =>')
      expect(installs.map { |c| c[:chdir] }).to eq(
        [File.join(dir, "lock")] + %w[metanorma-cli metanorma-iso].map do |gem|
          File.join(dir, "suites", gem)
        end,
      )
    end
  end

  it "is red when a gem suite fails, naming its gem and skipping canary" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["metanorma-iso bundle exec rspec"])
      verdict = run_gate(shell, dir)

      expect(verdict.result).to eq "red"
      expect(verdict.suspects).to eq ["metanorma-iso"]
      expect(verdict.steps.last).to have_attributes(
        name: "suite metanorma-iso: bundle exec rspec", kind: "suite",
        status: "failed", gems: ["metanorma-iso"]
      )
      expect(shell.commands.grep(/rake site|mn-samples/)).to be_empty
    end
  end

  it "refuses a publishing suite command before running anything" do
    Dir.mktmpdir do |dir|
      chain = FleetFixture.load_chain(<<~YAML)
        name: metanorma
        inventory:
          orgs: [metanorma]
          roots: [metanorma-cli]
        gate:
          commands: [bundle exec rake release]
      YAML
      shell = RecordingShell.new

      expect do
        described_class.new(chain: chain, graph: graph, workdir: dir,
                            shell: shell).call(pins)
      end.to raise_error(described_class::Refused,
                         /suite command would publish/)
      expect(shell.calls).to be_empty
    end
  end

  it "runs every configured suite command in each gem checkout" do
    Dir.mktmpdir do |dir|
      yaml = FleetFixture::METANORMA_CHAIN.sub(
        "commands: [bundle exec rspec]",
        "commands: [bundle exec rspec, bundle exec rake spec]",
      )
      chain = FleetFixture.load_chain(yaml)
      shell = RecordingShell.new
      verdict = described_class.new(chain: chain, graph: graph, workdir: dir,
                                    shell: shell).call(pins)

      expect(verdict).to be_green
      pins.each_key do |gem|
        commands = shell.calls.select do |call|
          call[:chdir] == File.join(dir, "suites", gem)
        end
        expect(commands.map { |call| call[:command] })
          .to eq ["bundle install", "bundle exec rspec",
                  "bundle exec rake spec"]
      end
    end
  end

  it "names an unclonable suite's gem and still checks the other gem" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["metanorma/metanorma-cli.git"])
      verdict = run_gate(shell, dir)
      suites = shell.calls.select { |c| c[:command] == "bundle exec rspec" }

      expect(verdict.result).to eq "red"
      expect(verdict.suspects).to eq ["metanorma-cli"]
      expect(suites.map { |c| File.basename(c[:chdir]) })
        .to eq ["metanorma-iso"]
      expect(shell.commands.grep(/rake site|mn-samples/)).to be_empty
    end
  end

  it "is red, and skips the canary, when the full set does not compile" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["bundle lock"])
      verdict = run_gate(shell, dir)

      expect(verdict.result).to eq "red"
      expect(verdict.steps.map(&:status)).to eq ["failed"]
      expect(shell.commands).to eq ["bundle lock"]
    end
  end

  it "is red when one corpus fails, naming the gems it gates" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["jis bundle exec rake site"])
      verdict = run_gate(shell, dir)

      expect(verdict.result).to eq "red"
      expect(verdict.suspects).to eq ["metanorma-cli"]
      expect(verdict.steps.count { |s| s.status == "failed" }).to eq 1
    end
  end

  it "treats a corpus that overruns its budget as red" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(time_out_on: ["rake site"])
      verdict = run_gate(shell, dir)

      expect(verdict.result).to eq "red"
      expect(verdict.steps.map(&:status)).to include("timeout")
    end
  end

  it "is red when a configured corpus cannot be cloned" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["https://github.com/metanorma/mn-samples"])
      verdict = run_gate(shell, dir)

      expect(verdict.result).to eq "red"
      expect(verdict.suspects).to eq %w[metanorma-cli metanorma-iso]
      expect(shell.commands.grep(/rake site/)).to be_empty
    end
  end

  it "keeps the token out of argv and the recorded output" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new(fail_on: ["git clone"])
      verdict = run_gate(shell, dir, token: "token-123")

      clone = shell.calls.find { |c| c[:command].start_with?("git clone") }
      expect(clone[:command]).not_to include("token-123")
      expect(clone[:env]["GIT_CONFIG_VALUE_0"])
        .to start_with("Authorization: basic ")
      expect(verdict.steps.map(&:detail).join).not_to include("token-123")
    end
  end

  it "runs the canary in the lock directory when the chain has no corpus" do
    Dir.mktmpdir do |dir|
      chain = FleetFixture.load_chain(<<~YAML)
        name: metanorma
        inventory:
          orgs: [metanorma]
          roots: [metanorma-cli]
        canary:
          commands: [bundle exec rake site]
      YAML
      shell = RecordingShell.new
      verdict = described_class.new(chain: chain, graph: graph, workdir: dir,
                                    shell: shell).call(pins)

      expect(verdict).to be_green
      expect(shell.calls.last[:chdir]).to eq File.join(dir, "lock")
    end
  end

  ["gem push pkg/x.gem", "gem --norc push pkg/x.gem", "git push origin main",
   "gh workflow run rubygems-release.yml", "bundle exec rake release",
   "git pu''sh origin main", "gem pu''sh pkg/x.gem"]
    .each do |command|
    it "refuses the publishing canary command #{command.inspect}" do
      Dir.mktmpdir do |dir|
        chain = FleetFixture.load_chain(<<~YAML)
          name: metanorma
          inventory:
            orgs: [metanorma]
            roots: [metanorma-cli]
          canary:
            commands: ["#{command}"]
        YAML
        shell = RecordingShell.new

        expect do
          described_class.new(chain: chain, graph: graph, workdir: dir,
                              shell: shell).call(pins)
        end.to raise_error(described_class::Refused, /would publish/)
        expect(shell.calls).to be_empty
      end
    end
  end

  it "refuses a pin for a gem the graph does not know, running nothing" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new

      expect do
        described_class.new(chain: chain, graph: graph, workdir: dir,
                            shell: shell).call({ "no-such-gem" => "1.0.0.pre.alpha.1" })
      end.to raise_error(described_class::Refused, /not in the graph: no-such-gem/)
      expect(shell.calls).to be_empty
    end
  end

  it "refuses a suite command whose quoting cannot be read" do
    Dir.mktmpdir do |dir|
      chain = FleetFixture.load_chain(<<~YAML)
        name: metanorma
        inventory:
          orgs: [metanorma]
          roots: [metanorma-cli]
        gate:
          commands: ["bundle exec rspec 'unterminated"]
      YAML
      shell = RecordingShell.new

      expect do
        described_class.new(chain: chain, graph: graph, workdir: dir,
                            shell: shell).call(pins)
      end.to raise_error(described_class::Refused, /cannot be read/)
      expect(shell.calls).to be_empty
    end
  end

  it "withholds publishing credentials from every command it runs" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new
      run_gate(shell, dir)

      expect(shell.calls.map { |c| c[:env] }).to all(
        include("GEM_HOST_API_KEY" => nil, "GITHUB_TOKEN" => nil,
                "GH_TOKEN" => nil, "RUBYGEMS_API_KEY" => nil),
      )
    end
  end

  it "is red, running nothing, while an external need has no final" do
    Dir.mktmpdir do |dir|
      finding = Ancora::Externals::Finding.new(
        gem: "ea", from: ["metanorma-plugin-lutaml"],
        constraints: [">= 0.6.41"], status: :awaiting_release,
        latest_final: "0.6.40"
      )
      shell = RecordingShell.new
      gate = described_class.new(chain: chain, graph: graph, workdir: dir,
                                 shell: shell)
      verdict = gate.call(pins, externals: [finding])

      expect(verdict.result).to eq "red"
      expect(verdict.steps.first.detail).to include("ea")
      expect(shell.calls).to be_empty
    end
  end

  it "keeps the bundler cause line behind more marker lines than the detail budget" do
    Dir.mktmpdir do |dir|
      cause = "Could not find gem 'metanorma-iso (= 3.5.1.pre.alpha.1)'.\n"
      resolver = Array.new(20) { |i| "Gem::Resolver noise #{i}\n" }.join
      tail = Array.new(20) { |i| "plain line #{i}\n" }.join
      shell = Object.new
      shell.define_singleton_method(:run) do |_command, **|
        Ancora::Shell::Result.new(ok: false, output: resolver + cause + tail,
                                  timed_out: false)
      end
      verdict = described_class.new(chain: chain, graph: graph, workdir: dir,
                                    shell: shell).call(pins)

      expect(verdict.steps.first.detail).to include("Could not find gem")
    end
  end

  it "keeps the bundler cause line when the lock fails with a long output" do
    Dir.mktmpdir do |dir|
      cause = "Could not find gem 'metanorma-iso (= 3.5.1.pre.alpha.1)'.\n"
      noise = Array.new(30) { |i| "resolving line #{i}\n" }.join
      shell = Object.new
      shell.define_singleton_method(:run) do |_command, **|
        Ancora::Shell::Result.new(ok: false, output: cause + noise,
                                  timed_out: false)
      end
      verdict = described_class.new(chain: chain, graph: graph, workdir: dir,
                                    shell: shell).call(pins)

      expect(verdict.steps.first.detail).to include("Could not find gem")
      expect(verdict.steps.first.detail).to end_with("resolving line 29\n")
    end
  end

  it "installs gate gems into a fresh GEM_HOME under the workdir" do
    Dir.mktmpdir do |dir|
      stale = File.join(dir, "gem_home", "gems", "stale-1.0", "lib")
      FileUtils.mkdir_p(stale)
      shell = RecordingShell.new
      run_gate(shell, dir)
      home = File.join(dir, "gem_home")
      bundler = shell.calls.select { |c| c[:command].start_with?("bundle") }

      expect(bundler.map { |c| c[:env] })
        .to all(include("GEM_HOME" => home, "GEM_PATH" => home))
      expect(File.exist?(stale)).to be false
    end
  end

  it "runs every gate command with RUBYOPT unset" do
    Dir.mktmpdir do |dir|
      shell = RecordingShell.new
      run_gate(shell, dir)

      expect(shell.calls.map { |c| c[:env] }).to all(include("RUBYOPT" => nil))
    end
  end

  it "resolves a relative workdir to an absolute path" do
    Dir.mktmpdir do |dir|
      Dir.chdir(dir) do
        shell = RecordingShell.new
        run_gate(shell, "relative-work")

        expect(shell.calls.map { |c| c[:chdir] })
          .to all(start_with(File.join(Dir.pwd, "relative-work")))
      end
    end
  end
end
