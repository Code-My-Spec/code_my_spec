defmodule CodeMySpecLocalWeb.InitController do
  @moduledoc """
  LLM API for project init checklist.

  Returns markdown responses for LLM consumption.
  The human interface is handled by `InitLive`.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.AgentTasks.Init
  alias CodeMySpecLocalWeb.InitMarkdown

  def index(conn, _params) do
    working_dir = conn.assigns.working_dir
    scope = %{cwd: working_dir}
    evaluated = Init.evaluate_all(scope)
    {done, total} = count_progress(evaluated)

    markdown =
      InitMarkdown.index(%{
        title: "Project Init",
        evaluated: evaluated,
        done: done,
        total: total,
        base_path: "/api/init"
      })

    text(conn, markdown)
  end

  def show(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = %{cwd: working_dir}

    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, status} ->
        markdown =
          InitMarkdown.show(%{
            mod: mod,
            status: status,
            base_path: "/api/init"
          })

        text(conn, markdown)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Step not found: #{step_id}")
    end
  end

  def prompt(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = %{cwd: working_dir}

    case Init.evaluate_one(step_id, scope) do
      {:ok, mod, _} ->
        {:ok, prompt_text} = mod.command(scope, %{})
        text(conn, prompt_text)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Step not found: #{step_id}")
    end
  end

  defp count_progress(evaluated) do
    done = Enum.count(evaluated, fn {_, s} -> s == :done end)
    {done, length(evaluated)}
  end
end
