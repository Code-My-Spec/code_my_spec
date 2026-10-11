defmodule CodeMySpec.Validation.DemotionWiringTest do
  @moduledoc """
  The stop judges the whole copy: a finding in a file this session never
  opened blocks as it would any other.

  John, 2026-10-04 and issue 48f4eada: task evaluation judges the whole copy,
  like promotion. `split_unattributed/2` used to demote any finding in a file
  the session or agent had not edited whenever edits were recorded, so the gate
  was changed-files-only for any agent that edited something and whole-copy
  only when there was no attribution at all — the wrong way round, and silent.

  `8ccd19097` removed the attribution excuse. `split_unattributed/2` survives as
  a function with its old shape, returning `{blocking, []}` unconditionally, so
  the call site and the property this file asserts stay readable; the list is
  still computed because the caller's log line wants it, but it no longer
  decides anything.

  What this file now pins is the consequence: where attribution *was* the
  answer, the finding blocks. Each case below is one of the shapes that used to
  demote, kept because the recording they exercise — project-relative,
  absolute, naming nothing that resolves — is still read for the log line, and
  a recording that breaks loudly is easier to notice than one that quietly
  changes the verdict.

  The spex describe is separate because spex never reached attribution the same
  way: `split_by_story_enforcement/3` runs first and answers from the finding's
  location, so enabling spex project-wide is survivable without attribution's
  help.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.{AnalysisFixtures, ProblemsFixtures, StoriesFixtures, UsersFixtures}

  alias CodeMySpec.Configurations
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.FileEdits
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.AcceptanceCriteria
  alias CodeMySpec.Validation

  @mine "lib/my_app/mine.ex"
  @theirs "lib/my_app/theirs.ex"
  @spex_path "test/spex/811_provisioning/criterion_6493_a_step_reports_its_provider_spex.exs"

  setup do
    tmp = CodeMySpec.TempFile.owned_dir("test")
    environment = Environment.new(:local, tmp)
    scope = put_fixture_environment(%{full_scope_fixture() | cwd: tmp}, environment)
    :ok = register_working_copy_environment(scope, environment)

    Configurations.get_or_create(scope)
    {:ok, _} = Configurations.update(scope, %{credo: :block_all})

    File.mkdir_p!(Path.join(tmp, "lib/my_app"))
    File.write!(Path.join(tmp, @mine), "defmodule MyApp.Mine do\nend\n")
    File.write!(Path.join(tmp, @theirs), "defmodule MyApp.Theirs do\nend\n")
    {:ok, _} = FileSync.sync(scope, base_dir: tmp)

    %{scope: scope, tmp: tmp, session: "sess-#{System.unique_integer([:positive])}"}
  end

  defp stop(scope, session), do: Validation.validate_stop(scope, nil, session_id: session)

  # Why spex never reached attribution's verdict, and no longer has to.
  #
  # `split_by_story_enforcement/3` runs before it and answers from the finding's
  # own location (`f8d823f7e`: every located red spex is enforced; only a
  # finding with no location is advisory). So a spex failure was already decided
  # before attribution was consulted, and the describe below pins that the
  # decision does not depend on whether this session opened the file.
  #
  # The case that mattered was the other one — two LiveView spex last touched
  # eight days before the session, on released stories, blocking a stop twice —
  # and attribution was briefly extended to spex to answer it. That was wrong:
  # `spex: :block_all` then did nothing at all for months, which is the failure
  # `ae0a8537` records and `split_unattributed/2`'s own comment calls worse than
  # blocking too much, because a gate that quietly stops blocking cannot be seen.
  describe "a spex failure on a story whose specs are ready" do
    setup ctx do
      :ok = FileEdits.track_edit(ctx.session, @mine)
      {:ok, _} = Configurations.update(ctx.scope, %{spex: :block_all})

      # A spex file with no `criterion:` stamp binds to no criterion; the
      # directory number is not a story id, so the finding stays enforced.
      File.mkdir_p!(Path.join(ctx.tmp, Path.dirname(@spex_path)))
      File.write!(Path.join(ctx.tmp, @spex_path), "defmodule S do\nend\n")
      {:ok, _} = FileSync.sync(ctx.scope, base_dir: ctx.tmp)

      # Criterion first, latch second — the order the real lifecycle runs in.
      # Adding a criterion now restarts the specs chain (issue 10e86fa2: a
      # criterion that did not exist has never been green, so a red spex for it
      # must not block on a latch the story earned before it), which means
      # latching at `story_fixture` and adding a criterion afterwards leaves the
      # story unlatched and this whole describe block testing nothing.
      story = story_fixture(ctx.scope)

      {:ok, _criterion} =
        AcceptanceCriteria.create_criterion(ctx.scope, story, %{
          description: "a step reports its provider",
          spec_path: @spex_path
        })

      {:ok, story} =
        Stories.set_specs_ready(ctx.scope, Stories.get_story(ctx.scope, story.id), true)

      Map.put(ctx, :story, story)
    end

    test "still blocks when the session edited the spex file", ctx do
      path = @spex_path
      :ok = FileEdits.track_edit(ctx.session, path)
      problem_fixture(ctx.scope, %{source: "spex", severity: :error, file_path: path})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ "criterion_6493"
    end

    test "still blocks when the session never opened the spex file", ctx do
      path = @spex_path
      problem_fixture(ctx.scope, %{source: "spex", severity: :error, file_path: path})
      fresh_analysis_runs_fixture(ctx.scope)

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

    test "a finding in a file it never edited blocks too", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session),
             "a finding in a file this session never opened was demoted. Task " <>
               "evaluation judges the whole copy (John, 2026-10-04; 48f4eada), so " <>
               "the file it is in is not what decides — the mode is."

      assert reason =~ @theirs,
             "the agent is stopped over a finding the reason does not name. Got:\n#{reason}"
    end

    test "a finding in a file it did edit still blocks", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "with both, it blocks and the reason names both", ctx do
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ @mine
      assert reason =~ @theirs, "the other file's finding is blocking too, so it must be named"
    end
  end

  describe "with the session's edits recorded absolute" do
    test "the path still resolves, so its own finding blocks", ctx do
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @mine})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "and a file it never edited blocks as well", ctx do
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, @mine))

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session),
             "the absolute-recording shape still demoted. Neither representation " <>
               "decides the verdict any more — 8ccd19097 retired the excuse, and " <>
               "both shapes are kept here only because both occur in the ledger."
    end
  end

  describe "when attribution names nothing in this project" do
    # The recording is still read — for the caller's log line — so a recording
    # that breaks loudly is worth pinning. What changed on 2026-10-04 is that
    # none of the three shapes changes the verdict: an unusable recording, a
    # session whose work lives in another repo, and a session that touched
    # nothing tracked all block on the same finding.
    test "the gate blocks on the project's red", ctx do
      # A path inside this working copy that names no file row. That is what a
      # failed recording looks like when there is a cwd to normalize against —
      # not `/somewhere/else/entirely.ex`, which is a session working in another
      # repo (042e343b).
      :ok = FileEdits.track_edit(ctx.session, Path.join(ctx.tmp, "lib/my_app/never_synced.ex"))

      # Stamped rather than merely written. `FileSync.sync_changed/2` pre-filters
      # on mtime against the row it holds, and the row was written by this test's
      # own setup a few milliseconds ago — at second resolution the edit is not
      # newer than the record of it, and the scan sees nothing.
      path = Path.join(ctx.tmp, @theirs)
      File.write!(path, "defmodule MyApp.Theirs do\n  # edited\nend\n")
      File.touch!(path, System.os_time(:second) + 5)

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, _reason, _key} = stop(ctx.scope, ctx.session)
    end

    test "and every recorded edit landed in another repo, it still blocks", ctx do
      # 042e343b: a task scoped to two other repositories, finished and
      # reported, refused a stop over 26 spex it never touched. Under the
      # whole-copy rule that refusal is correct and stays — what the report
      # actually named was that the agent could not act on findings in another
      # repo, which is what filing them as issues is for, not what demoting
      # them is for.
      :ok = FileEdits.track_edit(ctx.session, "/Users/someone/devops_drill/lib/webhooks.ex")

      path = Path.join(ctx.tmp, @theirs)
      File.write!(path, "defmodule MyApp.Theirs do\n  # somebody else\nend\n")
      File.touch!(path, System.os_time(:second) + 5)

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session)
      assert reason =~ @theirs
    end

    test "and nothing in the project changed, it still blocks", ctx do
      # The QA session of a9e9caca, in miniature: its only write went somewhere
      # `Files` does not row — `.code_my_spec/qa/884/brief.md`, git-ignored by
      # design. It was handed 26 failing spex in three unrelated stories and
      # demoted them all. Under the whole-copy rule the findings are real and
      # reported; the way out is to fix them or file them, not to have the gate
      # quietly look the other way.
      :ok = FileEdits.track_edit(ctx.session, ".code_my_spec/qa/884/brief.md")

      problem_fixture(ctx.scope, %{source: "credo", severity: :error, file_path: @theirs})
      fresh_analysis_runs_fixture(ctx.scope)

      assert {:error, reason, _key} = stop(ctx.scope, ctx.session),
             "an agent that changed no project file was excused from the project's red " <>
               "(story 894's rule, retired by 48f4eada)"

      assert reason =~ @theirs
    end
  end
end
