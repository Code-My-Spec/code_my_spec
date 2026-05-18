defmodule CodeMySpecSpex.TaskResponseHelpers do
  @moduledoc """
  Helpers for asserting on responses from the Tasks MCP tools
  (`StartTask`, `EvaluateTask`).

  Each tool returns an `Anubis.Server.Response` with one or more text
  parts. Most spec assertions just want the flattened text body
  (`response_text/1`) or the task id embedded in `StartTask`'s footer
  (`extract_task_id/1`). Both are pure observation — they read what
  the agent would see, nothing more.
  """

  @doc """
  Flattens a tool response into a single text string.

  Handles `%{content: [%{text: ..} | ...]}`, `%{content: [%{"text" => ..}]}`,
  and `%{text: ..}` shapes the Anubis Response builder produces.
  """
  @spec response_text(any()) :: String.t()
  def response_text(%{content: parts}) when is_list(parts) do
    Enum.map_join(parts, "\n", fn
      %{text: text} -> text
      %{"text" => text} -> text
      other -> inspect(other)
    end)
  end

  def response_text(%{text: text}), do: text
  def response_text(other), do: inspect(other)

  @doc """
  Extracts the task id from a `StartTask` response.

  `TasksMapper.prompt_response/2` writes the task id into a footer line
  formatted as `Task ID: \`<uuid>\``. Parsing the surface response keeps
  spec specs from reaching into the Sessions context to find the task.

  Returns the id string or `nil` if the footer isn't present.
  """
  @spec extract_task_id(any()) :: String.t() | nil
  def extract_task_id(response) do
    case Regex.run(~r/Task ID: `([^`]+)`/, response_text(response)) do
      [_, task_id] -> task_id
      _ -> nil
    end
  end

  @doc """
  Returns the agent-visible text for satisfied `qa_complete` requirements
  across all stories in the active scope, observed through the
  `list_requirements` MCP tool. Spex use this to assert that
  `qa_complete` is/is not satisfied for a given story without reaching
  into the `CodeMySpec.Qa` context.
  """
  @spec satisfied_qa_complete_text(map()) :: String.t()
  def satisfied_qa_complete_text(scope) do
    frame = %Anubis.Server.Frame{assigns: %{current_scope: scope}}

    {:reply, response, _frame} =
      CodeMySpec.McpServers.Requirements.Tools.ListRequirements.execute(
        %{
          status: "satisfied",
          entity_type: "story",
          requirement_name: "qa_complete"
        },
        frame
      )

    response_text(response)
  end
end
