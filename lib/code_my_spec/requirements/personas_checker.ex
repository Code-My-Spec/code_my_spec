defmodule CodeMySpec.Requirements.PersonasChecker do
  @moduledoc """
  Delegate checker for the `personas_complete` requirement on `project_graph`.

  Iterates over every persona in the active account and confirms each has:

    * A `personas` row (always true for anything list returns — proof by construction)
    * `.code_my_spec/personas/<slug>/summary.md` that validates as `persona_summary`
    * `.code_my_spec/personas/<slug>/sources.md` with at least one non-empty line

  Personas are an account-level reusable library — story linkage happens later
  via Three Amigos and is not required for `personas_complete`. Requiring a
  link would create a cycle with `stories_exist`, which is gated on
  `personas_complete` by the serial chain.

  Returns `{boolean(), map()}` per the checker contract (see `IssuesChecker`).
  Failure reasons are markdown-formatted and list each failing persona with its
  specific missing or invalid artifact so the stop-hook feedback can direct the
  next turn surgically.
  """

  alias CodeMySpec.Documents
  alias CodeMySpec.Environments
  alias CodeMySpec.Personas
  alias CodeMySpec.Users.Scope

  @spec complete?(Scope.t(), term()) :: {boolean(), map()}
  def complete?(%Scope{active_account_id: account_id, environment: env} = scope, _entity)
      when not is_nil(account_id) do
    personas = Personas.list_personas(scope)

    cond do
      personas == [] ->
        {false,
         %{
           reason:
             "No personas in this account's library. Start a persona research session to add one."
         }}

      is_nil(env) ->
        {false,
         %{reason: "Environment is not available — cannot verify persona artifacts on disk."}}

      true ->
        gaps =
          personas
          |> Enum.map(&check_persona(env, &1))
          |> Enum.reject(&(&1 == :ok))

        if gaps == [] do
          {true, %{status: "#{length(personas)} persona(s) complete"}}
        else
          {false, %{reason: format_gaps(gaps)}}
        end
    end
  end

  def complete?(%Scope{}, _entity) do
    {false, %{reason: "No active account in scope — cannot check personas."}}
  end

  # Returns :ok or {slug, [gap_messages]}
  defp check_persona(env, persona) do
    slug = persona.slug
    summary_path = Personas.summary_path(slug)
    sources_path = Personas.sources_path(slug)

    summary_gap = check_summary(env, summary_path)
    sources_gap = check_sources(env, sources_path)
    stray_gaps = check_stray_files(env, slug)

    gaps = Enum.reject([summary_gap, sources_gap | stray_gaps], &(&1 == :ok))

    case gaps do
      [] -> :ok
      gaps -> {slug, Enum.map(gaps, fn {:gap, message} -> message end)}
    end
  end

  # Flags any files in the persona folder other than summary.md and sources.md.
  defp check_stray_files(env, slug) do
    case Environments.list_directory(env, Personas.persona_folder(slug)) do
      {:ok, entries} ->
        strays = entries -- ["summary.md", "sources.md"]
        Enum.map(strays, fn name -> {:gap, "stray file `#{name}` — only summary.md and sources.md are allowed"} end)

      _ ->
        []
    end
  end

  defp check_summary(env, path) do
    case Environments.read_file(env, path) do
      {:ok, ""} ->
        {:gap, "`summary.md` is empty"}

      {:ok, content} ->
        case Documents.create_dynamic_document(content, "persona_summary") do
          {:ok, _document} -> :ok
          {:error, reason} -> {:gap, "`summary.md` invalid — #{reason}"}
        end

      {:error, _reason} ->
        {:gap, "`summary.md` missing"}
    end
  end

  defp check_sources(env, path) do
    case Environments.read_file(env, path) do
      {:ok, content} ->
        if has_non_empty_line?(content) do
          :ok
        else
          {:gap, "`sources.md` present but empty"}
        end

      {:error, _reason} ->
        {:gap, "`sources.md` missing"}
    end
  end

  defp has_non_empty_line?(content) do
    content
    |> String.split("\n", trim: true)
    |> Enum.any?(fn line -> String.trim(line) != "" end)
  end

  defp format_gaps(gaps) do
    sections =
      Enum.map(gaps, fn {slug, messages} ->
        bullets = Enum.map_join(messages, "\n", &"  - #{&1}")
        "### #{slug}\n#{bullets}"
      end)

    "Persona research incomplete:\n\n" <> Enum.join(sections, "\n\n")
  end
end
