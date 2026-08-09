defmodule CmsHarness.SpexDiagnosticTest do
  @moduledoc """
  The harness builds its spex diagnostic with the shared location rule.

  This test exists because its absence cost three stops. There were two copies
  of the same logic — this module, which is what a light harness executes, and
  `CodeMySpec.Analysis.Runners.run/4` for a server holding the disk itself. The
  location fix went into the second one, was tested there, passed, and changed
  nothing observable: the same two cassette failures came back filed against
  `lib/req_cassette/plug.ex` from a harness restarted specifically to pick it
  up.

  So the property worth pinning is not "the rule is correct" — that lives in
  `CodeMySpec.Analysis.SpexLocationTest` — but "the harness uses it". A third
  copy would pass that test and fail this one.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Analysis
  alias CodeMySpec.BddSpecs.Spex

  @spec_file "test/spex/972_my_blog_publishes/criterion_8039_site_deployed_spex.exs"

  defp failure(error) do
    %Spex.Failure{
      spex: "A visitor finds the widget on the live site",
      scenario: "the widget renders and can be opened on the deployed site",
      steps: [],
      error: error
    }
  end

  test "a raise from library code is filed against the spec, not the library" do
    diagnostic =
      Analysis.spex_failure(
        failure(%Spex.Error{
          message: "ReqCassette: Cassette not found: test/cassettes/972_8039_site_deployed.json",
          file: "lib/req_cassette/plug.ex",
          line: 481,
          stacktrace: [
            %{"file" => "lib/req_cassette/plug.ex", "line" => 481},
            %{"file" => @spec_file, "line" => 34}
          ]
        })
      )

    assert diagnostic["file"] == @spec_file,
           "the harness kept its own copy of the location logic, so fixing the server's " <>
             "changed nothing that runs here"

    assert diagnostic["line"] == 34
    assert diagnostic["message"] =~ "Cassette not found"
  end

  test "an assertion inside the spec is unchanged" do
    diagnostic =
      Analysis.spex_failure(
        failure(%Spex.Error{
          message: "Assertion failed",
          file: @spec_file,
          line: 34,
          stacktrace: [
            %{"file" => "lib/ex_unit/assertions.ex", "line" => 461},
            %{"file" => @spec_file, "line" => 34}
          ]
        })
      )

    assert diagnostic["file"] == @spec_file
    assert diagnostic["line"] == 34
  end

  # The spex and scenario names ride along untouched — they are what makes the
  # finding readable once it is filed in the right place.
  test "the spex and scenario names survive" do
    diagnostic =
      Analysis.spex_failure(
        failure(%Spex.Error{message: "boom", file: @spec_file, line: 1, stacktrace: []})
      )

    assert diagnostic["spex"] == "A visitor finds the widget on the live site"
    assert diagnostic["scenario"] == "the widget renders and can be opened on the deployed site"
  end
end
