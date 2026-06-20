defmodule CodeMySpec.AgentTasks.Init do
  @moduledoc """
  Parent task for project initialization.

  Orchestrates the pre-project-ID bootstrap steps. Each step is a module
  under `AgentTasks.Init.*` with `command/3` and `evaluate/3`.

  Once all init steps pass, the project has an ID and transitions to
  project-level setup.
  """

  alias CodeMySpec.AgentTasks.Init

  @steps [
    Init.Auth,
    Init.PhoenixProject,
    Init.CliConfig
  ]

  @doc "Returns the ordered list of init step modules."
  def steps, do: @steps

  @doc "Find a step module by its derived ID (e.g. \"auth\", \"phoenix_project\")."
  def find_step(id) do
    Enum.find(@steps, fn mod -> step_id(mod) == id end)
  end

  @doc "Evaluate all steps. Returns `[{module, :done | {:not_done, detail}}]`."
  def evaluate_all(scope) do
    Enum.map(@steps, fn mod -> {mod, run_evaluate(mod, scope)} end)
  end

  @doc "Evaluate a single step by ID."
  def evaluate_one(id, scope) do
    case find_step(id) do
      nil -> {:error, :not_found}
      mod -> {:ok, mod, run_evaluate(mod, scope)}
    end
  end

  @doc "Returns true if all steps are done."
  def all_done?(scope) do
    Enum.all?(@steps, fn mod -> run_evaluate(mod, scope) == :done end)
  end

  @doc "Derive a URL-friendly ID from a step module name."
  def step_id(mod), do: mod |> Module.split() |> List.last() |> Macro.underscore()

  @doc "Derive a human-readable name from a step module name."
  def step_name(mod), do: mod |> Module.split() |> List.last() |> humanize()

  # --- Agent task interface ---

  def command(scope, _task) do
    scope = ensure_cwd(scope)
    evaluated = evaluate_all(scope)
    {done, total} = count_progress(evaluated)
    incomplete = incomplete_steps(evaluated)

    prompt =
      case incomplete do
        [] ->
          """
          # Project Initialization Complete (#{done}/#{total})

          All init steps are done. The project is linked and ready for
          project-level setup.
          """

        _ ->
          step_sections = render_step_sections(incomplete, scope)

          """
          # Project Initialization (#{done}/#{total})

          ## Checklist

          #{render_checklist(evaluated)}

          #{step_sections}
          """
      end

    {:ok, prompt}
  end

  def evaluate(scope, _task) do
    scope = ensure_cwd(scope)

    if all_done?(scope) do
      {:ok, :valid}
    else
      evaluated = evaluate_all(scope)
      {done, total} = count_progress(evaluated)
      next = find_next_actionable(evaluated)

      next_action =
        case next do
          nil -> "All prerequisites blocked."
          {mod, {:not_done, detail}} -> "**Next**: #{step_name(mod)} — #{detail}"
        end

      {:ok, :invalid, """
      # Init Progress: #{done}/#{total}

      #{render_checklist(evaluated)}

      #{next_action}
      """}
    end
  end

  # --- Private ---

  defp run_evaluate(mod, scope) do
    case mod.evaluate(scope, %{}) do
      {:ok, :valid} -> :done
      {:ok, :invalid, detail} -> {:not_done, detail}
      other -> {:not_done, "Unexpected: #{inspect(other)}"}
    end
  rescue
    e -> {:not_done, "Error: #{Exception.message(e)}"}
  end

  defp ensure_cwd(scope) do
    if Map.get(scope, :cwd), do: scope, else: Map.put(scope, :cwd, File.cwd!())
  end

  defp find_next_actionable(evaluated) do
    Enum.find(evaluated, fn {_, status} -> match?({:not_done, _}, status) end)
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, status} -> status == :done end)
    {done, length(evaluated)}
  end

  defp incomplete_steps(evaluated) do
    Enum.filter(evaluated, fn {_, status} -> match?({:not_done, _}, status) end)
  end

  defp render_step_sections(incomplete, scope) do
    Enum.map_join(incomplete, "\n\n---\n\n", fn {mod, {:not_done, detail}} ->
      {:ok, step_prompt} = mod.command(scope, %{})

      """
      ## #{step_name(mod)}

      #{detail}

      #{step_prompt}\
      """
    end)
  end

  defp render_checklist(evaluated) do
    {_, checklist} =
      Enum.reduce(evaluated, {false, []}, fn {mod, status}, {seen_incomplete, acc} ->
        line = checklist_line(mod, status, seen_incomplete)
        {seen_incomplete || match?({:not_done, _}, status), [line | acc]}
      end)

    checklist |> Enum.reverse() |> Enum.join("\n")
  end

  defp checklist_line(mod, :done, _seen_incomplete), do: "- [x] #{step_name(mod)}"

  defp checklist_line(mod, {:not_done, _}, seen_incomplete) do
    marker = if seen_incomplete, do: "", else: " <- next"
    "- [ ] #{step_name(mod)}#{marker}"
  end

  defp humanize(camel) do
    camel
    |> Macro.underscore()
    |> String.replace("_", " ")
    |> String.capitalize()
  end
end
