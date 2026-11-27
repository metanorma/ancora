# frozen_string_literal: true

module Ancora
  # Applies a FloorFixer plan to gemspec files in a local checkout root
  # (<root>/<repo name>/**/<gem>.gemspec). Edits files only: no commit,
  # push, tag or release. Re-applying an applied plan is a no-op.
  class FloorApplier
    Outcome = Struct.new(:fix, :path, :status, keyword_init: true)

    def initialize(graph, root:)
      @graph = graph
      @root = root
    end

    def apply(fixes)
      fixes.group_by(&:from).flat_map { |gem, group| apply_gem(gem, group) }
    end

    private

    def apply_gem(gem, fixes)
      path = locate(gem)
      unless path
        return fixes.map do |f|
          Outcome.new(fix: f, path: nil, status: :no_gemspec)
        end
      end

      text, outcomes = edit(File.binread(path), fixes, path)
      File.binwrite(path, text) if outcomes.any? { |o| o.status == :patched }
      outcomes
    end

    def edit(text, fixes, path)
      outcomes = fixes.map do |fix|
        result = GemspecEdit.rewrite(text, fix.to, fix.proposed)
        text = result.text
        Outcome.new(fix: fix, path: path, status: result.status)
      end
      [text, outcomes]
    end

    def locate(gem)
      repo = @graph.nodes[gem]&.repo
      return unless repo

      dir = File.join(@root, File.basename(repo))
      Dir.glob(File.join(dir, "**", "#{gem}.gemspec")).min_by(&:size)
    end
  end
end
