defmodule CodeMySpecLocalWeb.StoryLive.Form do
  use CodeMySpecLocalWeb, :live_view

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

      <div :if={!@error && @form}>
        <.header>
          {@page_title}
          <:subtitle>Use this form to manage story records in your local database.</:subtitle>
        </.header>

        <.form for={@form} id="story-form" phx-change="validate" phx-submit="save">
          <.input field={@form[:title]} type="text" label="Title" />
          <.input field={@form[:description]} type="textarea" label="Description" />
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
                    placeholder="Enter criterion..."
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
            prompt="Choose a value"
            options={Ecto.Enum.values(CodeMySpec.Stories.Story, :status)}
          />
          <footer>
            <.button phx-disable-with="Saving...">Save Story</.button>
            <.button navigate={return_path(@slug, @return_to, @story)}>Cancel</.button>
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
    story = %Story{account_id: scope.active_account_id, criteria: []}

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
