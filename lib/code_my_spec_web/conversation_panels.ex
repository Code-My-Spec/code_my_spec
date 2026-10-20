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

  alias CodeMySpecWeb.WorkingCopyLive.Components.Copy

  @doc """
  The dynamic panel beside a conversation, with nothing to switch between.

  Same wrapper identity as `panels/1` — `data-test="conversation-panels"` —
  so a caller with exactly one thing to show (a form, a payment element, a
  boot-status card) doesn't get a tab strip with two dead tabs beside it:
  `IntakeLive.Plan`/`Workspace` (pre-signup, pre-project) have no preview to
  show and no team activity to report, so `panels/1`'s three-tab shape was
  chrome around nothing, not a smaller version of the real thing.

  Sized the same way `panels/1`'s body is — capped and independently
  scrollable when stacked below the conversation on a phone, a fixed-width
  column with no cap beside it on a desk — so a caller only supplies what
  differs (the one card), not the shape it sits in.
  """
  slot :inner_block, required: true

  def single_panel(assigns) do
    ~H"""
    <div
      data-test="conversation-panels"
      class="max-h-[45dvh] overflow-y-auto border-t border-base-300 p-4 lg:max-h-none lg:w-96 lg:shrink-0 lg:border-t-0 lg:border-l"
    >
      {render_slot(@inner_block)}
    </div>
    """
  end

  attr :screen, :atom, required: true
  attr :open, :list, required: true
  attr :dynamic_view, :string, required: true
  attr :dynamic_stories, :list, required: true
  attr :dynamic_story, :any, required: true
  attr :dynamic_epics, :list, required: true
  attr :offer, :any, default: nil
  attr :waiting, :list, required: true
  attr :copies, :list, required: true
  attr :scope, :any, default: nil
  attr :project_id, :string, required: true
  attr :conversation_id, :any, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent
  attr :extra_frame_origins, :list, default: []

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
          copies={@copies}
          scope={@scope}
          project_id={@project_id}
          conversation_id={@conversation_id}
          preview_src={@preview_src}
          preview_state={@preview_state}
          extra_frame_origins={@extra_frame_origins}
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
              copies={@copies}
              scope={@scope}
              project_id={@project_id}
              conversation_id={@conversation_id}
              preview_src={@preview_src}
              preview_state={@preview_state}
              extra_frame_origins={@extra_frame_origins}
            />
          </div>
        </LivePane.pane>

        <LivePane.resizer
          :if={key in @open and next_panel_open?(@tabs, @open, index)}
          group_id="side-panels-body"
          id={"panel-split-#{key}"}
          class="group flex h-3 shrink-0 cursor-row-resize select-none flex-col items-center justify-center self-stretch"
        >
          <span class="h-0.5 w-full rounded-full bg-base-300 transition-colors group-hover:bg-primary/60 group-active:bg-primary"></span>
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
  attr :copies, :list, required: true
  attr :scope, :any, default: nil
  attr :project_id, :string, required: true
  attr :conversation_id, :any, required: true
  attr :preview_src, :string, default: nil
  attr :preview_state, :atom, default: :absent
  attr :extra_frame_origins, :list, default: []

  # 886's pane, not a second one. It already renders every state a preview can
  # be in and refuses `:running` with no address, and a copy of it here would
  # be the same component with a different set of bugs.
  defp panel_body(%{which: :preview} = assigns) do
    ~H"""
    <div :if={@preview_src} data-test="panel-preview-frame" class="h-full">
      <p
        :if={@extra_frame_origins != []}
        data-test="panel-preview-extra-origins"
        class="mb-2 text-xs opacity-60"
      >
        Also allowed to open: <span class="font-mono">{Enum.join(@extra_frame_origins, ", ")}</span>
      </p>
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
          <button
            type="button"
            phx-click="show_copy"
            phx-value-id={copy.row.harness.id}
            class="link link-hover min-w-0 flex-1 truncate text-left"
            data-test="team-copy-open"
            title="This copy at a glance"
          >
            {copy.row.heading}
          </button>
          <.copy_assignment copy={copy} scope={@scope} project_id={@project_id} />
          <Copy.problems_marker
            tally={copy.problems}
            phx-click="show_problems"
            phx-value-id={copy.row.harness.id}
          />
          <Copy.harness_marker row={copy.row} />
          <Copy.preview_marker harness={copy.row.harness} />
        </div>

        <div :for={a <- copy.agents} data-test="team-agent" data-agent-id={a.agent.id}>
          <%!-- Line 1 is the agent: who it is and what state it is in, then the
          two controls on the right. Line 2 is its work, which opens the issue
          or story show. John, 2026-10-19. --%>
          <div
            class={["flex items-center gap-1", dimmed?(a) && "opacity-50"]}
            title={dimmed?(a) && liveness_title(a.liveness)}
          >
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
              data-unread={to_string(unread?(a))}
              data-current={to_string(current_agent?(a, @conversation_id))}
              aria-current={current_agent?(a, @conversation_id) && "true"}
              class={[
                "flex min-w-0 flex-1 items-center gap-1.5 rounded py-1 pl-4 text-xs hover:bg-base-200",
                a.question? && "font-semibold text-warning",
                current_agent?(a, @conversation_id) && "bg-base-300 font-semibold"
              ]}
            >
              <.icon
                :if={a.question?}
                name="hero-question-mark-circle-solid"
                class="size-3.5 shrink-0"
              />
              <span
                :if={unread?(a)}
                data-test="unread-dot"
                class="size-2 shrink-0 rounded-full bg-primary"
              ></span>
              <.agent_identity a={a} />
            </.link>

            <div
              :if={!a.chat}
              class="flex min-w-0 flex-1 items-center gap-1.5 py-1 pl-4 text-xs"
            >
              <.agent_identity a={a} />
            </div>

            <%!-- f096eba2: every agent controllable from here, not only the one
            whose conversation happens to be open — siblings of the link/div
            above rather than nested inside it, since a button inside an `<a>`
            both renders invalid HTML and would fire the patch-navigate on top
            of the toggle. --%>
            <button
              type="button"
              phx-click="toggle_agent_working"
              phx-value-agent-id={a.agent.id}
              data-test="team-agent-working"
              data-working={to_string(a.agent.continuous == true)}
              class={[
                "btn btn-ghost btn-xs btn-square shrink-0",
                a.agent.continuous == true && "text-success"
              ]}
              title={
                if a.agent.continuous == true,
                  do: "Let this agent stop after its current turn",
                  else: "Put this agent to work — it picks its own next task"
              }
            >
              <.icon
                name={if a.agent.continuous == true, do: "hero-pause", else: "hero-play"}
                class="size-3"
              />
            </button>
            <button
              :if={!a.agent.retired_at}
              type="button"
              phx-click="toggle_agent_power"
              phx-value-agent-id={a.agent.id}
              data-test="team-agent-power"
              data-on={to_string(is_nil(a.agent.off_at))}
              class={[
                "btn btn-ghost btn-xs btn-square shrink-0",
                if(is_nil(a.agent.off_at), do: "text-success", else: "text-error")
              ]}
              aria-label={if is_nil(a.agent.off_at), do: "Turn agent off", else: "Turn agent on"}
              aria-pressed={to_string(is_nil(a.agent.off_at))}
              title={
                if is_nil(a.agent.off_at),
                  do: "On — turn this agent off",
                  else: "Off — turn this agent on"
              }
            >
              <.icon name="hero-power" class="size-3" />
            </button>
          </div>

          <div
            :if={a.task_label}
            data-test="team-agent-work"
            class="flex min-w-0 items-center gap-2 pb-1 pl-4 text-[11px]"
          >
            <button
              :if={a.task_label}
              type="button"
              phx-click="show_task"
              phx-value-agent-id={a.agent.id}
              data-test="team-agent-task"
              title="What this agent was handed"
              class="link link-hover truncate text-left opacity-50 hover:opacity-100"
            >
              {a.task_label}
            </button>
          </div>
        </div>

        <.link
          :if={copy.empty_seats != []}
          navigate={~p"/app/projects/#{@project_id}/working-copies/#{copy.row.harness.id}"}
          data-test="team-empty-seats"
          class="flex items-center gap-1.5 rounded py-1 pl-4 text-xs opacity-70 hover:bg-base-200"
        >
          <span class="min-w-0 flex-1 truncate">{Enum.join(copy.empty_seats, ", ")} — empty</span>
          <span class="shrink-0 text-primary">Staff it</span>
        </.link>
      </div>
    </div>
    """
  end

  attr :copy, :map, required: true
  attr :scope, :any, required: true
  attr :project_id, :string, required: true

  # What the copy is working on, on the copy's row: work is assigned to the
  # copy and blown through to its agents. The pie is greyed when nothing is.
  defp copy_assignment(%{copy: %{assignment: %{kind: :story} = story}} = assigns) do
    assigns = assign(assigns, :story, story)

    ~H"""
    <button
      type="button"
      phx-click="show_assigned"
      phx-value-kind="story"
      phx-value-key={@story.key}
      data-test="team-copy-story"
      title={@story.title}
      class="link link-hover shrink-0 font-mono font-normal opacity-70"
    >
      {@story.ref}
    </button>
    <.live_component
      module={CodeMySpecWeb.StoryProgress}
      id={"story-progress-copy-#{@copy.row.harness.id}"}
      scope={@scope}
      story_id={@story.story_id}
      working_copy_id={@story.working_copy_id}
    />
    """
  end

  # One issue is named and opens like a story; a bag of several is a count
  # that opens the copy's status page, which draws the whole bag.
  defp copy_assignment(%{copy: %{assignment: %{kind: :issues} = bag}} = assigns) do
    {done, total} = bag.progress
    assigns = assign(assigns, issues: bag.issues, done: done, total: total)

    ~H"""
    <button
      :if={match?([_], @issues)}
      type="button"
      phx-click="show_assigned"
      phx-value-kind="issue"
      phx-value-key={hd(@issues).id}
      data-test="team-copy-issue"
      title={hd(@issues).title}
      class="link link-hover shrink-0 font-mono font-normal opacity-70"
    >
      {String.slice(hd(@issues).id, 0, 8)}
    </button>
    <.link
      :if={not match?([_], @issues)}
      navigate={~p"/app/projects/#{@project_id}/working-copies/#{@copy.row.harness.id}/status"}
      data-test="team-copy-issues"
      class="link link-hover shrink-0 font-mono font-normal opacity-70"
    >
      {length(@issues)} issues
    </.link>
    <span
      data-test="team-copy-issue-progress"
      data-done={@done}
      data-total={@total}
      title={"#{@done} of #{@total} issue milestones done"}
      style={CodeMySpecWeb.StoryProgress.fill(@done, @total)}
      class={CodeMySpecWeb.StoryProgress.ring(@done, @total)}
    ></span>
    """
  end

  defp copy_assignment(assigns) do
    ~H"""
    <span
      data-test="team-copy-unassigned"
      title="Nothing assigned"
      class="inline-block size-3 shrink-0 rounded-full ring-1 ring-base-content/15 opacity-40"
    ></span>
    """
  end

  defp unread?(agent), do: Map.get(agent, :unread?, false)

  # A turn in flight, which is not a liveness state: a running agent is either
  # mid-turn or waiting, and the row says which apart from the label.
  defp turn_running?(%{agent: %{turn_started_at: at}}), do: not is_nil(at)

  attr :a, :map, required: true

  # Who the agent is, then its state as icons that only appear when they say
  # something: running and idle are the normal case and show nothing.
  defp agent_identity(assigns) do
    ~H"""
    <%!-- The kind first: fixed-width marks line up in a column, and the role,
    which varies, truncates at the end instead of pushing them around. --%>
    <span class="flex min-w-0 flex-1 items-center gap-1.5">
      <.agent_kind agent={@a.agent} />
      <span class="truncate">{@a.agent.role}</span>
    </span>
    <span
      :if={liveness_mark(@a.liveness) == :starting}
      data-test="team-agent-starting"
      title={liveness_title(@a.liveness)}
      class="flex shrink-0 opacity-60"
    >
      <.icon name="hero-ellipsis-horizontal" class="size-3.5" />
    </span>
    <span
      :if={liveness_mark(@a.liveness) == :gave_up}
      data-test="team-agent-gave-up"
      title={liveness_title(@a.liveness)}
      class="flex shrink-0 text-warning"
    >
      <.icon name="hero-exclamation-triangle" class="size-3.5" />
    </span>
    <span
      :if={turn_running?(@a)}
      data-test="team-agent-turn"
      title="Mid-turn"
      class="flex shrink-0 text-primary motion-safe:animate-pulse"
    >
      <.icon name="hero-chat-bubble-oval-left-ellipsis" class="size-3.5" />
    </span>
    <span
      :if={@a.agent.waiting_since}
      data-test="team-agent-waiting"
      title="Waiting on its person"
      class="flex shrink-0 text-warning"
    >
      <.icon name="hero-hand-raised" class="size-3.5" />
    </span>
    <span
      :if={@a.agent.current_tool}
      data-test="team-agent-tool"
      title="Running a tool"
      class="min-w-0 truncate font-mono text-[10px] opacity-60"
    >{@a.agent.current_tool}</span>
    """
  end

  attr :agent, :map, required: true

  # Internal agents run on Alloy, sometimes over Claude Code, so the provider
  # alone cannot say whether the harness runs the agent or a person does.
  defp agent_kind(%{agent: %{engine: :claude_code}} = assigns) do
    ~H"""
    <span
      data-test="team-agent-kind"
      data-external="true"
      title="External: a Claude Code session a person runs in a terminal"
      class="flex shrink-0 items-center opacity-60"
    >
      <.icon name="hero-command-line" class="size-3.5" />
    </span>
    """
  end

  defp agent_kind(assigns) do
    ~H"""
    <span
      data-test="team-agent-kind"
      data-external="false"
      data-provider={@agent.provider}
      title={"Internal: the harness runs this agent on Alloy, over " <> provider_label(@agent.provider)}
      class="flex shrink-0 items-center gap-0.5"
    >
      <span class="font-mono text-[11px] font-semibold tracking-tighter text-primary">|&gt;</span>
      <svg
        :if={provider_path(@agent.provider)}
        viewBox="0 0 24 24"
        fill="currentColor"
        fill-rule="evenodd"
        aria-hidden="true"
        class="size-3.5 shrink-0 opacity-60"
      >
        <path clip-rule="evenodd" d={provider_path(@agent.provider)} />
      </svg>
    </span>
    """
  end

  defp provider_label("claude-code"), do: "Claude Code"
  defp provider_label("openai-codex"), do: "Codex"
  defp provider_label("anthropic"), do: "the Anthropic API"
  defp provider_label("zai"), do: "Z.ai"
  defp provider_label(nil), do: "no provider"
  defp provider_label(other), do: other

  # Provider marks from Lobe Icons 1.95.1 (MIT, github.com/lobehub/lobe-icons),
  # one path each rather than the package.
  defp provider_path("claude-code"),
    do:
      "M20.998 10.949H24v3.102h-3v3.028h-1.487V20H18v-2.921h-1.487V20H15v-2.921H9V20H7.488v-2.921H6V20H4.487v-2.921H3V14.05H0V10.95h3V5h17.998v5.949zM6 10.949h1.488V8.102H6v2.847zm10.51 0H18V8.102h-1.49v2.847z"

  defp provider_path("openai-codex"),
    do:
      "M8.086.457a6.105 6.105 0 013.046-.415c1.333.153 2.521.72 3.564 1.7a.117.117 0 00.107.029c1.408-.346 2.762-.224 4.061.366l.063.03.154.076c1.357.703 2.33 1.77 2.918 3.198.278.679.418 1.388.421 2.126a5.655 5.655 0 01-.18 1.631.167.167 0 00.04.155 5.982 5.982 0 011.578 2.891c.385 1.901-.01 3.615-1.183 5.14l-.182.22a6.063 6.063 0 01-2.934 1.851.162.162 0 00-.108.102c-.255.736-.511 1.364-.987 1.992-1.199 1.582-2.962 2.462-4.948 2.451-1.583-.008-2.986-.587-4.21-1.736a.145.145 0 00-.14-.032c-.518.167-1.04.191-1.604.185a5.924 5.924 0 01-2.595-.622 6.058 6.058 0 01-2.146-1.781c-.203-.269-.404-.522-.551-.821a7.74 7.74 0 01-.495-1.283 6.11 6.11 0 01-.017-3.064.166.166 0 00.008-.074.115.115 0 00-.037-.064 5.958 5.958 0 01-1.38-2.202 5.196 5.196 0 01-.333-1.589 6.915 6.915 0 01.188-2.132c.45-1.484 1.309-2.648 2.577-3.493.282-.188.55-.334.802-.438.286-.12.573-.22.861-.304a.129.129 0 00.087-.087A6.016 6.016 0 015.635 2.31C6.315 1.464 7.132.846 8.086.457zm-.804 7.85a.848.848 0 00-1.473.842l1.694 2.965-1.688 2.848a.849.849 0 001.46.864l1.94-3.272a.849.849 0 00.007-.854l-1.94-3.393zm5.446 6.24a.849.849 0 000 1.695h4.848a.849.849 0 000-1.696h-4.848z"

  defp provider_path("zai"),
    do:
      "M12.105 2L9.927 4.953H.653L2.83 2h9.276zM23.254 19.048L21.078 22h-9.242l2.174-2.952h9.244zM24 2L9.264 22H0L14.736 2H24z"

  defp provider_path("anthropic"),
    do:
      "M13.827 3.52h3.603L24 20h-3.603l-6.57-16.48zm-7.258 0h3.767L16.906 20h-3.674l-1.343-3.461H5.017l-1.344 3.46H0L6.57 3.522zm4.132 9.959L8.453 7.687 6.205 13.48H10.7z"

  defp provider_path(_provider), do: nil

  # Running and Idle are the normal case; Starting and Gave up are worth an
  # icon; anything else (Away, Off, Stopped, Retired, Last heard from) means
  # the agent is not doing anything, which the dimmed row says.
  defp liveness_mark(%{label: label}) when label in ["Running", "Idle"], do: :none
  defp liveness_mark(%{label: "Starting"}), do: :starting
  defp liveness_mark(%{label: "Gave up" <> _}), do: :gave_up
  defp liveness_mark(_liveness), do: :dim

  defp dimmed?(a), do: liveness_mark(a.liveness) == :dim

  defp liveness_title(%{label: label, basis: basis}), do: "#{label}: #{basis}"

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
