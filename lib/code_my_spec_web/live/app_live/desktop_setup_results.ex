defmodule CodeMySpecWeb.AppLive.DesktopSetupResults do
  @moduledoc "Displays recorded desktop setup outcomes for their connected project."
  use Phoenix.Component

  def load(project_id) do
    with :desktop <- Application.get_env(:code_my_spec, :env),
         {:ok, snapshot} <- CmsHarness.Setup.status(),
         %{
           "operations" => %{
             "connect" => %{"state" => "done", "result" => %{"id" => ^project_id}}
           }
         } <- snapshot do
      snapshot
    else
      _ -> nil
    end
  end

  attr :snapshot, :map, default: nil

  def results(assigns) do
    ~H"""
    <details
      :if={@snapshot}
      class="mx-4 my-2 rounded border border-base-300 p-3"
      data-test="desktop-setup-results"
    >
      <summary>Machine setup results</summary>
      <p data-test="setup-results-file" data-path={@snapshot["results_path"]}>
        Results saved to <code>{@snapshot["results_path"]}</code>
      </p>
      <section :for={step <- @snapshot["steps"] || []}>
        <h3>{step["key"]}: {step["state"]}</h3>
        <pre
          :for={command <- step["commands"] || []}
          class="whitespace-pre-wrap break-words"
        >{command["output"]}</pre>
        <p :if={step["error"]}>{step["error"]}</p>
      </section>
    </details>
    """
  end
end
