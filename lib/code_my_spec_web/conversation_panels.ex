defmodule CodeMySpecWeb.ConversationPanels do
  @moduledoc """
  The dynamic panel beside a conversation — preview, project, activity.

  Extracted from `AgentConversationLive.Show` (966/967) so the pre-signup
  screen (`IntakeLive.Plan`/`Workspace`, story 1033) renders the cockpit's own
  panel and chat components rather than a parallel implementation that only
  looks similar: "the same markup and behavior, given different backing
  data." A caller with no project yet passes empty lists and `nil` — the
  wrapper (`data-test="conversation-panels"`) and tab strip still render;
  `panel_body/1` simply never runs, since it is only reached for a `key in
  @open` and a caller with nothing to show opens nothing.
  """

  use CodeMySpecWeb, :html

  import CodeMySpecWeb.PreviewComponents, only: [pane: 1]

  attr :screen, :atom, required: true
  attr :open, :list, required: true
  attr :dynamic_view, :string, required: true
  attr :dynamic_stories, :list, required: true
  attr :dynamic_story, :any, required: true
  attr :dynamic_epics, :list, required: true
  attr :offer, :any, default: nil
  attr :activity, :list, required: true
  attr :waiting, :list, required: true
  attr :copies, :list, required: true
  attr :project_id, :string, required: true
  attr :conversation_id, :any, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent

  # Three tabs on a phone, an accordion on a desk.
  #
  # Stacked headers cost three full-width rows to say nothing when every panel
  # is shut, which on a 390px screen is most of what is above the conversation.
  # John: "the accordion takes up too much space when nothing is selected." A
  # tab strip says the same three words in one row, and the phone already only
  # ever shows one panel — so the accordion was paying for a choice it does not
  # have.
  #
  # A desk keeps the accordion, where the room exists and more than one panel
  # can be open at once.
  @panel_tabs [{:preview, "Preview"}, {:dynamic, "Project"}, {:activity, "Activity"}]

  def panels(%{screen: :narrow} = assigns) do
    assigns = assign(assigns, :tabs, @panel_tabs)

    ~H"""
    <div data-test="conversation-panels" class="flex w-full shrink-0 flex-col gap-2">
      <div role="tablist" class="flex gap-1">
        <div
          :for={{key, label} <- @tabs}
          data-test={"panel-#{key}"}
          data-panel-open={to_string(key in @open)}
          class="min-w-0 flex-1"
        >
          <button
            type="button"
            data-test={"panel-tab-#{key}"}
            phx-click="toggle_panel"
            phx-value-panel={key}
            class={[
              "flex w-full items-center justify-center gap-1 rounded-box border px-2 py-1.5 text-xs",
              key in @open && "border-primary bg-primary/10 font-semibold text-primary",
              key not in @open && "border-base-300"
            ]}
          >
            <span class="truncate">{label}</span>
            <.panel_attention
              :if={key == :activity}
              alert?={@waiting != []}
            />
            <.panel_offer :if={key == :dynamic} offer={@offer} />
          </button>
        </div>
      </div>

      <%!-- One body, below the strip, for whichever tab is open. Capped so a
      full panel scrolls inside itself rather than pushing the conversation off
      the bottom. --%>
      <div
        :if={@open != []}
        class="max-h-[40dvh] overflow-y-auto rounded-box border border-base-300 p-3 text-sm"
      >
        <.panel_body
          which={hd(@open)}
          dynamic_view={@dynamic_view}
          dynamic_stories={@dynamic_stories}
          dynamic_story={@dynamic_story}
          dynamic_epics={@dynamic_epics}
          offer={@offer}
          activity={@activity}
          copies={@copies}
          project_id={@project_id}
          conversation_id={@conversation_id}
          preview_src={@preview_src}
          preview_state={@preview_state}
        />
      </div>
    </div>
    """
  end

  # The outer wrapping div is `LivePane.pane id="conversation-panels"` in the
  # caller — this is that pane's content, not a second div of its own.
  #
  # Headers are plain, non-pane flex children living directly inside the
  # vertical `LivePane.group` alongside the pane bodies and resizers, exactly
  # as they were flattened siblings of one hand-rolled flex-col before: the
  # group hook finds panes and resizers by `data-pane-*` attribute, not by
  # walking its own DOM children, so an ordinary header div between them
  # neither needs to be a pane itself nor breaks the ones that are.
  def panels(assigns) do
    assigns = assign(assigns, :tabs, @panel_tabs)

    ~H"""
    <LivePane.group id="side-panels-body" direction="vertical" auto_save={true} class="min-h-0 flex-1">
      <%= for {{key, label}, index} <- Enum.with_index(@tabs) do %>
        <div
          data-test={"panel-#{key}"}
          data-panel-open={to_string(key in @open)}
          class="shrink-0 self-stretch"
        >
          <%!-- John: "very minimal panel styling... just a hairline with a
          down arrow that expands the panel" — no card, no box, a divider and
          a chevron. The chevron carries the state instead of the border that
          used to: rotated open, flat closed. --%>
          <button
            type="button"
            data-test={"panel-tab-#{key}"}
            phx-click="toggle_panel"
            phx-value-panel={key}
            class="flex w-full items-center gap-1.5 border-b border-base-300 py-1.5 text-sm"
          >
            <%!-- `icon/1` declares `class` as `:string` — unlike a plain
            element it does not accept the `[base, cond && extra]` list form,
            so the conditional is folded into one string here instead. --%>
            <.icon
              name="hero-chevron-right-micro"
              class={
                "size-3.5 shrink-0 opacity-50 transition-transform" <>
                  if(key in @open, do: " rotate-90", else: "")
              }
            />
            <span class="flex-1 text-left">{label}</span>
            <.panel_attention
              :if={key == :activity}
              alert?={@waiting != []}
            />
            <.panel_offer :if={key == :dynamic} offer={@offer} />
          </button>
        </div>

        <%!-- `order` is the fixed tab index rather than toggle order, for the
        same reason the old `next_panel_open?/3` walked `@tabs` instead of
        `@open`: a handle between "whichever opened most recently" would jump
        to a different visual spot every time a third panel opened. The
        library sorts registered panes by `order`, so this alone is what
        keeps a reopened preview pane back in first position rather than
        wherever it happened to mount.
        Sizing (flex-grow/flex-basis) is inline style the pane hook computes
        and writes itself — no CSS var on `<html>` to hand-roll any more, and
        `auto_save` above persists a drag the same way. Left unset, untouched
        panes simply split the column evenly, same as before. --%>
        <%!-- The pane hook overwrites this element's own `style` wholesale on
        every layout change (`el.style.cssText = ...`), inline `overflow:
        hidden` included — a class here asking for `overflow-y-auto` would
        lose to that every time. The scrolling lives one level in instead, on
        a div the hook never touches. --%>
        <LivePane.pane
          :if={key in @open}
          group_id="side-panels-body"
          id={"panel-body-#{key}"}
          order={index}
          min_size={10}
          class="min-h-0 self-stretch"
        >
          <div class="h-full overflow-y-auto py-2 text-sm">
            <.panel_body
              which={key}
              dynamic_view={@dynamic_view}
              dynamic_stories={@dynamic_stories}
              dynamic_story={@dynamic_story}
              dynamic_epics={@dynamic_epics}
              activity={@activity}
              copies={@copies}
              project_id={@project_id}
              conversation_id={@conversation_id}
              preview_src={@preview_src}
              preview_state={@preview_state}
            />
          </div>
        </LivePane.pane>

        <LivePane.resizer
          :if={key in @open and next_panel_open?(@tabs, @open, index)}
          group_id="side-panels-body"
          id={"panel-split-#{key}"}
          class="group flex h-3 shrink-0 cursor-row-resize select-none flex-col items-center justify-center self-stretch"
        >
          <span class="h-0.5 w-full rounded-full bg-base-300 transition-colors group-hover:bg-primary/60 group-active:bg-primary">
          </span>
        </LivePane.resizer>
      <% end %>
    </LivePane.group>
    """
  end

  # Whether a resizer belongs after this open panel — there needs to be one
  # between each pair of currently-open panes, and none after the last of
  # them. Drawn from the fixed tab order in `@tabs` rather than from `@open`
  # — `@open` records toggle order, and a handle between "whichever opened
  # most recently" would jump to a different visual spot every time someone
  # opened a third panel.
  defp next_panel_open?(tabs, open, index) do
    case Enum.at(tabs, index + 1) do
      {next_key, _label} -> next_key in open
      nil -> false
    end
  end

  # On the tab header, so a shut tab can still raise it. On a phone the other
  # panels are not merely collapsed but absent, and a question nobody sees is an
  # agent stopped for as long as nobody looks.
  # The agent has something for this tab and has not been given the screen.
  # Only ever rendered on a phone in practice — a wide screen takes the offer
  # the moment it arrives, so there is nothing left to mark.
  attr :offer, :any, default: nil

  defp panel_offer(assigns) do
    ~H"""
    <span :if={@offer} data-test="panel-offer" class="badge badge-xs badge-primary">
      new
    </span>
    """
  end

  # Used to carry a raw count — `{length(@waiting)}` — and `@waiting` is
  # every pending question on the person's account, not this project's:
  # `Notifications.list_pending_question_requests_for_user/1` has no
  # project filter at all, so the number this printed had no ceiling and no
  # relationship to anything on this screen. Reduced to presence only,
  # because *some* signal has to reach a closed tab — 2953 exists because a
  # question can come from a copy with no tracked agent at all (nothing an
  # asked-for scope can name), so this can't be swapped for the per-agent
  # tree's own `question?` flags the way the panel body was.
  attr :alert?, :boolean, required: true

  defp panel_attention(assigns) do
    ~H"""
    <span
      :if={@alert?}
      data-test="panel-attention"
      class="size-1.5 shrink-0 rounded-full bg-warning"
    />
    """
  end

  attr :which, :atom, required: true
  attr :dynamic_view, :string, required: true
  attr :dynamic_stories, :list, required: true
  attr :dynamic_story, :any, required: true
  attr :dynamic_epics, :list, required: true
  attr :offer, :any, default: nil
  attr :activity, :list, required: true
  attr :copies, :list, required: true
  attr :project_id, :string, required: true
  attr :conversation_id, :any, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent

  # 886's pane, not a second one. It already renders every state a preview can
  # be in and refuses `:running` with no address, and a copy of it here would
  # be the same component with a different set of bugs.
  defp panel_body(%{which: :preview} = assigns) do
    ~H"""
    <div :if={@preview_src} data-test="panel-preview-frame" class="h-full">
      <.pane src={@preview_src} state={@preview_state} title="Your app" />
    </div>
    <div :if={!@preview_src}>
      <p data-test="panel-preview-empty" class="opacity-70">
        No preview is running for this project yet.
      </p>
      <p data-test="panel-preview-remedy" class="mt-1 opacity-70">
        Ask the agent to deploy this project, and the running app appears here.
      </p>
    </div>
    """
  end

  defp panel_body(%{which: :dynamic} = assigns) do
    ~H"""
    <div data-dynamic-view={@dynamic_view}>
      <%!-- One story, when the agent has put one in front of you. Its criteria
      rather than its prose: what the story promises is the part you are being
      asked about. --%>
      <div :if={@dynamic_view == "story" and @dynamic_story}>
        <.link
          navigate={~p"/app/projects/#{@dynamic_story.project_id}/stories/#{@dynamic_story.number}"}
          class="font-semibold link link-hover"
        >
          {@dynamic_story.title}
        </.link>

        <ul class="mt-2 space-y-1">
          <li
            :for={criterion <- @dynamic_story.acceptance_criteria || []}
            data-test="dynamic-criterion"
            class="flex gap-2 text-xs opacity-80"
          >
            <span class={[
              "mt-1 block size-2 shrink-0 rounded-full",
              criterion.verified && "bg-success",
              not criterion.verified && "bg-base-content/20"
            ]} />
            <span>{criterion.description}</span>
          </li>
        </ul>

        <p :if={(@dynamic_story.acceptance_criteria || []) == []} class="mt-2 text-xs opacity-60">
          No criteria yet — this story has not been through Three Amigos.
        </p>
      </div>

      <p :if={@dynamic_view == "story" and is_nil(@dynamic_story)} class="opacity-70">
        That story is not on this project, or has been deleted.
      </p>

      <%!-- Epics, most recently named first — same list shape as stories below,
      switched to on any epic event (see `handle_info/2`) so an epic the agent
      just created appears without anybody asking for it. --%>
      <div :if={@dynamic_view == "epics"}>
        <p :if={@dynamic_epics == []} class="opacity-70">
          No epics yet. Ask the agent to group some stories into one.
        </p>

        <ul class="space-y-1">
          <li :for={epic <- @dynamic_epics} data-test="dynamic-epic">
            <.link
              navigate={~p"/app/projects/#{epic.project_id}/epics/#{epic.slug}"}
              class="flex items-baseline gap-2 link link-hover"
            >
              <span class={["block size-2 shrink-0 rounded-full", epic_status_dot(epic.status)]} />
              <span class="truncate">{epic.name}</span>
              <span class="shrink-0 text-xs opacity-60">{length(epic.stories)}</span>
            </.link>
          </li>
        </ul>
      </div>

      <%!-- Otherwise the project's stories, most recent first. The list is the
      default because it is the one view that is useful before anybody has asked
      for anything in particular. --%>
      <div :if={@dynamic_view not in ["story", "epics"]}>
        <p :if={@dynamic_stories == []} class="opacity-70">
          No stories yet. Ask the agent for one.
        </p>

        <ul class="space-y-1">
          <li :for={story <- @dynamic_stories} data-test="dynamic-story">
            <.link
              navigate={~p"/app/projects/#{story.project_id}/stories/#{story.number}"}
              class="flex items-baseline gap-2 link link-hover"
            >
              <span class={[
                "block size-2 shrink-0 rounded-full",
                story.ready_for_dev && "bg-success",
                not story.ready_for_dev && "bg-base-content/20"
              ]} />
              <span class="truncate">{story.title}</span>
            </.link>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  # John: "the most important thing that comes out of here is that we have a
  # place to see what agents need us, and a really fast way to get to the
  # conversation so we can answer the question." A tree, not a feed: every
  # working copy, its agents, and — the one thing worth a color — which of
  # them has a question waiting. Clicking an agent with a chat goes straight
  # to its transcript; that is the whole "fast way".
  defp panel_body(%{which: :activity} = assigns) do
    assigns =
      assigns
      |> assign(:agent_total, Enum.reduce(assigns.copies, 0, &(length(&1.agents) + &2)))
      |> assign(:needing_you, Enum.count(assigns.copies, & &1.question?))

    ~H"""
    <div class="space-y-3">
      <p :if={@copies == []} data-test="team-empty" class="opacity-70">
        No working copies on this project yet.
      </p>

      <div :if={@copies != []} class="flex items-center justify-between gap-2 text-xs">
        <span class="opacity-60">
          {@agent_total} {noun(@agent_total, "agent", "agents")} on {length(@copies)} {noun(
            length(@copies),
            "copy",
            "copies"
          )}
        </span>
        <span
          :if={@needing_you > 0}
          data-test="needs-you"
          class="badge badge-warning badge-sm shrink-0 gap-1"
        >
          <.icon name="hero-question-mark-circle-solid" class="size-3" />
          {@needing_you} {noun(@needing_you, "needs", "need")} you
        </span>
      </div>

      <div :for={copy <- @copies} data-test="team-copy" data-working-copy-id={copy.row.harness.id}>
        <%!-- `heading`, not the raw `label` field: an unrenamed harness's
        label is not blank, it is the auto-generated "the harness at <root>
        on <host>" sentence — `WorkingCopies.display_name/1` is what
        recognizes that shape and shortens it to the root's last segment,
        the same function the working-copy Show page titles itself with. A
        harness someone actually renamed passes straight through unchanged. --%>
        <div class="flex items-center gap-1.5 text-xs font-medium">
          <.icon
            :if={copy.row.harness.main}
            name="hero-star-solid"
            class="size-3 shrink-0 text-primary"
          />
          <span class="min-w-0 flex-1 truncate">{copy.row.heading}</span>
          <span class="shrink-0 opacity-60">{copy.row.liveness.label}</span>
        </div>

        <div :for={a <- copy.agents} data-test="team-agent" data-agent-id={a.agent.id}>
          <%!-- `patch`, not `navigate`: this panel is the fastest way to a
          different agent, and the panel is part of what a navigate would tear
          down and rebuild — including the preview pane and the widths somebody
          dragged. Patching swaps the transcript and leaves the rest alone.

          The one you are reading is marked, because a list whose whole job is
          picking between agents should say which one you picked. `aria-current`
          rather than only a background: the same claim, said once, in the way
          assistive tech reads. --%>
          <.link
            :if={a.chat}
            patch={conversation_path(@project_id, a.chat.conversation.id)}
            data-question={to_string(a.question?)}
            data-current={to_string(current_agent?(a, @conversation_id))}
            aria-current={current_agent?(a, @conversation_id) && "true"}
            class={[
              "flex items-center gap-1.5 rounded py-1 pl-4 text-xs hover:bg-base-200",
              a.question? && "font-semibold text-warning",
              current_agent?(a, @conversation_id) && "bg-base-300 font-semibold"
            ]}
          >
            <.icon
              :if={a.question?}
              name="hero-question-mark-circle-solid"
              class="size-3.5 shrink-0"
            />
            <span class="min-w-0 flex-1 truncate">{a.agent.role}</span>
            <span class="shrink-0 opacity-60">{a.liveness.label}</span>
          </.link>

          <div
            :if={!a.chat}
            class="flex items-center gap-1.5 py-1 pl-4 text-xs opacity-60"
          >
            <span class="min-w-0 flex-1 truncate">{a.agent.role}</span>
            <span class="shrink-0">{a.liveness.label}</span>
          </div>

          <%!-- One name, or a count — never both truncated names on one line.
          One task is the thing worth reading here; more than one is a reason
          to click through rather than a list to skim in a line-and-a-half. --%>
          <p
            :if={a.task_label}
            data-test="team-agent-task"
            class="truncate pl-9 text-[11px] opacity-50"
          >
            {a.task_label}
          </p>
        </div>
      </div>
    </div>
    """
  end

  defp noun(1, singular, _plural), do: singular
  defp noun(_n, _singular, plural), do: plural

  # The cockpit, showing one agent. Built here rather than inline so the query
  # param has one spelling — `FilesLive` keeps its own `files_path/2` for the
  # same reason.
  defp conversation_path(project_id, conversation_id),
    do: ~p"/app/projects/#{project_id}/agent-conversation?#{[conversation: conversation_id]}"

  defp current_agent?(%{chat: %{conversation: %{id: id}}}, id) when is_binary(id), do: true
  defp current_agent?(_agent, _conversation_id), do: false

  # Mirrors the story dot's done/not-yet split, widened to the epic's four
  # states: dispatched is done, proposed is waiting on a person (the same
  # amber the team-status panel uses for "needs you"), draft is not yet, and
  # failed is its own color because it is not simply "not yet" — the agent
  # tried and stopped.
  defp epic_status_dot(:dispatched), do: "bg-success"
  defp epic_status_dot(:proposed), do: "bg-warning"
  defp epic_status_dot(:failed), do: "bg-error"
  defp epic_status_dot(_draft), do: "bg-base-content/20"
end
