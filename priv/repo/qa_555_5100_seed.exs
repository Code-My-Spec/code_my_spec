# priv/repo/qa_555_5100_seed.exs
# Seeds a credo problem for QA story 555, criterion 5100.
# Idempotent: clears existing credo problems on the target file first.
#
# Usage: mix run priv/repo/qa_555_5100_seed.exs

alias CodeMySpec.Problems
alias CodeMySpec.Projects
alias CodeMySpec.Repo

# Find the CodeMySpec project by its local_path
cwd = "/Users/johndavenport/Documents/github/code_my_spec"

project =
  Repo.get_by(CodeMySpec.Projects.Project, local_path: cwd) ||
    raise "Project not found for local_path=#{cwd}. Run cli_qa_seeds first."

IO.puts("Found project: #{project.name} (#{project.id})")

# Build a minimal scope (no user/account needed for Problems operations)
scope = %CodeMySpec.Users.Scope{
  active_project_id: project.id
}

# The file path that will appear in changed_file_paths (relative to cwd)
file_path = ".code_my_spec/spec/code_my_spec/validation.spec.md"

# Clear any existing credo problems on this file
existing =
  Problems.list_project_problems(scope, source: "credo")
  |> Enum.filter(&(&1.file_path == file_path))

IO.puts("Clearing #{length(existing)} existing credo problem(s) on #{file_path}")

Enum.each(existing, fn p ->
  CodeMySpec.Repo.delete!(p)
end)

# Insert the credo problem
{:ok, _problem} =
  Problems.create_problems(scope, [
    %{
      project_id: project.id,
      severity: :warning,
      source_type: :static_analysis,
      source: "credo",
      file_path: file_path,
      line: 1,
      message: "Modules should have a @moduledoc tag.",
      category: "readability",
      rule: "Credo.Check.Readability.ModuleDoc"
    }
  ])

IO.puts("Seeded credo problem: #{file_path}:1 — Modules should have a @moduledoc tag.")
IO.puts("Done.")
