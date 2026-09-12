defmodule CodeMySpecWeb.StoryLive.Form do
  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria.Criterion
  alias CodeMySpec.Stories
  alias CodeMySpec.Stories.Story

  @impl true
  def render(assigns) do
    ~H"""
      <div :if={@error || @scope_error} role="alert" class="alert alert-error">
        <span>{@error || @scope_error}</span>
      </div>

      <div :if={!@error && @form} class="flex flex-col gap-6">
        <div data-test="story-form-header">
          <.section_eyebrow class="mb-2">
            {if @live_action == :new, do: "new story", else: "edit story"}
          </.section_eyebrow>
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
          <.section_eyebrow tone="warn">or be interviewed</.section_eyebrow>
          <p class="text-sm" style="color: var(--color-cms-text-dim);">
            Paste <code class="kbd kbd-sm">/codemyspec:product interview</code>
            into Claude Code — the agent will ask questions and draft the story for you.
          </p>
        </div>

        <.form
          for={@form}
          id="story-form"
          data-test="story-form"
          phx-change="validate"
          phx-submit="save"
          class="flex flex-col gap-4"
        >
          <.input
            field={@form[:title]}
            type="text"
            label="Title"
            placeholder="As a <user> I want <behavior>"
          />
          <.input
            field={@form[:story]}
            type="textarea"
            label="Story"
            placeholder="As a <role>, I want <goal>, so that <value>"
          />
          <.input
            field={@form[:notes]}
            type="textarea"
            label="Notes"
            placeholder="Mechanism, dependencies, caveats — anything that isn't the story itself"
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
          <footer class="flex items-center gap-3">
            <.button phx-disable-with="Saving...">
              <span>▸</span> Save Story
            </.button>
            <.button navigate={return_path(@socket, @slug, @return_to, @story)} class="btn-ghost">
              Cancel
            </.button>
          </footer>
        </.form>
      </div>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       section: :stories,
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
  def handle_params(params, _uri, %{assigns: %{scope: %{} = scope}} = socket) do
    {:noreply,
     socket
     |> assign(return_to: return_to(params["return_to"]))
     |> apply_action(socket.assigns.live_action, params, scope)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  defp return_to("show"), do: "show"
  defp return_to(_), do: "index"

  defp apply_action(socket, :edit, %{"number" => number}, scope) do
    story = Stories.get_story_by_number!(scope, number)

    socket
    |> assign(:page_title, "Edit Story")
    |> assign(:story, story)
    |> assign(:form, to_form(Stories.change_story(scope, story)))
  end

  defp apply_action(socket, :new, _params, scope) do
    # Pre-render one empty criterion so the BDD shape (`Given … when … then …`)
    # is visible as a placeholder.
    story = %Story{
      account_id: scope.active_account_id,
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
    save_story(socket, socket.assigns.live_action, drop_blank_criteria(story_params))
  end

  # The form always renders one empty criterion row, so saving a story with
  # just a title and a story sentence would fail on "description can't be
  # blank" for a row the user never asked for. Acceptance criteria come from
  # Three Amigos now — `create_story` doesn't even accept them — so an
  # untouched row means "no criterion", not an error.
  #
  # `criteria_sort` has to go with them: cast_assoc treats a sort entry with
  # no matching data as a request to add a fresh (empty) child.
  defp drop_blank_criteria(%{"criteria" => criteria} = params) when is_map(criteria) do
    kept =
      criteria
      |> Enum.reject(fn {_index, attrs} -> blank_description?(attrs) end)
      |> Map.new()

    if map_size(kept) == map_size(criteria) do
      params
    else
      params |> Map.put("criteria", kept) |> Map.delete("criteria_sort")
    end
  end

  defp drop_blank_criteria(params), do: params

  defp blank_description?(%{"description" => description}) when is_binary(description),
    do: String.trim(description) == ""

  defp blank_description?(_), do: true

  defp save_story(socket, :edit, story_params) do
    case Stories.update_story(socket.assigns.scope, socket.assigns.story, story_params) do
      {:ok, story} ->
        {:noreply,
         socket
         |> put_flash(:info, "Story updated successfully")
         |> push_navigate(to: return_path(socket, socket.assigns.slug, socket.assigns.return_to, story))}

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
         |> push_navigate(to: return_path(socket, socket.assigns.slug, socket.assigns.return_to, story))}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:noreply, assign(socket, form: to_form(changeset))}
    end
  end

  defp return_path(ctx, slug, "index", _story),
    do: path(ctx, ~p"/app/projects/#{slug}/stories")

  defp return_path(ctx, slug, "show", story),
    do: path(ctx, ~p"/app/projects/#{slug}/stories/#{story.number}")

end
