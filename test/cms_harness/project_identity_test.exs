defmodule CmsHarness.ProjectIdentityTest do
  @moduledoc """
  Which project a directory is — answered here, on the machine that has the
  directory, because a server with no disk cannot look a path up.

  The order is the working copy's own `config.yml`, then `CMS_PROJECT_ID`, then
  refuse. There is deliberately no fourth step: guessing means syncing one
  checkout's files over another project's rows.

  It used to be the other way round, and one of these tests said so — "the
  environment wins, which is what a sprite relies on". That is true of a sprite
  and wrong of everything else, because `resolve/1` is called once per working
  copy while the variable belongs to whatever started the daemon. See the
  replacement below.
  """

  # Sync: this mutates OS environment variables, which belong to the BEAM node
  # rather than to a test process. Saving and restoring them is careful and
  # still leaves a window every concurrent test can see.

  use ExUnit.Case, async: false

  import CmsHarnessTest.Projects

  alias CmsHarness.ProjectIdentity

  setup do
    previous = System.get_env("CMS_PROJECT_ID")
    System.delete_env("CMS_PROJECT_ID")

    on_exit(fn ->
      if previous,
        do: System.put_env("CMS_PROJECT_ID", previous),
        else: System.delete_env("CMS_PROJECT_ID")
    end)

    :ok
  end

  test "reads the id out of the project's config" do
    project = project_dir(project_id: 712)

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root)
  end

  # The inverted version of the test that used to live here. It asserted that
  # an exported id wins over a checkout's own config, which is the shape that
  # let one harness attribute every copy it serves to whichever project the
  # launching session happened to export. Story 1000's criterion 737 states the
  # rule the other way — "an agent learns which project it serves from its
  # identity, not from its environment" — and names this exact scenario, but it
  # drives the hook endpoint, where the project comes from the harness record,
  # so it never saw this path.
  #
  # Measured 2026-08-20 before the fix: a scratch copy whose config named
  # `11111111-…` minted a harness against `708492f9-…`, the id exported in the
  # session that ran the command, with nothing in the output naming the swap.
  test "a checkout's own config wins over an id exported in the shell" do
    project = project_dir(project_id: 712)
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root),
           "an exported CMS_PROJECT_ID redirected a working copy that says which " <>
             "project it is. A developer with two projects in two terminals has " <>
             "that variable set, and this decides whose rows a checkout's files " <>
             "are written to."
  end

  # The half the old test was right about, kept — this is the sprite: one VM,
  # one project, no config file of its own to read.
  test "a copy that names no project falls through to the environment" do
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: "999"}} = ProjectIdentity.resolve(anonymous_dir())
  end

  # The same source answers both questions. A copy whose project came from its
  # own config takes its harness id from its own file; only the sprite — which
  # had no config to read — falls through to the environment for either.
  #
  # Without this, a never-onboarded directory presents the launching session's
  # harness id on join. `Analysis.take_over/3` refuses that now (same id,
  # different root) so it announces itself instead of evicting the rightful
  # holder — but carrying a borrowed id and being refused is a worse answer than
  # carrying none and being issued one.
  test "a copy with a config and no harness file has no harness id, whatever the shell exports" do
    project = project_dir(project_id: 712)
    previous = System.get_env("CMS_HARNESS_ID")
    System.put_env("CMS_HARNESS_ID", "borrowed-from-another-checkout")

    on_exit(fn ->
      if previous,
        do: System.put_env("CMS_HARNESS_ID", previous),
        else: System.delete_env("CMS_HARNESS_ID")
    end)

    File.rm(Path.join(project.root, ".cms_harness.json"))

    assert {:ok, %{harness_id: nil}} = ProjectIdentity.resolve(project.root)
  end

  test "a directory that cannot say which project it is gets an error, not a guess" do
    assert {:error, :no_project_id} = ProjectIdentity.resolve(anonymous_dir())
  end

  test "a config with no project_id is refused rather than half-resolved" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "account_id: 1\n")

    assert {:error, :no_project_id} = ProjectIdentity.resolve(project.root)
  end

  test "a config that is not YAML says so, distinctly from having no id" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "project_id: [unclosed\n")

    assert {:error, {:invalid_config, _}} = ProjectIdentity.resolve(project.root)
  end

  test "the root is absolute, so two spellings of one checkout are one project" do
    project = project_dir(project_id: 712)
    {:ok, %{root: root}} = ProjectIdentity.resolve(project.root <> "/./")

    assert root == Path.expand(project.root)
  end

  # `project_id: 712` in YAML is an integer; the channel topic is a string. If
  # the two spellings reached the topic the harness would join two different
  # channels for one project.
  test "an integer id becomes the string the topic needs" do
    project = project_dir(project_id: nil)
    write(project.root, ".code_my_spec/config.yml", "project_id: 712\n")

    assert {:ok, %{id: "712"}} = ProjectIdentity.resolve(project.root)
  end
end
