# frozen_string_literal: true

require "spec_helper"

RSpec.describe Ancora::ReleaseNotes do
  let(:prs) do
    [
      { "number" => 12, "title" => "Fix table cells",
        "mergedAt" => "2026-11-02T10:00",
        "author" => { "login" => "alice" } },
      { "number" => 9, "title" => "Add figure ids",
        "mergedAt" => "2026-11-01T10:00",
        "author" => { "login" => "bob" } },
      { "number" => 11, "title" => "Closed unmerged", "mergedAt" => nil,
        "author" => { "login" => "eve" } },
    ]
  end

  it "lists merged PRs oldest first and drops unmerged ones" do
    expect(described_class.new(prs).render("1.2.4")).to eq(<<~MD)
      ## 1.2.4

      - Add figure ids (#9 @bob)
      - Fix table cells (#12 @alice)
    MD
  end

  it "says so when nothing merged" do
    expect(described_class.new([]).render("1.2.4"))
      .to include("No merged pull requests")
  end

  it "rejects input that is not an array of pull requests" do
    object = { "number" => 1, "mergedAt" => "2026-11-01" }
    expect { described_class.new(object) }
      .to raise_error(ArgumentError, /array of objects/)
  end

  it "rejects a null entry" do
    expect { described_class.new([nil]) }
      .to raise_error(ArgumentError, /array of objects/)
  end

  it "rejects a pull request without an integer number" do
    merged = { "title" => "a", "mergedAt" => "2026-11-01T00:00:00Z" }
    expect { described_class.new([merged, merged]).render("1.2.4") }
      .to raise_error(ArgumentError, /number/)
  end

  it "rejects a mergedAt that is not a timestamp string" do
    prs = [
      { "number" => 1, "title" => "a", "mergedAt" => "2026-11-01" },
      { "number" => 2, "title" => "b", "mergedAt" => 1_700_000_000 },
    ]
    expect { described_class.new(prs).render("1.2.4") }
      .to raise_error(ArgumentError, /mergedAt/)
  end

  it "rejects an author that is not an object" do
    prs = [{ "number" => 1, "title" => "a", "mergedAt" => "2026-11-01",
             "author" => "bob" }]
    expect { described_class.new(prs).render("1.2.4") }
      .to raise_error(ArgumentError, /author/)
  end

  it "keeps a title with a newline on one list item" do
    prs = [{ "number" => 2, "title" => "ok\n## Injected",
             "mergedAt" => "2026-11-01", "author" => { "login" => "a" } }]
    notes = described_class.new(prs).render("1.2.4")
    expect(notes).to include("- ok ## Injected (#2 @a)")
    expect(notes).not_to match(/^## Injected/)
  end
end
