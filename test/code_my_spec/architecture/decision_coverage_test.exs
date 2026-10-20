defmodule CodeMySpec.Architecture.DecisionCoverageTest do
  @moduledoc """
  Issue bce21d41: nothing kept ADRs true, so they drifted into instructions to use
  retired libraries. Coverage is declared in frontmatter and compared with the
  direct dependencies in `mix.exs`.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Architecture.DecisionCoverage

  @mix_exs """
  defmodule App.MixProject do
    use Mix.Project

    def project, do: [deps: deps()]

    defp deps do
      [
        {:phoenix, "~> 1.8"},
        {:jason, "~> 1.2"},
        {:req, "~> 0.5", override: true},
        {:oban, "~> 2.0"},
        {:sobelow, "~> 0.13", only: [:dev, :test], runtime: false}
      ]
    end

    defp aliases, do: [test: ["ecto.reset", "test"]]
  end
  """

  defp adr(front, body \\ "# Use a thing\n\n## Status\nAccepted\n"),
    do: "---\n#{front}\n---\n" <> body

  test "direct deps are the packages declared inside defp deps, and nothing after it" do
    assert DecisionCoverage.direct_deps(@mix_exs) == ~w(phoenix jason req oban sobelow)
  end

  test "frontmatter lists what an ADR covers and declines; no frontmatter covers nothing" do
    assert DecisionCoverage.frontmatter(adr("deps: [phoenix, jason]\ndeclined: [wallaby]")) ==
             %{deps: ["phoenix", "jason"], declined: ["wallaby"]}

    assert DecisionCoverage.frontmatter("# Use Elixir\n") == %{deps: [], declined: []}
    assert DecisionCoverage.frontmatter(adr("deps: []")) == %{deps: [], declined: []}
  end

  test "every direct dependency covered is clean, and an ADR covering nothing is never flagged" do
    adrs = %{
      "phoenix.md" => adr("deps: [phoenix, jason, req]"),
      "oban.md" => adr("deps: [oban]"),
      "sobelow.md" => adr("deps: [sobelow]"),
      "elixir.md" => "# Use Elixir as the primary language\n",
      "daisyui.md" => adr("deps: []")
    }

    assert DecisionCoverage.check(@mix_exs, adrs) == []
    assert DecisionCoverage.report([]) =~ "covered by an ADR"
  end

  test "a dependency no ADR covers is reported" do
    adrs = %{"phoenix.md" => adr("deps: [phoenix, jason, req, oban]")}

    assert DecisionCoverage.check(@mix_exs, adrs) == [{:uncovered, "sobelow"}]
  end

  test "an ADR covering a dependency no longer in mix.exs is stale" do
    adrs = %{
      "phoenix.md" => adr("deps: [phoenix, jason, req, oban, sobelow]"),
      "exvcr.md" => adr("deps: [exvcr]")
    }

    assert DecisionCoverage.check(@mix_exs, adrs) == [{:stale, "exvcr.md", "exvcr"}]
  end

  test "an ADR declining a dependency that is present contradicts mix.exs" do
    adrs = %{
      "phoenix.md" => adr("deps: [phoenix, jason, req, oban, sobelow]"),
      "oban-no.md" => adr("declined: [oban, wallaby]")
    }

    assert DecisionCoverage.check(@mix_exs, adrs) == [
             {:declined_but_present, "oban-no.md", "oban"}
           ]
  end

  test "the report names what to do about each kind of finding" do
    report =
      DecisionCoverage.report([
        {:uncovered, "sobelow"},
        {:stale, "exvcr.md", "exvcr"},
        {:declined_but_present, "oban-no.md", "oban"}
      ])

    assert report =~ "3 decision finding(s)"
    assert report =~ "`sobelow` is a direct dependency no ADR covers"
    assert report =~ "exvcr.md covers `exvcr`"
    assert report =~ "oban-no.md declines `oban`"
  end
end
