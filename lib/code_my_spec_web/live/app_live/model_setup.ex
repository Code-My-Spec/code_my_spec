defmodule CodeMySpecWeb.AppLive.ModelSetup do
  @moduledoc "The model-selection pane at the application's front door."
  use CodeMySpecWeb, :html

  attr :current_scope, :any, required: true
  attr :installations, :map, required: true
  attr :checking?, :boolean, required: true
  attr :error, :string, default: nil
  attr :selected_provider, :string, default: nil

  def wizard(assigns) do
    agents = [
      %{
        key: "codex",
        name: "Codex",
        provider: "openai-codex",
        install_url: "https://developers.openai.com/codex/cli"
      },
      %{
        key: "claude",
        name: "Claude Code",
        provider: "claude-code",
        install_url: "https://code.claude.com/docs/en/setup#install-claude-code"
      }
    ]

    selected = Enum.find(agents, &(&1.provider == assigns.selected_provider))
    ready? = selected && get_in(assigns.installations, [selected.key, :installed?])
    assigns = assign(assigns, agents: agents, selected: selected, ready?: ready?)

    ~H"""
    <section
      data-test="model-onboarding"
      data-state="active"
      class="card bg-base-100 border-2 border-primary p-6 space-y-6"
    >
      <div>
        <span class="badge badge-primary badge-outline">Step 1 · Agent models</span>
        <h1 class="text-2xl font-bold mt-3">Choose your agent</h1>
        <p class="text-base-content/70 mt-2">
          Pick the agent you want to use, then choose its default models.
          Your agents use the CLI login on this machine.
        </p>
      </div>
      <p :if={@error} role="alert" class="alert alert-error">{@error}</p>
      <div class="grid gap-4 sm:grid-cols-2">
        <div
          :for={agent <- @agents}
          data-test={"agent-installation-#{agent.key}"}
          class="card bg-base-100 border border-base-300"
        >
          <div class="card-body">
            <h2 class="card-title">{agent.name}</h2>
            <p role="status">
              <%= cond do %>
                <% @checking? -> %>
                  Checking installation…
                <% get_in(@installations, [agent.key, :installed?]) -> %>
                  Installed
                <% Map.has_key?(@installations, agent.key) -> %>
                  Not installed or unavailable
                <% true -> %>
                  Installation not checked
              <% end %>
            </p>
            <.link
              :if={get_in(@installations, [agent.key, :installed?]) != true}
              href={agent.install_url}
              target="_blank"
              rel="noopener noreferrer"
              class="link"
            >
              Install {agent.name}
            </.link>
            <p class="text-sm text-base-content/60">
              Open {agent.name} once to sign in before starting your first conversation.
            </p>
            <.link
              :if={get_in(@installations, [agent.key, :installed?]) == true}
              patch={~p"/app?provider=#{agent.provider}"}
              class="btn btn-primary"
            >
              Use {agent.name}
            </.link>
            <button
              :if={get_in(@installations, [agent.key, :installed?]) != true}
              type="button"
              class="btn btn-primary"
              disabled
            >Use {agent.name}</button>
          </div>
        </div>
      </div>
      <button type="button" phx-click="check_agents" disabled={@checking?} class="btn btn-ghost">
        Check again
      </button>
      <div :if={@ready?} class="card bg-base-100 border border-base-300" data-test="onboarding-models">
        <div class="card-body">
          <h2 class="card-title">Your {@selected.name} models</h2>
          <p class="text-base-content/70">
            Start with these defaults or adjust them. You can change them later in Agent models.
          </p>
          <.live_component
            module={CodeMySpecWeb.AgentModelsLive.Form}
            id={"onboarding-models-#{@selected_provider}"}
            current_scope={@current_scope}
            preset_provider={@selected_provider}
            save_label="Save and continue"
          />
        </div>
      </div>
    </section>
    """
  end
end
