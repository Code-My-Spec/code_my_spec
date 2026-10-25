defmodule CodeMySpecWeb.RunLive do
  @moduledoc """
  One analyzer run, watched as it happens (story 1141): each test's result as
  it finishes, the file it is in now, and whether it finished or died. A
  credo run shows each finding as credo finds it (story 1144).

  Live results come from `Analysis.live_state/1`, updated on
  `"analysis_run:<id>"`; how the run ended comes from its ledger row, reread
  when `"analysis:<project>"` says its status changed.
  """
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Analysis
  alias CodeMySpec.Analysis.RunsRepository

  @impl true
  def mount(%{"run_id" => run_id}, _session, %{assigns: %{current_scope: scope}} = socket) do
    run_id = String.to_integer(run_id)

    if connected?(socket) do
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "analysis_run:#{run_id}")
      Phoenix.PubSub.subscribe(CodeMySpec.PubSub, "analysis:#{scope.active_project_id}")
    end

    case RunsRepository.get_run_in_project(scope, run_id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "No run #{run_id} in this project.")
         |> assign(run: nil, live: nil)}

      run ->
        {:ok, assign(socket, section: :problems, run: run, live: Analysis.live_state(run_id))}
    end
  end

  @impl true
  def handle_event("cancel", _params, %{assigns: %{run: run, current_scope: scope}} = socket) do
    _ = Analysis.cancel_run(scope, run.id)
    {:noreply, socket}
  end

  @impl true
  def handle_info({:run_live, run_id, live}, %{assigns: %{run: %{id: run_id}}} = socket),
    do: {:noreply, assign(socket, live: live)}

  def handle_info({:analysis, %{run_id: run_id}}, %{assigns: %{run: %{id: run_id}}} = socket) do
    run = RunsRepository.get_run_in_project(socket.assigns.current_scope, run_id)
    {:noreply, assign(socket, run: run, live: Analysis.live_state(run_id))}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl true
  def render(%{run: nil} = assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <p>No such run.</p>
    </Layouts.app>
    """
  end

  def render(assigns) do
    assigns =
      assign(assigns,
        status: status(assigns.run),
        tests: tests(assigns.live),
        findings: findings(assigns.live),
        failures: Enum.count(tests(assigns.live), &(&1.state == "failed"))
      )

    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div class="space-y-4">
        <div class="flex items-baseline gap-3">
          <h1 class="text-xl font-semibold">{@run.source} run {@run.id}</h1>
          <span id="run-status" class={["badge", status_class(@status)]}>{@status}</span>
          <button
            :if={@status == "running"}
            id="run-cancel"
            phx-click="cancel"
            class="btn btn-sm btn-ghost"
          >
            Cancel
          </button>
        </div>

        <p :if={(@status == "running" and @live) && @live.running_files != []} id="run-current-files">
          Now in <code :for={file <- @live.running_files} class="mr-2">{file}</code>
        </p>

        <p :if={@status == "finished"} id="run-totals">{totals(@run, @live, @tests, @failures)}</p>

        <ul :if={@findings != []} id="run-findings" class="space-y-1">
          <li :for={finding <- @findings} class="text-sm">
            <span class="badge badge-sm badge-warning">finding</span>
            {finding.message}
            <code class="ml-2">{finding.file}:{finding.line}</code>
          </li>
        </ul>

        <ul id="run-tests" class="space-y-1">
          <li :for={test <- @tests} class="text-sm">
            <span class={["badge badge-sm", test_class(test.state)]}>{test.state}</span>
            {test.name}
            <div :if={test.state == "failed"} class="ml-6 text-error">
              <div>{test.message}</div>
              <code>{test.file}:{test.failure_line || test.line}</code>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp status(%{status: :running}), do: "running"
  defp status(%{status: :completed}), do: "finished"
  defp status(%{status: :cancelled}), do: "cancelled"
  defp status(_run), do: "died"

  defp tests(nil), do: []
  defp tests(live), do: live.tests

  defp findings(nil), do: []
  defp findings(live), do: live.findings

  # A credo run counts what it checked and found (story 1144).
  defp totals(%{source: "credo"}, %{totals: %{"files" => files, "findings" => found}}, _, _),
    do: "#{plural(files, "file")}, #{plural(found, "finding")}"

  defp totals(%{source: "credo"}, live, _tests, _failures),
    do: plural(length(findings(live)), "finding")

  # A run that reported nothing live (a scoped run, or one from before story
  # 1141) still recorded its counts: it read "0 tests" after five passed.
  defp totals(%{stats: %{"tests" => count} = stats}, _live, [], _failures)
       when is_integer(count),
       do: "#{plural(count, "test")}, #{plural(stats["failures"] || 0, "failure")}"

  defp totals(_run, _live, tests, failures),
    do: "#{plural(length(tests), "test")}, #{plural(failures, "failure")}"

  defp status_class("running"), do: "badge-info"
  defp status_class("finished"), do: "badge-success"
  defp status_class("cancelled"), do: "badge-warning"
  defp status_class(_died), do: "badge-error"

  defp test_class("passed"), do: "badge-success"
  defp test_class("failed"), do: "badge-error"
  defp test_class(_state), do: "badge-ghost"

  defp plural(1, noun), do: "1 #{noun}"
  defp plural(n, noun), do: "#{n} #{noun}s"
end
