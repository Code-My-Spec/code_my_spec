defmodule CmsHarness.ProjectIdentityTest do
  @moduledoc """
  Which project a directory is — answered here, on the machine that has the
  directory, because a server with no disk cannot look a path up.

  The order is `CMS_PROJECT_ID`, then `config.yml`, then refuse. There is
  deliberately no fourth step: guessing means syncing one checkout's files over
  another project's rows.
  """

  use ExUnit.Case, async: true

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

  test "the environment wins, which is what a sprite relies on" do
    project = project_dir(project_id: 712)
    System.put_env("CMS_PROJECT_ID", "999")

    assert {:ok, %{id: "999"}} = ProjectIdentity.resolve(project.root)
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
