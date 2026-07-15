defmodule CodeMySpecWeb.ContentLive.Pages.EarWitness do
  @moduledoc """
  Live-build case-study page for EarWitness.

  Unlike the completed teardowns, this page ships while the build is
  running: the requirements (10 stories with full Three Amigos records,
  exported from the harness database) are the centerpiece, and the
  dev-story teardown lands after the build ships. Stories fixture loads
  compile-time from the sibling `ear_witness_stories.exs`; regenerate it
  from the harness DB as the build progresses.
  """

  use CodeMySpecWeb, :live_view

  alias CodeMySpecWeb.Layouts

  @reddit_thread "https://www.reddit.com/r/ClaudeAI/comments/1utrsu7/live_build_im_having_claude_build_earwitness_a/"

  @external_resource stories_path =
                       Path.join(__DIR__, "ear_witness_stories.exs")

  @stories (case Code.eval_file(stories_path) do
              {stories, _} -> stories
            end)

  @copy %{
    metadata: %{
      meta_title: "EarWitness Live Build: A Local-First Otter Alternative, Built by the Harness",
      meta_description:
        "A live CodeMySpec build, happening now. EarWitness transcribes, segments, and diarizes speakers on your machine, taps your audio so meetings record without a bot, and exposes your conversations to Claude over MCP. 11 stories, 62 Three Amigos rules, 67 acceptance criteria, 4 stories browser-QA passed and 5 more in flight.",
      og_title: "EarWitness Live Build — The Requirements, Before the Code",
      og_description:
        "A local-first Otter alternative being built live by the CodeMySpec harness. 11 stories, 62 rules, 67 BDD criteria, statuses updating as the build runs. Follow the build on Reddit; download the releases as they land.",
      og_image: nil,
      author: "John Davenport",
      tags: [
        "case-study",
        "ear-witness",
        "live-build",
        "phoenix",
        "elixir",
        "transcription",
        "diarization",
        "local-first",
        "mcp",
        "three-amigos"
      ]
    },
    hero: %{
      title: "EarWitness",
      tagline: "A local-first Otter alternative, being built live. These are the requirements.",
      description:
        "EarWitness transcribes, segments, and diarizes speakers entirely on your machine, live while the recording runs. An audio tap records the meetings you're in without a bot in the participant list, with a recording notice participants actually hear. An Otter-style editor fixes speakers and prose, and MCP tools let Claude work your conversation data. The harness is building it live: the 11 stories below, with their Three Amigos rules and given-when-then scenarios, are the real records driving the build, and their statuses update as stories pass browser QA. The teardown lands here when it ships.",
      stats: [
        %{label: "Stories QA-Passed", value: "4 of 11"},
        %{label: "Three Amigos Rules", value: "62"},
        %{label: "Acceptance Criteria", value: "67"},
        %{label: "Spex Green", value: "75"}
      ]
    },
    overview: %{
      title: "What is EarWitness?",
      description:
        "Everything local: the audio, the models, the transcripts, the search index. Nothing leaves your machine. Two personas drive the requirements: Dana the Hearing Documenter, whose work depends on knowing who said what and who can't hand recordings to a cloud service, and Marcus the Meeting-Heavy Builder, who lives in back-to-back calls and wants them captured without a bot in the room.",
      integrations: [
        %{
          name: "Audio Tap",
          description: "Captures system audio so your meetings record without a bot in the room",
          icon: "hero-speaker-wave"
        },
        %{
          name: "Local Models",
          description: "Transcription, segmentation, and diarization run on your machine",
          icon: "hero-cpu-chip"
        },
        %{
          name: "MCP",
          description: "Claude and friends get tools to search and work your conversation data",
          icon: "hero-command-line"
        },
        %{
          name: "Live Transcription",
          description: "Transcribe and segment while the recording is still running",
          icon: "hero-bolt"
        },
        %{
          name: "Editor",
          description:
            "Otter-style: fix speaker labels, clean up prose, keep the record straight",
          icon: "hero-pencil-square"
        },
        %{
          name: "Desktop",
          description: "Elixir LiveView desktop app with a local SQLite store",
          icon: "hero-computer-desktop"
        }
      ],
      key_features: [
        "Transcribe hearing recordings locally, no cloud, no upload",
        "Capture your own meetings via audio tap, without a bot interfering",
        "Speaker diarization: know who said what",
        "Fix the transcript like Otter: speakers, prose, structure",
        "Search everything ever said",
        "Recordings organized and durable",
        "A working transcriber minutes after install",
        "Recording-law awareness built into the product",
        "Your AI assistant works your conversations over MCP",
        "A recording notice participants actually hear",
        "Live transcription and segmentation while recording"
      ]
    },
    repository: %{
      title: "Open Source Repository",
      description:
        "EarWitness is open source and being built in the open. Releases land as the build progresses: download, break it, and report back. If you have requirements you want in a local transcription app, surface them in the thread and they'll be considered for the story map.",
      url: "https://github.com/Code-My-Spec/ear_witness",
      stats: [
        %{label: "Language", value: "Elixir / Phoenix"},
        %{label: "Build Status", value: "Live"},
        %{label: "Commits", value: "111"},
        %{label: "Spex", value: "75 green"}
      ]
    }
  }

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.marketing flash={@flash} current_scope={@current_scope}>
      {hero_section(assigns)}
      {overview_section(assigns)}
      {stories_section(assigns)}
      {repository_section(assigns)}
      {follow_section(assigns)}

      <.stories_modal :if={@show_stories_modal} stories={@stories} />
    </Layouts.marketing>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    stories = @stories
    base_url = CodeMySpecWeb.Endpoint.url()

    json_ld =
      Jason.encode!([
        %{
          "@context" => "https://schema.org",
          "@type" => "Article",
          "@id" => "#{base_url}/case-studies/ear-witness",
          "headline" => @copy.metadata.meta_title,
          "description" => @copy.metadata.meta_description,
          "url" => "#{base_url}/case-studies/ear-witness",
          "image" => %{
            "@type" => "ImageObject",
            "url" => CodeMySpecWeb.ImageUrl.image_url("og-earwitness.png", base_url),
            "width" => 1200,
            "height" => 630
          },
          "datePublished" => "2026-07-11T00:00:00Z",
          "dateModified" => "2026-07-11T00:00:00Z",
          "author" => %{
            "@type" => "Person",
            "@id" => "#{base_url}/author/john-davenport",
            "name" => "John Davenport",
            "url" => "#{base_url}/author/john-davenport"
          },
          "publisher" => %{
            "@type" => "Organization",
            "@id" => "#{base_url}/#organization",
            "name" => "CodeMySpec",
            "logo" => %{
              "@type" => "ImageObject",
              "url" => "#{base_url}/images/logo-300.png",
              "width" => 300,
              "height" => 300
            }
          },
          "mainEntityOfPage" => %{
            "@type" => "WebPage",
            "@id" => "#{base_url}/case-studies/ear-witness"
          },
          "articleSection" => "Case Studies"
        },
        %{
          "@context" => "https://schema.org",
          "@type" => "BreadcrumbList",
          "itemListElement" => [
            %{"@type" => "ListItem", "position" => 1, "name" => "Home", "item" => base_url},
            %{
              "@type" => "ListItem",
              "position" => 2,
              "name" => "Case Studies",
              "item" => "#{base_url}/case-studies"
            },
            %{
              "@type" => "ListItem",
              "position" => 3,
              "name" => "EarWitness",
              "item" => "#{base_url}/case-studies/ear-witness"
            }
          ]
        }
      ])

    {:ok,
     socket
     |> assign(:copy, @copy)
     |> assign(@copy.metadata)
     |> assign(:stories, stories)
     |> assign(:reddit_thread, @reddit_thread)
     |> assign(:show_stories_modal, false)
     |> assign(:canonical_url, "#{base_url}/case-studies/ear-witness")
     |> assign(:og_image, CodeMySpecWeb.ImageUrl.image_url("og-earwitness.png", base_url))
     |> assign(:og_type, "article")
     |> assign(:article_published_time, "2026-07-11T00:00:00Z")
     |> assign(:json_ld, json_ld)}
  end

  @impl true
  def handle_event("open_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, true)}
  end

  def handle_event("close_stories", _params, socket) do
    {:noreply, assign(socket, :show_stories_modal, false)}
  end

  defp hero_section(assigns) do
    ~H"""
    <div class="hero mb-16">
      <div class="hero-content text-center">
        <div class="max-w-4xl">
          <div class="badge badge-error badge-lg mb-4 gap-2">
            <span class="relative flex h-2 w-2">
              <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-error-content opacity-75">
              </span>
              <span class="relative inline-flex rounded-full h-2 w-2 bg-error-content"></span>
            </span>
            Live Build
          </div>
          <h1 class="text-5xl md:text-6xl font-extrabold mb-4 bg-gradient-to-r from-primary to-secondary bg-clip-text text-transparent">
            {@copy.hero.title}
          </h1>
          <p class="text-2xl md:text-3xl font-bold mb-4 text-base-content">
            {@copy.hero.tagline}
          </p>
          <p class="text-xl mb-10 text-base-content/70 max-w-2xl mx-auto">
            {@copy.hero.description}
          </p>

          <div class="stats stats-horizontal bg-base-100 shadow border border-base-300">
            <%= for stat <- @copy.hero.stats do %>
              <div class="stat px-8 py-4">
                <div class="stat-value text-primary text-2xl">{stat.value}</div>
                <div class="stat-desc text-base-content/60 text-sm">{stat.label}</div>
              </div>
            <% end %>
          </div>

          <div class="mt-8 flex flex-wrap justify-center gap-3">
            <a
              href={@reddit_thread}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-primary btn-lg gap-2"
            >
              <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" /> Follow the Build on Reddit
            </a>
            <a
              href={@copy.repository.url}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-outline btn-lg gap-2"
            >
              <.icon name="hero-arrow-top-right-on-square" class="w-5 h-5" /> View on GitHub
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp overview_section(assigns) do
    ~H"""
    <div class="mb-16" id="overview">
      <div class="text-center mb-10">
        <h2 class="text-4xl font-bold mb-4">{@copy.overview.title}</h2>
        <p class="text-xl text-base-content/70 max-w-3xl mx-auto">
          {@copy.overview.description}
        </p>
      </div>

      <div class="flex flex-wrap justify-center gap-6 mb-10">
        <%= for integration <- @copy.overview.integrations do %>
          <div class="card bg-base-100 shadow-lg border border-base-300 hover:shadow-xl transition-shadow w-48">
            <div class="card-body items-center text-center p-5">
              <.icon name={integration.icon} class="w-10 h-10 text-primary mb-2" />
              <h3 class="font-bold text-sm">{integration.name}</h3>
              <p class="text-xs text-base-content/60">{integration.description}</p>
            </div>
          </div>
        <% end %>
      </div>

      <div class="card bg-base-100 shadow-lg border border-base-300 max-w-3xl mx-auto">
        <div class="card-body">
          <h3 class="card-title text-lg mb-3">
            <.icon name="hero-list-bullet" class="w-5 h-5 text-primary" /> The Story Map
          </h3>
          <ul class="space-y-2">
            <%= for feature <- @copy.overview.key_features do %>
              <li class="flex items-start gap-3">
                <.icon
                  name="hero-arrow-path"
                  class="w-5 h-5 text-info flex-shrink-0 mt-0.5"
                />
                <span class="text-base-content/80">{feature}</span>
              </li>
            <% end %>
          </ul>
        </div>
      </div>
    </div>
    """
  end

  defp stories_section(assigns) do
    total_criteria = Enum.reduce(assigns.stories, 0, fn s, acc -> acc + length(s.criteria) end)

    total_rules =
      Enum.reduce(assigns.stories, 0, fn s, acc ->
        acc + length(get_in(s, [:three_amigos, :rules]) || [])
      end)

    assigns =
      assigns
      |> assign(:total_criteria, total_criteria)
      |> assign(:total_rules, total_rules)

    ~H"""
    <div class="mb-16" id="stories">
      <div class="card bg-base-100 shadow-xl border-2 border-primary max-w-3xl mx-auto">
        <div class="card-body p-8 text-center">
          <h2 class="text-3xl font-bold mb-4">
            <.icon name="hero-clipboard-document-list" class="w-8 h-8 text-primary inline" />
            The Requirements, Before the Code
          </h2>
          <p class="text-base-content/70 mb-6">
            Each story carries its persona, its Three Amigos rules, full given-when-then scenarios, and its acceptance criteria, exported straight from the harness database while the build runs. Stories waiting their turn at Three Amigos show up too, empty and marked as such. When implementation starts, these become the BDD specs; when specs pass, browser QA verifies each story against the running app. Watch the statuses change as the build progresses.
          </p>

          <div class="stats bg-base-200 shadow mb-6">
            <div class="stat">
              <div class="stat-value text-primary">{length(@stories)}</div>
              <div class="stat-desc">Stories</div>
            </div>
            <div class="stat">
              <div class="stat-value text-secondary">{@total_rules}</div>
              <div class="stat-desc">Rules</div>
            </div>
            <div class="stat">
              <div class="stat-value text-accent">{@total_criteria}</div>
              <div class="stat-desc">Acceptance Criteria</div>
            </div>
          </div>

          <button class="btn btn-primary btn-lg gap-2" phx-click="open_stories">
            <.icon name="hero-book-open" class="w-5 h-5" /> Browse Stories &amp; Three Amigos
          </button>
        </div>
      </div>
    </div>
    """
  end

  defp repository_section(assigns) do
    ~H"""
    <div class="mb-16" id="repository">
      <div class="card bg-gradient-to-br from-base-200 to-base-100 shadow-xl border border-base-300 max-w-3xl mx-auto">
        <div class="card-body p-6 lg:p-8">
          <div class="flex flex-col sm:flex-row items-start sm:items-center gap-6">
            <div class="flex-1">
              <h2 class="text-2xl font-bold mb-2 flex items-center gap-2">
                <.icon name="hero-code-bracket" class="w-6 h-6 text-primary" />
                {@copy.repository.title}
              </h2>
              <p class="text-base text-base-content/70 mb-4">{@copy.repository.description}</p>
              <a
                href={@copy.repository.url}
                target="_blank"
                rel="noopener noreferrer"
                class="btn btn-primary btn-sm gap-2"
              >
                <.icon name="hero-arrow-top-right-on-square" class="w-4 h-4" /> View on GitHub
              </a>
            </div>
            <div class="grid grid-cols-2 gap-2 flex-shrink-0">
              <%= for stat <- @copy.repository.stats do %>
                <div class="bg-base-100 rounded-box px-3 py-2 text-center border border-base-300">
                  <div class="text-xs font-bold text-primary">{stat.value}</div>
                  <div class="text-[10px] text-base-content/50 leading-tight">{stat.label}</div>
                </div>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp follow_section(assigns) do
    ~H"""
    <div class="mb-16" id="follow">
      <div class="card bg-gradient-to-r from-primary/10 to-secondary/10 border border-primary/20 shadow-xl max-w-3xl mx-auto">
        <div class="card-body text-center">
          <h2 class="card-title text-2xl justify-center">The teardown lands here</h2>
          <p class="text-lg text-base-content/80">
            Every completed harness build gets the honest treatment: The Good, The Bad, and The Ugly, with the measured human-vs-agent character split. Cleaner CRM measured 0.4%, Legwork 2.1%, Keel 2.9%. EarWitness gets its number when it ships. Until then, the build updates live on Reddit.
          </p>
          <div class="card-actions justify-center mt-4 flex-wrap">
            <a
              href={@reddit_thread}
              target="_blank"
              rel="noopener noreferrer"
              class="btn btn-primary gap-2"
            >
              <.icon name="hero-chat-bubble-left-right" class="w-5 h-5" /> Follow the Live Build
            </a>
            <a href="/case-studies" class="btn btn-outline gap-2">
              <.icon name="hero-book-open" class="w-5 h-5" /> Read the Finished Teardowns
            </a>
          </div>
        </div>
      </div>
    </div>
    """
  end

  defp story_status_badge(%{status: :completed} = assigns) do
    ~H"""
    <div class="badge badge-success badge-sm gap-1">
      <.icon name="hero-check" class="w-3 h-3" /> Done
    </div>
    """
  end

  defp story_status_badge(%{status: :in_progress} = assigns) do
    ~H"""
    <div class="badge badge-info badge-sm gap-1">
      <.icon name="hero-arrow-path" class="w-3 h-3" /> In Progress
    </div>
    """
  end

  defp story_status_badge(assigns) do
    ~H"""
    <div class="badge badge-ghost badge-sm">New</div>
    """
  end

  attr :stories, :list, required: true

  defp stories_modal(assigns) do
    ~H"""
    <div class="modal modal-open">
      <div class="modal-box max-w-4xl max-h-[85vh]">
        <div class="flex items-center justify-between mb-6 sticky top-0 bg-base-100 pb-4 z-10 border-b border-base-300">
          <h3 class="font-bold text-2xl">
            <.icon name="hero-clipboard-document-list" class="w-6 h-6 text-primary inline" />
            EarWitness Stories ({length(@stories)})
          </h3>
          <button class="btn btn-sm btn-circle btn-ghost" phx-click="close_stories">
            <.icon name="hero-x-mark" class="w-5 h-5" />
          </button>
        </div>

        <div class="space-y-3 overflow-y-auto">
          <%= for story <- @stories do %>
            <div class="collapse collapse-arrow bg-base-200 border border-base-300">
              <input type="checkbox" />
              <div class="collapse-title">
                <div class="flex items-center justify-between pr-4">
                  <div class="flex-1">
                    <span class="font-semibold text-base">
                      <span class="text-base-content/40 mr-2">#{story.story_id}</span>{story.title}
                    </span>
                  </div>
                  <div class="flex items-center gap-2 ml-4 flex-shrink-0">
                    <div :if={specced?(story)} class="badge badge-accent badge-sm gap-1">
                      <.icon name="hero-users" class="w-3 h-3" /> 3A
                    </div>
                    <div :if={!specced?(story)} class="badge badge-ghost badge-sm gap-1">
                      <.icon name="hero-clock" class="w-3 h-3" /> Awaiting 3A
                    </div>
                    <.story_status_badge status={story.status} />
                    <div :if={story.criteria != []} class="badge badge-outline badge-sm gap-1">
                      <.icon name="hero-clipboard-document-check" class="w-3 h-3" />
                      {length(story.criteria)}
                    </div>
                  </div>
                </div>
              </div>
              <div class="collapse-content">
                <p class="text-base-content/80 mb-4 leading-relaxed">
                  {story.description}
                </p>

                <div :if={story.tags != []} class="mb-4 flex flex-wrap gap-1">
                  <span :for={tag <- story.tags} class="badge badge-sm badge-outline">
                    {tag.name}
                  </span>
                </div>

                <%= if Map.get(story, :qa) do %>
                  <div class="mb-4 flex items-center gap-2 flex-wrap">
                    <span class="text-xs font-semibold text-base-content/60">Browser QA:</span>
                    <span :for={attempt <- story.qa.history} class={qa_badge_class(attempt)}>
                      {attempt}
                    </span>
                  </div>
                <% end %>

                <%= if story.criteria != [] do %>
                  <h4 class="font-semibold mb-2 text-sm">Acceptance Criteria:</h4>
                  <ul class="space-y-1.5 text-base-content/80 mb-4">
                    <%= for criterion <- story.criteria do %>
                      <li class="flex items-center gap-2 text-sm">
                        <.icon
                          :if={criterion.verified}
                          name="hero-lock-closed"
                          class="size-3 text-success inline flex-shrink-0"
                        />
                        <.icon
                          :if={!criterion.verified}
                          name="hero-minus-circle"
                          class="size-3 text-base-content/30 inline flex-shrink-0"
                        />
                        <span class={[criterion.verified && "font-medium"]}>
                          {criterion.description}
                        </span>
                      </li>
                    <% end %>
                  </ul>
                <% end %>

                <.three_amigos_block :if={specced?(story)} three_amigos={story.three_amigos} />

                <p
                  :if={!specced?(story)}
                  class="mt-4 pt-4 border-t border-base-300 text-sm text-base-content/50 italic"
                >
                  This story hasn't run Three Amigos yet. Its rules, scenarios, and acceptance criteria appear here once it does.
                </p>
              </div>
            </div>
          <% end %>
        </div>
      </div>
      <div class="modal-backdrop" phx-click="close_stories"></div>
    </div>
    """
  end

  defp specced?(story) do
    case Map.get(story, :three_amigos) do
      nil -> false
      ta -> ta.rules != [] or not is_nil(ta.persona)
    end
  end

  attr :three_amigos, :map, required: true

  defp three_amigos_block(assigns) do
    ~H"""
    <div class="mt-4 pt-4 border-t border-base-300">
      <div class="flex items-center justify-between mb-3">
        <h4 class="font-semibold text-sm flex items-center gap-2">
          <.icon name="hero-users" class="w-4 h-4 text-accent" /> Three Amigos Records
        </h4>
      </div>

      <div :if={@three_amigos.persona} class="card bg-base-100 border border-base-300 mb-3">
        <div class="card-body p-3">
          <div class="flex items-center justify-between">
            <div class="flex items-center gap-2">
              <.icon name="hero-user-circle" class="w-5 h-5 text-primary" />
              <span class="font-semibold text-sm">{@three_amigos.persona.name}</span>
              <span class="text-xs text-base-content/50">@{@three_amigos.persona.slug}</span>
            </div>
            <span class="badge badge-outline badge-xs">{@three_amigos.persona.type}</span>
          </div>
        </div>
      </div>

      <div :if={@three_amigos.rules != []} class="mb-3">
        <h5 class="text-sm font-semibold text-base-content/70 mb-2">
          Rules &amp; Scenarios
        </h5>
        <div class="space-y-2">
          <%= for {rule, idx} <- Enum.with_index(@three_amigos.rules, 1) do %>
            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-3">
                <div class="flex gap-2 items-start">
                  <span class="badge badge-info badge-sm flex-shrink-0">R{idx}</span>
                  <span class="text-sm leading-relaxed">{rule.statement}</span>
                </div>

                <div :if={rule.scenarios != []} class="mt-3 ml-6 space-y-2">
                  <%= for scenario <- rule.scenarios do %>
                    <div class="bg-base-200 rounded p-2 border-l-2 border-accent">
                      <div class="flex items-center gap-2 mb-1">
                        <span class="badge badge-accent badge-xs">{scenario.kind}</span>
                        <span class="text-xs font-medium">{scenario.title}</span>
                      </div>
                      <pre
                        :if={scenario.body}
                        class="text-xs whitespace-pre-wrap text-base-content/80 mt-1 font-mono leading-relaxed"
                      >{scenario.body}</pre>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>

      <div :if={@three_amigos.questions != []} class="mb-3">
        <h5 class="text-sm font-semibold text-base-content/70 mb-2">
          Questions
        </h5>
        <div class="space-y-2">
          <%= for {question, idx} <- Enum.with_index(@three_amigos.questions, 1) do %>
            <div class="card bg-base-100 border border-base-300">
              <div class="card-body p-3">
                <div class="flex gap-2 items-start mb-2">
                  <span class="badge badge-warning badge-sm flex-shrink-0">Q{idx}</span>
                  <span class="text-sm leading-relaxed flex-1">{question.body}</span>
                  <span class={"badge badge-xs flex-shrink-0 #{question_status_class(question.status)}"}>
                    {question.status}
                  </span>
                </div>
              </div>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp qa_badge_class("pass"), do: "badge badge-success badge-xs"
  defp qa_badge_class("fail"), do: "badge badge-error badge-xs"
  defp qa_badge_class("partial"), do: "badge badge-warning badge-xs"
  defp qa_badge_class(atom) when is_atom(atom), do: qa_badge_class(Atom.to_string(atom))
  defp qa_badge_class(_), do: "badge badge-ghost badge-xs"

  defp question_status_class(:resolved), do: "badge-success"
  defp question_status_class(:open), do: "badge-warning"
  defp question_status_class(_), do: "badge-ghost"
end
