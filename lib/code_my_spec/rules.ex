defmodule CodeMySpec.Rules do
  @moduledoc """
  Simple file-based rules system.
  Reads rules from markdown files with YAML frontmatter in `.code_my_spec/rules/`.

  Filesystem access goes through `CodeMySpec.Environments` so spex tests
  can drive setup through the in-memory environment. When called without
  an environment, falls back to direct `File.*` reads in the process cwd.
  """

  alias CodeMySpec.Environments
  alias CodeMySpec.Environments.Environment

  defstruct [:name, :content, :component_type, :session_type]

  @rules_dir ".code_my_spec/rules"

  @doc """
  Finds matching rules based on component type and session type.
  Supports wildcard matching with "*".

  The third argument is the execution environment (`Environment.t()`)
  to read rule files from. When `nil`, falls back to the process
  filesystem at the relative `.code_my_spec/rules/` path.

  ## Examples

      iex> find_matching_rules("context", "coding", scope.environment)
      [%Rules{}, ...]

  """
  def find_matching_rules(component_type, session_type, env_or_nil \\ nil) do
    env_or_nil
    |> load_all_rules()
    |> filter_matching(component_type, session_type)
  end

  # Private functions

  defp load_all_rules(%Environment{} = env) do
    case Environments.list_directory(env, @rules_dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(@rules_dir, &1))
        |> Enum.map(&parse_env_rule_file(env, &1))
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, rule} -> rule end)

      {:error, _} ->
        []
    end
  end

  defp load_all_rules(nil) do
    rules_dir = CodeMySpec.Paths.rules_dir()

    case File.exists?(rules_dir) do
      true ->
        rules_dir
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(rules_dir, &1))
        |> Enum.map(&parse_disk_rule_file/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, rule} -> rule end)

      false ->
        []
    end
  end

  defp parse_env_rule_file(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} -> build_rule(path, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp parse_disk_rule_file(path) do
    case File.read(path) do
      {:ok, content} -> build_rule(path, content)
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_rule(path, content) do
    {:ok, frontmatter, markdown} = parse_frontmatter(content)

    rule = %__MODULE__{
      name: Path.basename(path, ".md"),
      content: String.trim(markdown),
      component_type: Map.get(frontmatter, "component_type", "*"),
      session_type: Map.get(frontmatter, "session_type", "*")
    }

    {:ok, rule}
  end

  defp parse_frontmatter(content) do
    case String.split(content, "---", parts: 3) do
      ["", yaml_content, markdown_content] ->
        case YamlElixir.read_from_string(yaml_content) do
          {:ok, frontmatter} ->
            {:ok, frontmatter, markdown_content}

          {:error, _} ->
            {:ok, %{}, content}
        end

      [markdown_content] ->
        {:ok, %{}, markdown_content}

      _ ->
        {:ok, %{}, content}
    end
  end

  defp filter_matching(rules, component_type, session_type) do
    Enum.filter(rules, fn rule ->
      component_matches?(rule.component_type, component_type) &&
        session_matches?(rule.session_type, session_type)
    end)
  end

  defp component_matches?("*", _), do: true
  defp component_matches?(rule_type, component_type), do: rule_type == component_type

  defp session_matches?("*", _), do: true
  defp session_matches?(rule_type, session_type), do: rule_type == session_type
end
