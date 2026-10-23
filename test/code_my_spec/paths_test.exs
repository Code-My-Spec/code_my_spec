defmodule CodeMySpec.PathsTest do
  use ExUnit.Case, async: false
  alias CodeMySpec.Paths

  setup do
    previous = Map.new(~w(CMS_PROJECT_DIR CMS_DESKTOP_DB), &{&1, System.get_env(&1)})
    agents = Application.get_env(:code_my_spec, :detached_agents_root)
    Enum.each(Map.keys(previous), &System.delete_env/1)
    Application.delete_env(:code_my_spec, :detached_agents_root)

    on_exit(fn ->
      for {key, value} <- previous do
        restore_env(key, value)
      end

      restore_agents(agents)
    end)

    :ok
  end

  test "machine defaults share the user state directory" do
    root = Paths.expand(Path.join(System.user_home!(), ".codemyspec"))
    assert Paths.user_state_dir() == root
    assert Paths.local_state_dir() == root
    assert Paths.agents_root() == Path.join(root, "agents")
    assert Paths.scratch_root() == Path.join(root, "scratch")
    assert Paths.projects_root() == Path.join(root, "projects")
    assert Paths.desktop_database() == Path.join(root, "desktop.db")
    assert CmsHarness.Config.projects_root() == Paths.projects_root()
  end

  test "workspace state keeps its independent identity without moving the desktop database" do
    project = Path.join(System.tmp_dir!(), "cms-path-test/workspace/project")
    System.put_env("CMS_PROJECT_DIR", project)
    root = project |> Paths.expand() |> Path.dirname()
    assert Paths.local_state_dir() == root
    assert Paths.agents_root() == Path.join(root, "agents")
    assert Paths.projects_root() == Path.join(root, "projects")
    assert Paths.desktop_database() == Path.join(Paths.user_state_dir(), "desktop.db")
  end

  test "explicit database and detached agent destinations take precedence" do
    System.put_env("CMS_DESKTOP_DB", "~/cms-custom/preview.db")
    Application.put_env(:code_my_spec, :detached_agents_root, "~/cms-custom/agents")
    assert Paths.desktop_database() == Paths.expand("~/cms-custom/preview.db")
    assert Paths.agents_root() == Paths.expand("~/cms-custom/agents")
  end

  test "project resource paths remain checkout relative" do
    assert Paths.base_dir() == ".code_my_spec"
    assert Paths.tasks_dir() == ".code_my_spec/tasks"
  end

  defp restore_env(key, nil), do: System.delete_env(key)
  defp restore_env(key, value), do: System.put_env(key, value)
  defp restore_agents(nil), do: Application.delete_env(:code_my_spec, :detached_agents_root)
  defp restore_agents(value), do: Application.put_env(:code_my_spec, :detached_agents_root, value)
end
