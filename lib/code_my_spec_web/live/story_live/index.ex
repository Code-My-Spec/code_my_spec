defmodule CodeMySpecWeb.StoryLive.Index do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Markdown
  alias CodeMySpec.WorkingCopies

  @impl true
  def render(assigns) do
    ~H"""
      <div :if={@project} role="tablist" class="tabs tabs-bordered mb-6">
        <.link
          navigate={path(@socket, ~p"/app/projects/#{@slug}/stories")}
          role="tab"
          class={["tab", "tab-active"]}
        >
          Stories
        </.link>
        <.link
          navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/scheduler")}
          role="tab"
          class="tab"
        >
          Scheduler
        </.link>
      </div>

      <.header>
        Stories
        <:actions>
          <div :if={@project} class="flex items-center gap-3">
            <label class="flex items-center gap-2 cursor-pointer">
              <span class="text-sm text-base-content/70">Criteria</span>
              <input
                type="checkbox"
                class="toggle toggle-sm toggle-primary"
                checked={@show_criteria}
                phx-click="toggle_criteria"
              />
            </label>
            <div class="divider divider-horizontal mx-0"></div>
            <button phx-click="export_markdown" class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-down-tray" /> Export
            </button>
            <.button navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/import")} class="btn btn-sm btn-outline">
              <.icon name="hero-arrow-up-tray" /> Import
            </.button>
            <.button navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/new")} class="btn btn-sm">
              <.icon name="hero-plus" /> New Story
            </.button>
          </div>
        </:actions>
      </.header>

      <div :if={@error || @scope_error} role="alert" class="alert alert-error">
        <span>{@error || @scope_error}</span>
      </div>

      <div :if={!@error && @project} id="stories" phx-update="stream" class="space-y-8">
        <div :for={{id, story} <- @streams.stories} id={id} class="card bg-base-100 shadow-md">
          <div class="card-body">
            <div class="flex items-start justify-between mb-4">
              <h2
                class="card-title text-2xl cursor-pointer hover:text-primary flex-1"
                phx-click={
                  JS.navigate(path(@socket, ~p"/app/projects/#{@slug}/stories/#{story.number}"))
                }
              >
                {story.title}
              </h2>
              <div class="flex items-center gap-2">
                <span
                  :if={story.ready_for_dev == true}
                  data-test="story-ready"
                  class="badge badge-success"
                >
                  Ready for development
                </span>
                <span
                  :if={story.ready_for_dev != true}
                  data-test="story-not-ready"
                  class="badge badge-ghost"
                >
                  Parked
                </span>
                <%!-- Assigned means one checkout is offered this story and no
                other is. Unassigned is not "nobody's" — it is the shared
                backlog every copy sees, which is why it reads as a state rather
                than as a gap to fill. --%>
                <span
                  :if={story.working_copy_id}
                  data-test="story-assigned"
                  data-working-copy-id={story.working_copy_id}
                  class="badge badge-info badge-outline"
                  title="Only this checkout is offered this story"
                >
                  {Map.get(@copy_labels, story.working_copy_id, "a checkout")}
                </span>
                <span
                  :if={is_nil(story.working_copy_id)}
                  data-test="story-unassigned"
                  class="badge badge-ghost"
                  title="In the shared backlog — every working copy is offered this"
                >
                  Unassigned
                </span>
                <button
                  type="button"
                  phx-click="toggle_story_ready"
                  phx-value-id={story.id}
                  data-test="toggle-story-ready"
                  class="btn btn-ghost btn-xs"
                >
                  {if story.ready_for_dev == true, do: "Park", else: "Release"}
                </button>
                <%!-- Named after enforcement, not spec colour. `specs_ready` carries one
                fact — whether spex failures block the agent on this story — and
                the manual toggle is exactly where that comes apart from "the
                specs pass". Parking a shipped story clears the latch without
                touching a spec file, and the badge then asserted the specs were
                failing, which is the opposite of the situation criterion 8169
                exists to support. The button beside it already said
                "Unenforce"/"Enforce"; now they agree. --%>
                <span
                  :if={story.specs_ready == true}
                  data-test="story-specs-ready"
                  class="badge badge-info"
                >
                  Enforced
                </span>
                <span
                  :if={story.specs_ready != true}
                  data-test="story-specs-not-ready"
                  class="badge badge-ghost"
                >
                  Not enforced
                </span>
                <button
                  type="button"
                  phx-click="toggle_story_specs_ready"
                  phx-value-id={story.id}
                  data-test="toggle-story-specs-ready"
                  class="btn btn-ghost btn-xs"
                  title="Spex failures only block the agent on stories whose specs have gone green"
                >
                  {if story.specs_ready == true, do: "Unenforce", else: "Enforce"}
                </button>
                <div
                  :if={is_nil(story.component_id)}
                  class="alert alert-warning py-1 px-3 flex items-center gap-2"
                >
                  <.icon name="hero-exclamation-triangle" class="h-4 w-4" />
                  <span class="text-sm">No Component</span>
                </div>
              </div>
            </div>

            <p class="text-base-content/80 mb-4 leading-relaxed">
              {story.story || story.description}
            </p>

            <p :if={story.notes not in [nil, ""]} class="text-sm text-base-content/60 mb-4 italic">
              Notes: {story.notes}
            </p>

            <div :if={@show_criteria} class="mb-4">
              <h3 class="font-semibold mb-2">Acceptance Criteria:</h3>
              <ul class="list-disc list-inside space-y-1 text-base-content/80">
                <li :for={criterion <- story.criteria} class="flex items-center gap-2">
                  <.icon
                    :if={criterion.verified}
                    name="hero-lock-closed"
                    class="size-3 text-success inline"
                  />
                  <span class={[criterion.verified && "font-medium"]}>{criterion.description}</span>
                </li>
              </ul>
              <div
                :if={
                  Enum.empty?(story.criteria) &&
                    !Enum.empty?(parse_acceptance_criteria(story.acceptance_criteria))
                }
                class="text-xs text-base-content/50 mt-1"
              >
                (legacy criteria: {length(parse_acceptance_criteria(story.acceptance_criteria))})
              </div>
            </div>

            <div :if={story.component_id} class="mb-4">
              <div class="text-sm text-base-content/60">
                <span class="font-semibold">Component:</span>
                <span class="font-mono text-xs">{String.slice(story.component_id, 0, 8)}...</span>
              </div>
            </div>

            <div :if={story.tags != []} class="mb-4 flex flex-wrap gap-1">
              <span :for={tag <- story.tags} class="badge badge-sm badge-outline">
                {tag.name}
              </span>
            </div>

            <div class="flex items-center justify-between">
              <div class="card-actions">
                <.link
                  navigate={
                    path(@socket, ~p"/app/projects/#{@slug}/stories/#{story.number}/three-amigos")
                  }
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-squares-2x2" class="size-4" /> Three Amigos
                </.link>
                <.link
                  navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{story.number}/gherkin")}
                  class="btn btn-sm btn-outline"
                >
                  <.icon name="hero-document-text" class="size-4" /> Gherkin
                </.link>
                <.link
                  navigate={path(@socket, ~p"/app/projects/#{@slug}/stories/#{story.number}/edit")}
                  class="btn btn-sm btn-outline"
                >
                  Edit
                </.link>
                <button
                  type="button"
                  phx-click={show_confirm("confirm-delete-story-#{story.id}")}
                  class="btn btn-sm btn-error btn-outline"
                >
                  Delete
                </button>
                <.confirm_dialog
                  id={"confirm-delete-story-#{story.id}"}
                  title={"Delete story \"#{story.title}\"?"}
                  message="This removes the story and its rules/scenarios; linked issues are preserved with story_id cleared."
                  confirm_label="Delete"
                  on_confirm={JS.push("delete", value: %{id: story.id}) |> hide("##{id}")}
                />
              </div>
            </div>
          </div>
        </div>
      </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       section: :stories,
       project: nil,
       scope: nil,
       slug: nil,
       error: nil,
       show_criteria: true,
       page_title: "Stories",
       subscribed?: false
     )
     |> stream(:stories, [])}
  end

  @impl true
  def handle_params(_params, _uri, %{assigns: %{scope: %{} = scope}} = socket) do
    {:noreply,
     socket
     |> maybe_subscribe(scope)
     |> assign(:copy_labels, copy_labels(scope))
     |> stream(:stories, Stories.list_project_stories_by_priority(scope), reset: true)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  # Which checkout each working copy is, keyed by id.
  #
  # Story 895 put `working_copy_id` on stories and nothing showed it, so the one
  # question the axis exists to answer — what is assigned and what is not —
  # could only be asked in psql. John: "I don't see on either the epics or the
  # stories UI, the assignments to agents."
  #
  # Named via `WorkingCopies.display_name/1`, which already owns this rule.
  #
  # A copy that has not named itself carries the generated label "the harness at
  # <root> on <host>" — a sentence with a full path in it, which is what this
  # badge printed at first: 90 characters where two checkouts differ in one
  # directory. John: "It's referencing the harness at full path on machine name,
  # which is super ugly." `display_name/1` cuts that to the root's last segment
  # and returns a label a person actually chose whole, and the harness picker
  # and the working-copies pages have been calling it all along. This was a
  # fourth copy of the rule, and the only one that got it wrong.
  defp copy_labels(scope) do
    scope
    |> WorkingCopies.list_harnesses()
    |> Map.new(&{&1.id, WorkingCopies.display_name(&1)})
  end

  defp maybe_subscribe(%{assigns: %{subscribed?: true}} = socket, _scope), do: socket

  defp maybe_subscribe(socket, scope) do
    if connected?(socket) do
      Stories.subscribe_stories(scope)
      assign(socket, subscribed?: true)
    else
      socket
    end
  end

  @impl true
  def handle_event("toggle_criteria", _params, socket) do
    new_show = !socket.assigns.show_criteria

    {:noreply,
     socket
     |> assign(:show_criteria, new_show)
     |> stream(
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.scope),
       reset: true
     )}
  end

  @impl true
  def handle_event("delete", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    story = Stories.get_story!(scope, id)
    {:ok, _} = Stories.delete_story(scope, story)

    {:noreply, stream_delete(socket, :stories, story)}
  end

  @impl true
  def handle_event("toggle_story_ready", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    story = Stories.get_story!(scope, id)

    case Stories.update_story(scope, story, %{ready_for_dev: !(story.ready_for_dev == true)}) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :stories, updated)}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, "Could not change readiness: #{inspect(reason)}")}
    end
  end

  # The manual override on the specs-ready latch. Clearing it parks a
  # shipped story mid-refactor without touching its specs; setting it puts
  # a story under enforcement the gate itself would have refused.
  @impl true
  def handle_event("toggle_story_specs_ready", %{"id" => id}, socket) do
    scope = socket.assigns.scope
    story = Stories.get_story!(scope, id)

    case Stories.set_specs_ready(scope, story, !(story.specs_ready == true)) do
      {:ok, updated} ->
        {:noreply, stream_insert(socket, :stories, updated)}

      {:error, reason} ->
        {:noreply,
         put_flash(socket, :error, "Could not change spec enforcement: #{inspect(reason)}")}
    end
  end

  @impl true
  def handle_event("export_markdown", _params, socket) do
    scope = socket.assigns.scope
    {:ok, stories} = Stories.list_project_stories(scope)
    project_name = scope.active_project.name

    story_attrs =
      stories
      |> Enum.sort_by(& &1.title)
      |> Enum.map(&story_to_attrs/1)

    markdown_content = Markdown.format_stories(story_attrs, project_name)
    filename = "#{String.downcase(String.replace(project_name, " ", "_"))}_stories.md"

    {:noreply,
     push_event(socket, "download_file", %{
       content: markdown_content,
       filename: filename,
       content_type: "text/markdown"
     })}
  end

  @impl true
  def handle_info({type, %CodeMySpec.Stories.Story{}}, socket)
      when type in [:created, :updated, :deleted] do
    {:noreply,
     stream(
       socket,
       :stories,
       Stories.list_project_stories_by_priority(socket.assigns.scope),
       reset: true
     )}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp parse_acceptance_criteria(nil), do: []
  defp parse_acceptance_criteria(""), do: []
  defp parse_acceptance_criteria(criteria) when is_list(criteria), do: criteria

  defp parse_acceptance_criteria(criteria) when is_binary(criteria) do
    criteria
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp story_to_attrs(story) do
    criteria_list =
      if Enum.empty?(story.criteria) do
        parse_acceptance_criteria(story.acceptance_criteria)
      else
        Enum.map(story.criteria, & &1.description)
      end

    %{
      title: story.title,
      description: story.description,
      acceptance_criteria: criteria_list
    }
  end
end
