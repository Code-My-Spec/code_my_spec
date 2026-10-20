defmodule CmsHarness.Project.AReattachedTerminalFindsItsTranscriptTest do
  @moduledoc """
  Issue c82e1d2d: after a harness restart no terminal agent's transcript was
  read, because the path was rebuilt replacing only `/` and `.` in the cwd;
  Claude Code replaces every character outside `[A-Za-z0-9-]`.
  """
  use ExUnit.Case, async: true

  alias CmsHarness.Project.ChannelClient

  @moduletag :tmp_dir

  test "a cwd with an underscore and a dot is found under the folder Claude Code made", %{
    tmp_dir: projects
  } do
    folder = Path.join(projects, "-Users-sam-code-my-spec-v2-1")
    File.mkdir_p!(folder)
    path = Path.join(folder, "s1.jsonl")
    File.write!(path, "")

    record = %{"cwd" => "/Users/sam/code_my_spec.v2/1", "sessionId" => "s1"}

    assert ChannelClient.transcript_path(record, projects) == path
  end

  test "a transcript that is not there is nil", %{tmp_dir: projects} do
    record = %{"cwd" => "/Users/sam/app", "sessionId" => "missing"}
    assert ChannelClient.transcript_path(record, projects) == nil
  end
end
