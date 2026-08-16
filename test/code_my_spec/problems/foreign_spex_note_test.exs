defmodule CodeMySpec.Problems.ForeignSpexNoteTest do
  @moduledoc """
  A red spex in a file this session never touched still blocks, and the response
  has to say why.

  `(not edited by this session)` means "demoted to advisory" on every source
  except spex, which `@attribution_exempt_sources` exempts. So the identical
  marker sits on a finding that is still blocking and the reader has no way to
  tell the two apart — the only reading available is "somebody else's problem
  and I am stuck behind it".

  `b9a9f9bc` is that bind. Story 985 blocked four unrelated sessions before
  anyone traced why.

  The note has to be *accurate* as well as present, which is the part worth
  testing: `specs_ready` is earned by a green spex run and cleared whenever the
  story is released or parked, so a red spex on a latched story is a regression
  rather than an optimistic latch. A gate message that named the wrong cause
  would send its reader to unlatch a story that has nothing wrong with its
  readiness.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.Problems.{Problem, ProblemRenderer}

  defp problem(source, path) do
    %Problem{source: source, severity: :error, file_path: path, line: 12, message: "red"}
  end

  defp render(problems, session_paths) do
    ProblemRenderer.render_stop_response(problems, [], session_paths: session_paths)
  end

  @mine "test/spex/985_x/criterion_1_spex.exs"
  @theirs "test/spex/985_x/criterion_2_spex.exs"

  test "explains itself when the blocking spex is in a file this session did not touch" do
    text = render([problem("spex", @theirs)], MapSet.new([@mine]))

    assert text =~ "not edited by this session"

    assert text =~ "attribution does not demote",
           "without this the marker reads the same as credo's, where it means the " <>
             "opposite — demoted and not blocking"

    assert text =~ "regression in this working copy",
           "the latch is earned by a green run, so red-on-latched means it went " <>
             "green and came back red; calling it an optimistic latch would send " <>
             "the reader to fix the wrong thing"

    assert text =~ "ready_for_dev",
           "there has to be an escape that is not 'edit spex you do not own'"
  end

  test "stays quiet when the blocking spex is this session's own" do
    text = render([problem("spex", @mine)], MapSet.new([@mine]))

    refute text =~ "attribution does not demote",
           "an agent looking at a spex it just broke does not need a paragraph " <>
             "about latches"
  end

  # An empty set is "attribution broke or the session wrote nothing", not "this
  # is foreign" — `unedited_marker/2` stays silent there for the same reason,
  # and a note claiming the finding belongs to someone else would be inventing
  # the evidence the marker declined to.
  test "stays quiet when nothing could be attributed" do
    text = render([problem("spex", @theirs)], MapSet.new([]))

    refute text =~ "attribution does not demote"
  end

  test "does not explain non-spex sources, which really are demoted" do
    text = render([problem("credo", "lib/a.ex")], MapSet.new([@mine]))

    refute text =~ "attribution does not demote"
  end
end
