defmodule CmsHarness.Agents do
  require Logger

  @moduledoc """
  Agents running on this machine — start one, say which are running, stop one.

  Harness-side because the working copy is here: an agent's hundreds of file
  and shell calls stay local. This module translates a server request into
  `CmsHarness.Agents.Engine` options; the engine owns the loop.
  """

  use Boundary,
    top_level?: true,
    deps: [
      CmsHarness,
      CmsHarness.Channel,
      CodeMySpec.CodeMode,
      # `Hooks.PreToolUse.route_command/4`: an in-app agent's `mix test` is
      # routed the way a Claude Code agent's is.
      CodeMySpec.Hooks
    ],
    exports: :all

  alias CmsHarness.Agents.Engine
  alias CmsHarness.Agents.ToolResults
  alias CmsHarness.Channel

  @doc """
  Start the agent this request describes.

  Answers `{:ok, %{agent_id: id, pid: pid}}`. The id resolves through the
  harness's registry while the harness is running.
  """
  @spec launch(map()) :: {:ok, %{agent_id: String.t(), pid: pid()}} | {:error, term()}
  def launch(%{"agent_id" => agent_id} = request) do
    Engine.start(
      agent_id: agent_id,
      provider: request["provider"],
      credential: credential(request),
      working_copy: request["working_copy"],
      # System prompt pieces, all resolved server-side;
      # `SystemPrompt.compose/1` orders them general to specific.
      universal: request["universal"],
      project_brief: request["project_brief"],
      provider_brief: request["provider_brief"],
      role_brief: request["role_brief"],
      tool_index: request["tool_index"],
      tool_reach: request["tool_reach"],
      direct_tools: request["direct_tools"],
      # Where the project's app runs; only the server knows it.
      app_url: request["app_url"],
      # Addresses the agent's MCP session (`x-harness-id`); without it the
      # agent reaches none of the project's tools. Falls back to the copy's
      # own config.
      working_copy_id: request["working_copy_id"] || copy_id(request["working_copy"]),
      model: request["model"],
      # The transcript to resume from: an agent dies with its harness and
      # the transcript is its state.
      messages: request["messages"],
      # An OpenAI-compatible endpoint other than the provider's own.
      base_url: request["base_url"],
      # Options for the provider's HTTP client; in-process callers only
      # (recordings).
      req_options: request["req_options"],
      # Called on a graceful stop. Nothing on the wire sets it yet.
      on_stop: request["on_stop"],
      # Defaults to this copy's channel; in-process callers may override.
      on_event: request["on_event"] || reporter_for(request["working_copy"]),
      on_consume: request["on_consume"],
      on_register:
        request["on_register"] ||
          fn agent_id, generation ->
            Channel.mailbox(request["working_copy"], %{
              "operation" => "register",
              "agent_id" => agent_id,
              "generation" => generation
            })
          end,
      # The text of a turn as it is written, to whoever is watching live. Only
      # the channel wants it; a caller naming its own `on_event` gets none.
      on_draft: request["on_draft"] || drafter_for(request["on_event"], request["working_copy"])
    )
  end

  def launch(_request), do: {:error, :agent_id_required}

  @doc """
  The direct tools this harness implements, by MCP name: one
  `CmsHarness.Agents.Tools.<Name>` module each. The server's launch request
  names which of them an agent carries (`direct_tools`); a harness started
  without a server, in its own tests, hands an agent these.
  """
  @spec implemented_tools() :: [String.t()]
  def implemented_tools do
    {:ok, modules} = :application.get_key(:code_my_spec, :modules)

    for module <- modules,
        String.starts_with?(Atom.to_string(module), "Elixir.CmsHarness.Agents.Tools."),
        module not in [
          CmsHarness.Agents.Tools.Bash,
          CmsHarness.Agents.Tools.Read,
          CmsHarness.Agents.Tools.Direct
        ],
        Code.ensure_loaded?(module) and function_exported?(module, :name, 0),
        do: module.name()
  end

  @doc """
  Stop one agent, and say whether it was there to stop.

  Stops exactly one agent: never a tree, never a match by name.
  """
  @spec halt(String.t()) :: :ok | {:error, :not_running}
  defdelegate halt(agent_id), to: Engine, as: :stop

  @doc "Consume a claimed mailbox message; waiting for the result does not bypass consumption."
  def send_message(agent_id, ref, text, timeout \\ 180_000, opts \\ []) when is_binary(text) do
    result = Engine.send_message(agent_id, ref, text, timeout, opts)
    if Keyword.get(opts, :await, false), do: message_result(result), else: result
  end

  defp message_result({:ok, result}), do: {:ok, said(result)}
  defp message_result(error), do: error

  @doc "Request coalescible work on an idle engine; this carries no queued instruction."
  def request_work_turn(agent_id, ref, text, timeout \\ 180_000),
    do: Engine.request_work_turn(agent_id, ref, text, timeout)

  @doc """
  Stop this agent's running turn so a message sent now is its next one. It
  keeps what it did up to its last completed tool call.
  """
  @spec interrupt(String.t()) :: :ok | :idle | {:error, term()}
  defdelegate interrupt(agent_id), to: Engine

  @doc """
  Whether the agent currently has an executing turn.
  """
  @spec status(String.t()) ::
          {:ok, %{busy?: boolean()}} | {:error, :not_running}
  defdelegate status(agent_id), to: Engine

  @doc """
  What this agent carries.

  Asked of the running agent rather than a constant, so the answer describes
  the agent that was actually started.
  """
  @spec tools(String.t()) :: [module()]
  defdelegate tools(agent_id), to: Engine, as: :agent_tools

  @doc """
  The context this agent's tools are called with.

  What `run_script` and `tool_docs` receive when the agent itself calls them —
  the session included — so a caller exercising a tool exercises the one the
  agent has rather than one built beside it.
  """
  @spec tool_context(String.t()) :: map()
  def tool_context(agent_id) do
    %{agent_id: agent_id, mcp_client: Engine.mcp_client(agent_id)}
  end

  @doc """
  What one agent knows — the turns its loop is actually holding.

  Distinct from its transcript, which is what was written down; the two differ
  after a restart.
  """
  @spec history(String.t()) ::
          {:ok, [Alloy.Message.t()]} | {:error, :not_running | :busy}
  defdelegate history(agent_id), to: Engine

  # What the agent said, narrowed out of Alloy's whole-turn result (the wire
  # contract is a string). A failed turn is an `:ok` result carrying an error;
  # it must read as a failure, not "(no message)".
  defp said(%{status: :error, error: reason}), do: "(the turn failed: #{inspect(reason)})"

  defp said(%{text: text}) when is_binary(text) and text != "", do: text

  defp said(%{tool_calls: calls}) when is_list(calls) and calls != [] do
    "(no message — the turn ended in #{length(calls)} tool call(s))"
  end

  defp said(_result), do: "(no message)"

  @doc """
  Agent ids running here, read from the registry rather than from anything we
  were told — so it cannot disagree with what is actually alive.
  """
  @spec running() :: [String.t()]
  defdelegate running(), to: Engine

  # Steps go per event, fire and forget, to the channel of the one copy the
  # agent runs in. See knowledge/harness, "Agents".
  defp drafter_for(nil, working_copy),
    do: fn agent_id, envelope -> Channel.report_draft(working_copy, agent_id, envelope) end

  defp drafter_for(_on_event, _working_copy), do: nil

  defp reporter_for(working_copy) do
    fn agent_id, envelope ->
      warn_on_tool_failure(agent_id, envelope)
      Channel.report_turn_event(working_copy, agent_id, envelope)
      report_head_at_turn_end(working_copy, envelope)
    end
  end

  # Agents commit inside a turn, and a commit moves no file a sync watches.
  defp report_head_at_turn_end(root, %{event: :turn_ended}) when is_binary(root),
    do: CmsHarness.Sync.report_head(root)

  defp report_head_at_turn_end(_root, _envelope), do: :ok

  # A failed tool call, logged on the machine: otherwise only Alloy's crash
  # branch logs. `:warning`, not `:error` — refusals are ordinary outcomes and
  # spex fail on any `:error` log. `Map.get/2`, so an event without the key
  # still matches. See knowledge/harness, "Agents".
  defp warn_on_tool_failure(agent_id, %{payload: %{name: name} = payload})
       when is_binary(name),
       do: warn_failure(agent_id, name, Map.get(payload, :error))

  defp warn_on_tool_failure(_agent_id, _envelope), do: :ok

  defp warn_failure(_agent_id, _name, nil), do: :ok

  defp warn_failure(agent_id, name, error) do
    Logger.warning("[CmsHarness] agent #{agent_id} tool #{name} failed: #{failure_text(error)}")
  end

  # Bounded, because a tool's error can carry a whole response body and this
  # goes to a file that rotates at 10 MB.
  defp failure_text(error), do: error |> ToolResults.describe() |> String.slice(0, 500)

  # This checkout's id, from its own `.cms_harness.json`.
  defp copy_id(nil), do: nil

  defp copy_id(root) do
    case CmsHarness.HarnessConfig.read_file(root) do
      {:ok, %{working_copy_id: id}} -> id
      _ -> nil
    end
  end

  # Passed through uninterpreted: what a credential means is `Provider`'s job.
  # A codex agent uses this machine's own Codex login (`codex_home`); no token
  # is ever written to disk. See knowledge/harness, "Providers".
  defp credential(request) do
    %{}
    |> put_if(:codex_home, request["codex_home"])
    |> put_if(:api_key, request["api_key"])
  end

  defp put_if(map, _key, nil), do: map
  defp put_if(map, key, value), do: Map.put(map, key, value)
end
