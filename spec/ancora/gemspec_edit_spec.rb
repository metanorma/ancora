# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::GemspecEdit do
  def rewrite(text, constraints = [">= 1.2.0"])
    described_class.rewrite(text, "dep", constraints)
  end

  it "replaces the constraints of a literal declaration, keeping comments" do
    result = rewrite(%(  spec.add_dependency "dep", "~> 1.0" # keep me\n))

    expect(result.status).to eq :patched
    expect(result.text)
      .to eq(%(  spec.add_dependency "dep", ">= 1.2.0" # keep me\n))
  end

  it "adds a floor to a floorless declaration" do
    result = rewrite(%(  spec.add_dependency "dep"\n))

    expect(result.text).to eq(%(  spec.add_dependency "dep", ">= 1.2.0"\n))
  end

  it "handles single quotes, parenthesised calls and several constraints" do
    result = rewrite(%(  s.add_runtime_dependency('dep', '< 2', '>= 1')\n),
                     [">= 1.2.0", "< 2"])

    expect(result.text)
      .to eq(%(  s.add_runtime_dependency('dep', ">= 1.2.0", "< 2")\n))
  end

  it "reports unchanged when the declaration already matches" do
    expect(rewrite(%(  spec.add_dependency "dep", ">= 1.2.0"\n)).status)
      .to eq :unchanged
  end

  it "leaves other dependencies and development dependencies alone" do
    text = %(  spec.add_dependency "dep-other", "~> 1"\n) +
      %(  spec.add_development_dependency "dep", "~> 1"\n)

    result = rewrite(text)

    expect(result.status).to eq :not_found
    expect(result.text).to eq text
  end

  it "refuses constraint arrays, interpolation and repeated declarations" do
    array = %(  spec.add_dependency "dep", [">= 1", "< 2"]\n)
    interpolated = %(  spec.add_dependency "dep", "~> \#{VERSION}"\n)
    twice = %(  spec.add_dependency "dep", "~> 1"\n) * 2

    expect(rewrite(array).status).to eq :unpatchable
    expect(rewrite(interpolated).status).to eq :unpatchable
    expect(rewrite(twice).status).to eq :ambiguous
    expect(rewrite(array).text).to eq array
  end

  it "never patches a declaration inside =begin/=end or after __END__" do
    declaration = %(  spec.add_dependency "dep", "~> 1"\n)
    text = "=begin\n#{declaration}=end\n#{declaration}__END__\n#{declaration}"

    result = rewrite(text)

    expect(result.status).to eq :patched
    expect(result.text.lines.map { |l| l.include?(">= 1.2.0") })
      .to eq [false, false, false, true, false, false]
  end

  it "does not find a declaration that only lives in a comment block" do
    text = %(=begin\n  spec.add_dependency "dep", "~> 1"\n=end\n)

    expect(rewrite(text).status).to eq :not_found
  end

  it "never patches declaration-looking text inside a heredoc" do
    text = <<~RUBY
      s.description = <<~DOC
        s.add_dependency "dep", "~> 1"
      DOC
      s.notes = [<<~ONE, <<~TWO]
        s.add_dependency "dep", "~> 1"
      ONE
        s.add_dependency "dep", "~> 1"
      TWO
      s.add_dependency(
        "dep", "~> 1"
      )
    RUBY

    expect(rewrite(text).status).to eq :not_found
    expect(rewrite(text).text).to eq text
    live = %(s.description = <<~DOC\n  x\nDOC\ns.add_dependency "dep", "~> 1"\n)
    expect(rewrite(live).text.lines.last)
      .to eq(%(s.add_dependency "dep", ">= 1.2.0"\n))
  end

  it "ends a bare heredoc only at an unindented terminator" do
    declaration = %(s.add_dependency "dep", "~> 1"\n)
    text = "s.description = <<DOC\n  DOC\n#{declaration}DOC\n#{declaration}"

    result = rewrite(text)

    expect(result.status).to eq :patched
    expect(result.text.lines.map { |l| l.include?(">= 1.2.0") })
      .to eq [false, false, false, false, true]
  end
end
