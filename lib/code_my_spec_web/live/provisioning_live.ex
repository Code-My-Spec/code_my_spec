defmodule CodeMySpecWeb.ProvisioningLive do
  @moduledoc """
  The setup status page — the whole sequence, in order, with where it stands.

  ## The page shows the plan before it shows progress

  Every step Sam's options include is on screen from mount, `:not_started`,
  with the reason it exists. He sees the shape of the run before anything has
  happened (criterion 7959), rather than steps appearing one at a time as they
  execute, which would make the run unpredictable exactly when he most wants
  to know what it is about to do.

  A step his options exclude is absent, not present-and-greyed (criterion
  7968). Greying it out still reads as part of the run.

  ## State is asked for, not remembered

  Running a step verifies against the provider first — `Provisioning.run_step/3`
  does that, and this page does not second-guess it by filtering on the stored
  state. That is what makes a retry converge rather than duplicate, and a
  resource deleted behind setup's back get rebuilt.

  ## Paused and errored render differently on purpose

  A paused step shows what Sam must do elsewhere; an errored one shows what
  the provider actually said, so the escalation an agent picks up carries the
  detail that names the fix rather than "the step failed".
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Provisioning
  alias CodeMySpec.Provisioning.Sequence

  @impl true
  def render(assigns) do
    ~H"""
    <.header>
      Setup
      <:subtitle>
        Everything your project needs, in the order it needs it.
      </:subtitle>
      <:actions>
        <.button data-test="start-setup" phx-click="start_setup">Run setup</.button>
        <.button :if={@halted_at} data-test="resume-setup" phx-click="resume_setup">
          Resume
        </.button>
      </:actions>
    </.header>

    <form data-test="setup-options-form" phx-change="toggle_options" class="my-6">
      <div class="flex flex-wrap gap-4">
        <label :for={option <- @available_options} class="label cursor-pointer gap-2">
          <input
            type="checkbox"
            class="checkbox"
            name={"options[#{option}]"}
            value="true"
            checked={option in @options}
          />
          <span class="label-text">{option}</span>
        </label>
      </div>
    </form>

    <ol class="steps steps-vertical w-full">
      <li
        :for={step <- @plan}
        data-test="setup-step"
        data-step={step.key}
        data-state={step.state}
        data-position={step.position}
        class="step"
      >
        <div class="card bg-base-100 w-full text-left">
          <div class="card-body">
            <div class="flex items-center justify-between gap-4">
              <div>
                <h3 class="card-title">{step.label}</h3>
                <p class="text-sm opacity-70">{step.why}</p>
              </div>

              <div class="flex items-center gap-2">
                <span class="badge">{step.state}</span>
                <.button
                  data-test="run-step"
                  phx-click="run_step"
                  phx-value-key={step.key}
                >
                  Run
                </.button>
                <.button
                  :if={step.state == :errored}
                  data-test="retry-step"
                  phx-click="run_step"
                  phx-value-key={step.key}
                >
                  Retry
                </.button>
              </div>
            </div>

            <p
              :if={step.state == :paused && step.paused_instructions}
              data-test="paused-instructions"
              data-step={step.key}
              class="alert alert-warning mt-3"
            >
              {step.paused_instructions}
            </p>

            <div
              :if={step.state == :errored}
              data-test="escalation"
              data-step={step.key}
              class="alert alert-error mt-3 flex-col items-start"
            >
              <p>{step.attempted}</p>
              <p class="font-mono text-xs">{step.provider_error}</p>
            </div>

            <div :if={step.resources != []} class="mt-3 flex flex-col gap-1">
              <span
                :for={resource <- step.resources}
                data-test="provisioned-resource"
                data-kind={resource.kind}
                data-location={resource.location}
                data-owner="user"
                class="badge badge-outline"
              >
                {resource.kind} — {resource.location}
              </span>
            </div>
          </div>
        </div>
      </li>
    </ol>

    <section data-test="setup-record" class="mt-8">
      <h2 class="text-lg font-semibold">What you now own</h2>
      <p :if={@resources == []} class="opacity-70">Nothing provisioned yet.</p>
      <ul class="mt-2 flex flex-col gap-1">
        <li
          :for={resource <- @resources}
          data-test="provisioned-resource"
          data-kind={resource.kind}
          data-location={resource.location}
          data-owner="user"
        >
          {resource.kind} — {resource.location}
        </li>
      </ul>
    </section>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, load(socket, default_options())}
  end

  @impl true
  def handle_event("toggle_options", params, socket) do
    options =
      params
      |> Map.get("options", %{})
      |> Enum.filter(fn {_key, value} -> value == "true" end)
      |> Enum.map(fn {key, _} -> String.to_existing_atom(key) end)

    {:noreply, load(socket, options)}
  end

  def handle_event("start_setup", _params, socket) do
    result = Provisioning.run(socket.assigns.current_scope, socket.assigns.options)

    {:noreply, apply_result(socket, result)}
  end

  def handle_event("resume_setup", _params, socket) do
    result = Provisioning.resume(socket.assigns.current_scope, socket.assigns.options)

    {:noreply, apply_result(socket, result)}
  end

  # Retry is the same call as run — a step verifies before it acts, so
  # retrying one step is running it, and a separate "retry" path would be a
  # second implementation of the same thing that could drift.
  def handle_event("run_step", %{"key" => key}, socket) do
    scope = socket.assigns.current_scope

    case Provisioning.run_step(scope, String.to_existing_atom(key)) do
      {:ok, _step} -> {:noreply, load(socket, socket.assigns.options)}
      {:halt, _step, reason} -> {:noreply, socket |> load(socket.assigns.options) |> assign(halted_at: key, halt_reason: reason)}
    end
  end

  defp apply_result(socket, %{halted_at: halted_at, reason: reason}) do
    socket
    |> load(socket.assigns.options)
    |> assign(halted_at: halted_at, halt_reason: reason)
  end

  defp load(socket, options) do
    plan = Provisioning.plan(socket.assigns.current_scope, options)

    socket
    |> assign(:options, options)
    |> assign(:available_options, available_options())
    |> assign(:plan, plan)
    |> assign(:resources, Enum.flat_map(plan, & &1.resources))
    |> assign_new(:halted_at, fn -> nil end)
    |> assign_new(:halt_reason, fn -> nil end)
  end

  # Every option any step declares, in sequence order and without duplicates,
  # so the toggles are derived from the sequence rather than a second list
  # that could fall out of step with it.
  defp available_options do
    Sequence.all()
    |> Enum.map(& &1.option)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  # Everything on. Setup's job is a working project; a user who wants less
  # turns it off, rather than having to discover what to turn on.
  defp default_options, do: available_options()
end
