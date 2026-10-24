defmodule CodeMySpecWeb.AgentModelsLive do
  @moduledoc """
  Which provider and model each agent type runs on, for you — per user, in
  every account, because the provider credentials it names are
  (`Agents.ModelSetting`). In the main nav, beside User settings.

  Story 983. Four types, four choices, and a launcher that knows nothing about
  any of them — a QA agent runs on something cheap because this page says so.

  ## An unset type shows what it would do

  Not an empty field. "Unset" and "unset, and here is what that means" are
  different things to read, and only the second is true: `Agents.Defaults`
  answers for a type nobody has chosen for, so the row shows the answer and
  says it is a default. An empty select would suggest the account has to fill
  four of them in before anything runs, which is exactly what the defaults
  exist to avoid.

  ## Unconnected providers are shown and disabled

  Rather than hidden. A provider that is simply absent is indistinguishable
  from one that does not exist, so somebody goes looking for a feature that is
  sitting there waiting to be connected. Disabled with the reason is the only
  version that tells them which it is.

  Choosing one is refused server-side too — `Agents.put_model_setting/4` checks
  against `connected_providers/1` — because a disabled option is a statement
  about a page rather than about the account.

  ## Cost is on the option

  The whole reason to have this page is to run QA on something cheap, and
  nobody can make that call from `glm-5.3` against `claude-sonnet-5`. A list of
  model names has not offered the decision it exists to offer.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Agents

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      project={assigns[:project]}
      projects={assigns[:projects] || []}
    >
      <div>
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Agent models</h2>

            <p class="text-base-content/70">
              Each kind of agent runs on the provider and model you choose for it.
              A type you have not set runs on a sensible default for a provider
              you have connected.
            </p>

            <p class="text-sm text-base-content/60">
              These are yours, not the account's — they run on the providers you
              connected, so everyone here picks their own.
            </p>

            <div :if={@connected == []} class="alert alert-warning mt-4">
              No provider is connected, so no agent can start.
              <.link navigate={~p"/app/users/settings"} class="link">
                Connect one
              </.link>
            </div>

            <.live_component
              module={CodeMySpecWeb.AgentModelsLive.Form}
              id="agent-models"
              current_scope={@current_scope}
            />
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok, socket |> assign(:page_title, "Agent models") |> load()}
  end

  @impl true
  def handle_info(:agent_models_saved, socket) do
    {:noreply, socket |> put_flash(:info, "Saved") |> load()}
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:connected, Agents.connected_providers(scope))
  end
end
