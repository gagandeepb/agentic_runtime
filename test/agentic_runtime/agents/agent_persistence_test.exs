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
      %{owner_id: owner_id} = scope = build(:scope)
      %{id: conversation_id} = insert(:conversation, user_id: owner_id)
      ctx = agent_context(conversation_id)
      state = %{"version" => 1, "state" => %{"messages" => []}}

      assert :ok = AgentPersistence.persist_state(scope, state, ctx)
      assert {:ok, ^state} = AgentPersistence.load_state(scope, ctx)
    end

    test "skips persistence when scope mismatch" do
      %{owner_id: owner_id} = build(:scope)
      %{id: conversation_id} = insert(:conversation, user_id: owner_id)

      other_scope = build(:scope)
      ctx = agent_context(conversation_id)
      state = %{"version" => 1, "state" => %{}}

      assert :ok = AgentPersistence.persist_state(other_scope, state, ctx)
      assert {:error, :not_found} = AgentPersistence.load_state(other_scope, ctx)
    end
  end

  describe "load_state/2" do
    test "returns {:error, :not_found} when no state has been persisted" do
      %{owner_id: owner_id} = scope = build(:scope)
      %{id: conversation_id} = insert(:conversation, user_id: owner_id)
      ctx = agent_context(conversation_id)

      assert {:error, :not_found} = AgentPersistence.load_state(scope, ctx)
    end

    test "respects conversation- prefix when extracting conversation_id" do
      %{owner_id: owner_id} = scope = build(:scope)
      %{id: conversation_id} = insert(:conversation, user_id: owner_id)

      state = %{"version" => 1, "state" => %{"key" => "value"}}

      ctx = %{
        agent_id: "conversation-#{conversation_id}",
        conversation_id: conversation_id,
        lifecycle: :on_message
      }

      :ok = AgentPersistence.persist_state(scope, state, ctx)

      assert {:ok, ^state} = AgentPersistence.load_state(scope, ctx)
    end

    test "second persist_state for the same conversation upserts and bumps the version" do
      %{owner_id: owner_id} = scope = build(:scope)
      %{id: conversation_id} = insert(:conversation, user_id: owner_id)
      ctx = agent_context(conversation_id)

      :ok = AgentPersistence.persist_state(scope, %{"version" => 1, "state" => %{}}, ctx)

      :ok =
        AgentPersistence.persist_state(
          scope,
          %{"version" => 7, "state" => %{"messages" => ["m"]}},
          ctx
        )

      assert {:ok, %{"version" => 7, "state" => %{"messages" => ["m"]}}} =
               AgentPersistence.load_state(scope, ctx)
    end

    test "skips persistence when the conversation has been deleted" do
      %{owner_id: owner_id} = scope = build(:scope)
      %{id: conversation_id} = conversation = insert(:conversation, user_id: owner_id)
      ctx = agent_context(conversation_id)

      {:ok, _} = AgenticRuntime.Conversations.delete_conversation(conversation)

      :ok = AgentPersistence.persist_state(scope, %{"version" => 1, "state" => %{}}, ctx)

      assert {:error, :not_found} = AgentPersistence.load_state(scope, ctx)
    end
  end
end
