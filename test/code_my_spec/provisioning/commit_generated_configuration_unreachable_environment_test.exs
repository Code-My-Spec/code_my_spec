defmodule CodeMySpec.Provisioning.CommitGeneratedConfigurationUnreachableEnvironmentTest do
  @moduledoc """
  What `commit_generated_configuration/1` does when it cannot run `git`
  against the project's own environment.

  Reported live against MarketMySpec, one step earlier in `deploy_environment/3`
  than `image_tag/2` — this runs first, so it is what actually crashed with
  `cannot run "git": this environment has no working directory` even after
  `head_commit/1` learned to fall back cleanly: `work_tree?/1` called `git`
  through the same `Environments.cmd/4` with no reachability check at all.
  The server has no real way to write to a harness-only project's checkout in
  the first place, so there is nothing for it to commit there — the fix is to
  recognise that shape and do nothing, not to find something else to fall
  back to.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Steps

  # The same shape a harness-only project's `Environment.new(:local, project.
  # local_path)` takes when `local_path` is nil — distinct from `nil` itself.
  defp unreachable(scope), do: %{scope | environment: Environment.new(:local, nil)}

  test "does nothing, rather than crashing, when the environment cannot be reached" do
    scope = unreachable(full_scope_fixture())

    assert :ok = Steps.commit_generated_configuration(scope)
  end

  test "still commits setup's generated files when the environment is reachable" do
    scope = full_scope_fixture()
    tmp = scope.environment.cwd

    System.cmd("git", ["init"], cd: tmp)
    System.cmd("git", ["config", "user.email", "test@example.com"], cd: tmp)
    System.cmd("git", ["config", "user.name", "Test"], cd: tmp)
    System.cmd("git", ["commit", "--allow-empty", "-m", "initial"], cd: tmp)
    File.mkdir_p!(Path.join(tmp, "envs"))
    File.write!(Path.join(tmp, "envs/prod.enc.env"), "SECRET_KEY_BASE=x\n")

    assert :ok = Steps.commit_generated_configuration(scope)

    {status_output, 0} = System.cmd("git", ["status", "--porcelain"], cd: tmp)
    assert status_output == ""

    {log_output, 0} = System.cmd("git", ["log", "-1", "--format=%s"], cd: tmp)
    assert String.trim(log_output) == "Setup-generated configuration"
  end
end
