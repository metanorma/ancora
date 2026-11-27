# frozen_string_literal: true

module Ancora
  # Renders a FleetDrift::Report as the markdown body of the weekly
  # report issue. Pure: same report in, same text out.
  class DriftReport
    # GitHub rejects issue bodies over 65536 characters.
    MAX_BODY = 60_000
    LABEL = "drift-report"
    WHOLE_FLEET = "whole fleet"

    def initialize(report, scope: WHOLE_FLEET, date: Date.today)
      @report = report
      @scope = scope
      @date = date
    end

    def title
      week = @date.strftime("%G-W%V")
      return "Fleet drift report #{week}" if @scope == WHOLE_FLEET

      "Fleet drift report #{week} (#{@scope})"
    end

    def body
      text = sections.join("\n\n")
      return text if text.size <= MAX_BODY

      note = "_(truncated; run `ancora drift-report` for the full report)_"
      "#{text[0, MAX_BODY]}\n\n#{note}"
    end

    private

    def sections
      [header, summary, drifting, untagged, floors, unpublished, behind]
    end

    def rows
      @report.rows
    end

    def header
      "Generated #{@date.iso8601} by `ancora drift-report` over " \
        "#{rows.size} gems (#{@scope})."
    end

    def summary
      <<~MD.chomp
        ## Summary

        - gems ahead of their release: #{rows.count { |r| r.ahead_by.positive? }}
        - gems behind their release: #{rows.count(&:behind)}
        - latest release without a git tag: #{untagged_count}
        - floor violations: #{floor_count}
      MD
    end

    def untagged_count
      return "not checked" unless @report.tags_checked

      count = rows.count(&:untagged_release?)
      unknown = rows.count { |r| r.tagged == :unknown }
      return count.to_s if unknown.zero?

      "#{count} (#{unknown} unknown: GitHub did not answer)"
    end

    def floor_count
      d = @report.drift
      d.floorless.size + d.stale_pins.size + d.prerelease_floors.size +
        @report.unpublished_floors.size
    end

    def drifting
      list("Ahead of release (unreleased commits)",
           rows.select { |r| r.ahead_by.positive? }
               .sort_by { |r| [-r.ahead_by, r.gem] }) do |r|
        "`#{r.gem}` (#{r.repo}): #{r.ahead_by} commits since #{r.released}"
      end
    end

    def behind
      list("Behind release (main older than the latest release)",
           rows.select(&:behind)) do |r|
        "`#{r.gem}`: main #{r.main_version}, released #{r.released}"
      end
    end

    def untagged
      list("Releases without a git tag",
           rows.select(&:untagged_release?)) do |r|
        "`#{r.gem}` (#{r.repo}): v#{r.released} not tagged"
      end
    end

    def floors
      d = @report.drift
      [floorless(d), stale_pins(d), prerelease_floors(d)].join("\n\n")
    end

    def floorless(drift)
      list("Floorless edges", drift.floorless) do |e|
        "`#{e.from}` -> `#{e.to}`"
      end
    end

    def stale_pins(drift)
      list("Stale pins", drift.stale_pins) do |s|
        "`#{s.from}` -> `#{s.to}`: #{s.constraints.join(', ')} " \
          "excludes main #{s.main_version}"
      end
    end

    def prerelease_floors(drift)
      list("Prerelease floors", drift.prerelease_floors) do |e|
        "`#{e.from}` -> `#{e.to}`: #{e.constraints.join(', ')}"
      end
    end

    def unpublished
      list("Floors the latest release does not satisfy",
           @report.unpublished_floors) do |f|
        "`#{f.from}` -> `#{f.to}`: #{f.constraints.join(', ')} " \
          "vs #{f.released ? "latest release #{f.released}" : 'no release yet'}"
      end
    end

    def list(title, items)
      lines = items.map { |item| "- #{yield(item)}" }
      ["## #{title} (#{items.size})", "", *lines].join("\n")
    end
  end
end
