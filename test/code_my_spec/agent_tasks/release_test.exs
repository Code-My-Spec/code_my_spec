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

  What counts as "deployed" is a real `deploys` row (`CodeMySpec.Deploys`),
  not a file — the graph's own `deploy` requirement and this checker must
  read the same thing, or one can say shipped while the other says nothing
  to release (issue 5d17a4d0). `story_id` carries a real FK to `stories`, so
  every deploy here is recorded against a real, fixture-created story rather
  than a bare integer — ids are DB-assigned and not literally 1/12/100 the
  way the old file-named tests could pick, so the substring-boundary tests
  build the collision by appending a digit to a real id rather than by
  choosing two convenient literals.
  """

  use CodeMySpecTest.DataCase, async: true

  import CodeMySpec.UsersFixtures

  alias CodeMySpec.AgentTasks.Release
  alias CodeMySpec.Deploys
  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths
  alias CodeMySpec.StoriesFixtures

  setup do
    tmp_dir = CodeMySpec.TempFile.owned_dir("test")

    scope =
      working_copy_scope_fixture() |> Map.put(:environment, Environment.new(:local, tmp_dir))

    :ok = register_working_copy_environment(scope, fixture_environment(scope))

    File.mkdir_p!(Path.join(tmp_dir, Paths.releases_dir()))

    {_, 0} = Environments.cmd(fixture_environment(scope), "git", ["init", "-q"])

    {_, 0} =
      Environments.cmd(fixture_environment(scope), "git", [
        "config",
        "user.email",
        "test@example.com"
      ])

    {_, 0} = Environments.cmd(fixture_environment(scope), "git", ["config", "user.name", "Test"])

    {_, 0} =
      Environments.cmd(fixture_environment(scope), "git", [
        "commit",
        "--allow-empty",
        "-q",
        "-m",
        "root"
      ])

    {:ok, root: tmp_dir, scope: scope}
  end

  defp ensure_nonempty(""), do: "0"
  defp ensure_nonempty(value), do: value

  defp deploy_story!(scope) do
    story = StoriesFixtures.story_fixture(scope)
    {:ok, _} = Deploys.record(scope, story.id, "uat", health_verified_at: DateTime.utc_now())
    story
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
      cmd: fn
        env, "git", args -> Environments.cmd(env, "git", args)
        _env, "gh", _args -> {"", gh_status}
      end
    ]
  end

  test "a manifest naming a longer id does not release the shorter number it's a prefix of", %{
    root: root,
    scope: scope
  } do
    story = deploy_story!(scope)
    # Appending a digit guarantees `story.number`'s decimal string is a true
    # prefix of `longer`, regardless of what the DB actually assigned —
    # reproducing the `story_12` contains `story_1` shape without needing
    # literal small ids.
    longer = "#{story.number}9"
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{longer}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))

    assert message =~ ~r/\bstory_#{story.number}\b/,
           "story #{story.number} is on UAT and no manifest covers it; the substring match " <>
             "found it inside story_#{longer} and called it shipped: #{message}"
  end

  test "a manifest naming the story itself releases it once tagged and published", %{
    root: root,
    scope: scope
  } do
    story = deploy_story!(scope)
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.number}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end

  test "manifest tokens are story numbers, not database ids", %{root: root, scope: scope} do
    for _ <- 1..2, do: StoriesFixtures.story_fixture(scope)
    story = deploy_story!(scope)
    assert story.id != story.number

    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.id}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))
    assert message =~ ~r/\bstory_#{story.number}\b/
    refute message =~ ~r/\bstory_#{story.id}\b/
  end

  test "a record with no matching tag does not release the story it names", %{
    root: root,
    scope: scope
  } do
    story = deploy_story!(scope)
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.number}\n")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))
    assert message =~ "story_#{story.number}"
  end

  test "a tagged record whose GitHub Release was never published stays unreleased", %{
    root: root,
    scope: scope
  } do
    story = deploy_story!(scope)
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.number}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(1))
    assert message =~ "story_#{story.number}"
  end

  test "a tag with the v-prefix the prompt names also satisfies coverage", %{
    root: root,
    scope: scope
  } do
    story = deploy_story!(scope)
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.number}\n")
    tag(fixture_environment(scope), "v1.0.0")

    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end

  test "a shorter manifest token does not release a longer deployed number it's a prefix of", %{
    root: root,
    scope: scope
  } do
    # A single-digit number has no non-empty proper prefix. Nine filler stories
    # first guarantees the number under test has at least two digits by the time
    # it's created, regardless of what the sequence already stood at.
    for _ <- 1..9, do: StoriesFixtures.story_fixture(scope)

    story = deploy_story!(scope)
    shorter = String.slice(to_string(story.number), 0..-2//1)

    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{shorter}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :invalid, message} = Release.evaluate(scope, %{}, opts(0))
    assert message =~ "story_#{story.number}"
  end

  test "nothing deployed is nothing to release", %{scope: scope} do
    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end

  test "an unverified deploy is not on UAT, so there is nothing unreleased to complain about", %{
    root: root,
    scope: scope
  } do
    story = StoriesFixtures.story_fixture(scope)
    {:ok, _} = Deploys.record(scope, story.id, "uat")
    released(root, "1.0.0", "# 1.0.0\n\n## Stories\n\n- story_#{story.number}\n")
    tag(fixture_environment(scope), "1.0.0")

    assert {:ok, :valid} = Release.evaluate(scope, %{}, opts(0))
  end
end
