# frozen_string_literal: true

module Ancora
  # Release notes generated from merged pull requests, never hand-written.
  # Input is the PR list since the previous tag (the `gh pr list --state
  # merged --json number,title,author,mergedAt,url` shape); output is
  # markdown. Pure: no network, so the notes are reproducible from the data.
  class ReleaseNotes
    def initialize(pull_requests)
      @pull_requests = validated(pull_requests)
    end

    def render(version)
      lines = ["## #{version}", ""]
      if merged.empty?
        lines << "No merged pull requests since the previous release."
      else
        merged.each { |pr| lines << entry(pr) }
      end
      "#{lines.join("\n")}\n"
    end

    private

    # only merged PRs, oldest first, so notes read in landing order
    def merged
      @merged ||= @pull_requests.select { |pr| pr["mergedAt"] }
        .sort_by { |pr| [pr["mergedAt"], pr["number"]] }
    end

    def validated(pull_requests)
      unless pull_requests.is_a?(Array) && pull_requests.all?(Hash)
        raise ArgumentError, "pull requests must be a JSON array of objects"
      end

      pull_requests.each do |request|
        problem = pull_request_problem(request)
        next unless problem

        raise ArgumentError, "pull request #{request.inspect}: #{problem}"
      end
    end

    def pull_request_problem(request)
      return "number must be an integer" unless request["number"].is_a?(Integer)
      return "title must be a string" unless request["title"].is_a?(String)
      return "mergedAt must be a timestamp string" unless
        optional?(request["mergedAt"], String)
      return "author must be an object" unless optional?(request["author"],
                                                         Hash)

      nil
    end

    def optional?(value, type)
      value.nil? || value.is_a?(type)
    end

    # one list item per PR: a newline in a title would start a markdown block
    def entry(request)
      title = request["title"].split(/[[:space:]]+/).join(" ")
      author = request.dig("author", "login")
      "- #{title} (##{request['number']}#{" @#{author}" if author})"
    end
  end
end
