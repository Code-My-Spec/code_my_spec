defmodule Mix.Tasks.Cms.ReconcileStatus do
  use Boundary, classify_to: CodeMySpec

  @moduledoc """
  Bring a project's story graph current with what its checkout has shown.

      mix cms.reconcile_status --root <checkout>                     # dry run: prints the plan
      mix cms.reconcile_status --root <checkout> --apply             # stamps
      mix cms.reconcile_status --root <checkout> --apply --unpark    # and releases parked stories

  Stamps stories whose latest QA attempt passed ready for QA, and with
  `--unpark` releases parked stories that are QA-passed. Never leaves a stamp
  cleared: what a release clears is put back. The project comes from the checkout's
  `.code_my_spec/config.yml`; see `CodeMySpec.StoryReconcile` for the rules.
  """

  use Mix.Task

  alias CodeMySpec.Projects
  alias CodeMySpec.StoryReconcile

  @shortdoc "Latch, stamp and un-park stories from analysis and QA results"

  def run(args) do
    {opts, _, _} =
      OptionParser.parse(args, strict: [apply: :boolean, root: :string, unpark: :boolean])

    case Keyword.fetch(opts, :root) do
      {:ok, root} ->
        run_in(
          Path.expand(root),
          Keyword.get(opts, :apply, false),
          Keyword.get(opts, :unpark, false)
        )

      :error ->
        Mix.shell().error(
          "Usage: mix cms.reconcile_status --root <checkout> [--apply] [--unpark]"
        )
    end
  end

  defp run_in(root, apply?, unpark?) do
    Mix.Task.run("app.start")

    with {:ok, scope} <- Projects.scope_from_local_config(root),
         {:ok, head} <- git(root, ["rev-parse", "HEAD"]) do
      scope = bind(scope, root)
      plan = StoryReconcile.plan(scope, head: head, unpark: unpark?)
      report(plan)
      finish(scope, plan, apply?)
    else
      {:error, reason} -> Mix.shell().error("reconcile_status: #{format(reason)}")
    end
  end

  # Without a registered copy step 1 refuses on its own; steps 2 and 3 still run.
  defp bind(scope, root) do
    case StoryReconcile.bind_checkout(scope, root) do
      {:ok, bound} -> bound
      {:error, message} -> tap(scope, fn _ -> Mix.shell().info("note: #{message}") end)
    end
  end

  defp finish(_scope, _plan, false),
    do: Mix.shell().info("\nDry run, nothing written. Re-run with --apply.")

  defp finish(scope, plan, true) do
    case StoryReconcile.carry_out(scope, plan) do
      :ok -> Mix.shell().info("\nApplied.")
      {:error, reason} -> Mix.shell().error("\nStopped: #{inspect(reason)}")
    end
  end

  defp git(root, args) do
    case System.cmd("git", ["-C", root | args], stderr_to_stdout: true) do
      {out, 0} -> {:ok, String.trim(out)}
      {out, _} -> {:error, "git #{Enum.join(args, " ")} failed in #{root}: #{String.trim(out)}"}
    end
  end

  defp format(reason) when is_binary(reason), do: reason
  defp format(reason), do: "failed to load project scope: #{inspect(reason)}"

  defp report(plan) do
    Mix.shell().info("HEAD #{plan.head}\n")
    # In the order `StoryReconcile.carry_out/2` writes: a release clears the
    # ready-for-QA stamp, so stamping comes after it.
    step("3. un-park", plan.unpark, &unpark_line/1, fn _ -> "" end)
    step("2. ready-for-QA stamp", plan.qa_ready, &qa_line/1, &qa_counts/1)
  end

  defp step(title, :skipped, _line, _counts),
    do: Mix.shell().info("#{title}: skipped (pass --unpark)")

  defp step(title, {:refused, message, items}, line, _counts) do
    Mix.shell().info("#{title}: REFUSED, #{length(items)} candidate(s)\n  #{message}")
    Enum.each(items, &Mix.shell().info("  " <> line.(&1)))
  end

  defp step(title, {:ok, items, counts}, line, summary) do
    Mix.shell().info("#{title}: #{length(items)} to change#{summary.(counts)}")
    Enum.each(items, &Mix.shell().info("  " <> line.(&1)))
  end

  defp qa_counts(counts), do: ", already stamped #{counts.already}"

  defp qa_line(%{source: :head} = item),
    do:
      "story #{item.story.number}: #{item.before} -> #{item.after} (HEAD; QA attempts record no commit)"

  defp qa_line(item),
    do:
      "story #{item.story.number}: #{item.before} -> #{item.after} (its stamp before the un-park)"

  defp unpark_line(item) do
    "story #{item.story.number}: #{item.before} -> #{item.after}" <>
      if(item.story.specs_ready,
        do:
          " (specs_ready at #{item.story.specs_ready_commit || "no recorded commit"} restored after the un-park)",
        else: ""
      )
  end
end
