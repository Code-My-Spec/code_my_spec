defmodule CodeMySpec.McpServers.Devops.Tools.DevopsStatus do
  @moduledoc """
  Whether the infrastructure this account is supposed to have actually exists.

  Answers three separate questions, because conflating them is what made
  "is devops setup done?" unanswerable:

  - **missing** — a step whose resources are not there. This is what decides
    whether `devops_setup` is complete.
  - **dangling** — a resource that exists and points at nothing, usually a DNS
    record left over from a destroyed server. Not a completion problem; it is
    cleanup, and it does not block the requirement.
  - **unreachable** — a provider that could not be read. This is the absence of
    an answer, not a verdict. Do not treat it as "not done".

  Read from the providers, not from a record file. Setup completion used to be
  decided by grepping a markdown file for the words "verified" and "prod",
  which an agent could satisfy by writing prose.

  ## Never sees past the one project it is connected to

  `Resources.report/1` is deliberately account-wide — the cross-project
  dangling checks need to see everything, and that is right for `/app/
  resources`, a human looking at their own whole account. It is wrong for
  this tool: a caller reaching it through the harness is scoped to one
  project's work, and has no business learning what devops state, missing
  steps, or dangling resources some *other* project in the same account
  carries. Confirmed live, twice: first a project whose own devops was
  still `:off` got back a different project's checklist entirely; then,
  once devops was turned on, that *same* other project kept appearing in
  full detail beside the real answer, because the underlying call was still
  `Resources.report/1`. This uses `Resources.project_report/2` instead,
  which never runs `deployable/1` or asks a provider for anything beyond
  the one project it is given — there is no account-wide data left to leak,
  on or off.
  """

  use Anubis.Server.Component, type: :tool

  alias Anubis.Server.Response
  alias CodeMySpec.McpServers.Validators
  alias CodeMySpec.Resources

  schema do
  end

  @impl true
  def execute(_params, frame) do
    with {:ok, scope} <- Validators.validate_local_scope(frame, %{}),
         {:ok, project} <- Validators.devops_project(scope) do
      {:reply, reply(scope, project), frame}
    else
      {:error, reason} -> {:reply, error(reason), frame}
    end
  end

  defp reply(scope, project) do
    case Resources.project_report(scope, project) do
      {:ok, report} -> ok(summary(report))
      {:error, :devops_off} -> devops_off(project)
    end
  end

  defp devops_off(project) do
    Response.tool()
    |> Response.error(
      "devops is off for #{project.name} — nothing to report. Turn it on for this " <>
        "project first; this tool never reports on any other project in the account."
    )
  end

  defp summary(report) do
    missing = Enum.filter(report.checklist, &(&1.state == :missing))
    dangling = Enum.filter(report.resources, &(&1.status == :dangling))

    [
      headline(report, missing),
      section("Missing", missing, &missing_line/1),
      section("Dangling", dangling, &"#{&1.kind} #{&1.location}"),
      unreachable(report.errors)
    ]
    |> Enum.reject(&(&1 == ""))
    |> Enum.join("\n\n")
  end

  defp headline(%{errors: errors}, _missing) when errors != %{},
    do:
      "Cannot say. One or more providers could not be read, so the answer is unknown rather than no."

  defp headline(_report, []), do: "Setup is complete: every step's resources are present."

  defp headline(_report, missing),
    do: "Setup is not complete: #{length(missing)} step(s) have nothing behind them."

  # The reason, when the step recorded one.
  #
  # The checklist has carried `detail` all along and this printed only the key,
  # so an agent asking what was missing got a list of names and no cause — and
  # then had to reproduce the run to learn what any of them said. One step
  # failing for a reason nobody could see cost three separate theories about
  # story 841 (provider capacity, an inventory bug, a placement fallback) before
  # anyone read the error the step had already stored.
  #
  # Truncated because a provider error can be a page of JSON, and the point here
  # is which step and why, not the whole body.
  #
  # The tail, not the head. Callers below this (`Remote.install_kamal/1`,
  # `Steps.with_output/2`) already learned to keep the tail of *their own*
  # output for the same reason — apt/gem/SSHKit chatter buries the actual
  # error first and its own conclusion last — but this slice sits outside all
  # of them, on the fully composed "<label> (exit N): <their already-trimmed
  # tail>" string. A head slice here re-truncates an already-correct tail
  # right back off the end, discarding exactly what the inner fix kept.
  # Confirmed live: a kamal-install failure whose real cause was a Ruby gem
  # backtrace arrived at this layer pre-trimmed to its own last 300
  # characters, and this then kept only the first 300 of *that* — the label
  # and exit code, and none of the backtrace the inner fix had preserved.
  #
  # `@doc false`: exists so the slice direction is assertable without
  # standing up a real failing provider, the same reason `wrap_with_timeout/2`
  # and `image_tag/2` are public.
  @doc false
  def missing_line(%{detail: detail} = entry) when is_binary(detail) and detail != "",
    do: "#{entry.project_name}/#{entry.key} — #{String.slice(detail, -300, 300)}"

  def missing_line(entry), do: "#{entry.project_name}/#{entry.key}"

  defp section(_label, [], _fmt), do: ""

  defp section(label, entries, fmt),
    do: "#{label} (#{length(entries)}):\n" <> Enum.map_join(entries, "\n", &("  - " <> fmt.(&1)))

  defp unreachable(errors) when errors == %{}, do: ""

  defp unreachable(errors) do
    "Unreachable (#{map_size(errors)}):\n" <>
      Enum.map_join(errors, "\n", fn {provider, reason} ->
        "  - #{provider}: #{inspect(reason)}"
      end)
  end

  defp ok(summary), do: Response.tool() |> Response.text(summary)

  defp error(reason),
    do: Response.tool() |> Response.error("Could not read devops status: #{inspect(reason)}")
end
