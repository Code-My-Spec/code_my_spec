defmodule CodeMySpec.Architecture.SpecStub do
  @moduledoc """
  Writes lightweight spec stub files for components.

  A stub spec contains module-level metadata (name, type, description, optional
  dependencies) but leaves the body empty for the ComponentSpec phase to fill
  in. Writing is idempotent — if a file already exists at the conventional
  path, the existing content is preserved.

  Used by:

    - `CodeMySpec.Architecture.Proposal.execute/3` — writes stubs for every
      component declared in a proposal.
    - `CodeMySpec.McpServers.Components.Tools.CreateComponent` — writes a
      stub for a single component added incrementally during patch mode.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.Paths

  @doc """
  Returns the conventional spec file path for a component module name.

      iex> CodeMySpec.Architecture.SpecStub.path_for("MyApp.Accounts")
      ".code_my_spec/spec/my_app/accounts.spec.md"
  """
  @spec path_for(String.t()) :: String.t()
  def path_for(module_name) do
    path_parts =
      module_name
      |> String.trim()
      |> String.split(".")
      |> Enum.map(&String.trim/1)
      |> Enum.map(&Macro.underscore/1)

    Path.join([Paths.spec_dir() | path_parts]) <> ".spec.md"
  end

  @doc """
  Writes a stub spec for the given component attrs through the environment.

  Returns `:ok` whether the file was written or already existed (idempotent).
  Returns `{:error, reason}` only on write failures.

  Required attrs: `:module_name`, `:type`. Optional: `:description`,
  `:dependencies` (list of module names).
  """
  @spec write(map(), map()) :: :ok | {:error, term()}
  def write(env, attrs) do
    spec_path = path_for(attrs.module_name)

    if Environments.file_exists?(env, spec_path) do
      :ok
    else
      Environments.write_file(env, spec_path, render_template(attrs))
    end
  end

  @doc """
  Writes a stub spec for a component using the environment derived from
  the scope. Falls back to a CLI environment rooted at the scope's cwd
  (or the current working directory) if `scope.environment` is nil.

  Used by callers in non-`Architecture` boundaries (e.g. `McpServers`)
  that should not reference `Environment` directly.
  """
  @spec write_for_scope(map(), map()) :: :ok | {:error, term()}
  def write_for_scope(scope, attrs) do
    env = scope.environment || Environment.new(:cli, scope.cwd || File.cwd!())
    write(env, attrs)
  end

  defp render_template(attrs) do
    base = """
    # #{attrs.module_name}

    #{Map.get(attrs, :description) || "No description provided"}

    ## Type

    #{attrs.type}
    """

    case dependencies(attrs) do
      [] -> base
      deps -> base <> "\n## Dependencies\n\n" <> format_dependencies(deps) <> "\n"
    end
  end

  defp dependencies(attrs) do
    case Map.get(attrs, :dependencies) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp format_dependencies(deps) do
    Enum.map_join(deps, "\n", &"- #{&1}")
  end
end
