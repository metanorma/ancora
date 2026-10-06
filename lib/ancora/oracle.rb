# frozen_string_literal: true

module Ancora
  # Read-only clients over the external truths. Nothing in ancora ever
  # writes to these; the wave state machine is a cache over them.
  class Oracle
    class Rubygems
      VERSIONS_URL = "https://rubygems.org/api/v1/versions/%s.json"

      def initialize(http: Net::HTTP)
        @http = http
      end

      def published?(gem, version)
        versions(gem).any? { |v| v["number"] == version }
      end

      def latest(gem)
        versions(gem).first&.fetch("number", nil)
      end

      def next_candidate_index(gem, target)
        pattern = /\A#{Regexp.escape(target)}#{Regexp.escape(Candidate::PREFIX)}(\d+)\z/
        versions(gem)
          .filter_map { |v| v["number"][pattern, 1] }
          .map(&:to_i).max.to_i
      end

      # released finals only, newest first - the promote-gate truth for
      # external chains (nothing promotes against a prerelease)
      def finals(gem)
        versions(gem).map { |v| v["number"] }
          .reject { |n| Gem::Version.new(n).prerelease? }
      end

      private

      def versions(gem)
        @versions ||= {}
        @versions[gem] ||= begin
          uri = URI(format(VERSIONS_URL, gem))
          res = @http.start(uri.host, uri.port, use_ssl: true, open_timeout: 10,
                                                read_timeout: 30) { |h| h.get(uri.request_uri) }
          res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : []
        rescue StandardError
          []
        end
      end
    end

    class Github
      API_HOST = "api.github.com"
      TAGS = "/repos/%s/tags?per_page=100"
      WORKFLOW_RUNS = "/repos/%s/actions/runs?branch=%s&per_page=20"

      def initialize(http: Net::HTTP,
                     token: ENV.fetch("GITHUB_TOKEN", nil) || ENV.fetch("GH_TOKEN", nil))
        @http = http
        @token = token
      end

      # Git tags are truth for "did the release tag land". First page
      # only (100): release checks are for fresh tags, which page one
      # holds; deep-history queries are out of scope.
      def tags(repo)
        get(format(TAGS, repo), []).map { |t| t["name"] }
      end

      def tagged_version?(repo, version)
        tags(repo).include?("v#{version}")
      end

      # CI runs are truth for "is the branch green". The rake workflow
      # gates releases; a pending run is not green.
      def latest_run(repo, branch: "main", workflow: "rake")
        runs = get(format(WORKFLOW_RUNS, repo, CGI.escape(branch)), {})
        list = runs["workflow_runs"] || []
        list = list.select { |r| r["name"] == workflow } if workflow
        list.first
      end

      def green?(repo, branch: "main", workflow: "rake")
        run = latest_run(repo, branch: branch, workflow: workflow)
        !run.nil? && run["conclusion"] == "success"
      end

      private

      def get(path, on_error)
        uri = URI("https://#{API_HOST}#{path}")
        headers = @token ? { "Authorization" => "Bearer #{@token}" } : {}
        res = @http.start(uri.host, uri.port, use_ssl: true, open_timeout: 10,
                                              read_timeout: 30) { |h| h.get(uri.request_uri, headers) }
        res.is_a?(Net::HTTPSuccess) ? JSON.parse(res.body) : on_error
      rescue StandardError
        on_error
      end
    end
  end
end
