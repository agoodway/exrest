defmodule PgRest.Utils do
  @moduledoc """
  Shared utility functions for PgRest modules.
  """

  @doc """
  Converts a string to an existing atom, passing atoms through unchanged.

  Raises `ArgumentError` if the atom does not already exist.
  """
  @spec safe_to_atom(atom()) :: atom()
  @spec safe_to_atom(String.t()) :: atom()
  def safe_to_atom(name) when is_atom(name), do: name
  def safe_to_atom(name) when is_binary(name), do: String.to_existing_atom(name)

  @doc """
  Converts a string to an existing atom, returning `nil` if the atom does not exist.

  Passes atoms through unchanged.
  """
  @spec safe_to_existing_atom(atom()) :: atom()
  @spec safe_to_existing_atom(String.t()) :: atom() | nil
  def safe_to_existing_atom(name) when is_atom(name), do: name

  def safe_to_existing_atom(name) when is_binary(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end
end
