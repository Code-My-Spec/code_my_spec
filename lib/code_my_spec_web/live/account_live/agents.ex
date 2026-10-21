defmodule CodeMySpecWeb.AccountLive.Agents do
  @moduledoc """
  Where the account says which provider and model each agent type runs on.

  Story 1039. Account-scoped in where it lives — beside `AccountLive.Members`
  and `AccountLive.Invitations`, under the account's own settings, because
  agents belong to the account rather than to any one project — not in the
  underlying data: the setting itself is still the one `CodeMySpec.Agents`
  already resolves against the current scope (`CodeMySpec.Agents.ModelSetting`
  is deliberately user-scoped, story 984, since the provider it names is only
  reachable through whoever holds the credential). This page is the same
  settings form as `CodeMySpecWeb.AgentModelsLive`, reached from the account's
  own navigation instead of the main nav.

  ## An unset type shows what it would do

  Not an empty field. `Agents.resolve_model/2` answers for a type nobody has
  chosen for, so the row shows that answer and says it is a default — "unset"
  and "unset, and here is what that means" are different things to read.

  ## Unconnected providers are shown and disabled

  Rather than hidden, with the reason named. A provider that is simply absent
  is indistinguishable from one that does not exist; `Agents.put_model_setting/4`
  refuses an unconnected provider server-side too, so a disabled option here
  is a statement about the account, not just about this page.

  ## Cost is on the option

  The point of this screen is picking a cheap model for QA, which nobody can
  do from a model name alone — each row says what tier it is.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Accounts
  alias CodeMySpec.Agents
  alias CodeMySpecWeb.AccountLive.Components.Navigation

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
      <.live_component
        module={Navigation}
        id="navigation"
        account={@account}
        current_scope={@current_scope}
        active_tab={:agents}
      />

      <div class="mt-6">
        <div class="card bg-base-100 border border-base-300">
          <div class="card-body">
            <h2 class="card-title">Agents</h2>

            <p class="text-base-content/70">
              Each kind of agent runs on the provider and model you choose for it.
              A type you have not set runs on a sensible default for a provider
              you have connected.
            </p>

            <div :if={@connected == []} class="alert alert-warning mt-4" data-test="no-provider">
              No provider is connected, so no agent can start.
              <.link navigate={~p"/app/users/settings"} class="link">
                Connect one
              </.link>
            </div>

            <form phx-submit="save" data-test="agent-models-form" class="mt-4 space-y-6">
              <div
                :for={row <- @settings}
                data-test={"agent-type-#{row.role}"}
                class="border-b border-base-300 pb-4"
              >
                <div class="flex items-center gap-2">
                  <span class="font-semibold">{row.role}</span>
                  <span :if={row.source == :default} class="badge badge-ghost badge-sm">
                    default
                  </span>
                </div>

                <div class="grid gap-2 sm:grid-cols-2 mt-2">
                  <label class="form-control">
                    <span class="label-text">Provider</span>
                    <select name={"#{row.role}[provider]"} class="select w-full text-base-content">
                      <%!-- The way to leave a type alone, and the way back to leaving it
                            alone: without this the select renders the resolved default as
                            its own value, so an untouched row posts that value and Save
                            pins it as a deliberate choice (issue c6f5acce). --%>
                      <option value="" selected={row.source == :default} data-test="use-default">
                        Use the default{if row.provider, do: " (#{row.provider})"}
                      </option>
                      <option
                        :for={provider <- @providers}
                        value={provider}
                        selected={row.source != :default and provider == row.provider}
                        disabled={provider not in @connected}
                        data-test={"provider-#{provider}"}
                      >
                        {provider}{if provider not in @connected, do: " — connect it first"}
                      </option>
                    </select>
                  </label>

                  <label class="form-control">
                    <span class="label-text">Model</span>
                    <input
                      type="text"
                      name={"#{row.role}[model]"}
                      value={row.model}
                      class="w-full input text-base-content"
                    />
                  </label>
                </div>

                <p class="text-sm text-base-content/70 mt-2" data-test="model-cost">
                  {cost_hint(row)}
                </p>
              </div>

              <button type="submit" class="btn btn-primary">Save</button>
            </form>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_scope = socket.assigns.current_scope

    case Accounts.get_account(current_scope, id) do
      nil ->
        {:ok,
         socket
         |> put_flash(:error, "Account not found")
         |> redirect(to: ~p"/app/accounts")}

      account ->
        {:ok,
         socket
         |> assign(:page_title, "Agents")
         |> assign(:account, account)
         |> load()}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    scope = socket.assigns.current_scope

    # Every type in one submit: the page is a table of four decisions and
    # saving one at a time would make "QA cheap, coder not" two round trips
    # to express one thought.
    # A blank provider is "use the default", a real instruction rather than a
    # missing field, and the way back once a type was pinned — skipping blanks
    # instead would make a row one-way and make Save mean "pin everything".
    results =
      for role <- Agents.roles(),
          choice = params[to_string(role)],
          is_map(choice) do
        case choice["provider"] do
          blank when blank in [nil, ""] ->
            Agents.clear_model_setting(scope, role)

          provider ->
            Agents.put_model_setting(scope, role, provider, blank_to_nil(choice["model"]))
        end
      end

    case Enum.find(results, &match?({:error, _}, &1)) do
      nil -> {:noreply, socket |> put_flash(:info, "Saved") |> load()}
      {:error, reason} -> {:noreply, socket |> put_flash(:error, refusal(reason)) |> load()}
    end
  end

  defp load(socket) do
    scope = socket.assigns.current_scope

    socket
    |> assign(:settings, Agents.model_settings(scope))
    |> assign(:connected, Agents.connected_providers(scope))
    |> assign(:providers, Agents.provider_names())
  end

  # The model this account would actually get, not the top of the preference
  # list — see AgentModelsLive's own note on this (issue from story 983: the
  # first version named a provider the page itself marked "connect it first").
  defp cost_hint(%{provider: nil}), do: "Nothing to run on until a provider is connected."

  defp cost_hint(%{role: role, model: model, source: :default}),
    do: "Defaults to #{model} — #{tier(role)}."

  defp cost_hint(%{role: role, model: model}), do: "Set to #{model} — #{tier(role)}."

  defp tier(:qa), do: "the cheapest that can follow instructions, because it runs constantly"
  defp tier(_role), do: "a stronger model, because this one is reasoning rather than checking"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp refusal(:unknown_provider),
    do: "That provider is not connected, so nothing was saved for it."

  defp refusal(_reason), do: "That could not be saved."
end
