defmodule CodeMySpec.AgentTasks.ReleaseTest do
  @moduledoc """
  Which deployed stories count as released.

  Coverage was decided with `String.contains?(released, "story_\#{id}")` against
  every release manifest concatenated. `story_1` is a substring of `story_12`,
  so a release covering story 12 also marked story 1 released — and the
  `release` requirement then read satisfied for work that had never shipped.

  It failed open, which is the direction that loses work, and on any project
  past nine stories it was the ordinary case rather than an edge one.
  """

  use ExUnit.Case, async: true

  alias CodeMySpec.AgentTasks.Release
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.Users.Scope

  setup do
    {:ok, root} = Briefly.create(directory: true)
    env = Environment.new(:local, root)

    File.mkdir_p!(Path.join(root, Paths.devops_deploys_dir()))
    File.mkdir_p!(Path.join(root, Paths.releases_dir()))

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

  test "a manifest naming story_12 does not release story_1", %{root: root, scope: scope} do
    deployed(root, [1, 12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{})

    assert message =~ ~r/\bstory_1\b/,
           "story 1 is on UAT and no manifest covers it; the substring match " <>
             "found it inside `story_12` and called it shipped: #{message}"
  end

  test "a manifest naming the story itself releases it", %{root: root, scope: scope} do
    deployed(root, [12])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_12\n")

    assert {:ok, :valid} = Release.evaluate(scope, %{})
  end

  test "longer ids are not released by a shorter prefix", %{root: root, scope: scope} do
    deployed(root, [100])
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_1\n")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{})
    assert message =~ "story_100"
  end

  test "nothing deployed is nothing to release", %{scope: scope} do
    assert {:ok, :valid} = Release.evaluate(scope, %{})
  end
end
