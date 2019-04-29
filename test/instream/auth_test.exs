defmodule Instream.AuthTest do
  use ExUnit.Case, async: true

  alias Instream.TestHelpers.Connections.AnonConnection
  alias Instream.TestHelpers.Connections.GuestConnection
  alias Instream.TestHelpers.Connections.InvalidConnection
  alias Instream.TestHelpers.Connections.NotFoundConnection
  alias Instream.TestHelpers.Connections.QueryAuthConnection

  test "anonymous user connection" do
    assert fn ->
      "SHOW DATABASES"
      |> AnonConnection.execute()
      |> Map.get(:error)
      |> String.contains?("Basic Auth")
    end
  end

  test "query auth connection" do
    refute (fn ->
              "SHOW DATABASES"
              |> QueryAuthConnection.execute()
              |> Map.has_key?(:error)
            end).()
  end

  test "invalid password" do
    assert fn ->
      "SHOW DATABASES"
      |> InvalidConnection.execute()
      |> Map.get(:error)
      |> String.contains?("authentication failed")
    end
  end

  test "privilege missing" do
    assert fn ->
      "ignore"
      |> Database.drop()
      |> GuestConnection.execute()
      |> Map.get(:error)
      |> String.contains?("requires admin privilege")
    end
  end

  test "user not found" do
    assert fn ->
      "SHOW DATABASES"
      |> NotFoundConnection.execute()
      |> Map.get(:error)
      |> String.contains?("not found")
    end
  end
end
