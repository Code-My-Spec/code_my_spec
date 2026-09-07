defmodule CodeMySpecWeb.ResourceLive.Index do
  @moduledoc """
  Everything the account owns at every provider, at `/app/resources`.

  ## Two readers, one page

  For someone who does not know what a DNS record is, forty rows is not an
  answer to "are we okay" — it is a research task. So the arithmetic is done
  for them: one count, above everything, saying whether today is a bad day.

  The counterpart matters as much. Exactly one thing is red when exactly one
  thing is wrong. A page that colours half the list amber to look thorough
  teaches the reader that red means nothing, and then it has cost them the one
  signal it existed to give.

  ## Read off the mount

  Four providers is a couple of seconds of network. The summary and checklist
  come from our own records and render immediately; the provider half arrives
  when it arrives.

  ## Read-only

  Acting on any of this — building what is missing, trimming what dangles,
  marking what is deliberate — is story 999.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Resources

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(:page_title, "Resources")
     |> assign(:report, :loading)
     |> assign(:fixing, nil)
     |> load_report()}
  end

  defp load_report(socket) do
    if connected?(socket) do
      scope = socket.assigns.current_scope
      start_async(socket, :report, fn -> Resources.report(scope) end)
    else
      socket
    end
  end

  @impl true
  def handle_async(:report, {:ok, report}, socket) do
    {:noreply, assign(socket, :report, report)}
  end

  def handle_async(:report, {:exit, reason}, socket) do
    {:noreply, assign(socket, :report, {:crashed, reason})}
  end

  @impl true
  def handle_event("keep", %{"kind" => kind, "location" => location}, socket) do
    Resources.keep(socket.assigns.current_scope, kind, location)

    {:noreply, reload(socket)}
  end

  def handle_event("release", %{"kind" => kind, "location" => location}, socket) do
    Resources.release(socket.assigns.current_scope, kind, location)

    {:noreply, reload(socket)}
  end

  def handle_event("trim", _params, socket) do
    %{ok: removed, error: failed} = Resources.trim(socket.assigns.current_scope)

    {:noreply,
     socket
     |> put_flash(:info, trimmed_message(removed, failed))
     |> reload()}
  end

  # Synchronous, and slow, and that is the honest shape: a provisioning run
  # can take minutes and the page has nothing useful to say until it lands.
  # Marked with `fix-running` so the button cannot be pressed twice.
  def handle_event("run-setup", %{"project-id" => project_id}, socket) do
    socket = assign(socket, :fixing, project_id)
    Resources.fix(socket.assigns.current_scope, project_id)

    {:noreply, socket |> assign(:fixing, nil) |> reload()}
  end

  def handle_event("fix-all", _params, socket) do
    socket = assign(socket, :fixing, :all)
    Resources.fix_all(socket.assigns.current_scope)

    {:noreply, socket |> assign(:fixing, nil) |> reload()}
  end

  # Re-reads every provider. Acting on a resource changes what is out there,
  # so anything less would leave the page describing the world as it was
  # before the button was pressed.
  defp reload(socket) do
    scope = socket.assigns.current_scope

    assign(socket, :report, Resources.report(scope))
  end

  defp trimmed_message(removed, []), do: "Removed #{length(removed)} resource(s)."

  defp trimmed_message(removed, failed),
    do:
      "Removed #{length(removed)}; #{length(failed)} could not be removed: " <>
        Enum.map_join(failed, ", ", fn {resource, _reason} -> resource.location end)

  defp describe(:unauthorized), do: "The provider refused the credential."
  defp describe(:timeout), do: "The provider did not answer in time."
  defp describe(:hetzner_not_configured), do: "No API token is connected for this provider."
  defp describe(reason) when is_binary(reason), do: reason
  defp describe(reason), do: "Could not ask this provider: #{inspect(reason)}"

  defp owner_label(:account), do: "Account"
  defp owner_label(:domain), do: "Domains"
  defp owner_label(:server), do: "Servers"
  defp owner_label(:project), do: "Projects"

  defp owners(resources), do: resources |> Enum.map(& &1.owner) |> Enum.uniq()

  defp for_owner(resources, owner), do: Enum.filter(resources, &(&1.owner == owner))

  defp dangling(resources), do: Enum.filter(resources, &(&1.status == :dangling))

  # One button per project, not per missing step.
  defp missing_projects(checklist) do
    checklist
    |> Enum.filter(&(&1.state == :missing))
    |> Enum.map(&%{id: &1.project_id, name: &1.project_name})
    |> Enum.uniq_by(& &1.id)
  end

  defp missing(checklist), do: Enum.filter(checklist, &(&1.state == :missing))

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div class="mx-auto max-w-5xl">
        <h1 class="text-2xl font-semibold mb-1">Resources</h1>
        <p class="text-base-content/70 mb-6">
          Everything your account owns at every provider, checked against what it should have.
        </p>

        <p :if={@report == :loading} data-test="report-pending" class="text-sm opacity-70">
          Asking every provider…
        </p>

        <div :if={is_map(@report)}>
          <%!--
            Above everything, and readable without knowing what any of the rows
            below are. The number is the point: one is a bad afternoon and
            twenty is a bad week, and they call for different reactions.
          --%>
          <div
            data-test="health-summary"
            data-status={@report.status}
            data-problems={@report.problems}
            class={[
              "card mb-8",
              @report.status == :healthy && "bg-success/10 border border-success",
              @report.status == :unhealthy && "bg-error/10 border border-error"
            ]}
          >
            <div class="card-body py-4">
              <p :if={@report.status == :healthy} class="text-lg font-semibold">
                Everything is where it should be.
              </p>
              <p :if={@report.status == :unhealthy} class="text-lg font-semibold">
                {@report.problems} {if @report.problems == 1, do: "thing needs", else: "things need"} attention
              </p>
              <p :if={@report.errors != %{}} class="text-sm opacity-80">
                {map_size(@report.errors)} provider(s) could not be asked, so this is not the whole picture.
              </p>
            </div>
          </div>

          <div
            :for={{provider, reason} <- @report.errors}
            data-test="provider-error"
            data-provider={provider}
            role="alert"
            class="alert alert-warning alert-soft mb-3"
          >
            <span><strong>{provider}</strong> — {describe(reason)}</span>
          </div>

          <section :if={missing(@report.checklist) != []} class="mb-10">
            <div class="flex items-center gap-3 mb-1">
              <h2 class="text-lg font-semibold">Missing</h2>
              <button
                :if={@fixing == nil}
                type="button"
                data-test="fix-all"
                phx-click="fix-all"
                class="btn btn-primary btn-sm"
              >
                Build everything missing
              </button>
              <span :if={@fixing} data-test="fix-running" class="loading loading-spinner loading-sm">
              </span>
            </div>
            <p class="text-base-content/70 text-sm mb-3">
              Things a project meant to be deployed should have and does not. Building runs that
              project's setup from where it stopped — steps depend on the ones before them, and
              running the sequence is what respects that.
            </p>

            <div :for={project <- missing_projects(@report.checklist)} class="mb-1">
              <button
                type="button"
                data-test="run-setup"
                phx-click="run-setup"
                phx-value-project-id={project.id}
                class="btn btn-outline btn-xs"
              >
                Run setup for {project.name}
              </button>
            </div>

            <%!--
              A summary of items the canonical checklist below already carries,
              so this one deliberately does not answer to `checklist-item` —
              two elements per key would make "is backups missing" ambiguous
              for anything reading the page.
            --%>
            <div
              :for={item <- missing(@report.checklist)}
              data-test="missing-item"
              data-key={item.key}
              data-project-id={item.project_id}
              class="card bg-base-200 mb-2"
            >
              <div class="card-body py-2 flex-row items-center gap-3">
                <span class="inline-block size-2.5 rounded-full bg-error shrink-0"></span>
                <span class="font-mono">{item.key}</span>
                <span class="badge badge-ghost badge-sm">{item.project_name}</span>
                <span :if={item.detail} class="text-xs opacity-70">{item.detail}</span>
              </div>
            </div>
          </section>

          <%!--
            Every checklist entry, present ones included, so the page can be
            read as "what should exist" rather than only as a list of
            complaints. Hidden by default because the complaints are the point.
          --%>
          <details :if={@report.checklist != []} class="mb-10">
            <summary class="cursor-pointer text-sm opacity-70">
              Show the whole checklist ({length(@report.checklist)} entries)
            </summary>
            <div class="mt-3 flex flex-wrap gap-2">
              <span
                :for={item <- @report.checklist}
                data-test="checklist-item"
                data-key={item.key}
                data-environment={item.environment}
                data-project-id={item.project_id}
                data-state={item.state}
                class="badge badge-outline gap-1"
              >
                <span class={[
                  "inline-block size-2 rounded-full",
                  item.state == :present && "bg-success",
                  item.state == :missing && "bg-error"
                ]}>
                </span>
                {item.project_name} · {item.key}
              </span>
            </div>
          </details>

          <section :for={owner <- owners(@report.resources)} class="mb-8">
            <h2 class="text-lg font-semibold mb-3">{owner_label(owner)}</h2>

            <div
              :for={resource <- for_owner(@report.resources, owner)}
              data-test="resource"
              data-kind={resource.kind}
              data-location={resource.location}
              data-owner={resource.owner}
              data-status={resource.status}
              data-origin={resource.origin}
              class={["card bg-base-200 mb-2", resource.status == :dangling && "border border-error"]}
            >
              <div class="card-body py-2 flex-row items-center gap-3">
                <span class={[
                  "inline-block size-2.5 rounded-full shrink-0",
                  resource.status == :dangling && "bg-error",
                  resource.status == :present && "bg-success"
                ]}>
                </span>
                <span class="badge badge-ghost badge-sm">{resource.kind}</span>
                <span class="font-mono text-sm">{resource.location}</span>
                <span :if={resource.identifier} class="text-xs opacity-70">
                  {resource.identifier}
                </span>
                <span :if={resource.status == :dangling} class="badge badge-error badge-sm ml-auto">
                  points at nothing
                </span>
                <span :if={resource.status == :kept} class="badge badge-ghost badge-sm ml-auto">
                  kept on purpose
                </span>

                <button
                  :if={resource.status == :dangling}
                  type="button"
                  data-test="keep"
                  phx-click="keep"
                  phx-value-kind={resource.kind}
                  phx-value-location={resource.location}
                  class="btn btn-ghost btn-xs"
                >
                  Keep
                </button>

                <button
                  :if={resource.status == :kept}
                  type="button"
                  data-test="release"
                  phx-click="release"
                  phx-value-kind={resource.kind}
                  phx-value-location={resource.location}
                  class="btn btn-ghost btn-xs"
                >
                  Stop keeping
                </button>
              </div>
            </div>
          </section>

          <%!--
            The candidates are listed by name before anything is pressed. Trim
            deletes at the provider and a DNS record does not come back, so
            "which things exactly" is not a detail to discover afterwards.
          --%>
          <section :if={dangling(@report.resources) != []} class="mb-8 border-t pt-6">
            <h2 class="text-lg font-semibold mb-1">Trim</h2>
            <p class="text-base-content/70 text-sm mb-3">
              These were made by setup and nothing points at them anymore. Removing them cannot be
              undone — mark anything you are keeping first.
            </p>

            <ul class="text-sm mb-3">
              <li
                :for={resource <- dangling(@report.resources)}
                data-test="trim-candidate"
                data-kind={resource.kind}
                data-location={resource.location}
                class="font-mono"
              >
                {resource.kind} {resource.location}
              </li>
            </ul>

            <button
              type="button"
              data-test="trim"
              phx-click={show_confirm("confirm-trim")}
              class="btn btn-error btn-sm"
            >
              Remove {length(dangling(@report.resources))} resource(s)
            </button>

            <.confirm_dialog
              id="confirm-trim"
              title="Remove these at the provider?"
              message="This cannot be undone. Anything you marked as kept is not included."
              confirm_label="Remove them"
              on_confirm={JS.push("trim")}
            />
          </section>

          <p
            :if={@report.resources == [] and @report.errors == %{}}
            data-test="no-resources"
            class="text-base-content/60"
          >
            Your providers report nothing in this account yet.
          </p>
        </div>

        <div :if={match?({:crashed, _}, @report)} role="alert" class="alert alert-error alert-soft">
          <span>Reading your providers failed. Reload to try again.</span>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
