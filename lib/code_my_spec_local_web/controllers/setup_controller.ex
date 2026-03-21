defmodule CodeMySpecLocalWeb.SetupController do
  @moduledoc """
  LLM API for project setup checklist.

  Returns markdown responses for LLM consumption.
  The human interface is handled by `SetupLive`.
  """
  use CodeMySpecLocalWeb, :controller

  alias CodeMySpec.Setup.SetupSteps
  alias CodeMySpecLocalWeb.SetupMarkdown

  def index(conn, _params) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}
    evaluated = SetupSteps.evaluate_all(scope, working_dir)
    {done, total} = count_progress(evaluated)

    markdown =
      SetupMarkdown.index(%{
        title: "Project Setup",
        evaluated: evaluated,
        done: done,
        total: total,
        base_path: "/api/setup"
      })

    text(conn, markdown)
  end

  def show(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}

    case SetupSteps.evaluate_one(step_id, scope, working_dir) do
      {:ok, step, status} ->
        markdown =
          SetupMarkdown.show(%{
            step: step,
            status: status,
            base_path: "/api/setup"
          })

        text(conn, markdown)

      {:error, :not_found} ->
        conn |> put_status(404) |> text("Step not found: #{step_id}")
    end
  end

  def prompt(conn, %{"step" => step_id}) do
    working_dir = conn.assigns.working_dir
    scope = conn.assigns[:current_scope] || %{cwd: working_dir}

    case SetupSteps.evaluate_one(step_id, scope, working_dir) do
      {:ok, step, _} ->
        {:ok, prompt_text} = step.module.command(scope, %{})
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
