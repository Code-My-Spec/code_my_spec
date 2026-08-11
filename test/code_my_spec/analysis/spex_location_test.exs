defmodule CodeMySpec.Analysis.SpexLocationTest do
  @moduledoc """
  Which file a spex failure is filed against.

  `error.file` is the top stacktrace frame. For an assertion written in the spec
  that is the spec, which is why taking it worked for so long. For anything that
  *raises* from library code it is the library: two cassette failures landed on
  `lib/req_cassette/plug.ex:481` and `:607` — the plug that raised — with
  nothing left pointing at the specs that failed.

  Three costs, and the first is the expensive one. A spex path carries its story
  id and a library path carries nothing, so the finding cannot be traced back to
  the work it belongs to. It reads as a bug in the library rather than a
  cassette that was never recorded. And under `:block_changed` it blocks
  whoever touches the library, who is never the person who can fix it.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Analysis.Runners

  @spec_file "test/spex/972_publishing/criterion_8039_the_site_is_deployed_spex.exs"

  defp raw(diagnostics), do: %{"exit_status" => 1, "diagnostics" => diagnostics}

  defp problems(diagnostics) do
    {:ok, result} = Runners.from_raw("spex", raw(diagnostics))
    result.problems
  end

  describe "from_raw/2 keeps the wire contract" do
    test "a diagnostic is filed at the file and line it carries" do
      [problem] =
        problems([
          %{
            "spex" => "A visitor finds the widget",
            "scenario" => "the widget renders",
            "file" => @spec_file,
            "line" => 42,
            "message" => "ReqCassette: Cassette not found"
          }
        ])

      assert problem.file_path == @spec_file
      assert problem.line == 42
    end
  end

  # `run/4` is what chooses the location before it reaches `from_raw/2`, and it
  # is the half that was wrong. Driving it needs a live `mix spex`, so the rule
  # itself is asserted here against the failure shape the runner parses.
  describe "the location rule" do
    defp locate(error), do: Runners.spex_location(error)

    test "a raise from library code is filed against the spec, not the library" do
      error = %{
        file: "lib/req_cassette/plug.ex",
        line: 481,
        stacktrace: [
          %{"file" => "lib/req_cassette/plug.ex", "line" => 481},
          %{"file" => @spec_file, "line" => 27},
          %{"file" => "lib/ex_unit/runner.ex", "line" => 528}
        ]
      }

      assert {@spec_file, 27} = locate(error),
             "filed against the plug, the story link is gone — a spex path carries its " <>
               "story id and a library path carries nothing"
    end

    # Taking the file without the line would pair a spec path with a line number
    # from somewhere else, which is worse than either alone.
    test "the file and the line come from the same frame" do
      {file, line} =
        locate(%{
          file: "lib/req_cassette/plug.ex",
          line: 481,
          stacktrace: [
            %{"file" => "lib/req_cassette/plug.ex", "line" => 481},
            %{"file" => @spec_file, "line" => 27}
          ]
        })

      assert file == @spec_file
      assert line == 27
    end

    test "an assertion in the spec is unchanged" do
      error = %{
        file: @spec_file,
        line: 27,
        stacktrace: [
          %{"file" => "lib/ex_unit/assertions.ex", "line" => 461},
          %{"file" => @spec_file, "line" => 27}
        ]
      }

      assert {@spec_file, 27} = locate(error)
    end

    # No spec frame at all — a raise from a setup block, a shared fixture or a
    # plug, with nothing in the trace naming the spec that was running.
    #
    # This used to keep the error's own location, on the reasoning that
    # somewhere beat nowhere. It recurred with that fix in place: a cassette
    # miss raised inside `ReqCassette.Plug` and two spex failures were filed at
    # `lib/req_cassette/plug.ex:481` — no story, no criterion, and blocking for
    # whoever next touched the plug. A spex failure belongs to a spec or to no
    # file.
    test "with no spec frame it names no file rather than the wrong one" do
      error = %{
        file: "lib/req_cassette/plug.ex",
        line: 481,
        stacktrace: [%{"file" => "lib/req_cassette/plug.ex", "line" => 481}]
      }

      assert {nil, nil} = locate(error),
             "filing a spex failure against a library loses its story and blocks " <>
               "whoever touches the library"
    end

    test "a missing stacktrace names no file either" do
      assert {nil, nil} = locate(%{file: "a.ex", line: 1, stacktrace: nil})
    end

    test "no error at all locates nothing" do
      assert {nil, nil} = locate(nil)
    end
  end
end
