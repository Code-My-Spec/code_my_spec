defmodule CodeMySpec.Requirements.RequirementsFormatter do
  @moduledoc """
  Formats unsatisfied requirements into human-readable feedback strings.

  Used by agent tasks (ComponentTest, ComponentCode) to produce feedback
  when requirement checks fail during evaluate.
  """

  alias CodeMySpec.Requirements.Requirement

  @doc """
  Formats a list of unsatisfied requirements into a feedback string.

  ## Parameters
    * `unsatisfied` - list of `%Requirement{}` structs that are not satisfied
    * `opts` - keyword options:
      - `:context` - prefix line (default: "Requirements not met:")

  ## Examples

      iex> format_unsatisfied([%Requirement{description: "File exists", details: %{reason: "File missing"}}])
      "Requirements not met:\\n- File exists: File missing"

  """
  @spec format_unsatisfied([Requirement.t()], keyword()) :: String.t()
  def format_unsatisfied(unsatisfied, opts \\ []) do
    context = Keyword.get(opts, :context, "Requirements not met:")

    issues =
      Enum.map_join(unsatisfied, "\n", fn req ->
        "- #{req.description}: #{format_details(req.details)}"
      end)

    "#{context}\n#{issues}"
  end

  @doc """
  Formats requirement details into a concise string.

  Handles both atom-keyed and string-keyed maps (from DB round-trips),
  and optionally includes a problems list.
  """
  @spec format_details(map()) :: String.t()
  def format_details(%{"reason" => reason, "problems" => problems})
      when is_list(problems) do
    "#{reason} — #{Enum.join(problems, "; ")}"
  end

  def format_details(%{reason: reason, problems: problems})
      when is_list(problems) do
    "#{reason} — #{Enum.join(problems, "; ")}"
  end

  def format_details(%{"reason" => reason, "errors" => errors}) when is_map(errors) do
    "#{reason} — #{format_errors(errors)}"
  end

  def format_details(%{reason: reason, errors: errors}) when is_map(errors) do
    "#{reason} — #{format_errors(errors)}"
  end

  def format_details(%{"reason" => reason, "errors" => errors}) when is_list(errors) do
    "#{reason} — #{Enum.join(errors, "; ")}"
  end

  def format_details(%{reason: reason, errors: errors}) when is_list(errors) do
    "#{reason} — #{Enum.join(errors, "; ")}"
  end

  def format_details(%{"reason" => reason, "expected_path" => path}), do: "#{reason} (expected at #{path})"
  def format_details(%{reason: reason, expected_path: path}), do: "#{reason} (expected at #{path})"
  def format_details(%{"reason" => reason}), do: reason
  def format_details(%{reason: reason}), do: reason
  def format_details(_), do: "unsatisfied"

  defp format_errors(%{missing: missing, extra: extra}) do
    parts = []
    parts = if missing != [], do: parts ++ ["missing: #{Enum.join(missing, ", ")}"], else: parts
    parts = if extra != [], do: parts ++ ["extra: #{Enum.join(extra, ", ")}"], else: parts
    Enum.join(parts, "; ")
  end

  defp format_errors(%{"missing" => missing, "extra" => extra}) do
    format_errors(%{missing: missing, extra: extra})
  end

  defp format_errors(%{error: error}), do: to_string(error)
  defp format_errors(%{"error" => error}), do: to_string(error)

  defp format_errors(errors) when is_map(errors) do
    Enum.map_join(errors, "; ", fn {k, v} -> "#{k}: #{inspect(v)}" end)
  end
end
