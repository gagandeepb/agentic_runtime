defmodule AgenticRuntime.Agents.AgentPersistenceTest do
  use AgenticRuntime.DataCase, async: true

  alias AgenticRuntime.Agents.AgentPersistence

  defp agent_context(conversation_id) do
    %{
      agent_id: "conversation-#{conversation_id}",
      conversation_id: conversation_id,
      lifecycle: :on_message
    }
  end

  describe "persist_state/3" do
    test "persists state and load_state returns it back" do
      scope = build_scope()
      conversation = insert_conversation!(scope)
      ctx = agent_context(conversation.id)
      state = %{"version" => 1, "state" => %{"messages" => []}}

      assert :ok = AgentPersistence.persist_state(scope, state, ctx)
      assert {:ok, ^state} = AgentPersistence.load_state(scope, ctx)
    end

    test "returns :ok (and skips persistence) when scope mismatch — no FK error reaches caller" do
      scope = build_scope()
      conversation = insert_conversation!(scope)
      other_scope = build_scope()
      ctx = agent_context(conversation.id)
      state = %{"version" => 1, "state" => %{}}

      assert :ok = AgentPersistence.persist_state(other_scope, state, ctx)
      assert {:error, :not_found} = AgentPersistence.load_state(other_scope, ctx)
    end
  end

  describe "load_state/2" do
    test "returns {:error, :not_found} when no state has been persisted" do
      scope = build_scope()
      conversation = insert_conversation!(scope)
      ctx = agent_context(conversation.id)

      assert {:error, :not_found} = AgentPersistence.load_state(scope, ctx)
    end

    test "respects conversation- prefix when extracting conversation_id" do
      scope = build_scope()
      conversation = insert_conversation!(scope)
      state = %{"version" => 1, "state" => %{"key" => "value"}}

      ctx = %{
        agent_id: "conversation-#{conversation.id}",
        conversation_id: conversation.id,
        lifecycle: :on_message
      }

      :ok = AgentPersistence.persist_state(scope, state, ctx)

      assert {:ok, %{"state" => %{"key" => "value"}}} = AgentPersistence.load_state(scope, ctx)
    end
  end
end
