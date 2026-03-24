defmodule CodeMySpec.AgentTasks.Init do
  @moduledoc """
  Parent task for project initialization.

  Orchestrates the pre-project-ID bootstrap steps. Same pattern as
  `DevelopContext` — walks child steps via `Setup.Steps`, finds the
  next actionable one, and returns a focused prompt.

  Once all init steps pass, the project has an ID and transitions to
  project-level requirements at `/project/:id/requirements`.

  The init checklist is always live at `GET /init`.
  """

  alias CodeMySpec.Setup.Steps

  @doc """
  Returns the orchestration prompt with checklist and next step's prompt.
  """
  def command(scope, _session, _opts \\ []) do
    working_dir = resolve_working_dir(scope)
    evaluated = Steps.evaluate_all(scope, working_dir)
    {done, total} = count_progress(evaluated)

    next = find_next_actionable(evaluated)

    prompt =
      case next do
        nil ->
          """
          # Project Initialization Complete (#{done}/#{total})

          All init steps are done. The project is linked and ready for
          project-level setup at `/project/:id/requirements`.
          """

        {step, {:not_done, detail}} ->
          {:ok, step_prompt} = step.module.command(scope, %{})

          """
          # Project Initialization (#{done}/#{total})

          ## Checklist

          #{render_checklist(evaluated)}

          ## Next Step: #{step.name}

          #{detail}

          ---

          #{step_prompt}
          """
      end

    {:ok, prompt}
  end

  @doc """
  Evaluates whether all init steps are complete.
  """
  def evaluate(scope, _session, _opts \\ []) do
    working_dir = resolve_working_dir(scope)

    if Steps.all_done?(scope, working_dir) do
      {:ok, :valid}
    else
      evaluated = Steps.evaluate_all(scope, working_dir)
      {done, total} = count_progress(evaluated)
      next = find_next_actionable(evaluated)

      next_action =
        case next do
          nil -> "All prerequisites blocked."
          {step, {:not_done, detail}} -> "**Next**: #{step.name} — #{detail}"
        end

      {:ok, :invalid, """
      # Init Progress: #{done}/#{total}

      #{render_checklist(evaluated)}

      #{next_action}
      """}
    end
  end

  defp resolve_working_dir(scope) do
    Map.get(scope, :cwd) || File.cwd!()
  end

  defp find_next_actionable(evaluated) do
    Enum.find(evaluated, fn {_step, status} ->
      match?({:not_done, _}, status)
    end)
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, status} -> status == :done end)
    {done, length(evaluated)}
  end

  defp render_checklist(evaluated) do
    Enum.map_join(evaluated, "\n", fn {step, status} ->
      case status do
        :done -> "- [x] #{step.name}"
        :blocked -> "- [ ] #{step.name} (blocked)"
        {:not_done, _} -> "- [ ] #{step.name} ← next"
      end
    end)
  end
end
