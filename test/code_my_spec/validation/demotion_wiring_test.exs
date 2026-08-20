defmodule CodeMySpec.Validation.DemotionWiringTest do
  @moduledoc """
  The demotion works through `validate_stop/3`, not just as a pure split.

  `split_unattributed/2` is unit-tested and the renderer is unit-tested, and
  neither touches the part that can actually be wrong: `session_paths/2` reads
  what PostToolUse recorded, relativizes it against `scope.cwd`, and compares
  it to `Problem.file_path`. Three representations have to line up, and the
  ways they fail to are all silent.

  Both recorded shapes are exercised here because both occur. Measured on the
  live database: this session recorded 368 paths, 259 project-relative and 109
  absolute — the harness normalizes repo paths before forwarding, and anything
  outside the working copy (a scratchpad) stays absolute. A guard that only
  handled one shape would look correct against half the traffic.

  What makes this worth an end-to-end test rather than more unit tests: a
  mismatch does not raise. It produces an empty attribution set, which
  `verify_against_ledger/3` reads as "unusable" and answers `nil` to — so the
  gate silently reverts to blocking on everything, which is the old behaviour
  and looks like nothing is wrong.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Validation

  @mine "lib/my_app/mine.ex"
  @theirs "lib/my_app/theirs.ex"
  @spex_path "test/spex/811_provisioning/criterion_6493_a_step_reports_its_provider_spex.exs"

  setup do
    {:ok, tmp} = Briefly.create(directory: true)
    scope = %{full_scope_fixture() | cwd: tmp, environment: Environment.new(:local, tmp)}

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{credo: :block_all})

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @mine), "defmodule MyApp.Mine do\nend\n")
    File.write!(Path.join(tmp, @theirs), "defmodule MyApp.Theirs do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope, tmp: tmp, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp stop(scope, session), do: Validation.validate_stop(scope, nil, session_id: session)

  # Spex is the source `d3fa4dc1` is about, and it does not reach the demotion
  # the way credo does. `split_by_story_enforcement/3` runs first and answers
  # from the owning story's `specs_ready` latch, so a spex failure is already
  # advisory while its story is mid-build — which is what makes enabling spex
  # project-wide survivable, and also what hides the demotion from every test
  # above: with the latch unset nothing reaches `split_unattributed/2` at all.
  #
  # The reported case was the other one — two LiveView spex last touched eight
  # days before the session, on released stories, blocking a stop twice — and
  # attribution was extended to spex to answer it. That was wrong, and the cost
  # was that `spex: :block_all` did nothing at all: the latch already demotes
  # every story mid-build, so the only findings reaching attribution were
  # regressions on green stories, and attribution demoted those too. Measured
  # across one evening: every agent, every stop, findings demoted, mode reading
  # `:block_all` for months.
  #
  # The latch is the mandate test. A story that went green and is now red is a
  # regression in this working copy, and "I did not open that file this turn" is
  # not a reason to pass it — the escape is to fix the regression or unlatch the
  # story, both of which are honest. Attribution still governs every other
  # source, which is where the inherited-rebase case actually lives.
  describe "a spex failure on a story whose specs are ready" do
    setup ctx do
      :ok = FileEdits.track_edit(ctx.session, @mine)
      {:ok, _} = Configurations.update(ctx.scope, %{spex: :block_all})

      # Bound by a criterion's `spec_path`, which is how a spex path actually
      # resolves to a story: `spec_path_story_ids/1` is consulted before the
      # directory number, and the number in the directory is not a story id.
      File.mkdir_p!(Path.join(ctx.tmp, Path.dirname(@spex_path)))
      File.write!(Path.join(ctx.tmp, @spex_path), "defmodule S do\nend\n")
      {:ok, _} = FileSync.sync(ctx.scope, base_dir: ctx.tmp)

      story = story_fixture(ctx.scope, %{specs_ready: true})

      {:ok, _criterion} =
        AcceptanceCriteria.create_criterion(ctx.scope, story, %{
          description: "a step reports its provider",
          spec_path: @spex_path
        })

      Map.put(ctx, :story, story)
    end

    test "still blocks when the session edited the spex file", ctx do
      path = @spex_path
      :ok = FileEdits.track_edit(ctx.session, path)
      problem_fixture(ctx.scope, %{source: "spex", severity: :error, file_path: path})
      fresh_analysis_runs_fixture(ctx.scope, ["spex"])

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ "criterion_6493"
    end

    test "still blocks when the session never opened the spex file", ctx do
      path = @spex_path
      problem_fixture(ctx.scope, %{source: "spex", severity: :error, file_path: path})
      fresh_analysis_runs_fixture(ctx.scope, ["spex"])

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session),
             "a latched story is red and the stop was allowed. Which files this turn " <>
               "wrote is not what decides whether a spex regression is the agent's to " <>
               "fix — the story's `specs_ready` latch already decided that, and this " <>
               "one is set. Demoting here is what made `spex: :block_all` a setting " <>
               "with no effect."

      assert reason =~ "criterion_6493",
             "the block has to name the failing spex, or the agent cannot act on it"
    end
  end

  describe "with the session's edits recorded project-relative" do
    setup ctx do
      :ok = FileEdits.track_edit(ctx.session, @mine)
      ctx
    end

    test "a finding in a file it never edited does not block", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:ok, _} = stop(ctx.scope, ctx.session),
             "block_all would block on this; the session did not write it"
    end

    test "a finding in a file it did edit still blocks", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "with both, it blocks and the reason names only its own", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ @mine
      refute reason =~ "#{@theirs}:", "the other file's finding is advisory, not blocking"
    end
  end

  describe "with the session's edits recorded absolute" do
    test "the path still resolves, so its own finding blocks", ctx do
      # The shape that needs `relativize/2` to do something. If it were a no-op
      # here the set would match nothing, `verify_against_ledger/3` would answer
      # nil, and the gate would block on everything — passing the test above for
      # the wrong reason while demoting nothing.
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "and a file it never edited is still demoted", ctx do
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:ok, _} = stop(ctx.scope, ctx.session)
    end
  end

  describe "when attribution names nothing in this project" do
    # The guard from 5d361fb7 held that a recorded path corresponding to no file
    # here means the comparison is not usable, so the gate must fail closed —
    # demoting on it would switch the gate off while looking like it worked.
    #
    # That is right about a mangled recording and wrong about a session whose
    # work genuinely lives outside the tracked tree, and the two were
    # indistinguishable at the point the guard ran. They are distinguishable one
    # step later: a mangled recording is mangled about files that changed, so
    # the project moved underneath it. Both halves are pinned here because the
    # gate silently reverting to block-everything is precisely what this module
    # exists to catch.
    test "and the project did change, the gate blocks — the recording is unusable", ctx do
      :ok = FileEdits.track_edit(ctx.session, "/somewhere/else/entirely.ex")

      # What a mangled recording looks like from outside: a file it never
      # managed to name is different than it was when the task started.
      #
      # Stamped rather than merely written. `FileSync.sync_changed/2` pre-filters
      # on mtime against the row it holds, and the row was written by this
      # test's own setup a few milliseconds ago — at second resolution the edit
      # is not newer than the record of it, and the scan sees nothing. Real
      # edits arrive seconds after a sync; a test that wrote and stopped inside
      # one second would silently assert against an empty changed set.
      path = Path.join(ctx.tmp, @theirs)
      File.write!(path, "defmodule MyApp.Theirs do\n  # edited\nend\n")
      File.touch!(path, System.os_time(:second) + 5)

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session),
             "unusable attribution must fail closed, not demote everything"
    end

    test "and nothing in the project changed, it owns none of the red", ctx do
      # The QA session of a9e9caca, in miniature: its only write went somewhere
      # `Files` does not row — there, `.code_my_spec/qa/884/brief.md`, which git
      # ignores by design. Nothing in the project moved, so there is nothing it
      # could have broken, and no action it could take that would change the
      # answer. It was handed 26 failing spex in three unrelated stories.
      :ok = FileEdits.track_edit(ctx.session, ".code_my_spec/qa/884/brief.md")

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope, ["credo"])

      assert {:ok, _} = stop(ctx.scope, ctx.session),
             "an agent that changed no project file is blocked by nothing (story 894)"
    end
  end
end
