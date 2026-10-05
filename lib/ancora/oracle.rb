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
        prefix = "#{target}.pre.alpha."
        versions(gem)
          .filter_map do |v|
          v["number"][/\A#{Regexp.escape(prefix)}(\d+)\z/,
                      1]
        end
          .map(&:to_i).max.to_i
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
  end
end
