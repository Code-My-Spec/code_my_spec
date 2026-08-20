defmodule CodeMySpec.Validation.EditsTheLedgerCannotSeeTest do
  @moduledoc """
  An empty edit ledger is not proof that the session edited nothing.

  Story 894's rule — an agent that made no edits is blocked by nothing —
  answers a question about the world, and `FileEdits` is only one witness to
  it. `PostToolUse` records a path from `tool_input.file_path`, which `Write`
  and `Edit` carry and `Bash` does not. An agent working through a heredoc,
  `sed -i`, or a script it writes and runs leaves the ledger empty while its
  edits sit plainly on disk.

  Taking the ledger's silence at face value would hand precisely that agent a
  blanket exemption from every finding in the project — the failure the rule
  was written to end, pointed the other way, and unnoticeable from the outside
  because an exempt agent looks exactly like a clean one.

  So the ledger's silence is corroborated against the files the pipeline is
  already analyzing for this task. The distinction the two cases turn on:

    * ledger empty, nothing changed on disk → the session really did edit
      nothing, and owns nothing. The QA case the rule exists for.
    * ledger empty, files changed on disk → the session edited; the ledger
      just could not see how. Attribution is unusable, so nothing is demoted.

  Disk answers only *whether*, never *what*. Widening attribution from it would
  credit this session with whatever else changed in the working copy while its
  task ran, which is the thing attribution exists to prevent — so the second
  case is `nil`, never a set of paths.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files
  alias CodeMySpec.Validation
  alias Ecto.Adapters.SQL.Sandbox

  @session "shell-edit-session"

  setup do
    Sandbox.mode(CodeMySpec.Repo, {:shared, self()})

    scope = full_scope_fixture()

    {2, _rows} =
      Files.upsert_files(scope, [
        %{path: "lib/mine.ex", role: :implementation, fingerprint: "a", valid: true},
        %{path: "lib/theirs.ex", role: :implementation, fingerprint: "b", valid: true}
      ])

    %{scope: scope}
  end

  # What the pipeline hands `check_blocking_problems/4`: the files this task
  # changed, already computed against the task's `started_at`.
  defp changed(paths), do: Enum.map(paths, &%{path: &1, component_id: nil})

  defp paths_for(scope, changed_files),
    do: Validation.session_paths_for_test(scope, [session_id: @session], changed_files)

  describe "the ledger is empty" do
    test "and nothing changed on disk — the session owns nothing", ctx do
      paths = paths_for(ctx.scope, changed([]))

      assert paths == MapSet.new(),
             "an empty set is what demotes every finding, which is story 894's rule. " <>
               "nil here would block a session that provably did nothing."
    end

    test "but files changed on disk — attribution is unusable, so nothing is demoted", ctx do
      paths = paths_for(ctx.scope, changed(["lib/mine.ex"]))

      assert is_nil(paths),
             "this session edited through a tool the ledger cannot see. Sparing it " <>
               "would exempt every shell-editing agent from every finding."
    end

    test "disk does not name what the session edited", ctx do
      # The half that must not drift: a changed file is evidence the session
      # edited, never evidence it edited *that*. Another agent's write landing
      # in this working copy during the task would otherwise become this
      # session's to answer for.
      refute match?(%MapSet{}, paths_for(ctx.scope, changed(["lib/theirs.ex"])))
    end
  end

  describe "the ledger is not empty" do
    test "disk changes it did not record do not widen what it owns", ctx do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")

      paths = paths_for(ctx.scope, changed(["lib/mine.ex", "lib/theirs.ex"]))

      assert MapSet.to_list(paths) == ["lib/mine.ex"],
             "corroboration answers whether the session edited, not what"
    end
  end
end
