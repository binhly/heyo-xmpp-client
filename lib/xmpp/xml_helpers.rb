module Xmpp
  module XmlHelpers
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
  end
end
