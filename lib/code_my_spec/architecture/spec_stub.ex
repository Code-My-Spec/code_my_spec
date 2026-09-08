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
      |> Enum.map(&(&1 |> String.trim() |> Macro.underscore()))

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
  Writes a stub spec for a component through the scope's environment.

  Returns `{:error, :no_working_copy}` when the scope has none, rather than
  rooting one at the current directory.

  That fallback existed and it wrote this project's stubs into the *server's*
  own checkout. Drill 7 left eight `e2e_todo` spec files in the code_my_spec
  repository, and the consequence in the container was the mirror image: the
  spec directory stayed empty, so no component had dependency edges, so every
  component read as an orphan, so `architecture_designed` could not pass. One
  fabricated environment, and the requirement was unsatisfiable while the agent
  did everything right.

  The caller decides what to do about a missing working copy — see
  `McpServers.Components.Tools.CreateComponent`, which hands the stub to the
  agent to write instead.
  """
  @spec write_for_scope(map(), map()) :: :ok | {:error, term()}
  def write_for_scope(%{environment: nil}, _attrs), do: {:error, :no_working_copy}

  def write_for_scope(scope, attrs), do: write(scope.environment, attrs)

  @doc """
  The stub's path and body, without writing anything.

  For callers that cannot write — the server has no disk on the light harness —
  and must hand the content to whoever does.
  """
  @spec render(map()) :: {String.t(), String.t()}
  def render(attrs), do: {path_for(attrs.module_name), render_template(attrs)}

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
