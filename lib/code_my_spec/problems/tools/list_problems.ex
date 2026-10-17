defmodule CodeMySpec.Problems.Tools.ListProblems do
  @moduledoc false
  @behaviour CodeMySpec.Tools.Tool

  alias CodeMySpec.Problems.Tools

  @impl true
  def name, do: "list_problems"

  @impl true
  def description do
    """
    The findings behind the alert, for the agent that wants them.

    `Hooks.AnalysisAlert` puts a count and an age on every tool call and stops
    there — a finding list on every call is noise the model learns to skip, which
    costs the signal a second time and more permanently than never sending it. So
    the alert pushes the fact and this pulls the detail, and the split only works
    because asking is one tool call.

    ## Paginated, and not optionally

    This working copy holds over 400 credo findings. An unpaginated list would
    overflow the tool-response window for the same reason the alert is counts-only
    — and a tool that dies on a large project is one nobody can rely on when a
    project gets large, which is exactly when they need it.

    Defaults to the first page and to `error` severity, because the common case is
    "what is blocking me" rather than "everything anyone has ever noticed".

    Scoped to the working copy, like everything else keyed on the harness: these
    are the findings from *this* checkout's analyzers, not the project's.
    """
  end

  @impl true
  def params do
    %{
      source:
        {:meta, :string,
         [
           description:
             "Filter to one analyzer — `compiler`, `credo`, `exunit`, `spex` or `qa_validation`."
         ]},
      severity:
        {:meta, :string,
         [description: "Filter by severity — `error`, `warning` or `info`. Omit for all."]},
      page: {:meta, :integer, [description: "1-based page number. Default: 1."]},
      per_page: {:meta, :integer, [description: "Findings per page. Default: 25, max 100."]}
    }
  end

  @impl true
  def call(params, context) do
    case Tools.list(params, context) do
      {:ok, scope, problems, total, page, pages} ->
        {:ok, Tools.render(scope, problems, total, page, pages, params)}

      {:error, reason} ->
        Tools.list_error(reason)
    end
  end

  @impl true
  def script_result(params, context) do
    case Tools.list(params, context) do
      {:ok, _scope, problems, _total, _page, _pages} -> {:ok, Tools.rows(problems)}
      {:error, reason} -> CodeMySpec.Tools.error(reason)
    end
  end
end
