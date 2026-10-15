defmodule CmsHarness.Setup.ProjectTest do
  use ExUnit.Case, async: true

  alias CmsHarness.Setup.Project

  setup do
    root = Path.join(System.tmp_dir!(), "setup-project-#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    %{root: root}
  end

  test "rejects a directory without mix.exs and preserves its files", %{root: root} do
    existing = Path.join(root, "index.html")
    File.write!(existing, "existing site")
    assert {:error, {:invalid_elixir_project, ^root, :enoent}} = Project.validate(root)
    assert File.read!(existing) == "existing site"
    refute File.exists?(Path.join(root, "mix.exs"))
  end

  test "rejects a mix.exs that does not declare a Mix project", %{root: root} do
    File.write!(Path.join(root, "mix.exs"), "IO.puts(\"not a project\")")
    assert {:error, {:invalid_elixir_project, ^root, :no_mix_project}} = Project.validate(root)
  end

  test "validates project syntax without executing its code", %{root: root} do
    marker = Path.join(root, "must-not-exist")

    source = """
    File.write!(#{inspect(marker)}, "executed")
    defmodule SelectedApp.MixProject do
      use Mix.Project
      def project, do: [app: :selected_app, version: "0.1.0"]
    end
    """

    File.write!(Path.join(root, "mix.exs"), source)
    assert {:ok, ^root} = Project.validate(root)
    refute File.exists?(marker)
    assert File.read!(Path.join(root, "mix.exs")) == source
  end

  test "generation refuses an existing directory before invoking commands", %{root: root} do
    File.write!(Path.join(root, "important.txt"), "keep me")
    assert {:error, {:already_exists, ^root}} = Project.generate(root, "selected_app")
    assert File.read!(Path.join(root, "important.txt")) == "keep me"
    refute File.exists?(Path.join(root, "mix.exs"))
  end

  test "invalid application names do not create a destination", %{root: root} do
    destination = Path.join(root, "new_app")
    assert {:error, :invalid_app_name} = Project.generate(destination, "--invalid")
    refute File.exists?(destination)
  end
end
