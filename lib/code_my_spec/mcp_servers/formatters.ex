defmodule CodeMySpec.McpServers.Formatters do
  @moduledoc """
  Formats responses and errors for MCP servers in a hybrid format:
  human-readable summary + JSON data for programmatic access.
  """

  @doc """
  Formats changeset errors as human-readable text with guidance.
  """
  def format_changeset_errors(changeset) do
    errors = extract_errors(changeset)

    error_lines =
      Enum.map_join(errors, "\n", fn {field, messages} ->
        Enum.map_join(messages, "\n", fn msg -> "- **#{field}**: #{msg}" end)
      end)

    guidance = generate_fix_guidance(errors)

    """
    ## Validation Error

    #{error_lines}

    #{guidance}
    """
    |> String.trim()
  end

  @doc """
  Extracts errors as a map for programmatic use.
  """
  def extract_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {message, opts} ->
      Regex.replace(~r"%{(\w+)}", message, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp generate_fix_guidance(errors) do
    hints =
      errors
      |> Enum.flat_map(fn {field, messages} ->
        Enum.map(messages, fn msg -> field_hint(field, msg) end)
      end)
      |> Enum.reject(&is_nil/1)

    if hints == [] do
      ""
    else
      "### How to fix\n#{Enum.join(hints, "\n")}"
    end
  end

  defp field_hint(:title, "can't be blank"), do: "- Provide a non-empty title string"
  defp field_hint(:description, "can't be blank"), do: "- Provide a description of the story"

  defp field_hint(:acceptance_criteria, msg) when is_binary(msg) do
    if String.contains?(msg, "at least") do
      "- Provide at least one acceptance criterion as a list of strings"
    else
      nil
    end
  end

  defp field_hint(_, _), do: nil
end
