defmodule CodeMySpec.AgentTasks.ReleaseTest do
  @moduledoc """
  Which deployed stories count as released.

  Coverage was decided with `String.contains?(released, "story_\#{id}")` against
  every release manifest concatenated. `story_1` is a substring of `story_12`,
  so a release covering story 12 also marked story 1 released — and the
  `release` requirement then read satisfied for work that had never shipped.

  It failed open, which is the direction that loses work, and on any project
  past nine stories it was the ordinary case rather than an edge one.

  A second failure-open bug lived next to it (issue 8db89425): a release
  record's content counted toward coverage the moment it existed on disk,
  whether or not the tag and GitHub Release it claims were ever made. These
  tests exercise real `git` against a real repo (so the tag check is the real
  thing) and fake only `gh` via `opts[:cmd]` — no network, no GitHub account,
  needed for an `async: true` unit test.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.Release
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  setup do
    {:ok, root} = Briefly.create(directory: true)
    env = Environment.new(:local, root)

    File.mkdir_p!(Path.join(root, Paths.devops_deploys_dir()))
    File.mkdir_p!(Path.join(root, Paths.releases_dir()))

    {_, 0} = Environments.cmd(env, "git", ["init", "-q"])
    {_, 0} = Environments.cmd(env, "git", ["config", "user.email", "test@example.com"])
    {_, 0} = Environments.cmd(env, "git", ["config", "user.name", "Test"])
    {_, 0} = Environments.cmd(env, "git", ["commit", "--allow-empty", "-q", "-m", "root"])

    {:ok, root: root, scope: %Scope{environment: env}}
  end

  defp deployed(root, ids) do
    for id <- ids do
      File.write!(Path.join([root, Paths.devops_deploys_dir(), "story_#{id}.md"]), "deployed\n")
    end
  end

  defp released(root, version, body) do
    File.write!(Path.join([root, Paths.releases_dir(), "#{version}.md"]), body)
  end

  defp tag(env, name) do
    {_, 0} = Environments.cmd(env, "git", ["tag", "-a", name, "-m", name])
  end

  # `gh` is never real here — the point of injecting `:cmd` is that a unit
  # test proves neither GitHub reachability nor an authenticated `gh`. `git`
  # still runs for real underneath, so the tag half of `published?/3` is
  # genuinely exercised.
  defp opts(gh_status) do
    [
      cmd: fn env, "git", args -> Environments.cmd(env, "git", args)
             _env, "gh", _args -> {"", gh_status} end
    ]
  end

  test "a manifest naming story_12 does not release story_1", %{root: root, scope: scope} do
    deployed(root, [1, 12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")
    tag(scope.environment, "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))

    assert message =~ ~r/\bstory_1\b/,
           "story 1 is on UAT and no manifest covers it; the substring match " <>
             "found it inside `story_12` and called it shipped: #{message}"
  end

  test "a manifest naming the story itself releases it once tagged and published", %{
    root: root,
    scope: scope
  } do
    deployed(root, [12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")
    tag(scope.environment, "1.0.0")

    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end

  test "a record with no matching tag does not release the story it names", %{
    root: root,
    scope: scope
  } do
    deployed(root, [12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))
    assert message =~ "story_12"
  end

  test "a tagged record whose GitHub Release was never published stays unreleased", %{
    root: root,
    scope: scope
  } do
    deployed(root, [12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")
    tag(scope.environment, "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(1))
    assert message =~ "story_12"
  end

  test "a tag with the v-prefix the prompt names also satisfies coverage", %{
    root: root,
    scope: scope
  } do
    deployed(root, [12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")
    tag(scope.environment, "v1.0.0")

    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end

  test "longer ids are not released by a shorter prefix", %{root: root, scope: scope} do
    deployed(root, [100])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_1\n")
    tag(scope.environment, "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))
    assert message =~ "story_100"
  end

  test "nothing deployed is nothing to release", %{scope: scope} do
    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end
end

