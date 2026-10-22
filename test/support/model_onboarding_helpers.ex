defmodule CodeMySpecSpex.ModelOnboardingHelpers do
  @moduledoc "Completes model selection before specs exercise later onboarding steps."
  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  @endpoint CodeMySpecWeb.Endpoint

  def configure_models(%{conn: conn}) do
    {:ok, view, _} = live(conn, "/app/agent-models")

    view
    |> form("[data-test=agent-models-form]", %{
      "main" => %{"provider" => "claude-code", "model" => "sonnet"}
    })
    |> render_submit()

    :ok
  end
end
