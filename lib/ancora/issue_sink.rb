# frozen_string_literal: true

module Ancora
  # Files the report as a GitHub issue: updates the open issue with the
  # same title (re-runs within a week stay one issue), else creates it.
  # The only writer in ancora besides the manifest; the HTTP client is
  # injected so specs run offline.
  class IssueSink
    API_HOST = "api.github.com"
    REPOSITORY = %r{\A[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_][A-Za-z0-9_.-]*\z}

    def initialize(repo, token:, http: Net::HTTP)
      unless REPOSITORY.match?(repo)
        raise ArgumentError, "repo must be OWNER/NAME, got #{repo.inspect}"
      end

      @repo = repo
      @token = token
      @http = http
    end

    # Returns the issue's html_url.
    def publish(title:, body:, label:)
      existing = open_issues(label).find { |i| i["title"] == title }
      issue = if existing
                number = existing.fetch("number")
                request(Net::HTTP::Patch, "/repos/#{@repo}/issues/#{number}",
                        body: body)
              else
                request(Net::HTTP::Post, "/repos/#{@repo}/issues",
                        title: title, body: body, labels: [label])
              end
      issue.fetch("html_url")
    end

    private

    def open_issues(label)
      request(Net::HTTP::Get,
              "/repos/#{@repo}/issues?state=open&per_page=100" \
              "&labels=#{CGI.escape(label)}")
    end

    def request(klass, path, payload = nil, **fields)
      payload ||= fields unless fields.empty?
      req = klass.new(path, "Authorization" => "Bearer #{@token}",
                            "Accept" => "application/vnd.github+json",
                            "Content-Type" => "application/json")
      req.body = JSON.generate(payload) if payload
      res = @http.start(API_HOST, 443, use_ssl: true, open_timeout: 10,
                                       read_timeout: 30) { |h| h.request(req) }
      unless res.is_a?(Net::HTTPSuccess)
        raise "GitHub #{klass::METHOD} #{path}: #{res.code} #{res.body}"
      end

      JSON.parse(res.body)
    end
  end
end
