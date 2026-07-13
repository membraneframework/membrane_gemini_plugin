defmodule Membrane.Gemini.EndpointTest do
  # Round-trip behaviour tests: a real `Membrane.Gemini.Bin` pipeline talking
  # to the scripted mock server (`GeminiMock.Scenario`), which lets each test
  # decide exactly which server frames arrive and when, and observe every
  # frame the plugin sends out.
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog
  import Membrane.Gemini.Test.PipelineHelper
  import Membrane.Testing.Assertions

  alias GeminiMock.{Frames, Scenario}
  alias Membrane.Buffer
  alias Membrane.Gemini.Events
  alias Membrane.Testing

  @moduletag timeout: 30_000

  # Starts the bin pipeline against a scripted connection and consumes the
  # initial setup frame, which every connection begins with.
  defp start!(mode, bin_opts \\ []) do
    extra_opts = Scenario.setup!()

    pipeline =
      Testing.Pipeline.start_link_supervised!(spec: bin_spec(mode, extra_opts, bin_opts))

    conn = Scenario.await_connection()
    assert %{"setup" => setup} = Scenario.await_client_frame(conn)
    {pipeline, conn, setup}
  end

  # A follow-up connection (session restart): consumes its setup frame too.
  defp await_restarted_connection do
    conn = Scenario.await_connection()
    assert %{"setup" => setup} = Scenario.await_client_frame(conn)
    {conn, setup}
  end

  defp reset_session(pipeline),
    do: Testing.Pipeline.notify_child(pipeline, :gemini, :reset_session)

  # Drives one full, clean model turn over an established connection.
  defp complete_turn(pipeline, conn, prompt) do
    push_text(pipeline, prompt)
    assert %{"realtimeInput" => %{"text" => ^prompt}} = Scenario.await_client_frame(conn)
    Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
    assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
    assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
  end

  describe "outgoing frames" do
    test "setup frame carries model, resumption config and system instruction" do
      {_pipeline, _conn, setup} =
        start!(:raw, model: "gemini-test-model", system_instruction: "Be brief.")

      assert setup["model"] =~ "gemini-test-model"
      assert setup["sessionResumption"] == %{}
      assert Jason.encode!(setup["systemInstruction"]) =~ "Be brief."
    end

    test "audio buffers are sent as base64 realtimeInput audio blobs" do
      {pipeline, conn, _setup} = start!(:raw)

      pcm = <<1, 2, 3, 4, 5, 6>>
      push_audio(pipeline, pcm)

      encoded = Base.encode64(pcm)

      assert %{
               "realtimeInput" => %{
                 "audio" => %{"data" => ^encoded, "mimeType" => "audio/pcm;rate=16000"}
               }
             } = Scenario.await_client_frame(conn)
    end

    test "text buffers are sent as realtimeInput text" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "Hello, Gemini!")

      assert %{"realtimeInput" => %{"text" => "Hello, Gemini!"}} =
               Scenario.await_client_frame(conn)
    end

    test "audio EOS flushes the cache with audioStreamEnd without ending the output" do
      {pipeline, conn, _setup} = start!(:raw)

      eos(pipeline, :audio_src)

      assert %{"realtimeInput" => %{"audioStreamEnd" => true}} =
               Scenario.await_client_frame(conn)

      # Text input is still open, so no EOS is propagated downstream
      refute_receive {Membrane.Testing.Pipeline, ^pipeline,
                      {:handle_child_notification, {{:end_of_stream, _pad}, :sink}}},
                     200
    end
  end

  describe "response handling (raw mode)" do
    test "a full turn produces the exact event/buffer sequence" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "hi")
      assert %{"realtimeInput" => %{"text" => "hi"}} = Scenario.await_client_frame(conn)

      pcm = :binary.copy(<<7, 7>>, 240)

      Scenario.push(conn, [
        Frames.thinking("pondering"),
        Frames.audio(pcm),
        Frames.output_transcription("response text"),
        Frames.generation_complete()
      ])

      assert {:event, %Events.ResponseStart{}} = pop_sink_payload(pipeline)
      assert {:event, %Events.Thinking{text: "pondering"}} = pop_sink_payload(pipeline)
      assert {:buffer, %Buffer{payload: ^pcm}} = pop_sink_payload(pipeline)

      assert {:event, %Events.Transcript{audio_origin: :server, text: "response text"}} =
               pop_sink_payload(pipeline)

      assert {:event, %Events.ResponseEnd{interrupted?: false}} = pop_sink_payload(pipeline)

      # Raw mode completes on generationComplete; turnComplete is ignored
      Scenario.push(conn, Frames.turn_complete())
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 200)
    end

    test "input transcriptions pass through as client transcripts" do
      {pipeline, conn, _setup} = start!(:raw)

      push_audio(pipeline, <<0, 0, 0, 0>>)
      assert %{"realtimeInput" => %{"audio" => _blob}} = Scenario.await_client_frame(conn)

      Scenario.push(conn, Frames.input_transcription("user said this"))

      assert_sink_event(pipeline, :sink, %Events.Transcript{
        audio_origin: :client,
        text: "user said this"
      })
    end

    test "consecutive turns complete independently" do
      {pipeline, conn, _setup} = start!(:raw)

      complete_turn(pipeline, conn, "first prompt")
      complete_turn(pipeline, conn, "second prompt")

      refute_receive {Membrane.Testing.Pipeline, ^pipeline,
                      {:handle_child_notification, {{:end_of_stream, _pad}, :sink}}},
                     100
    end

    test "second prompt sent before generation starts yields two clean responses" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "first")
      push_text(pipeline, "second")
      assert %{"realtimeInput" => %{"text" => "first"}} = Scenario.await_client_frame(conn)
      assert %{"realtimeInput" => %{"text" => "second"}} = Scenario.await_client_frame(conn)

      for _turn <- 1..2 do
        Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
        assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
        assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
      end

      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)
    end

    test "usageMetadata-only frames are consumed silently" do
      {pipeline, conn, _setup} = start!(:raw)

      Scenario.push(conn, Frames.usage_metadata(%{"totalTokenCount" => 5}))

      # No response-related activity, and the endpoint keeps working
      refute_sink_event(pipeline, :sink, %Events.ResponseStart{}, 100)
      complete_turn(pipeline, conn, "still fine?")
    end

    test "unrecognised frames are logged and do not break the session" do
      {pipeline, conn, _setup} = start!(:raw)

      log =
        capture_log(fn ->
          Scenario.push(conn, %{"bogus" => %{"such" => "frame"}})
          complete_turn(pipeline, conn, "still fine?")
        end)

      assert log =~ "Unrecognised message"
    end
  end

  describe "interruptions" do
    test "server interruption ends the response and mutes it until generation completes" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)

      Scenario.push(conn, [Frames.thinking("t"), Frames.audio_of_ms(10)])
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

      Scenario.push(conn, Frames.interrupted())
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: true})

      # Remaining output of the interrupted response is suppressed
      late_pcm = :binary.copy(<<9, 9>>, 100)
      Scenario.push(conn, [Frames.audio(late_pcm), Frames.output_transcription("late")])
      refute_sink_buffer(pipeline, :sink, %Buffer{payload: ^late_pcm}, 200)
      refute_sink_event(pipeline, :sink, %Events.Transcript{audio_origin: :server}, 100)

      # generationComplete of the aborted turn emits nothing but unblocks the endpoint
      Scenario.push(conn, Frames.generation_complete())
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)

      complete_turn(pipeline, conn, "next prompt")
    end

    test "text barge-in while receiving interrupts the response client-side" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)

      Scenario.push(conn, Frames.thinking("t"))
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

      # Interrupted immediately on sending the text, before any server frame
      push_text(pipeline, "barge-in")
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: true})
      assert %{"realtimeInput" => %{"text" => "barge-in"}} = Scenario.await_client_frame(conn)

      # The server-side interruption of the aborted turn adds no second ResponseEnd,
      # and its remaining output is dropped
      late_pcm = :binary.copy(<<9, 9>>, 100)
      Scenario.push(conn, [Frames.interrupted(), Frames.audio(late_pcm)])
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 200)
      refute_sink_buffer(pipeline, :sink, %Buffer{payload: ^late_pcm}, 100)

      # Response to the barge-in prompt completes cleanly
      Scenario.push(conn, Frames.generation_complete())
      Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
    end
  end

  describe "completion semantics" do
    test "paced mode completes on turnComplete, not generationComplete" do
      {pipeline, conn, _setup} = start!(:paced)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)

      Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 300)

      Scenario.push(conn, Frames.turn_complete())
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
    end

    test "paced mode ignores a stray turnComplete between responses" do
      {pipeline, conn, _setup} = start!(:paced)

      Scenario.push(conn, Frames.turn_complete())
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 200)

      # And the endpoint still handles the next turn
      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)
      Scenario.push(conn, [Frames.audio_of_ms(10), Frames.turn_complete()])
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
    end
  end

  describe "session restarts" do
    test "goAway restarts the session with the previously received resume handle" do
      {pipeline, conn, _setup} = start!(:raw)

      Scenario.push(conn, [Frames.resumption_update("resume-h1"), Frames.go_away("10s")])

      {conn2, setup2} = await_restarted_connection()
      assert setup2["sessionResumption"] == %{"handle" => "resume-h1"}
      Scenario.await_close(conn)

      # Conversation continues on the new connection
      complete_turn(pipeline, conn2, "still there?")
    end

    test "goAway without a resume handle restarts the session from scratch" do
      {pipeline, conn, _setup} = start!(:raw)

      Scenario.push(conn, Frames.go_away("10s"))

      {conn2, setup2} = await_restarted_connection()
      assert setup2["sessionResumption"] == %{}
      Scenario.await_close(conn)

      complete_turn(pipeline, conn2, "still there?")
    end

    test "reset_session during a response emits an interrupted ResponseEnd and reconnects" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)
      Scenario.push(conn, Frames.thinking("t"))
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

      reset_session(pipeline)
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: true})

      {conn2, _setup2} = await_restarted_connection()
      Scenario.await_close(conn)

      complete_turn(pipeline, conn2, "fresh session")
    end

    test "reset_session in standby reconnects silently" do
      {pipeline, conn, _setup} = start!(:raw)

      complete_turn(pipeline, conn, "prompt")

      reset_session(pipeline)
      {conn2, _setup2} = await_restarted_connection()
      Scenario.await_close(conn)

      refute_sink_event(pipeline, :sink, %Events.ResponseStart{}, 100)
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)

      complete_turn(pipeline, conn2, "fresh session")
    end

    test "reset_session after a prompt but before any response emits no events" do
      # Documents current behaviour: in the :text_sent state the reset produces
      # no ResponseStart/ResponseEnd, and EOS still propagates afterwards
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => %{"text" => "prompt"}} = Scenario.await_client_frame(conn)

      reset_session(pipeline)
      {conn2, _setup2} = await_restarted_connection()
      Scenario.await_close(conn)

      refute_sink_event(pipeline, :sink, %Events.ResponseStart{}, 100)
      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)

      eos(pipeline, :audio_src)

      assert %{"realtimeInput" => %{"audioStreamEnd" => true}} =
               Scenario.await_client_frame(conn2)

      eos(pipeline, :text_src)
      assert_end_of_stream(pipeline, :sink)
    end

    test "reset_session after audio-only input reconnects silently" do
      # Audio input does not change the endpoint status, so this resets in :standby
      {pipeline, conn, _setup} = start!(:raw)

      push_audio(pipeline, <<0, 0, 0, 0>>)
      assert %{"realtimeInput" => %{"audio" => _blob}} = Scenario.await_client_frame(conn)

      reset_session(pipeline)
      {conn2, _setup2} = await_restarted_connection()
      Scenario.await_close(conn)

      refute_sink_event(pipeline, :sink, %Events.ResponseEnd{}, 100)

      complete_turn(pipeline, conn2, "fresh session")
    end
  end

  describe "end of stream" do
    test "EOS on both inputs closes the session and propagates downstream" do
      {pipeline, conn, _setup} = start!(:raw)

      complete_turn(pipeline, conn, "prompt")

      eos(pipeline, :audio_src)
      assert %{"realtimeInput" => %{"audioStreamEnd" => true}} = Scenario.await_client_frame(conn)

      eos(pipeline, :text_src)
      assert_end_of_stream(pipeline, :sink)
      Scenario.await_close(conn)
    end

    test "EOS during a response is deferred until the turn completes" do
      {pipeline, conn, _setup} = start!(:raw)

      push_text(pipeline, "prompt")
      assert %{"realtimeInput" => _input} = Scenario.await_client_frame(conn)
      Scenario.push(conn, Frames.thinking("t"))
      assert_sink_event(pipeline, :sink, %Events.ResponseStart{})

      eos(pipeline, :audio_src)
      assert %{"realtimeInput" => %{"audioStreamEnd" => true}} = Scenario.await_client_frame(conn)
      eos(pipeline, :text_src)

      refute_receive {Membrane.Testing.Pipeline, ^pipeline,
                      {:handle_child_notification, {{:end_of_stream, _pad}, :sink}}},
                     200

      Scenario.push(conn, [Frames.audio_of_ms(10), Frames.generation_complete()])
      assert_sink_event(pipeline, :sink, %Events.ResponseEnd{interrupted?: false})
      assert_end_of_stream(pipeline, :sink)
      Scenario.await_close(conn)
    end
  end
end
