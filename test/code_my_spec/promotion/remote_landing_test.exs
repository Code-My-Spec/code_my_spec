defmodule CodeMySpec.Promotion.RemoteLandingTest do
  use CodeMySpecTest.DataCase, async: true
  import CodeMySpec.UsersFixtures
  import CodeMySpec.DevicesFixtures
  alias CodeMySpec.AppInstances
  alias CodeMySpec.ExecutionContexts.ExecutionContext
  alias CodeMySpec.{Promotion, Repo, WorkingCopies}

  setup do
    dir = CodeMySpec.TempFile.owned_dir("test")
    origin = Path.join(dir, "origin.git")
    root = Path.join(dir, "source")
    git!(dir, ["init", "--bare", "--initial-branch=develop", origin])
    git!(dir, ["clone", origin, root])
    git!(root, ["config", "user.email", "test@example.com"])
    git!(root, ["config", "user.name", "Test"])
    git!(root, ["commit", "--allow-empty", "-m", "base"])
    base = git!(root, ["rev-parse", "HEAD"])
    git!(root, ["push", "origin", "develop"])
    git!(root, ["commit", "--allow-empty", "-m", "candidate"])
    head = git!(root, ["rev-parse", "HEAD"])

    scope =
      put_fixture_execution_context(full_scope_fixture(), ExecutionContext.new(:local, root))

    {:ok, source} = WorkingCopies.fetch(scope.active_working_copy_id)
    %{scope: scope, source: source, origin: origin, base: base, head: head}
  end

  test "publication completes without contacting an offline destination", c do
    {:ok, main} =
      WorkingCopies.issue(c.scope, nil, device: device_fixture(c.scope), root: "/offline/main")

    {:ok, main} = main |> Ecto.Changeset.change(main: true) |> Repo.update()
    assert {:ok, %{published: true, head: head, device_sync: %{"status" => "pending"}}} = land(c)
    assert head == c.head
    assert git!(c.origin, ["rev-parse", "develop"]) == c.head
    assert AppInstances.for_working_copy(c.scope, main).promotion_sync["head"] == c.head
    assert {:ok, %{published: true, reconciled: true}} = land(c)
  end

  test "rejected publication never schedules destination update", c do
    hook = Path.join(c.origin, "hooks/pre-receive")
    File.write!(hook, "#!/bin/sh\nexit 1\n")
    File.chmod!(hook, 0o755)
    assert {:error, %{status: :rejected}} = land(c)
    assert git!(c.origin, ["rev-parse", "develop"]) == c.base
    assert Repo.reload!(c.scope.active_project).promotion_sync == %{}
  end

  test "publication result does not claim the application is serving", c do
    assert {:ok, report} = land(c)
    text = Promotion.outcome_text({:ok, report})
    assert text =~ "origin/develop"
    assert text =~ "does not confirm"
    refute Map.has_key?(report, :serving)
  end

  defp land(c) do
    Promotion.land_remote(c.scope, c.source, c.head, [], [],
      branch: "develop",
      base: c.base,
      promotion_id: "landing-test"
    )
  end

  defp git!(root, args) do
    {output, status} = System.cmd("git", args, cd: root, stderr_to_stdout: true)
    assert status == 0, output
    String.trim(output)
  end
end
