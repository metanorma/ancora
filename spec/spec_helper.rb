# frozen_string_literal: true

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require "ancora"
require "tempfile"
require "webmock/rspec"

WebMock.disable_net_connect!
require_relative "support/fleet_fixture"
