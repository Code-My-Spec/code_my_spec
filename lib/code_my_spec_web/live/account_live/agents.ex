defmodule CodeMySpecWeb.AccountLive.Agents do
  @moduledoc """
  Which provider and model each agent type runs on, for this account.

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

  alias CodeMySpec.Accounts
  alias CodeMySpec.Agents
  alias CodeMySpec.Agents.Defaults
  alias CodeMySpecWeb.AccountLive.Components.Navigation

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_scope={@current_scope}
      current_path={@current_path}
      pending_notifications={@pending_notifications}
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
            <h2 class="card-title">Agent models</h2>

            <p class="text-base-content/70">
              Each kind of agent runs on the provider and model you choose for it.
              A type you have not set runs on a sensible default for a provider
              you have connected.
            </p>

            <div :if={@connected == []} class="alert alert-warning mt-4">
              No provider is connected, so no agent can start.
              <.link navigate={~p"/app/accounts/#{@account.id}/manage"} class="link">
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
                      <option
                        :for={provider <- @providers}
                        value={provider}
                        selected={provider == row.provider}
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
                  {cost_hint(row.role)}
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
    scope = socket.assigns.current_scope

    case Accounts.get_account(scope, id) do
      nil ->
        {:ok, socket |> put_flash(:error, "Account not found") |> redirect(to: ~p"/app/accounts")}

      account ->
        {:ok, socket |> assign(:account, account) |> load()}
    end
  end

  @impl true
  def handle_event("save", params, socket) do
    scope = socket.assigns.current_scope

    # Every type in one submit: the page is a table of four decisions and
    # saving one at a time would make "QA cheap, coder not" two round trips to
    # express one thought.
    results =
      for role <- Agents.roles(),
          choice = params[to_string(role)],
          is_map(choice),
          provider = choice["provider"],
          provider not in [nil, ""] do
        Agents.put_model_setting(scope, role, provider, blank_to_nil(choice["model"]))
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

  # What a type's default would cost, said in words rather than in model ids.
  # Read off the preference list so it cannot disagree with what actually
  # launches.
  defp cost_hint(role) do
    case Defaults.for_role(role) do
      [] ->
        ""

      [{_provider, model} | _rest] ->
        "Defaults to #{model} — #{tier(role)}."
    end
  end

  defp tier(:qa), do: "the cheapest that can follow instructions, because it runs constantly"
  defp tier(_role), do: "a stronger model, because this one is reasoning rather than checking"

  defp blank_to_nil(""), do: nil
  defp blank_to_nil(value), do: value

  defp refusal(:unknown_provider),
    do: "That provider is not connected, so nothing was saved for it."

  defp refusal(_reason), do: "That could not be saved."
end
