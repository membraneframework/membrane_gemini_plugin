defmodule Membrane.Gemini.Test.PushSource do
  @moduledoc false
  # A source with a push-flow output pad, driven entirely by parent
  # notifications. Lets a test emit arbitrary interleavings of buffers,
  # events and EOS at the exact moment it chooses:
  #
  #   Membrane.Testing.Pipeline.notify_child(pipeline, :src, {:push, actions})
  #
  # where `actions` is a list of regular element actions, e.g.
  # `[buffer: {:output, %Membrane.Buffer{...}}, end_of_stream: :output]`.
  #
  # Actions pushed before the element enters playback are buffered and
  # flushed in order once it does, so tests may push right after the
  # pipeline starts.

  use Membrane.Source

  def_output_pad :output, accepted_format: _any, flow_control: :push

  def_options stream_format: [
                spec: struct(),
                description: "Stream format sent on the output pad when entering playback"
              ]

  @impl true
  def handle_init(_ctx, opts) do
    {[], %{stream_format: opts.stream_format, playing?: false, pending: []}}
  end

  @impl true
  def handle_playing(_ctx, state) do
    actions = [stream_format: {:output, state.stream_format}] ++ state.pending
    {actions, %{state | playing?: true, pending: []}}
  end

  @impl true
  def handle_parent_notification({:push, actions}, _ctx, %{playing?: true} = state) do
    {actions, state}
  end

  @impl true
  def handle_parent_notification({:push, actions}, _ctx, state) do
    {[], %{state | pending: state.pending ++ actions}}
  end
end
