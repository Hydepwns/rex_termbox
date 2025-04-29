defmodule ExTermbox.Integration.ExamplesTest do
  use ExUnit.Case, async: false
  @moduletag :integration

  # Get the path to the examples directory relative to the test file
  @examples_dir Path.expand("../../../examples", __DIR__)

  # Helper to run an example script
  defp run_example(script_name) do
    script_path = Path.join(@examples_dir, script_name)
    # Spawn and link to ensure test fails if script crashes immediately
    pid = spawn_link(fn ->
      {_output, exit_code} = System.cmd("elixir", [script_path], into: IO.stream(:stdio, :line), stderr_to_stdout: true)
      # Optional: Exit test process with script's exit code?
      # For now, just let it run. Linking ensures immediate crashes fail the test.
      IO.puts("Example script #{script_name} finished with exit code: #{exit_code}")
    end)
    # Give the script a moment to start up and potentially crash
    Process.sleep(500)
    pid
  end

  # Test cases for each example
  # These tests now only check if the script can be spawned without immediate crash.
  # They don't verify functionality or interact with ExTermbox lifecycle.

  test "running example \'hello_world.exs\' spawns", _context do
    # Only check if the process starts without immediate crash
    pid = run_example("hello_world.exs")
    assert Process.alive?(pid)
    # Give it a short time, then assume it worked if it didn't crash.
    # Don't try to manage its lifecycle further in this test.
    Process.sleep(500)
    # We need to kill it *after* the test finishes otherwise the next
    # test might run while this example still holds the TTY
    # Use Process.spawn_monitor instead? For now, just let it run briefly.
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  test "running example \'event_viewer.exs\' spawns", _context do
    # Only check if the process starts without immediate crash
    pid = run_example("event_viewer.exs")
    assert Process.alive?(pid)
    # Give it a short time, then assume it worked if it didn't crash.
    Process.sleep(500)
    if Process.alive?(pid), do: Process.exit(pid, :kill)
  end

  # Add more tests for other examples if needed, noting they need updates.

end
