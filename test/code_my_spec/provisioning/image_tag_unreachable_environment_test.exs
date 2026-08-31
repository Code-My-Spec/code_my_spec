defmodule CodeMySpec.Provisioning.ImageTagUnreachableEnvironmentTest do
  @moduledoc """
  What `image_tag/2` does when it cannot run `git` against the project's own
  environment.

  Reported live against MarketMySpec: `run(:deploy, ...)` errored with
  `cannot run "git": this environment has no working directory, and running
  it wherever the caller happens to be would analyse the wrong project` — an
  unhandled `ArgumentError` from `Environments.cmd/4`, which raises rather
  than returning an error for exactly this shape (a harness-only project,
  where `scope.environment` resolves to `Environment.new(:local, nil)`), the
  same reachability gap `app_path/1` and `missing_required_secrets/3` already
  had with `mix.exs` and `envs/<env>.enc.env`. `head_commit/1` now checks
  reachability before calling `Environments.cmd/4` at all, falling back to
  the harness-reported `project.head_commit` (`CmsHarness.Sync.
  report_head_commit/2`, delivered on every sync) instead of crashing.
  """
  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Provisioning.Steps

  # The same shape a harness-only project's `Environment.new(:local, project.
  # local_path)` takes when `local_path` is nil — distinct from `nil` itself.
  defp unreachable(scope), do: %{scope | environment: Environment.new(:local, nil)}

  describe "the environment is reachable" do
    test "reads the real git HEAD rather than any reported value" do
      scope = full_scope_fixture(%{head_commit: String.duplicate("a", 40)})
      tmp = scope.environment.cwd

      System.cmd("git", ["init"], cd: tmp)
      System.cmd("git", ["commit", "--allow-empty", "-m", "x"], cd: tmp)
      {sha, 0} = System.cmd("git", ["rev-parse", "HEAD"], cd: tmp)
      real_sha = String.trim(sha)

      assert {:ok, tag} = Steps.image_tag(scope, [])
      assert tag == String.slice(real_sha, 0, 12)
      refute tag == "aaaaaaaaaaaa"
    end
  end

  describe "the environment cannot be reached" do
    test "falls back to the harness-reported head_commit instead of crashing" do
      sha = String.duplicate("b", 40)
      scope = unreachable(full_scope_fixture(%{head_commit: sha}))

      assert {:ok, tag} = Steps.image_tag(scope, [])
      assert tag == String.slice(sha, 0, 12)
    end

    test "reports nothing to tag, rather than raising, when nothing has been reported" do
      scope = unreachable(full_scope_fixture())

      assert {:error, reason} = Steps.image_tag(scope, [])
      assert reason =~ "no commit to build"
    end

    test "an explicit :tag still wins over both" do
      scope = unreachable(full_scope_fixture(%{head_commit: String.duplicate("c", 40)}))

      assert {:ok, "deadbeef"} = Steps.image_tag(scope, tag: "deadbeef")
    end
  end
end
