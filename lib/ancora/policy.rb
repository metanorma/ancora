# frozen_string_literal: true

require "ripper"

module Ancora
  # The owner's standing release rules as machine checks over one gem
  # checkout. Read-only: it inspects files and `git ls-files`, nothing is
  # written, tagged or released. Humans still authorize the release; this
  # only reports whether the repo is fit to be released.
  #
  #   version_behind_next      lib/**/version.rb sits strictly BEHIND the
  #                            requested next_version (the release workflow
  #                            performs the bump; a branch never pre-bumps)
  #   release_workflow         .github/workflows/release.yml registers the
  #                            reusable metanorma/ci rubygems-release workflow
  #                            with a next_version input and do-release dispatch
  #   lockfile_uncommitted     Gemfile.lock is git-ignored and not tracked
  class Policy
    REUSABLE_RELEASE =
      %r{\Ametanorma/ci/\.github/workflows/rubygems-release\.yml@\S+\z}
    Finding = Struct.new(:rule, :message, keyword_init: true)

    RULES = %i[version_behind_next release_workflow lockfile_uncommitted].freeze

    def initialize(root, next_version: nil)
      @root = root
      @next_version = next_version
    end

    # Findings for every violated rule; empty means the repo conforms.
    # Without a next_version the version rule is skipped (nothing to compare).
    def check
      unless File.directory?(@root)
        return [finding(:checkout, "#{@root} is not a directory")]
      end

      RULES.flat_map { |rule| send(rule) }
    end

    private

    def version_behind_next
      return [] unless @next_version
      unless version?(@next_version)
        return [version_problem("next_version #{@next_version.inspect} " \
                                "is not a version")]
      end

      files = Dir.glob("lib/**/version.rb", base: @root)
      return [version_problem("no lib/**/version.rb found")] if files.empty?

      files.flat_map { |relative| version_findings(relative) }
    end

    def version_findings(relative)
      literals = version_literals(File.read(File.join(@root, relative)))
      if literals.empty? || literals.include?(nil)
        return [version_problem("#{relative}: no VERSION literal")]
      end

      literals.uniq.filter_map do |current|
        version_problem_for(relative, current)
      end
    end

    def version_problem_for(relative, current)
      unless version?(current)
        return version_problem("#{relative}: #{current.inspect} " \
                               "is not a valid version")
      end
      return unless Gem::Version.new(current) >= Gem::Version.new(@next_version)

      version_problem("#{relative}: #{current} is not behind " \
                      "next_version #{@next_version}")
    end

    def version_problem(message)
      finding(:version_behind_next, message)
    end

    def version?(text)
      !text.strip.empty? && Gem::Version.correct?(text)
    end

    def release_workflow
      path = File.join(@root, ".github", "workflows", "release.yml")
      unless File.file?(path)
        return [finding(:release_workflow,
                        "missing .github/workflows/release.yml")]
      end

      workflow = load_workflow(path)
      problems = workflow ? workflow_problems(workflow) : ["is not valid YAML"]
      problems.map { |why| finding(:release_workflow, "release.yml #{why}") }
    end

    def workflow_problems(workflow)
      {
        "does not call the reusable rubygems-release" =>
          reusable_job?(workflow),
        "has no next_version input" => next_version_input?(workflow),
        "ignores the do-release dispatch" => do_release?(workflow),
      }.reject { |_why, ok| ok }.keys
    end

    def lockfile_uncommitted
      unless own_repository?
        return [finding(:lockfile_uncommitted,
                        "not its own git repository; the Gemfile.lock " \
                        "ignore rule cannot be checked")]
      end

      [
        (tracked?("Gemfile.lock") ? "Gemfile.lock is tracked by git" : nil),
        (ignored?("Gemfile.lock") ? nil : "Gemfile.lock is not in .gitignore"),
      ].compact.map { |why| finding(:lockfile_uncommitted, why) }
    end

    # Git searches upward for a repository, so a gem nested in another one
    # would be judged by that repository's .gitignore instead of its own.
    def own_repository?
      out, status = Open3.capture2("git", "rev-parse", "--show-toplevel",
                                   chdir: @root, err: File::NULL)
      status.success? && File.identical?(out.strip, @root)
    end

    def tracked?(name)
      out, status = Open3.capture2("git", "ls-files", "--", name, chdir: @root,
                                                                  err: File::NULL)
      status.success? && !out.strip.empty?
    end

    # Ask git itself, so negation, wildcards and nested ignore files agree
    # with what `git add` would do.
    def ignored?(name)
      _out, status = Open3.capture2("git", "check-ignore", "-q", "--no-index",
                                    "--", name, chdir: @root, err: File::NULL)
      status.success?
    end

    # Every `VERSION = ...` assignment (bare or qualified) found by parsing
    # with Ripper; nil marks one whose value is not a string literal. Comments
    # and =begin blocks never reach the tree and no repo code is executed.
    def version_literals(text)
      tree = Ripper.sexp(text)
      tree ? version_assignments(tree) : []
    end

    def version_assignments(node)
      return [] unless node.is_a?(Array)

      assigned = node.first == :assign && version_target?(node[1])
      (assigned ? [string_value(node[2])] : []) +
        node.flat_map { |child| version_assignments(child) }
    end

    # `"1.2.3".freeze` (also with empty parens) is the string literal itself.
    def frozen_receiver(node)
      node = node[1] if node_type(node) == :method_add_arg
      return node unless node_type(node) == :call

      node.dig(3, 1) == "freeze" ? node[1] : node
    end

    def node_type(node)
      node.first if node.is_a?(Array)
    end

    def version_target?(target)
      const = target&.last
      %i[var_field const_path_field top_const_field].include?(target&.first) &&
        const.is_a?(Array) && const[0] == :@const && const[1] == "VERSION"
    end

    def string_value(node)
      node = frozen_receiver(node)
      return unless node.is_a?(Array) && node.first == :string_literal

      parts = node[1][1..]
      parts.map { |p| p[0] == :@tstring_content ? p[1] : (return nil) }.join
    end

    def load_workflow(path)
      data = YAML.safe_load_file(path, aliases: true)
      data.is_a?(Hash) ? data : nil
    rescue Psych::Exception
      nil
    end

    # YAML 1.1 reads the bare key `on` as boolean true.
    def triggers(workflow)
      on = workflow.fetch("on") { workflow[true] }
      on.is_a?(Hash) ? on : {}
    end

    def next_version_input?(workflow)
      dispatch = triggers(workflow)["workflow_dispatch"]
      inputs = dispatch.is_a?(Hash) ? dispatch["inputs"] : nil
      inputs.is_a?(Hash) && inputs.key?("next_version")
    end

    def do_release?(workflow)
      dispatch = triggers(workflow)["repository_dispatch"]
      types = dispatch.is_a?(Hash) ? Array(dispatch["types"]) : []
      types.include?("do-release")
    end

    def reusable_job?(workflow)
      jobs = workflow["jobs"]
      jobs.is_a?(Hash) && jobs.values.any? do |job|
        job.is_a?(Hash) && REUSABLE_RELEASE.match?(job["uses"].to_s) &&
          runnable?(job)
      end
    end

    # `if: false`, bare or wrapped in ${{ }}, skips the job on every run
    def runnable?(job)
      condition = job["if"].to_s.delete_prefix("${{").delete_suffix("}}").strip
      condition != "false"
    end

    def finding(rule, message)
      Finding.new(rule: rule, message: message)
    end
  end
end
