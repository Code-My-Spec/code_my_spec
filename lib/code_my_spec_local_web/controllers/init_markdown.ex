defmodule CodeMySpecLocalWeb.InitMarkdown do
  @moduledoc """
  Markdown rendering for the init API (LLM interface).

  Each function takes an assigns map and returns a markdown string.
  These are called by InitController for the `/api/init/*` endpoints.
  """

  def index(%{evaluated: evaluated, title: title, done: done, total: total, base_path: base_path}) do
    lines =
      Enum.map(evaluated, fn {step, status} ->
        case status do
          :done -> "- [x] #{step.name}"
          :blocked -> "- [ ] #{step.name} (blocked)"
          {:not_done, _} -> "- [ ] [#{step.name}](#{base_path}/#{step.id})"
        end
      end)

    "# #{title} (#{done}/#{total})\n\n#{Enum.join(lines, "\n")}\n"
  end

  def show(%{step: step, status: status, base_path: base_path}) do
    status_line =
      case status do
        :done -> "Status: done"
        :blocked -> "Status: blocked (prerequisites: #{Enum.join(step.prereqs, ", ")})"
        {:not_done, detail} -> "Status: not done — #{detail}"
      end

    prompt_link =
      case status do
        {:not_done, _} -> "\n\nPrompt: [#{base_path}/#{step.id}/prompt](#{base_path}/#{step.id}/prompt)"
        _ -> ""
      end

    "# #{step.name}\n\n#{status_line}#{prompt_link}\n"
  end
end
