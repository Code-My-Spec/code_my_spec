defmodule CodeMySpec.CloudStatePathsTest do
  use ExUnit.Case, async: false

  setup do
    previous = Map.new(~w(CMS_STATE_DIR CMS_PROJECT_DIR), &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "a cloud box has explicit persistent state independent of its checkout" do
    System.put_env("CMS_STATE_DIR", "/tmp/cloud-box/state")
    System.put_env("CMS_PROJECT_DIR", "/tmp/target/repo")
    assert CodeMySpec.Paths.local_state_dir() == "/tmp/cloud-box/state"
  end

  test "desktop and existing workspace defaults remain unchanged" do
    System.delete_env("CMS_STATE_DIR")
    System.delete_env("CMS_PROJECT_DIR")
    assert CodeMySpec.Paths.local_state_dir() == Path.expand("~/.codemyspec")
    System.put_env("CMS_PROJECT_DIR", "/tmp/workspace/repo")
    assert CodeMySpec.Paths.local_state_dir() == "/tmp/workspace"
    System.put_env("CMS_STATE_DIR", "")
    assert CodeMySpec.Paths.local_state_dir() == "/tmp/workspace"
  end
end
