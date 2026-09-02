module Xmpp
  # Base class for errors raised by the client (timeouts, protocol
  # failures, authentication problems).
  class Error < StandardError; end
end

module Xmpp
  module XmlHelpers
    # The XML namespace used for the stream itself (RFC 6120).
    StreamNamespace = "http://etherx.jabber.org/streams"
    # The namespace used for STARTTLS negotiation (RFC 6120).
    StartTlsNamespace = "urn:ietf:params:xml:ns:xmpp-tls"

    def escape_text(text)
      text.to_s
          .gsub("&", "&amp;")
          .gsub("<", "&lt;")
          .gsub(">", "&gt;")
    end

    def escape_attr(text)
      escape_text(text).gsub("'", "&apos;").gsub('"', "&quot;")
    end

    def text_to_i(text)
      text.to_s.empty? ? 0 : text.to_i
    end

    def child_by_name(parent, name)
      parent&.elements&.each do |element|
        return element if element.name == name
      end
      nil
    end

    def child_text(parent, name)
      child_by_name(parent, name)&.text
    end

    # True when +element+ resolves to +namespace+. Uses REXML's effective
    # namespace resolution (which accounts for inherited default namespaces)
    # rather than the raw xml: xmlns attribute, so stanzas that inherit a
    # default namespace instead of redeclaring it on every child are matched
    # correctly.
    def namespaced?(element, namespace)
      element.namespace == namespace
    end

    # Extract the server-supplied <error><text> message from an error IQ,
    # falling back to +fallback+ when absent.
    def iq_error_message(iq, fallback)
      error = iq&.elements&.[]("error")
      return fallback unless error
      error.elements["text"]&.text || fallback
    end

    def raise_iq_error(iq, fallback)
      raise Xmpp::Error, iq_error_message(iq, fallback)
    end

    # Run each callback registered for +event+, isolating failures so a
    # misbehaving listener cannot stop sibling listeners or the caller.
    def emit_callbacks(callbacks, event, payload)
      Array(callbacks[event]).each do |cb|
        begin
          cb.call(payload)
        rescue StandardError => e
          # per-callback isolation: a misbehaving listener must not
          # stop sibling listeners or the parser thread.
          warn("XMPP plugin callback #{event} error: #{e.class}: #{e.message}")
        end
      end
    end

    def warn(message)
      Kernel.warn(message)
    end
  end
end
