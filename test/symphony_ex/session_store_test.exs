defmodule SymphonyEx.SessionStoreTest do
  use ExUnit.Case, async: true

  alias SymphonyEx.SessionStore

  test "saves, loads, and normalizes workspace session metadata" do
    workspace_path = tmp_workspace("save-load")

    assert {:ok, saved} =
             SessionStore.save(workspace_path, %{
               thread_id: "thread-1",
               turn_id: "turn-1",
               turns_executed: 2,
               capability_profile: %{supports_thread_reuse: true},
               recovery_count: 1,
               last_event: "turn_completed",
               phase: :running,
               error: nil,
               error_category: nil
             })

    assert saved.phase == :running
    assert saved.capability_profile["supports_thread_reuse"] == true
    assert is_binary(saved.session_id)

    assert {:ok, loaded} = SessionStore.load(workspace_path)
    assert loaded.thread_id == "thread-1"
    assert loaded.turn_id == "turn-1"
    assert loaded.turns_executed == 2
    assert loaded.recovery_count == 1
    assert loaded.phase == :running
    assert loaded.capability_profile["supports_thread_reuse"] == true
  end

  test "recoverable? requires reusable thread support and non-terminal session" do
    assert SessionStore.recoverable?(%{
             thread_id: "thread-1",
             phase: :running,
             recovery_count: 3,
             capability_profile: %{"supports_thread_reuse" => true}
           })

    refute SessionStore.recoverable?(%{
             thread_id: "thread-1",
             phase: :completed,
             recovery_count: 0,
             capability_profile: %{"supports_thread_reuse" => true}
           })

    refute SessionStore.recoverable?(%{
             thread_id: "thread-1",
             phase: :running,
             recovery_count: 4,
             capability_profile: %{"supports_thread_reuse" => true}
           })

    refute SessionStore.recoverable?(%{
             thread_id: "thread-1",
             phase: :running,
             recovery_count: 0,
             capability_profile: %{"supports_thread_reuse" => false}
           })
  end

  test "mark_recovered increments recovery_count in-place" do
    workspace_path = tmp_workspace("mark-recovered")

    assert {:ok, _saved} =
             SessionStore.save(workspace_path, %{
               thread_id: "thread-9",
               turns_executed: 1,
               capability_profile: %{supports_thread_reuse: true},
               recovery_count: 1,
               phase: :running
             })

    assert {:ok, updated} = SessionStore.mark_recovered(workspace_path)
    assert updated.recovery_count == 2
    assert updated.phase == :running
    assert updated.last_event == "session_recovered"
  end

  test "persists failure breadcrumbs including error category" do
    workspace_path = tmp_workspace("error-category")

    assert {:ok, saved} =
             SessionStore.save(workspace_path, %{
               thread_id: "thread-err",
               capability_profile: %{supports_thread_reuse: true},
               phase: :failed,
               last_event: "startup_failed",
               error: "boom",
               error_category: "startup_failed"
             })

    assert saved.error_category == "startup_failed"

    assert {:ok, loaded} = SessionStore.load(workspace_path)
    assert loaded.error == "boom"
    assert loaded.error_category == "startup_failed"
  end

  test "load/1 returns a tagged error for invalid integer fields" do
    workspace_path = tmp_workspace("invalid-integer")
    File.mkdir_p!(workspace_path)

    File.write!(
      Path.join(workspace_path, ".symphony-session.json"),
      Jason.encode!(%{
        "session_id" => "sess-1",
        "thread_id" => "thread-1",
        "issue_id" => "issue-1",
        "issue_identifier" => "SYM-1",
        "phase" => "running",
        "turns_executed" => "oops",
        "recovery_count" => 0
      })
    )

    assert {:error, {:invalid_turns_executed, "oops"}} = SessionStore.load(workspace_path)
  end

  defp tmp_workspace(name) do
    Path.join(
      System.tmp_dir!(),
      "symphony-session-store-#{name}-#{System.unique_integer([:positive])}"
    )
  end
end
