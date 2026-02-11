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

  def format_details(%{"reason" => reason}), do: reason
  def format_details(%{reason: reason}), do: reason
  def format_details(_), do: "unsatisfied"
end
