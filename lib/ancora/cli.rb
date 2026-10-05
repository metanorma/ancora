# frozen_string_literal: true

require "optparse"

module Ancora
  # M1 dry-run CLI. Plans waves over collector data and prints them;
  # dispatches nothing, releases nothing.
  #
  #   ancora plan --network network.json --delta delta.json
  #   ancora plan --network network.json --seeds metanorma-standoc
  #   ancora check metanorma-plugin-lutaml 0.7.54
  class CLI
    def self.run(argv)
      new(argv).run
    end

    def initialize(argv)
      @argv = argv
    end

    def run
      command = @argv.shift
      case command
      when "plan" then plan; 0
      when "check" then check; 0
      else usage
      end
    end

    private

    def plan
      options = { delta: nil, seeds: [] }
      OptionParser.new do |o|
        o.on("--network PATH") { |v| options[:network] = v }
        o.on("--delta PATH") { |v| options[:delta] = v }
        o.on("--seeds a,b,c") { |v| options[:seeds] = v.split(",") }
      end.parse!(@argv)

      graph = Graph.load(options.fetch(:network), options[:delta])
      scope = options[:seeds].empty? ? :full : :scoped
      waves = Planner.new(graph).plan(scope: scope, seeds: options[:seeds])
      puts "scope: #{scope} (#{waves.flatten.size} gems, #{waves.size} waves)"
      waves.each_with_index do |wave, i|
        puts "wave #{i + 1}: #{wave.join(', ')}"
      end
    end

    def check
      gem = @argv.shift
      version = @argv.shift
      return usage unless gem && version

      oracle = Oracle::Rubygems.new
      puts oracle.published?(gem, version) ? "#{gem} #{version}: published" :
        "#{gem} #{version}: NOT published"
    end

    def usage
      warn "usage: ancora plan --network PATH [--delta PATH] [--seeds a,b]"
      warn "       ancora check GEM VERSION"
      1
    end
  end
end
