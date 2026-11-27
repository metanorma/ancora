# frozen_string_literal: true

# records every command; failures and timeouts are scripted by substring
class RecordingShell
  attr_reader :calls

  def initialize(fail_on: [], time_out_on: [])
    @fail_on = fail_on
    @time_out_on = time_out_on
    @calls = []
  end

  def run(command, chdir:, env: {}, timeout: nil)
    text = Array(command).join(" ")
    @calls << { command: text, chdir: chdir, env: env, timeout: timeout }
    where = "#{chdir} #{text}"
    Ancora::Shell::Result.new(
      ok: [@fail_on, @time_out_on].flatten.none? { |s| where.include?(s) },
      output: "ran #{text}\nboom token-123\n",
      timed_out: @time_out_on.any? { |s| where.include?(s) },
    )
  end

  def commands
    @calls.map { |c| c[:command] }
  end
end
