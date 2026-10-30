defmodule CodeMySpec.Hooks.AgentBriefing do
  @moduledoc """
  The system prompt an agent starts with, assembled in three sections.

  Nothing was sent at all before this existed. `Alloy.Agent.Config` accepts a
  `:system_prompt` and defaults it to nil, and no caller ever set one — so an
  agent's role decided which tools it had and never what it was for. Issue
  `0f022a10`.

  ## General to specific

      §1  Universal    the loop, and how the machinery behaves
                       — the same for every agent on every project

      §2  Situational  where this project's application runs,
                       which tools this machine offers, and how a tool call
                       happens on the engine running this agent
                       — the same for every agent on this checkout

      §3  Role         what this agent in particular is for

  The order is the point. A model reads the top of a prompt hardest, and what
  an agent needs first is the loop it is in — ask what the work is, claim it,
  do it, stop. What it *is* comes last, because it is the most specific thing
  and nothing after it should qualify it.

  ## Every section is resolved by the server

  This module orders and joins. It does not read, look up or decide, and that
  is deliberate: role semantics belong beside the tool list that enforces them,
  the loop belongs with the machinery that enforces it, and the project's
  description is a column. None of it is knowable from a machine, and a second
  place to write any of it is a second place for it to drift.

  ## The project's guide is no longer read off disk

  `compose/4` used to append `.code_my_spec/AGENTS.md` from the working copy.
  That made the most basic instruction an agent has — claim work before doing
  it — conditional on a file the checkout might not have.

  It frequently did not. Story 1039's behavioural eval builds its checkout with
  `File.mkdir_p!` and nothing else, so the read returned `nil` and the agent was
  measured on a prompt that never told it to claim anything; the criterion
  asserting it calls `get_next_requirement` then `start_task` would have been
  scoring a guess. Every project that had not run `install_agents_md` shipped
  the same gap in production.

  The loop moved into §1, where it ships with every agent. `AGENTS.md` remains
  the guide handed to *external* agents, and is generated from the same source
  rather than being the source.
  """

  @doc """
  The prompt for one agent, or `nil` when there is nothing worth saying.

  `nil` rather than an empty string: it is what `Alloy.Agent.Config` already
  defaults to, so an agent we have nothing to tell is exactly as it was before
  this existed.

  Every key is optional, and a section with nothing in it contributes nothing
  rather than an empty heading — a machine with no browser and one that never
  reported are different states, and only one of them is a fault.
  """
  @spec for_request(map(), String.t() | nil) :: String.t() | nil
  def for_request(request, scratch_dir \\ nil) when is_map(request) do
    compose(
      universal: field(request, :universal),
      provider_brief: field(request, :provider_brief),
      app_url: field(request, :app_url),
      scratch_dir: scratch_dir,
      tool_index: field(request, :tool_index),
      role_brief: field(request, :role_brief)
    )
  end

  defp field(request, key), do: Map.get(request, key) || Map.get(request, Atom.to_string(key))

  @spec compose(keyword() | map()) :: String.t() | nil
  def compose(parts) when is_list(parts), do: parts |> Map.new() |> compose()

  def compose(parts) when is_map(parts) do
    [
      # §1 — universal
      parts[:universal],
      # §2 — situational
      running_app(parts[:app_url]),
      scratch_dir(parts[:scratch_dir]),
      parts[:tool_index],
      # Beside the index, because it is about that list: where it arrives and
      # what to conclude when a name seems absent from it.
      parts[:provider_brief],
      # §3 — role
      parts[:role_brief]
    ]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end

  # Where the application is, so an agent testing it can open it.
  #
  # It cannot work this out. The address is a column on the project's main
  # working copy — `preview_url`, written when the harness brings a preview up —
  # and nothing on this side can see the database. So a QA agent with the
  # browser bound and 77 tools ready reported "no app URL has been identified"
  # and stopped, correctly refusing to guess, while the app was up the whole
  # time.
  #
  # Always the main checkout's, whichever copy the agent is working in.
  # `record_preview_url/2` matches `main: true` and refuses everything else, so
  # a worktree has no preview of its own — the app runs on the main copy under
  # the harness, and that is the address there is.
  #
  # Nil says nothing at all rather than "there is no app", because those are
  # different and only one of them is knowable from here: a project between
  # previews looks identical to one that never had them.
  defp running_app(url) when is_binary(url) and url != "" do
    """
    The application you are working on is running at #{url}.

    That is the main checkout's preview, served under the harness — it is the
    address to point a browser at, whichever working copy you are in. Your own
    copy does not serve one.
    """
    |> String.trim()
  end

  defp running_app(_url), do: nil

  # f72b7ba3: a fixture built through bash (a guardrail, not a sandbox -- it
  # can write anywhere) was then refused by the read tool, which only allows
  # the working copy and a couple of fixed, per-agent directories. QA builds
  # disposable fixtures -- a mock server, its log -- to test against, and had
  # no way to know in advance which path, if any, it could read one back from.
  defp scratch_dir(path) when is_binary(path) and path != "" do
    """
    A disposable fixture you build through `bash` to test against -- a mock
    server, its log, anything you need to inspect afterward -- is only
    readable back if you put it under #{path}. Anywhere else, including an
    ad hoc `mktemp` path, your read tool will refuse it once bash is done
    writing it.
    """
    |> String.trim()
  end

  defp scratch_dir(_), do: nil
end
