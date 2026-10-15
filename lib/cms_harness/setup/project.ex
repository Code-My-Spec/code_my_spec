defmodule CmsHarness.Setup.Project do
  @moduledoc "Validates selected Elixir directories and invokes the existing project generator."

  alias CmsHarness.Projects.Generator.Runner

  @spec validate(String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate(path) when is_binary(path) and path != "" do
    root = Path.expand(path)

    with {:ok, source} <- File.read(Path.join(root, "mix.exs")),
         {:ok, ast} <- Code.string_to_quoted(source),
         true <- mix_project?(ast) do
      {:ok, root}
    else
      {:error, reason} -> {:error, {:invalid_elixir_project, root, reason}}
      false -> {:error, {:invalid_elixir_project, root, :no_mix_project}}
    end
  end

  def validate(_path), do: {:error, :project_path_required}

  @spec generate(String.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def generate(path, app_name) when is_binary(path) and path != "" and is_binary(app_name) do
    root = Path.expand(path)

    with :ok <- validate_app_name(app_name),
         :ok <- refuse_existing(root),
         :ok <- File.mkdir_p(Path.dirname(root)),
         {:ok, _output} <-
           generator_command(Path.dirname(root), [
             "cms.new",
             root,
             "--app",
             app_name,
             "--no-install"
           ]) do
      validate(root)
    end
  end

  def generate(_path, _app_name), do: {:error, :project_path_and_name_required}

  defp generator_command(directory, args) do
    Runner.impl().cmd(directory, "mix", args)
  rescue
    error in ErlangError ->
      {:error, {:generator_unavailable, Exception.message(error)}}
  end

  defp validate_app_name(name) do
    case Regex.match?(~r/\A[a-z][a-z0-9_]*\z/, name) do
      true -> :ok
      false -> {:error, :invalid_app_name}
    end
  end

  defp refuse_existing(root) do
    case File.lstat(root) do
      {:error, :enoent} -> :ok
      {:ok, _stat} -> {:error, {:already_exists, root}}
      {:error, reason} -> {:error, reason}
    end
  end

  # Parse the selected file without evaluating arbitrary project code.
  defp mix_project?(ast) do
    {_ast, found} =
      Macro.prewalk(ast, false, fn
        {:use, _, [{:__aliases__, _, [:Mix, :Project]} | _]} = node, _found ->
          {node, true}

        node, found ->
          {node, found}
      end)

    found
  end
end
