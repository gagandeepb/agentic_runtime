defmodule AgenticRuntime.TestPresence do
  @moduledoc """
  Lightweight `Phoenix.Presence`-shaped stub backed by an Agent.
  Used by tests that exercise Coordinator presence helpers without
  starting a full Phoenix.Presence tracker.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def reset do
    Agent.update(__MODULE__, fn _ -> %{} end)
  end

  def track(_pid, topic, key, meta) do
    Agent.update(__MODULE__, fn state ->
      topic_map = Map.get(state, topic, %{})
      entry = %{metas: [meta]}
      Map.put(state, topic, Map.put(topic_map, to_string(key), entry))
    end)

    {:ok, "test-presence-ref"}
  end

  def untrack(_pid, topic, key) do
    Agent.update(__MODULE__, fn state ->
      case Map.get(state, topic) do
        nil -> state
        topic_map -> Map.put(state, topic, Map.delete(topic_map, to_string(key)))
      end
    end)

    :ok
  end

  def list(topic) do
    Agent.get(__MODULE__, fn state -> Map.get(state, topic, %{}) end)
  end
end
