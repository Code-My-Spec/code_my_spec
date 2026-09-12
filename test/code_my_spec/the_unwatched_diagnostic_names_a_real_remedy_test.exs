defmodule CodeMySpec.TheUnwatchedDiagnosticNamesARealRemedyTest do
  @moduledoc """
  `DevState`'s "no GraphWatcher" disagreement must name a remedy that exists.

  It used to end "until something reads the graph". Nothing on the read path
  starts a watcher — `RequirementsLive.provenance/2` calls `status/1`, which is
  read-only, and `Requirements.cached_all/1` does not ensure one either. A QA
  agent did exactly what the sentence said, read the graph page twice, checked
  `/dev/state` after each, got `watching: false` both times, and only turned it
  into a report because it grepped `ensure_watching/1` rather than shrugging
  (`07f42ebf`). A cycle went to it, and the claim had been copied from this
  sentence into a seed's documentation.

  The same false claim was in `application.ex`, justifying `:temporary` on the
  seeding task with "the next stop decision on a project starts its watcher
  anyway". There is no stop-path caller either.

  A diagnostic that sends a reader to a dead end is worse than one that says
  nothing, because the reader spends the cycle before doubting it.

  So this pins the invariant the sentence depends on rather than its wording:
  the remedies it names — toggle a loop, restart the server — are the only two
  things that start a watcher. If a third caller appears, especially on a read
  path, this fails and the sentence gets revisited on purpose.
  """
  use ExUnit.Case, async: true

  # Everywhere outside `GraphWatcher` itself that starts one, and why each is a
  # remedy a reader can actually perform.
  #
  # `graph_watcher.ex` is excluded because it defines the function and calls it
  # from `watch_active_projects/0` — that is the boot task, and it is the
  # "restart the server" remedy rather than a separate caller to police.
  @callers %{
    "lib/code_my_spec/agents.ex" =>
      "the two continuous toggles — the 'toggle an agent's loop' remedy"
  }

  @definer "lib/code_my_spec/requirements/graph_watcher.ex"

  defp calls_ensure_watching?(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.any?(fn line ->
      trimmed = String.trim(line)

      not String.starts_with?(trimmed, "#") and
        not String.contains?(line, "`") and
        String.contains?(line, "GraphWatcher.ensure_watching(") and
        not String.contains?(line, "@spec")
    end)
  end

  test "nothing outside GraphWatcher starts a watcher except the continuous toggles" do
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&(&1 == @definer))
      |> Enum.filter(&calls_ensure_watching?/1)
      |> Enum.sort()

    assert callers == Enum.sort(Map.keys(@callers)),
           """
           The set of things that start a GraphWatcher has changed.

           `DevState`'s "no GraphWatcher" disagreement names the remedies a reader
           can perform, and that sentence is only true while this list is. If you
           have added a read-path caller, the diagnostic should stop telling
           people to toggle a loop; if you have added another, it should say so.

           Expected: #{inspect(Map.keys(@callers))}
           Found:    #{inspect(callers)}
           """
  end

  test "the diagnostic does not send the reader back to the read path" do
    source = File.read!("lib/code_my_spec/dev_state.ex")

    [sentence] =
      Regex.run(~r/"project #\{project\.name\} has agents in the loop[^"]*"[^\]]*/, source)
      |> List.wrap()
      |> Enum.take(1)

    refute sentence =~ "until something reads the graph",
           "this is the exact claim that cost a QA cycle"

    assert sentence =~ "toggle"
    assert sentence =~ "restart"
  end
end
