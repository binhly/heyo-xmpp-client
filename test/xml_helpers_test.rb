require "test_helper"

class XmlHelpersTest < Minitest::Test
  class Helper
    include Xmpp::XmlHelpers
  end

  def setup
    @h = Helper.new
  end

  def test_escape_text_escapes_special_chars
    assert_equal "a&amp;b&lt;c&gt;d", @h.escape_text("a&b<c>d")
  end

  def test_escape_text_handles_nil_and_non_strings
    assert_equal "", @h.escape_text(nil)
    assert_equal "42", @h.escape_text(42)
  end

  def test_escape_attr_also_escapes_quotes
    assert_equal "&apos;&quot;&amp;", @h.escape_attr("'\"&")
  end

  def test_text_to_i_empty_is_zero
    assert_equal 0, @h.text_to_i(nil)
    assert_equal 0, @h.text_to_i("")
    assert_equal 7, @h.text_to_i("7")
  end

  def test_raise_iq_error_uses_server_text
    doc = REXML::Document.new("<iq type='error'><error><text>Token expired</text></error></iq>")
    err = assert_raises(Xmpp::Error) { @h.raise_iq_error(doc.root, "fallback") }
    assert_equal "Token expired", err.message
  end

  def test_raise_iq_error_falls_back
    doc = REXML::Document.new("<iq type='error'/>")
    err = assert_raises(Xmpp::Error) { @h.raise_iq_error(doc.root, "fallback msg") }
    assert_equal "fallback msg", err.message
  end

  def test_emit_callbacks_isolates_failures
    calls = []
    callbacks = Hash.new { |h, k| h[k] = [] }
    callbacks[:ev] << proc { raise "boom" }
    callbacks[:ev] << proc { calls << :ok }

    @h.emit_callbacks(callbacks, :ev, nil)

    assert_equal [:ok], calls
  end
end
