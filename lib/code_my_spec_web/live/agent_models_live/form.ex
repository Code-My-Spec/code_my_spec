defmodule CodeMySpecWeb.AgentModelsLive.Form do
  @moduledoc """
  Shared user model settings form.

  Required assigns: `id` (string), `current_scope` (Scope).
  Optional: `preset_provider` (string), `save_label` (string).
  Sends `:agent_models_saved` to its parent after a successful save.
  """
  use CodeMySpecWeb, :live_component
  alias CodeMySpec.Agents

  @impl true
  def update(assigns, socket) do
    socket = socket |> assign(assigns) |> assign_new(:save_label, fn -> "Save" end)
    key = {assigns.current_scope.user.id, assigns[:preset_provider]}

    if socket.assigns[:loaded_key] == key do
      {:ok, socket}
    else
      {:ok, socket |> assign(:loaded_key, key) |> load_settings(assigns)}
    end
  end

  defp load_settings(socket, assigns) do
    settings = Agents.model_settings(assigns.current_scope)

    settings =
      case assigns[:preset_provider] do
        nil ->
          settings

        provider ->
          Enum.map(settings, fn row ->
            %{
              row
              | provider: provider,
                model: Agents.default_model(row.role, provider),
                source: :set
            }
          end)
      end

    assign(socket,
      settings: settings,
      providers: Agents.provider_names(),
      connected: Agents.connected_providers(assigns.current_scope),
      served: served(assigns.current_scope),
      preset_provider: assigns[:preset_provider],
      error: nil
    )
  end

  # Per provider, what its login reports serving, or `:unknown`.
  defp served(scope), do: Map.new(Agents.provider_names(), &{&1, Agents.served_models(scope, &1)})

  @impl true
  def render(assigns) do
    ~H"""
    <div>
      <p :if={@error} role="alert" class="alert alert-error">{@error}</p>
      <div :if={@preset_provider && @preset_provider not in @connected} class="alert alert-warning">
        Connect this provider before saving its models.
        <.link navigate={~p"/app/users/settings"} class="link">Connect provider in User settings</.link>
      </div>
      <form
        id={"#{@id}-form"}
        phx-change="change"
        phx-submit="save"
        phx-target={@myself}
        data-test="agent-models-form"
        class="mt-3 space-y-3"
      >
        <div
          :for={row <- @settings}
          data-test={"agent-type-#{row.role}"}
          class="space-y-1"
        >
          <div class="flex items-center gap-2">
            <span class="font-semibold">{row.role}</span>
            <span :if={row.source == :default} class="badge badge-ghost badge-sm">
              default
            </span>
          </div>

          <div class="grid gap-2 sm:grid-cols-2">
            <label class="form-control">
              <span class="label-text">Provider</span>
              <select name={"#{row.role}[provider]"} class="select select-sm w-full text-base-content">
                <%!-- The way to leave a type alone, and the way back to
                            leaving it alone. Without this the select renders the
                            resolved default as its value, so an untouched row
                            posts that value and Save writes it down as a
                            deliberate choice — issue c6f5acce, where one click
                            froze all four types at that day's defaults. --%>
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
              <%= case @served[row.provider] do %>
                <% {:ok, models} -> %>
                  <select
                    name={"#{row.role}[model]"}
                    class="select select-sm w-full text-base-content"
                    data-test={"served-models-#{row.role}"}
                  >
                    <option value="" selected={is_nil(row.model)}>The login's default</option>
                    <option :for={model <- models} value={model} selected={model == row.model}>
                      {model}
                    </option>
                  </select>
                <% _unknown -> %>
                  <input
                    type="text"
                    name={"#{row.role}[model]"}
                    value={row.model}
                    placeholder={if is_nil(row.provider), do: "Nothing to run on"}
                    class="w-full input input-sm text-base-content"
                  />
                  <span :if={row.provider} class="label-text-alt" data-test={"unverified-#{row.role}"}>
                    Unverified: {row.provider} has not reported which models it serves.
                  </span>
              <% end %>
            </label>
          </div>
        </div>

        <button
          type="submit"
          class="btn btn-primary"
          disabled={@preset_provider && @preset_provider not in @connected}
        >
          {@save_label}
        </button>
      </form>
    </div>
    """
  end

  @impl true
  def handle_event("change", params, socket) do
    settings =
      Enum.map(socket.assigns.settings, fn row ->
        case params[to_string(row.role)] do
          %{"provider" => provider, "model" => model} when provider != "" ->
            changed? = row.source != :set or provider != row.provider

            %{
              row
              | provider: provider,
                model: if(changed?, do: Agents.default_model(row.role, provider), else: model),
                source: :set
            }

          %{"provider" => ""} ->
            case Agents.Defaults.resolve(row.role, socket.assigns.connected) do
              {:ok, {provider, model}} ->
                %{row | provider: provider, model: model, source: :default}

              _ ->
                %{row | provider: nil, model: nil, source: :default}
            end

          _ ->
            row
        end
      end)

    {:noreply, assign(socket, settings: settings, error: nil)}
  end

  @impl true
  def handle_event("save", params, socket) do
    case Agents.save_model_settings(socket.assigns.current_scope, params) do
      {:ok, _} ->
        send(self(), :agent_models_saved)

        {:noreply,
         assign(socket, settings: Agents.model_settings(socket.assigns.current_scope), error: nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error, refusal(reason))}
    end
  end

  defp refusal(:unknown_provider),
    do: "That provider is not connected, so nothing was saved for it."

  defp refusal({:model_not_served, models}),
    do:
      "That model is not served by its provider, so nothing was saved. It serves: " <>
        Enum.join(models, ", ") <> "."

  defp refusal(_reason), do: "That could not be saved."
end
