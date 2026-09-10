defmodule CodeMySpec.Analysis.Alert do
  @moduledoc """
  Tells an agent, on its next tool call, that an analyzer run has landed.

  ## Why it lives here and not in `Hooks`

  It was `Hooks.AnalysisAlert`, because a hook was the only thing that delivered
  it. That stopped being true: an agent running under Alloy fires none of Claude
  Code's seven hooks, and its tool results are the surface that reaches it —
  `McpServers.AgentAlert` is the second transport.

  `Hooks` is a top-level boundary that depends on `McpServers`, so `McpServers`
  cannot reach back into it. Boundary refused the reference and was right to:
  the message is not a hook's, it is analysis's, and both transports render the
  same one. That is the persona split from story 890 arriving as a compile
  error.

  `Hooks.AnalysisAlert` remains as a delegating shim, so the external path and
  everything that names it are untouched.

  ## Why this exists at all

  Analyzers run async and the only place a result was ever delivered was the
  next stop hook — one turn late by construction, and free if the agent never
  stops again. On 2026-08-12 a schema change took the spex suite from 7 failures
  to 25; `mix test` was green across eight runs, the change was committed, and
  the spex answer that would have caught it was ~126 seconds away the whole
  time. Nothing asked for it and nothing handed it over.

  The stop hook is not a backstop for that window, and measurement says so
  rather than argument: the three stop decisions inside it all allowed, two for
  "Active subagent task" and one for "analysis pending". The second is
  structural — `analysis pending` *is* the state right after code changes,
  because changing code is what makes analysis pending. The gate is reliably
  open at the only moment it matters.

  ## The shape

  Push the fact, pull the detail. The alert names the analyzer, the count and
  the age, and nothing else; `list_problems` is one tool call away for anything
  more. A finding list on every tool call is noise the model learns to skip,
  which costs the signal a second time and more permanently than never sending
  it.

  Scoped to the **working copy**, never to a session or an edited file. That is
  the grain story 1000 established, and narrowing it here would reproduce
  `split_unattributed`, which turned `spex: block_all` into a no-op for months
  by deciding on the agent's behalf whose a finding was.
  """

  alias CodeMySpec.Problems
  alias CodeMySpec.Users.Scope
  alias CodeMySpec.Validation

  @doc """
  A one-line alert for this session, or `nil` when there is nothing new to say.

  Silent in three cases, and each is deliberate:

    * no run has landed since this session was last told — repeating the same
      line on every tool call in a turn is how a signal becomes wallpaper;
    * the run landed clean — "your fix worked" is real information and still not
      worth a line, because announcing every green run teaches the model to skip
      the channel, and then the red one arrives where nobody reads;
    * the caller names no session, so there is nobody to have told.

  The silent path costs **one** query — the watermark below — because this runs
  before every Read, Grep and Bash in the system. A check that made every tool
  call feel slow would be switched off, and a disabled gate ends where
  `split_unattributed` ended.
  """
  @spec check(Scope.t(), String.t() | nil, String.t() | nil) :: String.t() | nil
  def check(scope, session_id, agent_id \\ nil)

  # Nobody to have told. A session id or an agent id will do — an external agent
  # has the first, an agent running under Alloy has only the second, and either
  # is enough to be a recipient. Requiring the session was what made this
  # unreachable for half the agents on the product: `check/2` answered `nil` for
  # every internal agent no matter what its analyzers had found.
  def check(_scope, nil, nil), do: nil

  def check(%Scope{active_working_copy_id: working_copy_id} = scope, session_id, agent_id)
      when is_binary(working_copy_id) and (is_binary(session_id) or is_binary(agent_id)) do
    # The cheap read: one indexed query for this working copy's problem count
    # and the most recent change among them. Nothing is loaded.
    case Problems.watermark(scope) do
      {0, _} ->
        # Nothing to say. Also the clean-run case — a green run leaves no
        # problems, and "your fix worked" is not worth a line.
        nil

      {_count, nil} ->
        nil

      {_count, latest} = mark ->
        who = {working_copy_id, session_id, agent_id}

        if already_told?(who, mark) do
          nil
        else
          record(who, mark)
          cached_message(working_copy_id, mark, scope, latest)
        end
    end
  end

  def check(_scope, _session_id, _agent_id), do: nil

  # Per *agent*, and deliberately not per working copy: two agents in one
  # checkout are told independently. Dedup of *notification*, never filtering of
  # *content* — nothing is withheld, and no finding can hide behind "somebody
  # was already notified".
  #
  # The agent id is in the key because a session id is not an agent identity. A
  # Task-spawned subagent shares its parent's session — `PostToolUse` says so in
  # its own moduledoc, and keys file edits on `(session_id, agent_id, file_path)`
  # for exactly that reason — so keying on the session alone made a main agent
  # and its subagent in one checkout collide: whichever was told first silenced
  # the other until the watermark moved. Story 890's criteria 2340 and 2341 were
  # false by construction, while this comment claimed the opposite.
  #
  # `nil` is the main agent's own key component, so it dedupes exactly as before.
  #
  # In memory because it is worth exactly one duplicate alert after a restart,
  # which is cheaper than a column and a write on every tool call.
  defp already_told?({_copy, _session, _agent} = who, mark) do
    :persistent_term.get({__MODULE__, who}, nil) == mark
  end

  defp record({_copy, _session, _agent} = who, mark) do
    :persistent_term.put({__MODULE__, who}, mark)
  end

  # One landing, one rendering. `message/2` is otherwise recomputed per
  # caller, and its `age()` term is seconds since `DateTime.utc_now()` — two
  # recipients told about the same mark a moment apart can straddle a second
  # boundary and be handed different text for the same event. The transports
  # differ; the words must not, so the first caller to render a mark decides
  # it for every caller after, until the mark itself moves.
  defp cached_message(working_copy_id, mark, scope, latest) do
    key = {__MODULE__, :message, working_copy_id, mark}

    case :persistent_term.get(key, :unset) do
      :unset ->
        text = message(scope, latest)
        :persistent_term.put(key, text)
        text

      text ->
        text
    end
  end

  # Sources named, counts only, no file paths. The detail is one `list_problems`
  # away, and a finding list on every tool call is noise the model learns to
  # skip — which costs the signal a second time and more permanently.
  # Counts what the gate would actually enforce, not everything recorded.
  #
  # A spex failure on a story whose specs have never gone green is *supposed* to
  # be red — it is the red bar driving an implementation nobody has written yet
  # — and `Validation` already demotes those to advisory. Counting them here put
  # a number in the alert that no agent could ever act on, and one that never
  # changes: every agent on this project saw `spex: 6` on its first tool call
  # and would keep seeing it until an unrelated team finished a devops story.
  #
  # That is the wallpaper failure arriving by a different door. R4 keeps the
  # alert quiet by saying it once; a permanent, unactionable number defeats that
  # from inside the message.
  #
  # Not a conflict with surfacing for the whole working copy. That rule forbids
  # narrowing by agent or by file — deciding whose a finding is. This declines to
  # report a fact that is red by design, which is a different thing, and the
  # blocking gate already draws exactly this line.
  defp message(scope, latest) do
    sources =
      scope
      |> enforceable_problems()
      |> Enum.frequencies_by(& &1.source)
      |> Enum.sort_by(fn {_source, n} -> -n end)
      |> Enum.map_join(", ", fn {source, n} -> "#{source}: #{n}" end)

    case sources do
      "" ->
        nil

      named ->
        # Capped, not merely short. It rides on every tool call in every turn,
        # so the budget is a sentence.
        String.slice(
          "#{named} failing in this working copy, #{age(latest)}. `list_problems` for detail",
          0,
          199
        )
    end
  end

  # The age is the point, not decoration. A count alone is a claim about a tree
  # the agent cannot identify: analysis is async, so the run behind it may
  # predate the last three edits. Without this, an agent that has just fixed
  # something reads the outstanding count as a verdict on the fix, and either
  # re-fixes finished work or distrusts a correct result. Both happened on
  # 2026-08-13.
  defp age(%DateTime{} = at) do
    case DateTime.diff(DateTime.utc_now(), at, :second) do
      s when s < 60 -> "as of #{max(s, 0)}s ago"
      s when s < 3600 -> "as of #{div(s, 60)}m ago"
      s -> "as of #{div(s, 3600)}h ago"
    end
  end

  defp age(%NaiveDateTime{} = at),
    do: at |> DateTime.from_naive!("Etc/UTC") |> age()

  defp enforceable_problems(scope) do
    Validation.enforceable(scope, Problems.list_project_problems(scope, []))
  end
end
