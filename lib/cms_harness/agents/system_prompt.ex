defmodule CmsHarness.Agents.SystemPrompt do
  @moduledoc """
  The system prompt an agent starts with, assembled in three sections.

  Nothing was sent at all before this existed. `Alloy.Agent.Config` accepts a
  `:system_prompt` and defaults it to nil, and no caller ever set one — so an
  agent's role decided which tools it had and never what it was for. Issue
  `0f022a10`.

  ## General to specific

      §1  Universal    the loop, and how the machinery behaves
                       — the same for every agent on every project

      §2  Situational  what this project is, where its application runs,
                       which tools this machine offers
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
  @spec compose(keyword() | map()) :: String.t() | nil
  def compose(parts) when is_list(parts), do: parts |> Map.new() |> compose()

  def compose(parts) when is_map(parts) do
    [
      # §1 — universal
      parts[:universal],
      # §2 — situational
      project_brief(parts[:project_brief]),
      running_app(parts[:app_url]),
      parts[:tool_index],
      # §3 — role
      parts[:role_brief]
    ]
    |> Enum.reject(&(is_nil(&1) or String.trim(&1) == ""))
    |> case do
      [] -> nil
      sections -> Enum.join(sections, "\n\n")
    end
  end

  # Headed, because it arrives between the framework's rules and the agent's own
  # brief and without a heading it reads as a continuation of whichever it is
  # nearer. The wording says "may be out of date" on purpose: it is prose nobody
  # verifies, and an agent that treats it as authoritative over what it can see
  # in the code will act on a stale claim. Measured 2026-09-20 — 7 of 76
  # projects had written one at all, and the longest contradicted the tool index
  # printed directly beneath it.
  defp project_brief(text) when is_binary(text) and text != "" do
    """
    ## The project

    #{String.trim(text)}

    That is the project's own description of itself. It is prose, not something
    derived from the code, so prefer what you can see in the repository where
    the two disagree.
    """
    |> String.trim()
  end

  defp project_brief(_), do: nil

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
end
