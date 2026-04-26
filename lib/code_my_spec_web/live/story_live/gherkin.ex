defmodule CodeMySpecWeb.StoryLive.Gherkin do
  @moduledoc """
  Renders a story's Three Amigos artifacts as a `.feature`-formatted
  Gherkin document. The DB is the source of truth; this view assembles
  the deliverable on demand via `BddRules.GherkinRenderer`.

  Mounted at `/app/stories/:id/gherkin`. Live-updates when underlying
  records change so the spec reflects the wall in real time.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.GherkinRenderer
  alias CodeMySpec.Questions
  alias CodeMySpec.Stories

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    scope = socket.assigns.current_scope

    if connected?(socket) do
      BddRules.subscribe(scope)
      Questions.subscribe(scope)
      AcceptanceCriteria.subscribe_criteria(scope)
    end

    case parse_id(id) do
      {:ok, story_id} ->
        case Stories.get_story(scope, story_id) do
          nil ->
            {:ok, assign(socket, story: nil, error: "Story not found.", gherkin: "")}

          story ->
            {:ok, assign_view(socket, scope, story)}
        end

      :error ->
        {:ok, assign(socket, story: nil, error: "Invalid story id.", gherkin: "")}
    end
  end

  @impl true
  def handle_info({:bdd_rule_created, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:bdd_rule_updated, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:bdd_rule_deleted, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_created, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_updated, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_deleted, _}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:created, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:updated, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:deleted, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(%{assigns: %{story: nil}} = socket), do: socket

  defp refresh(%{assigns: %{current_scope: scope, story: story}} = socket) do
    assign_view(socket, scope, story)
  end

  defp assign_view(socket, scope, story) do
    gherkin = GherkinRenderer.render(scope, story)

    assign(socket,
      story: story,
      error: nil,
      gherkin: gherkin,
      page_title: "#{story.title} — Gherkin"
    )
  end

  defp parse_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {id, ""} -> {:ok, id}
      _ -> :error
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <.header>
        Gherkin — {if @story, do: @story.title, else: "Story"}
        <:subtitle :if={@story}>
          Rendered from <.link navigate={~p"/app/stories/#{@story}/three-amigos"} class="link link-primary">Three Amigos</.link>
          artifacts. The DB is the source of truth; this view assembles the
          <code>.feature</code> on demand.
        </:subtitle>
        <:actions>
          <.button :if={@story} navigate={~p"/app/stories/#{@story}"}>
            <.icon name="hero-arrow-left" /> Back to story
          </.button>
          <.button :if={@story} navigate={~p"/app/stories/#{@story}/three-amigos"}>
            <.icon name="hero-squares-2x2" /> Three Amigos wall
          </.button>
        </:actions>
      </.header>

      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @story}>
        <div class="mockup-code w-full mb-4">
          <pre><code id="gherkin-source" class="whitespace-pre">{@gherkin}</code></pre>
        </div>

        <p class="text-sm text-base-content/60">
          Updated live as the agent and PM mutate the wall. Copy the block above
          into a <code>.feature</code> file or feed it to SexySpex generation
          downstream.
        </p>
      </div>
    </Layouts.app>
    """
  end
end
