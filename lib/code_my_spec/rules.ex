defmodule CodeMySpec.Rules do
  @moduledoc """
  Simple local file-based rules system.
  Reads rules from markdown files with YAML frontmatter in .code_my_spec/rules/.
  """

  defstruct [:name, :content, :component_type, :session_type]

  @doc """
  Finds matching rules based on component type and session type.
  Supports wildcard matching with "*".

  When `working_dir` is provided, reads rules from `<working_dir>/.code_my_spec/rules/`.
  When omitted, reads from the relative `.code_my_spec/rules/` path (process cwd).

  ## Examples

      iex> find_matching_rules("context", "coding", "/path/to/project")
      [%Rules{}, ...]

  """
  def find_matching_rules(component_type, session_type, working_dir \\ nil) do
    rules_dir = resolve_rules_dir(working_dir)

    load_all_rules(rules_dir)
    |> filter_matching(component_type, session_type)
  end

  defp resolve_rules_dir(nil), do: CodeMySpec.Paths.rules_dir()
  defp resolve_rules_dir(working_dir), do: Path.join(working_dir, CodeMySpec.Paths.rules_dir())

  # Private functions

  defp load_all_rules(rules_directory) do
    case File.exists?(rules_directory) do
      true ->
        rules_directory
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(rules_directory, &1))
        |> Enum.map(&parse_rule_file/1)
        |> Enum.filter(&match?({:ok, _}, &1))
        |> Enum.map(fn {:ok, rule} -> rule end)

      false ->
        []
    end
  end

  defp parse_rule_file(file_path) do
    with {:ok, content} <- File.read(file_path),
         {:ok, frontmatter, markdown} <- parse_frontmatter(content) do
      rule_name = Path.basename(file_path, ".md")

      rule = %__MODULE__{
        name: rule_name,
        content: String.trim(markdown),
        component_type: Map.get(frontmatter, "component_type", "*"),
        session_type: Map.get(frontmatter, "session_type", "*")
      }

      {:ok, rule}
    else
      {:error, reason} -> {:error, reason}
    end
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
