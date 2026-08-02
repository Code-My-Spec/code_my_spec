defmodule CodeMySpecWeb.StoryLive.Gherkin do
  @moduledoc """
  Renders a story's Three Amigos artifacts as a `.feature`-formatted
  Gherkin document. The DB is the source of truth; this view assembles
  the deliverable on demand via `BddRules.GherkinRenderer`.

  Mounted at `/app/stories/:id/gherkin` and
  `/app/projects/:project_id/stories/:id/gherkin`. Live-updates
  when underlying records change so the spec reflects the wall in real
  time.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.BddRules.GherkinRenderer
  alias CodeMySpec.Questions
  alias CodeMySpec.Stories

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :stories,
       project: nil,
       scope: nil,
       slug: nil,
       story: nil,
       error: nil,
       page_title: "Gherkin",
       gherkin: "",
       subscribed?: false
     )}
  end

  @impl true
  def handle_params(%{"id" => id}, _uri, %{assigns: %{scope: %{} = scope}} = socket) do
    with {:ok, story_id} <- parse_id(id),
         %Stories.Story{} = story <- Stories.get_story(scope, story_id) do
      socket =
        socket
        |> maybe_subscribe(scope)
        |> assign_view(scope, story)

      {:noreply, socket}
    else
      :error -> {:noreply, assign(socket, error: "Invalid story id.", story: nil, gherkin: "")}
      nil -> {:noreply, assign(socket, error: "Story not found.", story: nil, gherkin: "")}
    end
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp maybe_subscribe(%{assigns: %{subscribed?: true}} = socket, _scope), do: socket

  defp maybe_subscribe(socket, scope) do
    if connected?(socket) do
      BddRules.subscribe(scope)
      Questions.subscribe(scope)
      AcceptanceCriteria.subscribe_criteria(scope)
      assign(socket, subscribed?: true)
    else
      socket
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

  defp refresh(%{assigns: %{scope: scope, story: story}} = socket) do
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
      <.header>
        Gherkin — {if @story, do: @story.title, else: "Story"}
        <:subtitle :if={@story && @project}>
          Rendered from
          <.link
            navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}/three-amigos")}
            class="link link-primary"
          >
            Three Amigos
          </.link>
          artifacts. The DB is the source of truth; this view assembles the
          <code>.feature</code> on demand.
        </:subtitle>
        <:actions>
          <.button
            :if={@story && @project}
            navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}")}
          >
            <.icon name="hero-arrow-left" /> Back to story
          </.button>
          <.button
            :if={@story && @project}
            navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{@story.id}/three-amigos")}
          >
            <.icon name="hero-squares-2x2" /> Three Amigos wall
          </.button>
        </:actions>
      </.header>

      <div :if={@error || @scope_error} role="alert" class="alert alert-error">
        <span>{@error || @scope_error}</span>
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
    """
  end
end
