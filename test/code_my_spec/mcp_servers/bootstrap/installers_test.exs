defmodule CodeMySpec.McpServers.Bootstrap.InstallersTest do
  @moduledoc """
  `init_project` runs these installers so the four harness-owned setup steps
  (AGENTS.md, CLAUDE.md, rules, credo checks) cost no model turns.

  The assertions go further than "a file appeared": each installed file is
  pushed back through `Files.FileSync`, the same validator the requirements
  graph reads. That is what actually decides whether `project_setup` is
  satisfied, so it is what this test checks.
  """
  use ExUnit.Case, async: true

  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Files.FileSync
  alias CodeMySpec.McpServers.Bootstrap.Installers
  alias CodeMySpec.Paths

  setup do
    {:ok, tmp} = Briefly.create(directory: true)

    # AGENTS.md derives the app name from mix.exs; without one the installer
    # has nothing to name the project after.
    File.write!(Path.join(tmp, "mix.exs"), """
    defmodule MyApp.MixProject do
      use Mix.Project
      def project, do: [app: :my_app]
    end
    """)

    {:ok, tmp: tmp, env: Environment.new(:local, tmp)}
  end

  defp validation_errors(tmp, env, path) do
    {^path, role} = FileSync.classify(path)
    out = FileSync.validate_entry(%{path: path, role: role, component_id: nil}, env, %{}, true)
    _ = tmp

    case out[:validation_errors] do
      %{errors: e} -> e |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
      %{"errors" => e} -> e |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> Map.new()
      _ -> %{}
    end
  end

  test "install_all installs every harness file", %{tmp: tmp, env: env} do
    assert {installed, []} = Installers.install_all(env)
    assert Enum.sort(installed) == ["AGENTS.md", "CLAUDE.md", "credo_checks", "rules"]

    assert File.exists?(Path.join([tmp, Paths.base_dir(), "AGENTS.md"]))
    assert File.exists?(Path.join(tmp, "CLAUDE.md"))
    assert File.dir?(Path.join(tmp, Paths.rules_dir()))
    assert File.dir?(Path.join(tmp, Paths.credo_checks_framework_dir()))
    assert File.dir?(Path.join(tmp, Paths.credo_checks_local_dir()))

    rules = File.ls!(Path.join(tmp, Paths.rules_dir()))
    assert Enum.any?(rules, &String.ends_with?(&1, ".md")), "expected rule files, got #{inspect(rules)}"
  end

  test "installed files satisfy the sync-time validators", %{tmp: tmp, env: env} do
    {_installed, []} = Installers.install_all(env)

    assert validation_errors(tmp, env, "CLAUDE.md") == %{},
           "CLAUDE.md must carry the managed section marker"

    assert validation_errors(tmp, env, Path.join(Paths.base_dir(), "AGENTS.md")) == %{}
  end

  test "install_all is idempotent", %{tmp: tmp, env: env} do
    {_, []} = Installers.install_all(env)

    claude_before = File.read!(Path.join(tmp, "CLAUDE.md"))
    rules_before = tmp |> Path.join(Paths.rules_dir()) |> File.ls!() |> Enum.sort()

    assert {_, []} = Installers.install_all(env)

    assert File.read!(Path.join(tmp, "CLAUDE.md")) == claude_before,
           "re-running must not duplicate the managed section"

    assert tmp |> Path.join(Paths.rules_dir()) |> File.ls!() |> Enum.sort() == rules_before
  end

  test "a user's own CLAUDE.md content is preserved", %{tmp: tmp, env: env} do
    File.write!(Path.join(tmp, "CLAUDE.md"), "# My project\n\nHand-written notes.\n")

    {_, []} = Installers.install_all(env)

    content = File.read!(Path.join(tmp, "CLAUDE.md"))
    assert content =~ "Hand-written notes."
    assert content =~ "<!-- code_my_spec:start -->"
  end

  test "rule files already in the project are not overwritten", %{tmp: tmp, env: env} do
    rules_dir = Path.join(tmp, Paths.rules_dir())
    File.mkdir_p!(rules_dir)

    {_, []} = Installers.install_all(env)
    [existing | _] = rules_dir |> File.ls!() |> Enum.filter(&String.ends_with?(&1, ".md"))

    customized = Path.join(rules_dir, existing)
    File.write!(customized, "MY CUSTOMIZED RULE")

    {_, []} = Installers.install_all(env)

    assert File.read!(customized) == "MY CUSTOMIZED RULE",
           "installing must never clobber a rule the project has customized"
  end
end
