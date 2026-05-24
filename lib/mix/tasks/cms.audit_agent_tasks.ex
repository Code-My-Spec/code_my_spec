defmodule Mix.Tasks.Cms.AuditAgentTasks do
  @moduledoc """
  Emit a markdown audit report for agent_task modules.

  Surfaces violations of the conventions in
  `.code_my_spec/knowledge/skills/agent_task_guide.md`:

  - source line count and heredoc size (proxy for inlined static content)
  - dispatcher registration (@session_type_map and the four dispatch lists)
  - Evaluator registration vs evaluate/2 export
  - dispatch/1 surface quality (presence of "Use when")

  Usage:

      mix cms.audit_agent_tasks            # prints report to stdout
      mix cms.audit_agent_tasks > audit.md # capture to file
  """
  @shortdoc "Audit agent_task design conventions"
  use Boundary, classify_to: CodeMySpec
  use Mix.Task

  alias CodeMySpec.AgentTasks.{Evaluator, StartAgentTask}

  @agent_tasks_dir "lib/code_my_spec/agent_tasks"
  @skip_basenames ~w(evaluator start_agent_task problem_feedback)

  @impl true
  def run(_args) do
    Mix.Task.run("compile")

    dispatch_map = StartAgentTask.session_type_map()
    bootstrap = StartAgentTask.bootstrap_tasks()
    project = StartAgentTask.project_tasks()
    componentless = StartAgentTask.componentless_tasks()
    topic = StartAgentTask.topic_tasks()
    custom_eval = MapSet.new(Evaluator.custom_evaluate_modules())

    dispatch_index = build_dispatch_index(bootstrap, project, componentless, topic)

    reports =
      @agent_tasks_dir
      |> Path.join("*.ex")
      |> Path.wildcard()
      |> Enum.reject(&skip?/1)
      |> Enum.map(&analyze(&1, dispatch_map, dispatch_index, custom_eval))
      |> Enum.sort_by(& &1.severity, :desc)

    IO.puts(render(reports, dispatch_map, custom_eval))
  end

  defp skip?(path), do: Path.basename(path, ".ex") in @skip_basenames

  defp build_dispatch_index(bootstrap, project, componentless, topic) do
    Enum.reduce(
      [
        {bootstrap, "bootstrap"},
        {project, "project"},
        {componentless, "componentless"},
        {topic, "topic"}
      ],
      %{},
      fn {types, shape}, acc ->
        Enum.reduce(types, acc, &Map.put(&2, &1, shape))
      end
    )
  end

  defp analyze(path, dispatch_map, dispatch_index, custom_eval) do
    content = File.read!(path)
    module = extract_module(content)
    raw_source_lines = content |> String.split("\n") |> length()
    %{moduledoc_size: moduledoc_size, heredocs: heredocs} = heredoc_analysis(content)
    source_lines = raw_source_lines - moduledoc_size
    largest_heredoc = Enum.max(heredocs, fn -> 0 end)
    heredoc_total = Enum.sum(heredocs)
    big_heredoc_count = Enum.count(heredocs, &(&1 > 30))
    exports = exported_callbacks(module)
    registered_as = registered_type(module, dispatch_map)
    dispatch_shape = registered_as && Map.get(dispatch_index, registered_as, "component")
    in_custom_eval = MapSet.member?(custom_eval, module)
    orchestrate = safe_orchestrate(module)
    has_use_when = orchestrate && String.contains?(orchestrate, "Use when")

    severity =
      0
      |> bump(is_nil(registered_as), 5)
      |> bump(:evaluate in exports and not in_custom_eval, 1)
      |> bump(:evaluate not in exports and in_custom_eval, 5)
      |> bump(source_lines > 250, 4)
      |> bump(source_lines > 150 and source_lines <= 250, 2)
      |> bump(largest_heredoc > 60, 4)
      |> bump(largest_heredoc > 30 and largest_heredoc <= 60, 2)
      |> bump(big_heredoc_count >= 3, 2)
      |> bump(:orchestrate in exports and not has_use_when, 1)

    %{
      module: module,
      path: path,
      source_lines: source_lines,
      largest_heredoc: largest_heredoc,
      heredoc_total: heredoc_total,
      big_heredoc_count: big_heredoc_count,
      exports: exports,
      registered_as: registered_as,
      dispatch_shape: dispatch_shape,
      in_custom_eval: in_custom_eval,
      orchestrate: orchestrate,
      has_use_when: has_use_when,
      severity: severity
    }
  end

  defp bump(score, true, n), do: score + n
  defp bump(score, false, _), do: score

  defp extract_module(content) do
    case Regex.run(~r/defmodule\s+([\w.]+)\s+do/, content) do
      [_, name] -> Module.concat([name])
      _ -> nil
    end
  end

  defp registered_type(module, dispatch_map) do
    Enum.find_value(dispatch_map, fn {type, mod} -> mod == module && type end)
  end

  defp exported_callbacks(nil), do: []

  defp exported_callbacks(module) do
    targets = [
      {:command, 2},
      {:evaluate, 2},
      {:dispatch, 1},
      {:before_evaluate, 2},
      {:init_session, 2},
      {:analyzers, 0}
    ]

    if Code.ensure_loaded?(module) do
      for {name, arity} <- targets, function_exported?(module, name, arity), do: name
    else
      []
    end
  end

  defp safe_orchestrate(nil), do: nil

  defp safe_orchestrate(module) do
    if Code.ensure_loaded?(module) and function_exported?(module, :dispatch, 1) do
      stub = %{
        name: "stub_requirement",
        entity_type: "component",
        entity_id: "stub-id",
        entity_name: "StubComponent"
      }

      raw =
        try do
          module.dispatch(stub)
        rescue
          _ -> nil
        catch
          _, _ -> nil
        end

      normalize_orchestrate(raw)
    end
  end

  defp normalize_orchestrate(s) when is_binary(s), do: s
  defp normalize_orchestrate({:ok, s}) when is_binary(s), do: s
  defp normalize_orchestrate(_), do: nil

  # Walk the source, classify each heredoc as either inside a @moduledoc or
  # a regular code heredoc. Moduledoc heredocs don't ship to the agent at
  # runtime — they're documentation — so they're tracked separately and
  # excluded from the bloat metrics.
  defp heredoc_analysis(content) do
    content
    |> String.split("\n")
    |> Enum.with_index()
    |> Enum.reduce({%{moduledoc_size: 0, heredocs: []}, :outside}, fn
      {line, idx}, {acc, state} ->
        triple_count = length(Regex.scan(~r/"""/, line))

        case {state, triple_count} do
          {:outside, 0} ->
            {acc, :outside}

          {:outside, n} when rem(n, 2) == 0 ->
            {acc, :outside}

          {:outside, _} ->
            is_moduledoc = Regex.match?(~r/@moduledoc\s*"""/, line)
            {acc, {:inside, idx, is_moduledoc}}

          {{:inside, _start, _moduledoc?}, 0} ->
            {acc, state}

          {{:inside, start, true}, _} ->
            size = idx - start - 1
            {%{acc | moduledoc_size: acc.moduledoc_size + size}, :outside}

          {{:inside, start, false}, _} ->
            size = idx - start - 1
            {%{acc | heredocs: [size | acc.heredocs]}, :outside}
        end
    end)
    |> elem(0)
  end

  defp render(reports, dispatch_map, custom_eval) do
    [
      "# Agent Tasks Audit Report",
      "",
      "Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}",
      "",
      render_summary(reports, dispatch_map, custom_eval),
      "",
      "## Per-Task Details (sorted by severity, high to low)",
      "",
      Enum.map_join(reports, "\n", &render_task/1)
    ]
    |> Enum.join("\n")
  end

  defp render_summary(reports, dispatch_map, custom_eval) do
    n = length(reports)
    orphans = Enum.count(reports, &is_nil(&1.registered_as))
    over_250 = Enum.count(reports, &(&1.source_lines > 250))
    big_heredocs = Enum.count(reports, &(&1.largest_heredoc > 60))
    eval_export_registered = Enum.count(reports, &(:evaluate in &1.exports and &1.in_custom_eval))
    eval_export_unregistered = Enum.count(reports, &(:evaluate in &1.exports and not &1.in_custom_eval))
    no_orchestrate = Enum.count(reports, &(:orchestrate not in &1.exports))
    no_use_when = Enum.count(reports, &(:orchestrate in &1.exports and not &1.has_use_when))

    """
    ## Summary

    - **#{n}** agent task modules discovered (top-level only)
    - **#{map_size(dispatch_map)}** entries in `@session_type_map`
    - **#{orphans}** modules NOT registered in `@session_type_map` (orphans)
    - **#{over_250}** modules with source > 250 lines
    - **#{big_heredocs}** modules with a heredoc > 60 lines
    - **#{MapSet.size(custom_eval)}** modules listed in `Evaluator.custom_evaluate_modules/0`
    - **#{eval_export_registered}** modules export `evaluate/2` AND are registered
    - **#{eval_export_unregistered}** modules export `evaluate/2` but are NOT registered (review case-by-case)
    - **#{no_orchestrate}** modules do not export `dispatch/1`
    - **#{no_use_when}** modules export `dispatch/1` without a "Use when" clause
    """
  end

  defp render_task(r) do
    sev = severity_label(r.severity)
    flags = build_flags(r)
    dispatch_preview = preview(r.orchestrate)

    """
    ### `#{inspect(r.module)}` — #{sev} (severity #{r.severity})

    Path: `#{r.path}`

    | Check | Value |
    |---|---|
    | Source lines | #{r.source_lines}#{flag(r.source_lines > 250, " ⚠ over 250") || flag(r.source_lines > 150, " ⚠ over 150") || ""} |
    | Largest heredoc | #{r.largest_heredoc}#{flag(r.largest_heredoc > 60, " ⚠ over 60") || flag(r.largest_heredoc > 30, " ⚠ over 30") || ""} |
    | Heredoc total | #{r.heredoc_total} |
    | Heredocs > 30 | #{r.big_heredoc_count}#{flag(r.big_heredoc_count >= 3, " ⚠") || ""} |
    | Exports | #{Enum.map_join(r.exports, ", ", &Atom.to_string/1)} |
    | Registered as | #{r.registered_as || "**ORPHAN**"} |
    | Dispatch shape | #{r.dispatch_shape || "—"} |
    | In `custom_evaluate_modules` | #{yes_no(r.in_custom_eval)}#{eval_mismatch_flag(r)} |
    | `dispatch/1` preview | #{dispatch_preview} |
    | "Use when" clause | #{yes_no_na(r.has_use_when, :orchestrate in r.exports)} |
    #{flags}
    """
  end

  defp build_flags(r) do
    flags =
      []
      |> add_flag(is_nil(r.registered_as), "orphan: not in @session_type_map — won't be dispatchable")
      |> add_flag(:evaluate not in r.exports and r.in_custom_eval,
        "stale: in custom_evaluate_modules but evaluate/2 not exported")
      |> add_flag(:evaluate in r.exports and not r.in_custom_eval,
        "soft: exports evaluate/2 without registering — may be expressible as RequirementCalculator definition")
      |> add_flag(r.source_lines > 250, "bloat: extract static content to priv/knowledge/")
      |> add_flag(r.largest_heredoc > 60, "heredoc: move long static block to priv/knowledge/")

    case flags do
      [] -> ""
      list -> "\nIssues:\n" <> Enum.map_join(list, "\n", &"- #{&1}")
    end
  end

  defp add_flag(list, true, msg), do: [msg | list]
  defp add_flag(list, false, _), do: list

  defp eval_mismatch_flag(%{exports: exports, in_custom_eval: in_custom_eval}) do
    evaluates? = :evaluate in exports

    cond do
      evaluates? and in_custom_eval -> ""
      in_custom_eval -> " ⚠ stale"
      evaluates? -> " (soft)"
      true -> ""
    end
  end

  defp flag(true, msg), do: msg
  defp flag(false, _), do: nil

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no_na(_, false), do: "n/a"
  defp yes_no_na(true, _), do: "yes"
  defp yes_no_na(false, _), do: "no"

  defp preview(nil), do: "—"

  defp preview(text) do
    text
    |> String.replace("\n", " ")
    |> String.slice(0, 120)
    |> then(&("`" <> &1 <> "`"))
  end

  defp severity_label(s) when s >= 8, do: "**HIGH**"
  defp severity_label(s) when s >= 4, do: "**medium**"
  defp severity_label(s) when s >= 1, do: "low"
  defp severity_label(_), do: "ok"
end
