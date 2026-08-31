defmodule CmsHarness.Agents.Tools.ToolDocs do
  @moduledoc """
  The other of the two: what a script may call, and what each one takes.

  The reason two tools beat ninety-eight is not that the ninety-eight are
  unavailable — they are all reachable through `run_script` — it is that their
  schemas are read on every turn to answer a question the agent asks once. This
  is that question, asked once, when it has decided which tool it wants.

  Names by default and arguments on request, for the same reason. A list of
  every tool's schema is the catalogue again in one string.
  """

  @behaviour Alloy.Tool

  alias CmsHarness.Mcp

  @impl true
  def name, do: "tool_docs"

  @impl true
  def description do
    """
    What this project's tools are called, and what one takes.

    With no arguments: every tool name with a one-line summary. With `names`:
    the full arguments for those tools, which is what you need before calling
    one from `run_script`.
    """
  end

  @impl true
  def input_schema do
    %{
      type: "object",
      properties: %{
        names: %{
          type: "array",
          items: %{type: "string"},
          description: "Tools to describe in full. Omit for the list of names."
        }
      }
    }
  end

  @impl true
  def execute(input, context) do
    with {:ok, client} <- session(context) do
      Mcp.call(client, "tool_docs", arguments(input))
    end
  end

  @impl true
  def allowed_callers, do: [:human, :code_execution]

  @impl true
  def result_type, do: :text

  defp arguments(%{"names" => names}) when is_list(names) and names != [], do: %{"names" => names}
  defp arguments(_input), do: %{}

  defp session(%{mcp_client: client}) when not is_nil(client), do: {:ok, client}

  defp session(_context) do
    {:error,
     "This agent has no session with its project's server, so there is nothing " <>
       "to look up. Check the harness is connected."}
  end
end
