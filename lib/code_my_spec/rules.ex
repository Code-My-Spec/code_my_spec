defmodule CodeMySpec.Rules do
  @moduledoc """
  Simple local file-based rules system.
  Reads rules from markdown files with YAML frontmatter in docs/rules/.
  """

  defstruct [:name, :content, :component_type, :session_type]

  @rules_directory CodeMySpec.Paths.rules_dir()

  @doc """
  Finds matching rules based on component type and session type.
  Supports wildcard matching with "*".

  ## Examples

      iex> find_matching_rules("context", "coding")
      [%Rules{}, ...]

  """
  def find_matching_rules(component_type, session_type) do
    load_all_rules()
    |> filter_matching(component_type, session_type)
  end

  # Private functions

  defp load_all_rules do
    case File.exists?(@rules_directory) do
      true ->
        @rules_directory
        |> File.ls!()
        |> Enum.filter(&String.ends_with?(&1, ".md"))
        |> Enum.map(&Path.join(@rules_directory, &1))
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
