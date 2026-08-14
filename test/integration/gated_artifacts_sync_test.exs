defmodule CodeMySpec.Integration.GatedArtifactsSyncTest do
  @moduledoc """
  Write the artifacts a sprite writes, run the real sync, and check they landed.

  The unit test in `Files.ClassifiableArtifactsTest` asserts the classifier has a
  role for each gated path. This asserts the whole path works: classify →
  validate → upsert → a row a checker can read. Those are different failures.
  A role can exist while the validator crashes, or the file can classify and
  still not survive `FileSync.reconcile/2`.

  It exists because five of these gaps reached production, and each was found by
  reading a drill log forty minutes in. Every one would have failed here in under
  a second.

  The failure mode is worth stating because it fooled two agents in a row: an
  unclassified file is silently dropped, so the scan reports a *constant* file
  count while the agent keeps writing. That reads as "the file watcher is dead",
  and both agents spent their remaining time trying to revive a watcher that was
  scanning every forty-five seconds and having every manifest accepted.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.Paths

  @moduletag :tmp_dir

  # {path, content, expected_role}
  defp artifacts do
    [
      {Paths.qa_plan(), qa_plan_body(), :qa_plan},
      {Paths.qa_journey_plan(), "# QA Journey Plan\n\n## Journeys\n\n### One\n1. Step\n",
       :qa_plan},
      {Paths.qa_journey_result(), "# Journey Result\n\nRan it.\n", :qa_result},
      {Paths.proposal_path(), "# Architecture Proposal\n\nSome design.\n", :architecture},
      {Paths.decisions_index(), "# Decisions\n\n- 0001\n", :architecture},
      {Path.join(Paths.credo_checks_framework_dir(), "spex_denied_calls.ex"), "# check\n",
       :credo_check},
      {Path.join(Paths.credo_checks_local_dir(), "my_app_spex_denies.ex"), "# check\n",
       :credo_check},
      {Path.join([Paths.knowledge_dir(), "bdd", "spex", "index.md"]), "# BDD plan\n",
       :project_knowledge},
      {Path.join(Paths.personas_dir(), "dana/summary.md"), persona_summary(), :persona_summary},
      {Path.join(Paths.personas_dir(), "dana/sources.md"),
       "- https://example.com — A source — 2026-01-01\n", :persona_sources},
      {"test/support/fixtures/my_app_spex_fixtures.ex", "defmodule X do\nend\n", :test_support},
      {"lib/my_app/tasks.ex", "defmodule MyApp.Tasks do\nend\n", :implementation}
    ]
  end

  setup %{tmp_dir: tmp_dir} do
    scope = full_scope_fixture()
    env = Environment.new(:local, tmp_dir)

    for {path, body, _role} <- artifacts() do
      full = Path.join(tmp_dir, path)
      full |> Path.dirname() |> File.mkdir_p!()
      File.write!(full, body)
    end

    File.write!(
      Path.join(tmp_dir, "mix.exs"),
      "defmodule MyApp.MixProject do\n  def project, do: [app: :my_app]\nend\n"
    )

    %{scope: %{scope | environment: env, cwd: tmp_dir}, tmp_dir: tmp_dir}
  end

  test "every artifact a requirement gates on survives a real sync", %{scope: scope} do
    assert {:ok, _result} = FileSync.sync(scope, base_dir: scope.cwd)

    missing =
      for {path, _body, expected} <- artifacts(),
          record = Files.get_by_path(scope, path),
          record == nil or record.role != expected do
        {path, expected, record && record.role}
      end

    assert missing == [],
           """
           These artifacts did not sync with the role a requirement expects:

           #{Enum.map_join(missing, "\n", fn {p, want, got} -> "  #{p}\n    expected #{inspect(want)}, got #{inspect(got)}" end)}

           An unclassified artifact is dropped in silence: the scan keeps
           reporting a constant file count, the server keeps accepting manifests,
           and the checker reports the file missing while it sits on disk. That
           has cost five drills. Add the classifier clause, the role, the enum
           migration, and the cms_scan port.
           """
  end

  test "the qa plans are judged by their own schemas, not each other's", %{scope: scope} do
    assert {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)

    journey = Files.get_by_path(scope, Paths.qa_journey_plan())
    error = journey.validation_errors["errors"]["plan"]

    if error do
      refute error =~ "tools registry",
             "the journey plan is being validated against the `qa_plan` schema — " <>
               "it has its own registered document type, and judging it by the " <>
               "wrong one tells an agent to fix a correct file"
    end
  end

  defp qa_plan_body do
    """
    # QA Plan

    ## App Overview

    Phoenix app on 4000, session auth.

    ## Tools Registry

    ### curl

    `curl localhost:4000`

    ## Seed Strategy

    `mix run priv/repo/qa_seeds.exs` creates a user.
    """
  end

  defp persona_summary do
    """
    # Dana

    ## Role

    Keeps a list.

    ## Goals

    Capture fast.

    ## Frustrations

    Loses things.

    ## Evidence

    Desk research.
    """
  end

  describe "components own their files after a sync" do
    test "an implementation file is linked to its component", %{scope: scope} do
      spec = Path.join(scope.cwd, ".code_my_spec/spec/my_app/tasks.spec.md")
      spec |> Path.dirname() |> File.mkdir_p!()

      File.write!(
        spec,
        "# MyApp.Tasks\n\nStores tasks.\n\n## Type\n\ncontext\n"
      )

      assert {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
      assert {:ok, _} = CodeMySpec.Files.ComponentSync.sync_from_files(scope)

      impl = Files.get_by_path(scope, "lib/my_app/tasks.ex")

      assert impl.component_id,
             """
             The implementation file synced but nothing owns it.

             `implementation_file` is a file_exists check scoped to a component's
             own files, so an unlinked file is invisible to it and the requirement
             stays open forever. Drill 11 finished the whole project chain with
             157 tests passing and still showed 15 of these open, every file
             synced and not one linked.
             """
    end
  end

  describe "a module Phoenix does not put where its name suggests" do
    test "is owned by what it declares, not by its path", %{scope: scope} do
      # Phoenix's own layout: the module is `MyApp.CoreComponents`, the file is
      # under `components/`. Deriving from the path gives
      # `MyApp.Components.CoreComponents`, which matches no component — so the
      # file is owned by nothing and `implementation_file` can never pass. The
      # QA drill hit four of these and rightly refused to move framework files.
      spec = Path.join(scope.cwd, ".code_my_spec/spec/my_app/core_components.spec.md")
      spec |> Path.dirname() |> File.mkdir_p!()
      File.write!(spec, "# MyApp.CoreComponents\n\nShared UI.\n\n## Type\n\nmodule\n")

      impl = Path.join(scope.cwd, "lib/my_app/components/core_components.ex")
      impl |> Path.dirname() |> File.mkdir_p!()
      File.write!(impl, "defmodule MyApp.CoreComponents do\nend\n")

      assert {:ok, _} = FileSync.sync(scope, base_dir: scope.cwd)
      assert {:ok, _} = CodeMySpec.Files.ComponentSync.sync_from_files(scope)

      record = Files.get_by_path(scope, "lib/my_app/components/core_components.ex")

      assert record.component_id,
             "the file declares MyApp.CoreComponents; nothing else should be " <>
               "needed to know which component owns it"
    end
  end
end
