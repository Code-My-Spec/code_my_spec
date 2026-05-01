defmodule CodeMySpecWeb.StoryLive.ThreeAmigos do
  @moduledoc """
  Three Amigos cluster wall — V4 design (server tier).

  Mounted at `/app/stories/:id/three-amigos` for authenticated PMs in
  the SaaS UI. The agent (running in Claude Code on a developer's
  machine) calls MCP tools that hit the server API via the
  `BddRules.RemoteClient` / `Questions.RemoteClient` write-through path
  — those mutations broadcast on server PubSub, so this LiveView sees
  cards land in real time as the session unfolds.

  Three states: `:listening` (no artifacts), `:active` (populated), and
  `:sealed` (readiness gate cleared).
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpec.AcceptanceCriteria
  alias CodeMySpec.BddRules
  alias CodeMySpec.Personas
  alias CodeMySpec.Questions
  alias CodeMySpec.Requirements.BddRulesChecker
  alias CodeMySpec.Stories

  @impl true
  def mount(_params, _session, socket) do
    # Subscribe in mount on the websocket-connect cycle. mount runs twice
    # for stateful LiveViews (HTTP render with connected? = false, then
    # WebSocket connect with connected? = true). Subscribing here, on the
    # second call, binds the LiveView's pid to the PubSub topics BEFORE
    # any handle_params side effects — which means broadcasts triggered by
    # MCP / RemoteClient writes that happen between mount and the user's
    # next interaction land in this pid's mailbox.
    if connected?(socket) do
      scope = socket.assigns.current_scope
      BddRules.subscribe(scope)
      Questions.subscribe(scope)
      AcceptanceCriteria.subscribe_criteria(scope)
    end

    {:ok,
     assign(socket,
       story: nil,
       error: nil,
       menu_open: nil,
       editing: nil,
       confirming_delete: nil
     )}
  end

  @impl true
  def handle_params(%{"id" => story_id}, _uri, socket) do
    scope = socket.assigns.current_scope

    with {:ok, story_id_int} <- parse_story_id(story_id),
         {:story, %Stories.Story{} = story} <-
           {:story, Stories.get_story(scope, story_id_int)} do
      {:noreply, assign_session_state(socket, scope, story)}
    else
      {:error, msg} ->
        {:noreply, assign(socket, error: "#{msg}")}

      {:story, nil} ->
        {:noreply, assign(socket, error: "Story not found in this account.")}
    end
  end

  @impl true
  def handle_info({:bdd_rule_created, _rule}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:bdd_rule_updated, _rule}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:bdd_rule_deleted, _rule}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_created, _q}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_updated, _q}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:question_deleted, _q}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:created, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:updated, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info({:deleted, %AcceptanceCriteria.Criterion{}}, socket), do: {:noreply, refresh(socket)}
  def handle_info(_msg, socket), do: {:noreply, socket}

  # ─── PM admin events ─────────────────────────────────────────────────

  @impl true
  def handle_event("open_menu", %{"type" => type, "id" => id}, socket) do
    {:noreply, assign(socket, menu_open: %{type: String.to_existing_atom(type), id: id})}
  end

  def handle_event("close_menu", _params, socket) do
    {:noreply, assign(socket, menu_open: nil)}
  end

  def handle_event("start_edit", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       editing: %{type: String.to_existing_atom(type), id: id},
       menu_open: nil
     )}
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, editing: nil)}
  end

  # Two-step delete: first click sets `confirming_delete` and renders a
  # modal; the modal's Confirm button fires the actual `delete_*` event.
  # Replaces the prior `data-confirm` attribute, which the headless QA
  # agent could not click through.
  def handle_event("confirm_delete", %{"type" => type, "id" => id}, socket) do
    {:noreply,
     assign(socket,
       confirming_delete: %{type: String.to_existing_atom(type), id: id},
       menu_open: nil
     )}
  end

  def handle_event("cancel_confirm_delete", _params, socket) do
    {:noreply, assign(socket, confirming_delete: nil)}
  end

  def handle_event("save_rule", %{"id" => id, "rule" => %{"statement" => statement}}, socket) do
    rule = BddRules.get_rule(socket.assigns.current_scope, id)

    if rule do
      case BddRules.update_rule(socket.assigns.current_scope, rule, %{statement: statement}) do
        {:ok, _updated} ->
          {:noreply, socket |> assign(editing: nil) |> put_flash(:info, "Rule updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not update rule")}
      end
    else
      {:noreply, put_flash(socket, :error, "Rule not found")}
    end
  end

  def handle_event("delete_rule", %{"id" => id}, socket) do
    rule = BddRules.get_rule(socket.assigns.current_scope, id)

    if rule do
      case BddRules.delete_rule(socket.assigns.current_scope, rule) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> assign(menu_open: nil, confirming_delete: nil)
           |> put_flash(:info, "Rule deleted")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(confirming_delete: nil)
           |> put_flash(:error, "Could not delete rule")}
      end
    else
      {:noreply, put_flash(socket, :error, "Rule not found")}
    end
  end

  def handle_event(
        "save_scenario",
        %{"id" => id, "scenario" => %{"description" => description, "body" => body}},
        socket
      ) do
    criterion = AcceptanceCriteria.get_criterion(socket.assigns.current_scope, id)

    if criterion do
      case AcceptanceCriteria.update_criterion(socket.assigns.current_scope, criterion, %{
             description: description,
             body: body
           }) do
        {:ok, _updated} ->
          {:noreply, socket |> assign(editing: nil) |> put_flash(:info, "Scenario updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not update scenario")}
      end
    else
      {:noreply, put_flash(socket, :error, "Scenario not found")}
    end
  end

  def handle_event("delete_scenario", %{"id" => id}, socket) do
    criterion = AcceptanceCriteria.get_criterion(socket.assigns.current_scope, id)

    if criterion do
      case AcceptanceCriteria.delete_criterion(socket.assigns.current_scope, criterion) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> assign(menu_open: nil, confirming_delete: nil)
           |> put_flash(:info, "Scenario deleted")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(confirming_delete: nil)
           |> put_flash(:error, "Could not delete scenario")}
      end
    else
      {:noreply, put_flash(socket, :error, "Scenario not found")}
    end
  end

  def handle_event("save_question", %{"id" => id, "question" => %{"text" => text}}, socket) do
    question = Questions.get_question(socket.assigns.current_scope, id)

    if question do
      case Questions.update_question(socket.assigns.current_scope, question, %{text: text}) do
        {:ok, _updated} ->
          {:noreply, socket |> assign(editing: nil) |> put_flash(:info, "Question updated")}

        {:error, _changeset} ->
          {:noreply, put_flash(socket, :error, "Could not update question")}
      end
    else
      {:noreply, put_flash(socket, :error, "Question not found")}
    end
  end

  def handle_event("delete_question", %{"id" => id}, socket) do
    question = Questions.get_question(socket.assigns.current_scope, id)

    if question do
      case Questions.delete_question(socket.assigns.current_scope, question) do
        {:ok, _deleted} ->
          {:noreply,
           socket
           |> assign(menu_open: nil, confirming_delete: nil)
           |> put_flash(:info, "Question deleted")}

        {:error, _reason} ->
          {:noreply,
           socket
           |> assign(confirming_delete: nil)
           |> put_flash(:error, "Could not delete question")}
      end
    else
      {:noreply, put_flash(socket, :error, "Question not found")}
    end
  end

  def handle_event("toggle_question_status", %{"id" => id}, socket) do
    question = Questions.get_question(socket.assigns.current_scope, id)

    if question do
      result =
        case question.status do
          :open -> Questions.resolve_question(socket.assigns.current_scope, question)
          _ -> Questions.reopen_question(socket.assigns.current_scope, question)
        end

      case result do
        {:ok, _updated} ->
          {:noreply, assign(socket, menu_open: nil)}

        {:error, _reason} ->
          {:noreply, put_flash(socket, :error, "Could not toggle question status")}
      end
    else
      {:noreply, put_flash(socket, :error, "Question not found")}
    end
  end

  defp refresh(%{assigns: %{current_scope: scope, story: story}} = socket) do
    assign_session_state(socket, scope, story)
  end

  defp refresh(socket), do: socket

  defp assign_session_state(socket, scope, story) do
    rules = BddRules.list_rules_for_story(scope, story.id)

    scenarios =
      AcceptanceCriteria.list_story_criteria(scope, story.id)
      |> Enum.filter(&(not is_nil(&1.kind)))

    questions = Questions.list_questions_for_story(scope, story.id)
    personas = Personas.list_personas_for_story(scope, story.id)

    {checker_satisfied?, _} = BddRulesChecker.complete?(scope, story)

    session_state =
      cond do
        checker_satisfied? -> :sealed
        rules == [] and scenarios == [] and questions == [] -> :listening
        true -> :active
      end

    open_question_count = Enum.count(questions, &(&1.status == :open))

    assign(socket,
      story: story,
      rules: rules,
      scenarios: scenarios,
      questions: questions,
      personas: personas,
      session_state: session_state,
      open_question_count: open_question_count,
      page_title: "#{story.title} — Three Amigos",
      error: nil
    )
  end

  defp parse_story_id(s) when is_binary(s) do
    case Integer.parse(s) do
      {id, ""} -> {:ok, id}
      _ -> {:error, "Story id must be an integer"}
    end
  end

  # ─── Layout helpers ──────────────────────────────────────────────────

  defp scenarios_for_rule(scenarios, rule_id) do
    Enum.filter(scenarios, &(&1.rule_id == rule_id))
  end

  # ─── Render ──────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope}>
      <div :if={@error} role="alert" class="alert alert-error">
        <span>{@error}</span>
      </div>

      <div :if={!@error && @story} class={"wv4-root #{if @session_state == :sealed, do: "sealed", else: ""}"}>
        <.wall_styles />
        <.wall_header
          story={@story}
          rules={@rules}
          scenarios={@scenarios}
          open_question_count={@open_question_count}
          session_state={@session_state}
        />

        <div class="wv4-body">
          <div class={"wv4-wall #{if @session_state == :listening, do: "empty", else: ""}"}>
            <div :if={@session_state == :sealed} class="wv4-sealed-stamp">
              Three Amigos sealed
            </div>

            <div class="wv4-canvas">
              <div :for={{rule, idx} <- Enum.with_index(@rules)} class="wv4-rule-column">
                <.rule_card
                  rule={rule}
                  index={idx}
                  menu_open={@menu_open}
                  editing={@editing}
                />
                <.scenario_card
                  :for={scenario <- scenarios_for_rule(@scenarios, rule.id)}
                  scenario={scenario}
                  menu_open={@menu_open}
                  editing={@editing}
                />
              </div>
            </div>

            <div :if={@session_state == :listening} class="wv4-listening">
              <div class="wv4-listening-text">Agent is listening.</div>
              <div class="wv4-listening-sub">Cards land here as the session unfolds.</div>
            </div>
          </div>

          <.questions_rail
            questions={@questions}
            open_count={@open_question_count}
            menu_open={@menu_open}
            editing={@editing}
          />
        </div>

        <.activity_ribbon
          story={@story}
          rules={@rules}
          scenarios={@scenarios}
          questions={@questions}
          session_state={@session_state}
        />

        <.delete_confirm_modal :if={@confirming_delete} confirming_delete={@confirming_delete} />
      </div>
    </Layouts.app>
    """
  end

  attr :confirming_delete, :map, required: true

  defp delete_confirm_modal(assigns) do
    {label, event} =
      case assigns.confirming_delete.type do
        :rule -> {"rule", "delete_rule"}
        :scenario -> {"scenario", "delete_scenario"}
        :question -> {"question", "delete_question"}
      end

    assigns = assign(assigns, label: label, event: event)

    ~H"""
    <div class="wv4-modal-backdrop" phx-click="cancel_confirm_delete">
      <div class="wv4-modal" phx-click-away="cancel_confirm_delete">
        <div class="wv4-modal-title">Delete this {@label}?</div>
        <div class="wv4-modal-body">
          This action cannot be undone. The {@label} will be removed from the wall and the database.
        </div>
        <div class="wv4-modal-actions">
          <button type="button" class="wv4-btn" phx-click="cancel_confirm_delete">Cancel</button>
          <button
            type="button"
            class="wv4-btn wv4-btn-danger"
            phx-click={@event}
            phx-value-id={@confirming_delete.id}
            data-test="confirm-delete"
          >
            Delete {@label}
          </button>
        </div>
      </div>
    </div>
    """
  end

  # ─── Component partials ───────────────────────────────────────────

  attr :story, :map, required: true
  attr :rules, :list, required: true
  attr :scenarios, :list, required: true
  attr :open_question_count, :integer, required: true
  attr :session_state, :atom, required: true

  defp wall_header(assigns) do
    ~H"""
    <div class="wv4-header">
      <div>
        <div class="wv4-feature-id">STORY-{@story.id}</div>
        <div class="wv4-feature-title">{@story.title}</div>
        <div class="wv4-feature-sub">
          {String.slice(@story.description || "", 0, 140)}
        </div>
      </div>
      <div style="flex: 1;" />
      <div class="wv4-counts">
        <span><strong>{length(@rules)}</strong>rules</span>
        <span><strong>{length(@scenarios)}</strong>scenarios</span>
        <span style={if @open_question_count > 0, do: "color: var(--wall-sand);", else: ""}>
          <strong style={if @open_question_count > 0, do: "color: var(--wall-sand);", else: ""}>
            {@open_question_count}
          </strong>
          open
        </span>
      </div>
      <div class="wv4-session-state">
        <span :if={@session_state != :sealed} class="wv4-pulse" />
        {state_label(@session_state)}
      </div>
    </div>
    """
  end

  attr :rule, :map, required: true
  attr :index, :integer, required: true
  attr :menu_open, :map, default: nil
  attr :editing, :map, default: nil

  defp rule_card(assigns) do
    is_editing? = match?(%{type: :rule, id: id} when id == assigns.rule.id, assigns.editing)
    is_menu? = match?(%{type: :rule, id: id} when id == assigns.rule.id, assigns.menu_open)
    assigns = assign(assigns, is_editing?: is_editing?, is_menu?: is_menu?)

    ~H"""
    <div class="wv4-card wv4-rule">
      <button
        type="button"
        class="wv4-card-menu"
        phx-click={if @is_menu?, do: "close_menu", else: "open_menu"}
        phx-value-type="rule"
        phx-value-id={@rule.id}
        title="Admin"
      >⋯</button>

      <div :if={@is_menu? && !@is_editing?} class="wv4-menu">
        <button type="button" class="wv4-menu-item" phx-click="start_edit" phx-value-type="rule" phx-value-id={@rule.id}>Edit</button>
        <button type="button" class="wv4-menu-item wv4-menu-danger" phx-click="confirm_delete" phx-value-type="rule" phx-value-id={@rule.id}>Delete</button>
      </div>

      <%= if @is_editing? do %>
        <form phx-submit="save_rule" phx-value-id={@rule.id}>
          <div class="wv4-rule-id">RULE · #{@index + 1} · EDITING</div>
          <textarea
            name="rule[statement]"
            class="wv4-edit-textarea"
            rows="3"
            autofocus
          >{@rule.statement}</textarea>
          <div class="wv4-edit-actions">
            <button type="button" class="wv4-btn wv4-btn-ghost" phx-click="cancel_edit">Cancel</button>
            <button type="submit" class="wv4-btn wv4-btn-primary">Save</button>
          </div>
        </form>
      <% else %>
        <div class="wv4-rule-id">RULE · #{@index + 1}</div>
        <div class="wv4-rule-title">{@rule.statement}</div>
      <% end %>
    </div>
    """
  end

  attr :scenario, :map, required: true
  attr :menu_open, :map, default: nil
  attr :editing, :map, default: nil

  defp scenario_card(assigns) do
    sid = to_string(assigns.scenario.id)

    is_editing? = match?(%{type: :scenario, id: id} when id == sid, assigns.editing)
    is_menu? = match?(%{type: :scenario, id: id} when id == sid, assigns.menu_open)

    assigns = assign(assigns, is_editing?: is_editing?, is_menu?: is_menu?, sid: sid)

    ~H"""
    <div class={"wv4-card wv4-example wv4-example-#{@scenario.kind}"}>
      <button
        type="button"
        class="wv4-card-menu"
        phx-click={if @is_menu?, do: "close_menu", else: "open_menu"}
        phx-value-type="scenario"
        phx-value-id={@sid}
        title="Admin"
      >⋯</button>

      <div :if={@is_menu? && !@is_editing?} class="wv4-menu">
        <button type="button" class="wv4-menu-item" phx-click="start_edit" phx-value-type="scenario" phx-value-id={@sid}>Edit</button>
        <button type="button" class="wv4-menu-item wv4-menu-danger" phx-click="confirm_delete" phx-value-type="scenario" phx-value-id={@sid}>Delete</button>
      </div>

      <%= if @is_editing? do %>
        <form phx-submit="save_scenario" phx-value-id={@sid}>
          <div class="wv4-example-id">{kind_label(@scenario.kind)} · EDITING</div>
          <input
            type="text"
            name="scenario[description]"
            class="wv4-edit-input"
            value={@scenario.description}
            placeholder="Scenario title"
            autofocus
          />
          <textarea
            name="scenario[body]"
            class="wv4-edit-textarea"
            rows="4"
            placeholder="Given... When... Then..."
          >{@scenario.body}</textarea>
          <div class="wv4-edit-actions">
            <button type="button" class="wv4-btn wv4-btn-ghost" phx-click="cancel_edit">Cancel</button>
            <button type="submit" class="wv4-btn wv4-btn-primary">Save</button>
          </div>
        </form>
      <% else %>
        <div class="wv4-example-id">{kind_label(@scenario.kind)} · {short_id(@scenario.id)}</div>
        <div class="wv4-example-text">{@scenario.description}</div>
      <% end %>
    </div>
    """
  end

  attr :questions, :list, required: true
  attr :open_count, :integer, required: true
  attr :menu_open, :map, default: nil
  attr :editing, :map, default: nil

  defp questions_rail(assigns) do
    resolved_count = Enum.count(assigns.questions, &(&1.status == :resolved))
    assigns = assign(assigns, resolved_count: resolved_count)

    ~H"""
    <div class="wv4-rail">
      <div class="wv4-rail-head">
        <div class="wv4-rail-title">Questions</div>
        <div class="wv4-rail-sub">
          {@open_count} open · {@resolved_count} resolved
        </div>
      </div>
      <div class="wv4-rail-body">
        <div :if={@questions == []} class="wv4-rail-empty">
          No red cards yet.
        </div>
        <.question_card
          :for={q <- @questions}
          question={q}
          menu_open={@menu_open}
          editing={@editing}
        />
      </div>
    </div>
    """
  end

  attr :question, :map, required: true
  attr :menu_open, :map, default: nil
  attr :editing, :map, default: nil

  defp question_card(assigns) do
    qid = to_string(assigns.question.id)
    is_editing? = match?(%{type: :question, id: id} when id == qid, assigns.editing)
    is_menu? = match?(%{type: :question, id: id} when id == qid, assigns.menu_open)

    assigns = assign(assigns, qid: qid, is_editing?: is_editing?, is_menu?: is_menu?)

    ~H"""
    <div class={"wv4-q #{@question.status}"}>
      <button
        type="button"
        class="wv4-card-menu"
        phx-click={if @is_menu?, do: "close_menu", else: "open_menu"}
        phx-value-type="question"
        phx-value-id={@qid}
        title="Admin"
      >⋯</button>

      <div :if={@is_menu? && !@is_editing?} class="wv4-menu">
        <button type="button" class="wv4-menu-item" phx-click="start_edit" phx-value-type="question" phx-value-id={@qid}>Edit</button>
        <button type="button" class="wv4-menu-item" phx-click="toggle_question_status" phx-value-id={@qid}>
          {if @question.status == :open, do: "Resolve", else: "Reopen"}
        </button>
        <button type="button" class="wv4-menu-item wv4-menu-danger" phx-click="confirm_delete" phx-value-type="question" phx-value-id={@qid}>Delete</button>
      </div>

      <%= if @is_editing? do %>
        <form phx-submit="save_question" phx-value-id={@qid}>
          <div class="wv4-q-id">Q · EDITING</div>
          <textarea
            name="question[text]"
            class="wv4-edit-textarea"
            rows="3"
            autofocus
          >{@question.text}</textarea>
          <div class="wv4-edit-actions">
            <button type="button" class="wv4-btn wv4-btn-ghost" phx-click="cancel_edit">Cancel</button>
            <button type="submit" class="wv4-btn wv4-btn-primary">Save</button>
          </div>
        </form>
      <% else %>
        <div class="wv4-q-id">Q · {short_id(@question.id)}</div>
        <span class="wv4-q-state">{@question.status}</span>
        <div class="wv4-q-text">{@question.text}</div>
      <% end %>
    </div>
    """
  end

  attr :story, :map, required: true
  attr :rules, :list, required: true
  attr :scenarios, :list, required: true
  attr :questions, :list, required: true
  attr :session_state, :atom, required: true

  defp activity_ribbon(assigns) do
    last = derive_last_event(assigns)
    assigns = assign(assigns, last: last)

    ~H"""
    <div class="wv4-ribbon">
      <span class="wv4-ribbon-time">{@last.time}</span>
      <span>
        <span class="wv4-ribbon-verb">{@last.verb}</span>
        <span :if={@last.target} class="wv4-ribbon-target"> {@last.target}</span>
        <span :if={@last.detail} class="wv4-ribbon-detail"> — {@last.detail}</span>
      </span>
      <span class="wv4-ribbon-chev">▴ activity</span>
    </div>
    """
  end

  defp derive_last_event(%{session_state: :listening}),
    do: %{time: "—", verb: "Agent is listening", target: nil, detail: nil}

  defp derive_last_event(%{session_state: :sealed}),
    do: %{time: "now", verb: "Three Amigos sealed", target: nil, detail: "readiness gate cleared"}

  defp derive_last_event(%{rules: rules, scenarios: scenarios, questions: questions, story: story}) do
    candidates =
      [
        Enum.map(rules, fn r ->
          %{at: r.inserted_at, verb: "Pinned rule", target: short_id(r.id), detail: r.statement}
        end),
        Enum.map(scenarios, fn s ->
          %{at: s.inserted_at, verb: "Pinned #{kind_label(s.kind) |> String.downcase()}", target: short_id(s.id), detail: s.description}
        end),
        Enum.map(questions, fn q ->
          verb = if q.status == :open, do: "Raised question", else: "Resolved question"
          %{at: q.inserted_at, verb: verb, target: short_id(q.id), detail: q.text}
        end)
      ]
      |> List.flatten()
      |> Enum.sort_by(& &1.at, {:desc, NaiveDateTime})

    case candidates do
      [last | _] ->
        %{
          time: format_time(last.at),
          verb: last.verb,
          target: last.target,
          detail: String.slice(last.detail || "", 0, 70)
        }

      [] ->
        %{time: "—", verb: "Session for #{story.title}", target: nil, detail: nil}
    end
  end

  defp state_label(:listening), do: "Listening"
  defp state_label(:active), do: "In session"
  defp state_label(:sealed), do: "Sealed"

  defp kind_label(:happy_path), do: "HAPPY"
  defp kind_label(:failure_path), do: "FAILURE"
  defp kind_label(_), do: "SCENARIO"

  defp short_id(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short_id(id), do: to_string(id)

  defp format_time(%DateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(%NaiveDateTime{} = dt), do: Calendar.strftime(dt, "%H:%M:%S")
  defp format_time(_), do: "—"

  # ─── Wall styles ─────────────────────────────────────────────────────

  defp wall_styles(assigns) do
    ~H"""
    <style>
      .wv4-root {
        --wall-bg: #050308;
        --wall-bg-2: #0b0f18;
        --wall-ink: oklch(85% 0.005 256);
        --wall-ink-mid: oklch(68% 0.006 256);
        --wall-ink-dim: oklch(52% 0.008 256);
        --wall-line: oklch(22% 0.01 256);
        --wall-line-hi: oklch(30% 0.012 256);
        --wall-card: #0b0f18;
        --wall-card-hi: #111827;
        --wall-accent: #f97316;
        --wall-accent-soft: oklch(40% 0.14 45 / 0.18);
        --wall-secondary: #7e22ce;
        --wall-aqua: #22d3ee;
        --wall-sand: #fbbf77;
        --wall-q: #fbbf77;
        --wall-q-soft: oklch(30% 0.08 70 / 0.18);
        --wall-ok: oklch(60% 0.118 184.704);
        --wall-serif: "Space Grotesk", system-ui, sans-serif;
        --wall-sans: "Inter", system-ui, sans-serif;
        --wall-mono: "JetBrains Mono", ui-monospace, monospace;
        font-family: var(--wall-sans);
        color: var(--wall-ink);
        background: var(--wall-bg);
        height: calc(100vh - 64px);
        width: 100%;
        position: relative;
        overflow: hidden;
        display: flex;
        flex-direction: column;
        margin: -1rem;
      }
      .wv4-root.sealed { filter: saturate(0.5) brightness(0.82); }
      .wv4-root *, .wv4-root *::before, .wv4-root *::after { box-sizing: border-box; }
      .wv4-body { flex: 1; display: flex; overflow: hidden; min-height: 0; }
      .wv4-wall { flex: 1; min-width: 0; position: relative; overflow: auto; background-color: var(--wall-bg);
        background-image: radial-gradient(circle at 18% 25%, oklch(25% 0.08 45 / 0.35) 0, transparent 45%), radial-gradient(circle at 82% 72%, oklch(22% 0.09 300 / 0.3) 0, transparent 45%); }
      .wv4-wall.empty { background-image: radial-gradient(circle at 18% 25%, oklch(25% 0.08 45 / 0.35) 0, transparent 45%), radial-gradient(circle at 82% 72%, oklch(22% 0.09 300 / 0.3) 0, transparent 45%), radial-gradient(circle at 1px 1px, oklch(25% 0.012 256) 1px, transparent 0); background-size: auto, auto, 24px 24px; }
      .wv4-canvas { display: grid; grid-template-columns: repeat(auto-fill, minmax(320px, 1fr)); gap: 1.5rem; padding: 1.5rem; align-content: start; }
      .wv4-rule-column { display: flex; flex-direction: column; gap: 0.75rem; min-width: 0; }
      .wv4-card { position: relative; background: var(--wall-card); border: 1.5px solid var(--wall-line); border-radius: 0.5rem; box-shadow: 0 1px 2px oklch(0% 0 0 / 0.4), 0 6px 16px oklch(0% 0 0 / 0.35); transition: box-shadow .18s ease, transform .18s ease, border-color .18s ease; min-width: 0; }
      .wv4-card:hover { border-color: var(--wall-line-hi); background: var(--wall-card-hi); box-shadow: 0 2px 4px oklch(0% 0 0 / 0.5), 0 10px 28px oklch(0% 0 0 / 0.45); transform: translateY(-1px); }
      .wv4-rule { padding: 16px 18px 14px; }
      .wv4-rule-id { font-family: var(--wall-mono); font-size: 10px; color: var(--wall-aqua); letter-spacing: 0.08em; text-transform: uppercase; }
      .wv4-rule-title { font-family: var(--wall-serif); font-size: 17px; line-height: 1.25; font-weight: 600; margin: 6px 0 8px; letter-spacing: -0.01em; color: var(--wall-ink); }
      .wv4-example { padding: 10px 12px; margin-left: 1.25rem; border-left: 2px solid var(--wall-accent); }
      .wv4-example.wv4-example-failure_path { border-left-color: var(--wall-secondary); }
      .wv4-example-id { font-family: var(--wall-mono); font-size: 9.5px; color: var(--wall-accent); letter-spacing: 0.1em; text-transform: uppercase; }
      .wv4-example-failure_path .wv4-example-id { color: var(--wall-secondary); }
      .wv4-example-text { font-size: 12px; line-height: 1.45; color: var(--wall-ink); margin-top: 4px; }
      .wv4-card-menu { position: absolute; top: 6px; right: 6px; opacity: 0; transition: opacity .12s; cursor: pointer; width: 20px; height: 20px; display: flex; align-items: center; justify-content: center; border-radius: 3px; color: var(--wall-ink-dim); background: transparent; border: 0; }
      .wv4-card:hover .wv4-card-menu, .wv4-q:hover .wv4-card-menu { opacity: 1; }
      .wv4-card-menu:hover { background: var(--wall-line-hi); color: var(--wall-accent); }
      .wv4-header { display: flex; align-items: center; gap: 14px; padding: 14px 22px; border-bottom: 1.5px solid var(--wall-line); background: var(--wall-bg-2); }
      .wv4-feature-id { font-family: var(--wall-mono); font-size: 10px; color: var(--wall-ink-dim); letter-spacing: 0.08em; }
      .wv4-feature-title { font-family: var(--wall-serif); font-size: 18px; font-weight: 600; letter-spacing: -0.01em; }
      .wv4-feature-sub { font-size: 12px; color: var(--wall-ink-mid); }
      .wv4-counts { display: flex; gap: 14px; font-family: var(--wall-mono); font-size: 10.5px; color: var(--wall-ink-dim); letter-spacing: 0.04em; }
      .wv4-counts strong { color: var(--wall-ink); font-weight: 600; margin-right: 4px; }
      .wv4-session-state { font-family: var(--wall-mono); font-size: 10px; letter-spacing: 0.12em; text-transform: uppercase; padding: 5px 10px; border: 1.5px solid var(--wall-line-hi); border-radius: 0.25rem; color: var(--wall-ink-mid); display: inline-flex; align-items: center; gap: 7px; }
      .wv4-session-state .wv4-pulse { width: 6px; height: 6px; border-radius: 50%; background: var(--wall-accent); animation: wv4-pulse 1.6s ease-in-out infinite; }
      @keyframes wv4-pulse { 0%, 100% { opacity: 0.35; transform: scale(0.85); } 50% { opacity: 1; transform: scale(1.1); } }
      .wv4-rail { width: 300px; flex-shrink: 0; border-left: 1.5px solid var(--wall-line); background: var(--wall-bg-2); display: flex; flex-direction: column; }
      .wv4-rail-head { padding: 14px 18px 10px; border-bottom: 1.5px solid var(--wall-line); }
      .wv4-rail-title { font-family: var(--wall-serif); font-size: 15px; font-weight: 600; letter-spacing: -0.005em; }
      .wv4-rail-sub { font-family: var(--wall-mono); font-size: 10px; color: var(--wall-ink-dim); letter-spacing: 0.06em; margin-top: 3px; }
      .wv4-rail-body { flex: 1; overflow: auto; padding: 12px 14px; }
      .wv4-rail-empty { font-family: var(--wall-serif); font-style: italic; font-size: 12.5px; color: var(--wall-ink-dim); text-align: center; padding: 20px 0; }
      .wv4-q { padding: 11px 12px; margin-bottom: 10px; border-radius: 0.25rem; border: 1.5px solid var(--wall-line); background: var(--wall-card); position: relative; }
      .wv4-q.open { border-left: 2px solid var(--wall-q); background: var(--wall-q-soft); }
      .wv4-q.resolved { opacity: 0.6; }
      .wv4-q.deferred { opacity: 0.7; }
      .wv4-q-id { font-family: var(--wall-mono); font-size: 9.5px; letter-spacing: 0.1em; color: var(--wall-ink-dim); text-transform: uppercase; }
      .wv4-q.open .wv4-q-id { color: var(--wall-sand); }
      .wv4-q-state { font-family: var(--wall-mono); font-size: 9px; letter-spacing: 0.12em; text-transform: uppercase; float: right; color: var(--wall-ink-dim); }
      .wv4-q.open .wv4-q-state { color: var(--wall-sand); }
      .wv4-q.resolved .wv4-q-state { color: var(--wall-ok); }
      .wv4-q-text { font-size: 12.5px; line-height: 1.45; margin-top: 5px; }
      .wv4-q.resolved .wv4-q-text { text-decoration: line-through; text-decoration-color: var(--wall-ink-dim); }
      .wv4-ribbon { border-top: 1.5px solid var(--wall-line); background: var(--wall-bg-2); padding: 10px 22px; display: flex; align-items: center; gap: 14px; font-size: 11.5px; color: var(--wall-ink-mid); }
      .wv4-ribbon-time { font-family: var(--wall-mono); font-size: 10px; color: var(--wall-ink-dim); letter-spacing: 0.04em; flex-shrink: 0; }
      .wv4-ribbon-verb { color: var(--wall-ink); font-weight: 500; }
      .wv4-ribbon-target { font-family: var(--wall-mono); color: var(--wall-accent); }
      .wv4-ribbon-detail { color: var(--wall-ink-dim); font-style: italic; }
      .wv4-ribbon-chev { margin-left: auto; font-family: var(--wall-mono); font-size: 10px; color: var(--wall-ink-dim); }
      .wv4-sealed-stamp { position: absolute; top: 20px; right: 20px; border: 2px solid var(--wall-ok); color: var(--wall-ok); padding: 7px 14px; font-family: var(--wall-mono); font-size: 11px; letter-spacing: 0.16em; text-transform: uppercase; transform: rotate(-4deg); background: oklch(20% 0.04 184 / 0.5); border-radius: 0.25rem; z-index: 5; font-weight: 600; box-shadow: 0 4px 20px oklch(60% 0.12 184 / 0.15); }
      .wv4-listening { position: absolute; inset: 0; display: flex; align-items: center; justify-content: center; flex-direction: column; gap: 12px; pointer-events: none; }
      .wv4-listening-text { font-family: var(--wall-serif); font-style: italic; font-size: 16px; color: var(--wall-ink-dim); letter-spacing: 0.01em; }
      .wv4-listening-sub { font-family: var(--wall-mono); font-size: 10.5px; color: var(--wall-ink-dim); letter-spacing: 0.12em; text-transform: uppercase; }
      .wv4-menu { position: absolute; top: 28px; right: 6px; background: var(--wall-card-hi); border: 1.5px solid var(--wall-line-hi); border-radius: 0.25rem; box-shadow: 0 4px 18px oklch(0% 0 0 / 0.5); z-index: 10; padding: 4px; display: flex; flex-direction: column; min-width: 110px; }
      .wv4-menu-item { background: transparent; border: 0; color: var(--wall-ink-mid); font-family: var(--wall-sans); font-size: 12px; padding: 6px 10px; text-align: left; cursor: pointer; border-radius: 0.2rem; transition: background-color .12s, color .12s; }
      .wv4-menu-item:hover { background: var(--wall-line); color: var(--wall-ink); }
      .wv4-menu-danger { color: oklch(72% 0.18 25); }
      .wv4-menu-danger:hover { background: oklch(28% 0.12 25 / 0.5); color: oklch(85% 0.18 25); }
      .wv4-edit-input, .wv4-edit-textarea { width: 100%; background: var(--wall-bg); border: 1.5px solid var(--wall-line-hi); border-radius: 0.25rem; color: var(--wall-ink); font-family: var(--wall-sans); font-size: 13px; line-height: 1.4; padding: 6px 8px; margin-top: 6px; resize: vertical; }
      .wv4-edit-input:focus, .wv4-edit-textarea:focus { outline: none; border-color: var(--wall-accent); }
      .wv4-edit-actions { display: flex; gap: 6px; justify-content: flex-end; margin-top: 8px; }
      .wv4-btn { font-family: var(--wall-sans); font-size: 12px; font-weight: 500; padding: 5px 12px; border-radius: 0.25rem; border: 1.5px solid var(--wall-line-hi); background: transparent; color: var(--wall-ink-mid); cursor: pointer; transition: background-color .12s, color .12s, border-color .12s; }
      .wv4-btn:hover { border-color: var(--wall-ink-mid); color: var(--wall-ink); }
      .wv4-btn-primary { background: var(--wall-accent); border-color: var(--wall-accent); color: var(--wall-bg); font-weight: 600; }
      .wv4-btn-primary:hover { background: oklch(75% 0.17 45); border-color: oklch(75% 0.17 45); color: var(--wall-bg); }
      .wv4-btn-danger { background: oklch(50% 0.18 25); border-color: oklch(50% 0.18 25); color: var(--wall-ink); font-weight: 600; }
      .wv4-btn-danger:hover { background: oklch(60% 0.20 25); border-color: oklch(60% 0.20 25); }

      /* Confirm-delete modal — replaces data-confirm so QA agent can click through */
      .wv4-modal-backdrop {
        position: fixed; inset: 0; background: oklch(0% 0 0 / 0.6);
        display: flex; align-items: center; justify-content: center;
        z-index: 50; backdrop-filter: blur(2px);
      }
      .wv4-modal {
        background: var(--wall-card); border: 1.5px solid var(--wall-line-hi);
        border-radius: 0.5rem; padding: 22px 24px; min-width: 380px; max-width: 460px;
        box-shadow: 0 12px 40px oklch(0% 0 0 / 0.6);
      }
      .wv4-modal-title {
        font-family: var(--wall-serif); font-size: 17px; font-weight: 600;
        color: var(--wall-ink); margin-bottom: 8px;
      }
      .wv4-modal-body {
        font-size: 13px; line-height: 1.5; color: var(--wall-ink-mid);
        margin-bottom: 18px;
      }
      .wv4-modal-actions {
        display: flex; gap: 8px; justify-content: flex-end;
      }

      @media (max-width: 768px) {
        .wv4-body { flex-direction: column; }
        .wv4-rail { width: 100%; max-height: 40vh; border-left: 0; border-top: 1.5px solid var(--wall-line); }
        .wv4-canvas { padding: 1rem; gap: 1rem; }
        .wv4-header { flex-wrap: wrap; gap: 8px 14px; padding: 12px 16px; }
        .wv4-counts { flex-wrap: wrap; }
      }
    </style>
    """
  end
end
