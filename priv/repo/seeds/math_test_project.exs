# Seed file for Math Test Project
# Run with: mix run priv/repo/seeds/math_test_project.exs
#
# Creates account, project, stories, and criteria
# for the Math Test Project demo.

alias CodeMySpec.Repo
import Ecto.Query

now = DateTime.utc_now() |> DateTime.truncate(:second)

# Helper: convert UUID string to binary for raw insert_all
uuid = &Ecto.UUID.dump!/1

# =============================================================================
# Account
# =============================================================================

account = %{
  id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
  name: "Code My Spec",
  slug: "code-my-spec",
  type: "team",
  inserted_at: now,
  updated_at: now
}

unless Repo.exists?(from a in "accounts", where: a.id == ^account.id) do
  Repo.insert_all("accounts", [account])
end

# =============================================================================
# Project
# =============================================================================

project = %{
  id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
  name: "Math Test Project",
  module_name: "MathTestProject",
  status: "created",
  account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
  inserted_at: now,
  updated_at: now
}

unless Repo.exists?(from p in "projects", where: p.id == ^project.id) do
  Repo.insert_all("projects", [project])
end

# =============================================================================
# Stories
# =============================================================================

stories = [
  %{
    id: 457,
    title: "Addition",
    description: "As a user, I can add two numbers and see the result on a dedicated addition page.",
    status: nil,
    priority: nil,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 458,
    title: "Subtraction",
    description: "As a user, I can subtract two numbers and see the result on a dedicated subtraction page.",
    status: nil,
    priority: nil,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  }
]

for story <- stories do
  unless Repo.exists?(from s in "stories", where: s.id == ^story.id) do
    Repo.insert_all("stories", [story])
  end
end

# =============================================================================
# Criteria (Acceptance Criteria)
# =============================================================================

criteria = [
  %{
    id: 4420,
    description: "Given I am on the addition page, when I enter two valid numbers and click calculate, then I see their sum displayed",
    position: nil,
    verified: false,
    story_id: 457,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4421,
    description: "Given I am on the addition page, when I enter non-numeric input, then I see a validation error",
    position: nil,
    verified: false,
    story_id: 457,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4422,
    description: "Given I am on the addition page, when I enter decimal numbers, then the sum handles decimals correctly",
    position: nil,
    verified: false,
    story_id: 457,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4423,
    description: "Given I am on the subtraction page, when I enter two valid numbers and click calculate, then I see their difference displayed",
    position: nil,
    verified: false,
    story_id: 458,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4424,
    description: "Given I subtract a larger number from a smaller one, then I see a negative result",
    position: nil,
    verified: false,
    story_id: 458,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  },
  %{
    id: 4425,
    description: "Given I am on the subtraction page, when I enter non-numeric input, then I see a validation error",
    position: nil,
    verified: false,
    story_id: 458,
    project_id: uuid.("d7f466a1-591e-4f36-8319-42633f59411e"),
    account_id: uuid.("0f27281c-240b-4d6d-8e52-9c5972329522"),
    inserted_at: now,
    updated_at: now
  }
]

for criterion <- criteria do
  unless Repo.exists?(from c in "criteria", where: c.id == ^criterion.id) do
    Repo.insert_all("criteria", [criterion])
  end
end

IO.puts("""
Seeded Math Test Project:
  - 1 account (Code My Spec)
  - 1 project (Math Test Project)
  - 2 stories
  - 6 criteria
""")
