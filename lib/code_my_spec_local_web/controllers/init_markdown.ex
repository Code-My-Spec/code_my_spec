defmodule CodeMySpecLocalWeb.InitMarkdown do
  @moduledoc """
  Markdown rendering for the init API (LLM interface).

  Each function takes an assigns map and returns a markdown string.
  """

  alias CodeMySpec.AgentTasks.Init

  def index(%{evaluated: evaluated, title: title, done: done, total: total, base_path: base_path}) do
    lines =
      Enum.map(evaluated, fn {mod, status} ->
        case status do
          :done -> "- [x] #{Init.step_name(mod)}"
          {:not_done, _} -> "- [ ] [#{Init.step_name(mod)}](#{base_path}/#{Init.step_id(mod)})"
        end
      end)

    "# #{title} (#{done}/#{total})\n\n#{Enum.join(lines, "\n")}\n"
  end

  def show(%{mod: mod, status: status, base_path: base_path}) do
    id = Init.step_id(mod)
    name = Init.step_name(mod)

    status_line =
      case status do
        :done -> "Status: done"
        {:not_done, detail} -> "Status: not done — #{detail}"
      end

    prompt_link =
      case status do
        {:not_done, _} -> "\n\nPrompt: [#{base_path}/#{id}/prompt](#{base_path}/#{id}/prompt)"
        _ -> ""
      end

    "# #{name}\n\n#{status_line}#{prompt_link}\n"
  end
end
