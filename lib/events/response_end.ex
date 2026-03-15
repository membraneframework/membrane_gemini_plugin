defmodule Membrane.Gemini.Events.ResponseEnd do
  @moduledoc """
  Sent by `Membrane.Gemini.Bin` upon model turn completion or interruption.

  Whether or not the turn was interrupted is signaled by the `interrupted?` flag.
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{interrupted?: boolean()}

  @enforce_keys [:interrupted?]

  defstruct @enforce_keys
end
