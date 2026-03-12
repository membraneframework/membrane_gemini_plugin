defmodule Membrane.Gemini.ResponseEndEvent do
  @moduledoc """
  Sent by `Membrane.Gemini.Bin` upon model turn completion or interruption.
  """

  @derive Membrane.EventProtocol

  @type t :: %__MODULE__{
    interrupted?: boolean() #  Whether or not the turn was interrupted by the user
  }

  @enforce_keys [:interrupted?]

  defstruct @enforce_keys
end
