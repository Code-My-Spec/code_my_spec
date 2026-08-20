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

  # `project_changed?` — whether anything in the project moved while this task
  # ran, read before attribution narrows anything. A boolean on purpose: it is
  # evidence that the session edited, never evidence of what.
  defp paths_for(scope, project_changed?),
    do: Validation.session_paths_for_test(scope, [session_id: @session], project_changed?)

  describe "the ledger is empty" do
    test "and nothing in the project moved — the session owns nothing", ctx do
      assert paths_for(ctx.scope, false) == MapSet.new(),
             "an empty set is what demotes every finding, which is story 894's rule. " <>
               "nil here would block a session that provably did nothing."
    end

    test "but the project moved — attribution is unusable, so nothing is demoted", ctx do
      assert is_nil(paths_for(ctx.scope, true)),
             "this session edited through a tool the ledger cannot see. Sparing it " <>
               "would exempt every shell-editing agent from every finding."
    end
  end

  describe "the ledger names only files this project does not track" do
    # The QA case, and the reason this is not simply "the ledger is empty":
    # `.code_my_spec/qa/` is gitignored, so `Files` never rows it and the paths
    # join nothing. Real work, no project file, owns none of the project's red.
    test "and the project did not otherwise move, it owns nothing", ctx do
      :ok = FileEdits.track_edit(@session, ".code_my_spec/qa/884/brief.md")

      assert paths_for(ctx.scope, false) == MapSet.new()
    end

    # And the case the old `nil` was written for, which still answers `nil`: a
    # recording that names nothing joinable *while the project demonstrably
    # moved* is a recording that failed, not a session that stayed still.
    #
    # This scope has no cwd — the light harness shape — so there is nothing to
    # measure a path against and every recorded path counts as inside. That is
    # the ambiguity 9a623a13 is about, and it is why the corroboration has to
    # answer it rather than the path.
    test "and the project did move, attribution is broken and blocks", ctx do
      :ok = FileEdits.track_edit(@session, "lib/never_synced.ex")

      assert is_nil(paths_for(ctx.scope, true))
    end

    # With a cwd there is a third answer, and it is not "broken". A path that
    # stays absolute after `relativize/2` is a path under some other root: a
    # different repo, a scratchpad, another worktree. The session did edit, and
    # not here — so the project moving underneath it says nothing about what it
    # owns (042e343b).
    test "and a cwd shows the edits went to another repo, it owns nothing here", ctx do
      :ok = FileEdits.track_edit(@session, "/Users/someone/devops_drill/lib/webhooks.ex")

      scope = %{ctx.scope | cwd: "/Users/someone/code_my_spec"}

      assert Validation.session_paths_for_test(scope, [session_id: @session], true) ==
               MapSet.new()
    end
  end

  describe "the ledger names files this project tracks" do
    test "a project that moved does not widen what the session owns", ctx do
      :ok = FileEdits.track_edit(@session, "lib/mine.ex")

      assert MapSet.to_list(paths_for(ctx.scope, true)) == ["lib/mine.ex"],
             "corroboration answers whether the session edited, not what. Widening " <>
               "from disk would credit this session with whatever else changed in " <>
               "the working copy while its task ran."
    end
  end
end
