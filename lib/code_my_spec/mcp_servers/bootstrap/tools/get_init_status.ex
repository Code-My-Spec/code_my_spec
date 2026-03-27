defmodule CodeMySpec.McpServers.Bootstrap.Tools.GetInitStatus do
  @moduledoc """
  Check the status of project initialization steps.

  Returns a checklist of pre-project-ID bootstrap steps (auth, elixir,
  phoenix, postgresql, project creation, config linking) with their
  current status.
  """

  use Anubis.Server.Component, type: :tool

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpec.Environments.Environment
  alias CodeMySpec.McpServers.Bootstrap.BootstrapMapper
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Users.Scope

  schema do
  end

  @impl true
  def execute(_params, frame) do
    working_dir = Validators.mcp_working_dir(frame)
    env = Environment.new(:local, working_dir)
    scope = %Scope{environment: env}

    evaluated = Init.evaluate_all(scope)
    {done, total} = count_progress(evaluated)

    checklist =
      Enum.map_join(evaluated, "\n", fn {mod, status} ->
        case status do
          :done -> "- [x] #{Init.step_name(mod)}"
          {:not_done, detail} -> "- [ ] #{Init.step_name(mod)} — #{detail}"
        end
      end)

    text = "# Init Status (#{done}/#{total})\n\n#{checklist}"

    data = %{
      done: done,
      total: total,
      all_done: done == total,
      steps:
        Enum.map(evaluated, fn {mod, status} ->
          %{
            id: Init.step_id(mod),
            name: Init.step_name(mod),
            status: if(status == :done, do: :done, else: :not_done)
          }
        end)
    }

    {:reply, BootstrapMapper.status_response(text, data), frame}
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, status} -> status == :done end)
    {done, length(evaluated)}
  end
end
