defmodule CodeMySpec.Requirements.CheckersWithoutADiskTest do
  @moduledoc """
  The requirement checkers against a scope with no environment.

  That is the light harness: the server holds no working copy. These two used to
  stat and read files through `scope.environment` and so could never return true
  there — an agent wrote the persona research and the architecture proposal,
  watched both sync, and was told they were missing on every re-evaluation. It
  spent a drill working a requirement that could not be satisfied.

  The evidence they need now travels with the file record: existence for the
  proposal, and a per-concern verdict written by `Files.Scanner` at sync time
  for the persona artifacts.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Files.File, as: FileRecord
  alias CodeMySpec.Paths
  alias CodeMySpec.Personas

  alias CodeMySpec.Requirements.{
    ArchitectureChecker,
    PersonasChecker,
    Preloader,
    Registry,
    RequirementCalculator,
    SpexBoundaryChecker
  }

  setup do
    scope = full_scope_fixture()
    %{scope: %{scope | environment: nil}}
  end

  defp sync(scope, path, role, errors \\ %{}) do
    Repo.insert!(%FileRecord{
      project_id: scope.active_project_id,
      harness_id: scope.active_harness_id,
      path: path,
      role: role,
      valid: errors == %{},
      validation_errors: %{"errors" => errors, "data" => %{}}
    })
  end

  # A real second working copy. `harness_id` is a foreign key, so a generated
  # UUID is a constraint error rather than another checkout.
  defp second_harness(scope) do
    {:ok, harness} = CodeMySpec.Harnesses.issue(scope, nil, label: "the other checkout")
    harness.id
  end

  defp persona!(scope, slug) do
    {:ok, persona} =
      Personas.create_persona(scope, %{
        name: "Overloaded IC",
        slug: slug,
        status: :proto
      })

    persona
  end

  describe "personas_complete" do
    test "no personas is still the first thing said", %{scope: scope} do
      assert {false, %{reason: reason}} = PersonasChecker.complete?(scope, nil)
      assert reason =~ "No personas"
    end

    test "a persona whose artifacts synced clean is complete", %{scope: scope} do
      persona!(scope, "overloaded-ic")
      sync(scope, Personas.summary_path("overloaded-ic"), :persona_summary)
      sync(scope, Personas.sources_path("overloaded-ic"), :persona_sources)

      assert {true, %{status: status}} = PersonasChecker.complete?(scope, nil)
      assert status =~ "all personas complete"
    end

    test "an unsynced artifact reads as missing", %{scope: scope} do
      persona!(scope, "overloaded-ic")
      sync(scope, Personas.summary_path("overloaded-ic"), :persona_summary)

      assert {false, %{reason: reason}} = PersonasChecker.complete?(scope, nil)
      assert reason =~ "sources.md` missing"
      refute reason =~ "summary.md` missing"
    end

    test "the validator's own message is what the agent is told", %{scope: scope} do
      persona!(scope, "overloaded-ic")
      sync(scope, Personas.summary_path("overloaded-ic"), :persona_summary)

      sync(scope, Personas.sources_path("overloaded-ic"), :persona_sources, %{
        "sources" => "`sources.md` entry missing URL or YYYY-MM-DD date: - a bare line"
      })

      assert {false, %{reason: reason}} = PersonasChecker.complete?(scope, nil)

      assert reason =~ "missing URL or YYYY-MM-DD date",
             "the gap is decided at sync where the bytes are; carrying the message " <>
               "with it is what keeps the feedback specific enough to act on"

      assert reason =~ "overloaded-ic"
    end
  end

  describe "architecture_designed" do
    test "an unsynced proposal is missing, and says which path", %{scope: scope} do
      assert {false, %{reason: reason}} = ArchitectureChecker.complete?(scope, nil)
      assert reason =~ Paths.proposal_path()
    end

    test "a synced proposal gets past the file check", %{scope: scope} do
      sync(scope, Paths.proposal_path(), :architecture)

      # Whatever it returns now is about stories and orphans, not the file —
      # which is the whole point: with no disk it could never get this far.
      assert {result, details} = ArchitectureChecker.complete?(scope, nil)
      assert is_boolean(result)
      refute inspect(details) =~ "is missing"
      refute inspect(details) =~ "Environment is not available"
    end
  end

  describe "spex_boundary_ready" do
    test "reports every gap instead of refusing to look", %{scope: scope} do
      assert {false, %{reason: reason}} =
               SpexBoundaryChecker.complete?(scope, nil)

      refute reason =~ "Environment is not available",
             "with no disk this used to decline to check at all, which reads to " <>
               "an agent as a blocked requirement rather than a list of work"

      assert reason =~ "spex_denied_calls.ex"
      assert reason =~ "credo_checks/local"
    end

    test "synced credo checks, fixtures bridge and bdd plan satisfy it", %{scope: scope} do
      framework = CodeMySpec.Paths.credo_checks_framework_dir()

      for f <- ["spex_denied_calls.ex", "no_direct_send_in_spex.ex"] do
        sync(scope, Path.join(framework, f), :credo_check)
      end

      sync(
        scope,
        Path.join(CodeMySpec.Paths.credo_checks_local_dir(), "my_app_spex_denies.ex"),
        :credo_check
      )

      sync(scope, "mix.exs", :mix_exs)

      Repo.update_all(
        from(f in FileRecord,
          where: f.project_id == ^scope.active_project_id and f.path == "mix.exs"
        ),
        set: [validation_errors: %{"errors" => %{}, "data" => %{"app_name" => "my_app"}}]
      )

      sync(scope, "test/support/fixtures/my_app_spex_fixtures.ex", :test_support)

      sync(
        scope,
        Path.join([CodeMySpec.Paths.knowledge_dir(), "bdd", "spex", "index.md"]),
        :project_knowledge
      )

      assert {true, %{status: status}} =
               SpexBoundaryChecker.complete?(scope, nil)

      assert status =~ "installed"
    end
  end

  # `path_exists` reached the disk until now: it consulted the preloader's file
  # map and, failing that, statted `scope.environment`. On the light harness
  # that environment is nil, so the six requirements using it could report
  # satisfied on a laptop and unsatisfied on the server for the same project at
  # the same instant — the answer depended on which process was asked.
  #
  # It reads rows only now. The stop path syncs before it evaluates
  # (`Validation.validate_stop/3` calls `FileSync.sync_changed/2` first), so
  # dropping the disk costs nothing there.
  #
  # Both clauses are covered because they are reached by different callers and
  # the nil-`ctx` one is easy to get wrong: `RequirementGraph` preloads a
  # context, but `AgentTasks.Evaluator` calls `compute_one/4` without one — and
  # that is the stop hook, on every agent turn. A first cut of this returned
  # `false` whenever `ctx` was nil, which blocked the stop on a file the agent
  # had written and synced.
  describe "path_exists without a working copy" do
    @decisions ".code_my_spec/architecture/decisions.md"

    defp technical_strategy do
      Registry.get_project_requirements()
      |> Enum.find(&(&1.name == "technical_strategy"))
    end

    defp check(scope, ctx) do
      RequirementCalculator.compute_one(
        scope,
        scope.active_project,
        technical_strategy(),
        [],
        ctx
      )
    end

    test "a synced file satisfies it with no environment to stat", %{scope: scope} do
      sync(scope, @decisions, :architecture)

      assert %{satisfied: true} = check(scope, nil)
    end

    test "an unsynced file does not", %{scope: scope} do
      assert %{satisfied: false, details: %{reason: reason}} = check(scope, nil)
      assert reason =~ "File missing"
    end

    # The nil-`ctx` clause queried by `project_id` alone, so it asked "does any
    # checkout have this file" and answered yes. That is the stop-hook path, on
    # every agent turn.
    #
    # The six requirements using `path_exists` are all `.code_my_spec/` project
    # paths — a technical strategy, a QA plan, a journey — which is precisely
    # the category that differs between working copies, because one checkout
    # writing it is the work the requirement is asking for. A second checkout
    # that already had it made this one's requirement read as done.
    #
    # Same bug the preloader had, surviving in the fallback because the fix
    # went in one layer up: `RequirementGraph` preloads a harness-scoped
    # context, so the ctx clause was already correct and the gap only showed
    # where there is no ctx at all.
    test "a file synced by another checkout does not satisfy this one", %{scope: scope} do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        harness_id: second_harness(scope),
        path: @decisions,
        role: :architecture,
        valid: true,
        validation_errors: %{"errors" => %{}, "data" => %{}}
      })

      assert %{satisfied: false, details: %{reason: reason}} = check(scope, nil),
             "another working copy having the file is not this one having written it"

      assert reason =~ "File missing"
    end

    # Loose on a nil harness, matching the preloader. The UI has no working copy
    # and refusing there took the graph out of the web view entirely.
    test "a scope with no harness still sees it", %{scope: scope} do
      Repo.insert!(%FileRecord{
        project_id: scope.active_project_id,
        harness_id: second_harness(scope),
        path: @decisions,
        role: :architecture,
        valid: true,
        validation_errors: %{"errors" => %{}, "data" => %{}}
      })

      assert %{satisfied: true} = check(%{scope | active_harness_id: nil}, nil)
    end

    # The `Evaluator` path. Without the query clause this answered false for a
    # file that was sitting in the table.
    test "a nil context queries rather than giving up", %{scope: scope} do
      sync(scope, @decisions, :architecture)

      assert %{satisfied: true} = check(scope, nil)
    end

    test "a preloaded context is used when there is one", %{scope: scope} do
      sync(scope, @decisions, :architecture)
      {:ok, ctx} = Preloader.load(scope)

      assert %{satisfied: true} = check(scope, ctx)
    end

    test "a preloaded context that lacks the file reports it missing", %{scope: scope} do
      {:ok, ctx} = Preloader.load(scope)

      assert %{satisfied: false, details: %{reason: reason}} = check(scope, ctx)
      assert reason =~ "File missing"
    end
  end
end
