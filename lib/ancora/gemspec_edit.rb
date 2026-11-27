# frozen_string_literal: true

module Ancora
  # Rewrites ONE runtime dependency's constraints in gemspec text. Only
  # the plain literal form is touched:
  #
  #   spec.add_dependency "name", "~> 1.0", ">= 1.2"   # optional comment
  #
  # Anything else (constraint arrays, interpolation, a name declared twice,
  # no declaration) is reported as unpatchable rather than guessed at.
  module GemspecEdit
    Result = Struct.new(:text, :status, keyword_init: true)
    Scan = Struct.new(:in_block, :terminators)
    Terminator = Struct.new(:tag, :indented)

    LITERAL = /"(?:[^"\\#]|#(?!\{))*"|'[^'\\]*'/
    TAIL = /\A(?:\s*,\s*(?:#{LITERAL}))*(?<rest>\s*\)?\s*(?:#.*)?)\z/

    def self.rewrite(text, name, constraints)
      lines = text.lines
      code = code_lines(lines)
      index = code.select { |i| declares?(lines[i], name) }
      failure = refusal(index.size)
      return Result.new(text: text, status: failure) if failure

      patch(text, lines, index.first, name, constraints)
    end

    def self.patch(text, lines, at, name, constraints)
      edited = edit_line(lines[at], name, constraints)
      return Result.new(text: text, status: :unpatchable) unless edited

      lines[at] = edited
      Result.new(text: lines.join, status: status_of(lines.join, text))
    end

    HEREDOC = /<<(?<indent>[~-]?)
      (?:(?<q>["'`])(?<tag>[^"'`]+)\k<q>|(?<bare>[A-Z_a-z]\w*))/x

    # indexes of lines that are code: not inside =begin/=end, a heredoc
    # body, or after __END__ (text that merely looks like a declaration
    # must never be patched in place of the real one)
    def self.code_lines(lines)
      stop = lines.index { |l| l.start_with?("__END__") } || lines.size
      state = Scan.new(false, [])
      (0...stop).select { |i| advance(state, lines[i]) }
    end

    # true when the line is code; updates the block/heredoc state
    def self.advance(state, line)
      state.in_block ||= line.start_with?("=begin")
      live = !state.in_block && state.terminators.empty?
      state.in_block = false if line.start_with?("=end")
      state.terminators = next_terminators(line, state.terminators)
      live
    end

    # heredoc bodies run until a line holding only the tag; a line that
    # opens heredocs queues their tags in order
    def self.next_terminators(line, terminators)
      return terminators.drop(1) if closes_heredoc?(line, terminators)
      return terminators unless terminators.empty?

      line.to_enum(:scan, HEREDOC).map { Regexp.last_match }.map do |m|
        Terminator.new(m[:tag] || m[:bare], !m[:indent].empty?)
      end
    end

    # <<~ and <<- allow an indented terminator; a bare << does not
    def self.closes_heredoc?(line, terminators)
      return false if terminators.empty?

      first = terminators.first
      text = line.chomp
      first.indented ? text.lstrip == first.tag : text == first.tag
    end

    def self.refusal(count)
      return :not_found if count.zero?

      :ambiguous if count > 1
    end

    def self.status_of(new_text, old_text)
      new_text == old_text ? :unchanged : :patched
    end

    def self.declares?(line, name)
      line.match?(declaration(name))
    end

    def self.declaration(name)
      /\A(?<head>\s*[\w.]+\.add_(?:runtime_)?dependency\s*\(?\s*)
        (?<q>["'])#{Regexp.escape(name)}\k<q>(?<tail>.*?)(?<nl>\r?\n?)\z/x
    end

    def self.edit_line(line, name, constraints)
      match = line.match(declaration(name))
      tail = match[:tail].match(TAIL)
      return unless tail

      list = constraints.map { |c| %(, "#{c}") }.join
      "#{match[:head]}#{match[:q]}#{name}#{match[:q]}#{list}" \
        "#{tail[:rest]}#{match[:nl]}"
    end
  end
end
