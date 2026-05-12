defmodule CodeMySpecLocalWeb.StoryLive.Form do
  use CodeMySpecLocalWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Projects
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story
  alias CodeMySpec.Users.Scope

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      projects={@projects}
      project={@project}
      section={:stories}
      page_title={@page_title}
    >
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @form} class="flex flex-col gap-6">
        <div data-test="story-form-header">
          <div class="cms-onboarding-eyebrow mb-2">
            {if @live_action == :new, do: "// new story", else: "// edit story"}
          </div>
          <h1 class="cms-onboarding-heading">{@page_title}</h1>
          <p :if={@live_action == :new} class="cms-onboarding-sub mt-2">
            Write the behaviour you want the harness to deliver. The agent
            turns this into a spec, scenarios, tests, and code in that order.
          </p>
          <p :if={@live_action == :edit} class="cms-onboarding-sub mt-2">
            Update the story. Existing scenarios and tests stay linked.
          </p>
        </div>

        <%!--
          Audit re-pass §2d: was an alert-info banner (blue chrome that
          fought the brand). Now a quieter mono eyebrow + line, matching the
          rest of the system. Re-themes the interview path as a peer, not
          a sidebar.
        --%>
        <div
          :if={@live_action == :new}
          data-test="interview-path-callout"
          class="flex flex-col gap-1 border-l-2 pl-4"
          style="border-color: var(--color-cms-amber, #ffb84a);"
        >
          <div class="cms-onboarding-eyebrow" style="color: var(--color-cms-amber, #ffb84a);">
            // or be interviewed
          </div>
          <p class="text-sm" style="color: var(--color-cms-text-dim);">
            Paste <code class="kbd kbd-sm">/codemyspec:product interview</code>
            into Claude Code — the agent will ask questions and draft the story for you.
          </p>
        </div>

        <.form for={@form} id="story-form" phx-change="validate" phx-submit="save" class="flex flex-col gap-4">
          <.input
            field={@form[:title]}
            type="text"
            label="Title"
            placeholder="As a <user> I want <behavior>"
          />
          <.input
            field={@form[:description]}
            type="textarea"
            label="Description"
            placeholder="Why this matters — what does it unlock for the user?"
          />
          <div class="fieldset mb-2">
            <span class="label mb-1">Acceptance Criteria</span>
            <div class="space-y-2">
              <.inputs_for :let={criterion_form} field={@form[:criteria]}>
                <div class="flex items-center gap-2">
                  <input type="hidden" name="story[criteria_sort][]" value={criterion_form.index} />
                  <input
                    type="text"
                    name={criterion_form[:description].name}
                    id={criterion_form[:description].id}
                    value={criterion_form[:description].value}
                    placeholder="Given <state>, when <action>, then <observable outcome>"
                    class="flex-1 input"
                  />
                  <label class="flex items-center gap-1 cursor-pointer">
                    <input type="hidden" name={criterion_form[:verified].name} value="false" />
                    <input
                      type="checkbox"
                      name={criterion_form[:verified].name}
                      value="true"
                      checked={
                        Phoenix.HTML.Form.normalize_value("checkbox", criterion_form[:verified].value)
                      }
                      class="checkbox checkbox-sm"
                    />
                    <.icon name="hero-lock-closed" class="size-4 text-base-content/60" />
                  </label>
                  <button
                    type="button"
                    name="story[criteria_drop][]"
                    value={criterion_form.index}
                    phx-click={JS.dispatch("change")}
                    class="btn btn-sm btn-error btn-outline"
                  >
                    <.icon name="hero-x-mark" class="size-4" />
                  </button>
                </div>
              </.inputs_for>
              <input type="hidden" name="story[criteria_drop][]" />
              <button
                type="button"
                name="story[criteria_sort][]"
                value="new"
                phx-click={JS.dispatch("change")}
                class="btn btn-sm btn-outline"
              >
                <.icon name="hero-plus" class="size-4" /> Add Criterion
              </button>
            </div>
          </div>
          <.input
            field={@form[:status]}
            type="select"
            label="Status"
            options={Ecto.Enum.values(CodeMySpec.Stories.Story, :status)}
          />
          <footer class="flex items-center gap-3">
            <.button phx-disable-with="Saving...">
              <span>▸</span> Save Story
            </.button>
            <.button navigate={return_path(@slug, @return_to, @story)} class="btn-ghost">
              Cancel
            </.button>
          </footer>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    projects = Projects.list_local_projects()

    {:ok,
     assign(socket,
       projects: projects,
       project: nil,
       scope: nil,
       slug: nil,
       story: nil,
       form: nil,
       error: nil,
       page_title: "Story",
       return_to: "index"
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    case load_project_and_scope(params["project_name"]) do
      {:ok, project, scope} ->
        socket =
          socket
          |> assign(
            project: project,
            scope: scope,
            slug: project_slug(project),
            return_to: return_to(params["return_to"]),
            error: nil
          )
          |> apply_action(socket.assigns.live_action, params, scope)

        {:noreply, socket}

      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}
    end
  end

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"id" => id}, scope) do
    story = Stories.get_story!(scope, id)

    socket
    |> assign(:page_title, "Edit Story")
    |> assign(:story, story)
    |> assign(:form, to_form(Stories.change_story(scope, story)))
  end

  defp apply_action(socket, :new, _params, scope) do
    # Pre-render one empty criterion so the BDD shape (`Given … when … then …`)
    # is visible as a placeholder, and set a sane default status so the user
    # doesn't have to make a meaningless "Choose a value" decision.
    story = %Story{
      account_id: scope.active_account_id,
      status: :in_progress,
      criteria: [%Criterion{description: "", verified: false}]
    }

    socket
    |> assign(:page_title, "New Story")
    |> assign(:story, story)
    |> assign(:form, to_form(Stories.change_story(scope, story)))
  end

  @impl true
  def handle_event("validate", %{"story" => story_params}, socket) do
    changeset =
      Stories.change_story(socket.assigns.scope, socket.assigns.story, story_params)

    {:noreply, assign(socket, form: to_form(changeset, action: :validate))}
  end

  def handle_event("save", %{"story" => story_params}, socket) do
    save_story(socket, socket.assigns.live_action, story_params)
  end

  defp save_story(socket, :edit, story_params) do
    case Stories.update_story(socket.assigns.scope, socket.assigns.story, story_params) do
      {:ok, story} ->
        {:noreply,
         socket
         |> put_flash(:info, "Story updated successfully")
         |> push_navigate(to: return_path(socket.assigns.slug, socket.assigns.return_to, story))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp save_story(socket, :new, story_params) do
    case Stories.create_story(socket.assigns.scope, story_params) do
      {:ok, story} ->
        {:noreply,
         socket
         |> put_flash(:info, "Story created successfully")
         |> push_navigate(to: return_path(socket.assigns.slug, socket.assigns.return_to, story))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(slug, "index", _story), do: ~p"/projects/#{slug}/stories"
  defp return_path(slug, "show", story), do: ~p"/projects/#{slug}/stories/#{story.id}"

  defp load_project_and_scope(name) do
    with {:ok, project} <- Projects.get_project_by_name(name),
         {:ok, scope} <- Scope.for_local_project(project) do
      {:ok, project, scope}
    end
  end

  defp project_slug(project) do
    (project.name || "project")
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/, "-")
    |> String.trim("-")
  end
end
