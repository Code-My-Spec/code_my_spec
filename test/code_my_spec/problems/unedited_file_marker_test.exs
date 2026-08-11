defmodule CodeMySpec.Problems.UneditedFileMarkerTest do
  @moduledoc """
  A blocking finding in a file this session never opened says so.

  Several agents share one repo here and rebase onto main, so a warning one
  agent pushes becomes a hard block on every other agent's stop, presented in
  the same voice as their own work. Reported three times in three shapes:
  compiler warnings from another branch's in-flight file (`7a0fadeb`), spex
  failures eight days older than the session (`d3fa4dc1`), and credo infos
  recorded two days before the file was opened.

  It is not merely noise. In `7a0fadeb` the obvious repair — deleting an unused
  `@endpoint` — was actively wrong: the override exists because that story's
  preview is served by a different endpoint, and removing it silently falls
  back to the local one, which `~p` binds at compile time. So the blocked agent
  is steered toward introducing a silent wrong-target bug in code they do not
  own.

  `FileEdits` already records `{session, agent, path}` per edit, so this is a
  lookup rather than a git call — and it answers the question actually being
  asked ("did *I* touch this?") rather than the one git answers ("who committed
  it last?").

  This marks; it does not demote. Whether an unattributed finding should still
  block is a policy decision about what the gate is for, and a bug in this
  would silently switch the gate off — so the change that could do that is not
  the one to make from a message renderer.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.ProblemRenderer

  defp problem(path) do
    %CodeMySpec.Problems.Problem{
      source: "compiler",
      severity: :error,
      file_path: path,
      line: 12,
      message: "module attribute @endpoint was set but never used",
      category: "warning"
    }
  end

  defp render(paths, opts) do
    ProblemRenderer.render_stop_response(Enum.map(paths, &problem/1), [], opts)
  end

  describe "when the session's edits are known" do
    test "a finding in a file the session never edited is marked" do
      out = render(["lib/theirs.ex"], session_paths: MapSet.new(["lib/mine.ex"]))

      assert out =~ "not edited by this session"
    end

    test "a finding in a file the session did edit is not marked" do
      out = render(["lib/mine.ex"], session_paths: MapSet.new(["lib/mine.ex"]))

      refute out =~ "not edited by this session"
    end

    test "with both, only the foreign one is marked" do
      out =
        render(["lib/mine.ex", "lib/theirs.ex"], session_paths: MapSet.new(["lib/mine.ex"]))

      [mine, theirs] =
        out
        |> String.split("\n")
        |> Enum.filter(&String.starts_with?(&1, "  - lib/"))
        |> Enum.sort()

      assert mine =~ "lib/mine.ex"
      refute mine =~ "not edited by this session"
      assert theirs =~ "lib/theirs.ex"
      assert theirs =~ "not edited by this session"
    end
  end

  describe "when the session's edits are not known" do
    test "an empty set marks nothing" do
      # No evidence either way. A session that recorded no edits may have
      # written nothing, or attribution may be broken — a restart, or a path
      # shape that does not normalize. Marking every finding foreign on the
      # second reading would tell an agent to ignore its own work, so absence
      # of evidence stays silent.
      out = render(["lib/theirs.ex"], session_paths: MapSet.new())

      refute out =~ "not edited by this session"
    end

    test "no option at all renders exactly as before" do
      assert render(["lib/theirs.ex"], []) == render(["lib/theirs.ex"], session_paths: nil)
    end
  end
end
